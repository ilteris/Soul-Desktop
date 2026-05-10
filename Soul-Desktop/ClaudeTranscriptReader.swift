import Foundation

/// Reads a Claude Code session transcript JSONL into ThreadItems for read-only display.
///
/// Source: ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
/// The cwd encoding replaces "/" with "-" (so /Users/ilteris/Code/Foo → -Users-ilteris-Code-Foo).
///
/// We only consume `type: "user"` and `type: "assistant"` records. Other record kinds
/// (system, attachment, permission-mode, file-history-snapshot, ai-title, last-prompt)
/// are skipped — they're internal bookkeeping, not turns.
enum ClaudeTranscriptReader {
    static func transcript(forSession sid: String, cwd: String) -> [ThreadItem]? {
        let encoded = encodeCwd(cwd)
        let path = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sid).jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        var items: [ThreadItem] = []
        var pendingAgentText: (id: UUID, text: String, ts: Date)? = nil

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = rec["type"] as? String
            let ts = parseTimestamp(rec["timestamp"] as? String) ?? Date.distantPast

            switch type {
            case "user":
                // Flush any pending assistant text first.
                flush(&items, pending: &pendingAgentText)

                let msg = rec["message"] as? [String: Any]
                if let raw = msg?["content"] as? String, !raw.isEmpty {
                    let content = sanitizeUserContent(raw)
                    if !content.isEmpty {
                        items.append(.userMessage(id: UUID(), text: content, timestamp: ts))
                    }
                }
                // user records with list content are tool_results — skip; they're already
                // implied by the preceding tool_use card and the agent's follow-up text.

            case "assistant":
                let msg = rec["message"] as? [String: Any]
                guard let blocks = msg?["content"] as? [[String: Any]] else { continue }

                for blk in blocks {
                    let kind = blk["type"] as? String
                    switch kind {
                    case "text":
                        let text = (blk["text"] as? String) ?? ""
                        if text.isEmpty { continue }
                        if var pending = pendingAgentText {
                            pending.text += text
                            pendingAgentText = pending
                        } else {
                            pendingAgentText = (UUID(), text, ts)
                        }

                    case "tool_use":
                        flush(&items, pending: &pendingAgentText)
                        let name = (blk["name"] as? String) ?? "tool"
                        let input = (blk["input"] as? [String: Any]) ?? [:]
                        let (title, location) = describe(tool: name, input: input)
                        items.append(.toolCall(
                            id: UUID(),
                            kind: name,
                            title: title,
                            status: "completed",
                            locationHint: location
                        ))

                    case "thinking":
                        // Skip — historical thinking blocks would clutter the view.
                        continue

                    default:
                        continue
                    }
                }

            default:
                continue
            }
        }

        flush(&items, pending: &pendingAgentText)
        return items.isEmpty ? nil : items
    }

    // MARK: - helpers

    private static func flush(_ items: inout [ThreadItem],
                              pending: inout (id: UUID, text: String, ts: Date)?) {
        guard let p = pending else { return }
        items.append(.agentMessage(id: p.id, text: p.text, complete: true, timestamp: p.ts))
        pending = nil
    }

    /// Slash-command invocations land in the transcript as scaffolded XML:
    ///   <command-message>args</command-message><command-name>/cmd</command-name>
    /// We strip the tags and surface just `/cmd args` so the bubble reads as
    /// what the user actually typed.
    private static func sanitizeUserContent(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = extractTag(s, "command-name") {
            let args = extractTag(s, "command-message")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Claude duplicates the command name into <command-message> when
            // the user invokes the command without arguments, so drop it.
            let bareName = name.hasPrefix("/") ? String(name.dropFirst()) : name
            if args.isEmpty || args == bareName || args == name {
                return name
            }
            return "\(name) \(args)"
        }
        return raw
    }

    private static func extractTag(_ s: String, _ tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let o = s.range(of: open),
              let c = s.range(of: close, range: o.upperBound..<s.endIndex)
        else { return nil }
        return String(s[o.upperBound..<c.lowerBound])
    }

    private static func encodeCwd(_ cwd: String) -> String {
        // Claude's projects/ subdirectory uses "-" as the separator for the absolute path.
        // /Users/ilteris/Code/Foo → -Users-ilteris-Code-Foo
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func describe(tool name: String, input: [String: Any]) -> (title: String, location: String?) {
        // Best-effort summaries that match what the live ToolCallRow expects.
        switch name {
        case "Read", "Edit", "Write", "MultiEdit":
            let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? name
            return (path, path)
        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            let desc = (input["description"] as? String) ?? cmd
            return (desc.isEmpty ? cmd : desc, nil)
        case "Grep":
            let pattern = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String)
            return ("grep \"\(pattern)\"", path)
        case "Glob":
            let pattern = (input["pattern"] as? String) ?? ""
            return (pattern, nil)
        default:
            // Generic fallback: first short string-valued key.
            let summary = input.values
                .compactMap { $0 as? String }
                .first(where: { !$0.isEmpty }) ?? name
            return (summary.count > 80 ? String(summary.prefix(80)) + "…" : summary, nil)
        }
    }
}
