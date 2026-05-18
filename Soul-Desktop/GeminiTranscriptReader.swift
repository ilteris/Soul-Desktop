import Foundation

/// Reads a Gemini-CLI chat transcript (`.jsonl` shape) into ThreadItems for
/// read-only display under SOUL-SOUL_DESKTOP-043 (read-first session open).
///
/// Source: `~/.gemini/tmp/<projectKey>/chats/session-<YYYY-MM-DDTHH-mm>-<short>.jsonl`
///
/// File layout:
///   - First line: `{ "sessionId": "<uuid>", "projectHash": "...", "startTime": "...", "kind": "main" }`
///   - Subsequent lines: either a message record (`type: "user" | "gemini"`)
///     or a `$set` mutation that updates session metadata (skipped here).
///
/// Message shapes we render:
///   - user:   `{ id, timestamp, type: "user", content: [{text}] }`
///   - gemini: `{ id, timestamp, type: "gemini", content: "<string>", toolCalls?: [{id, name, args, result}] }`
///
/// We surface user text → `.userMessage`, gemini text → `.agentMessage`, and
/// each `toolCalls` entry → `.toolCall`. The `result` field on a toolCall is
/// the file content / shell output Gemini received back; we don't render it
/// inline (matches ClaudeTranscriptReader which also skips tool_result).
enum GeminiTranscriptReader {
    /// Resolve to a ThreadItem list, or nil if we couldn't find / parse the
    /// transcript. We scan the project's chats dir for the file whose first-
    /// line `sessionId` matches `sid` — Gemini-CLI's filenames include only
    /// a short hex suffix, not the full UUID, so a directory glob is needed.
    static func transcript(forSession sid: String, projectKey: String) -> [ThreadItem]? {
        SoulSignposts.interval("GeminiTranscriptReader.transcript", id: sid) {
            _transcript(forSession: sid, projectKey: projectKey)
        }
    }

    private static func _transcript(forSession sid: String, projectKey: String) -> [ThreadItem]? {
        guard let url = locateTranscript(sessionId: sid, projectKey: projectKey) else { return nil }

        var items: [ThreadItem] = []

        // SOUL-SOUL_DESKTOP-161: stream lines instead of slurping the whole
        // file. Gemini-CLI's snapshot-per-mutation chat format duplicates
        // cumulative tool-result content across every record; a single big
        // tool result (e.g., 30 MB git diff) turns into multi-GB chat files
        // over a long session. `String(contentsOf:)` on the 2.17 GB file
        // observed in the wild aborted the app with malloc failure on click.
        let stats = enumerateJSONLines(atPath: url.path) { data in
            guard let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // Skip mutation records (`{"$set": {...}}`) and the first-line
            // metadata (which has no `type` field).
            guard let type = rec["type"] as? String else { return }
            let ts = parseTimestamp(rec["timestamp"] as? String) ?? Date.distantPast

            switch type {
            case "user":
                let blocks = rec["content"] as? [[String: Any]] ?? []
                let raw = blocks
                    .compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Gemini-CLI auto-expands `@<path>` references by inlining
                // the resolved file content under a `--- Content from
                // referenced files ---` marker. The expansion bloats the
                // user bubble (the screenshot showed a 60KB JSON dump in
                // a one-line user prompt). Strip from the marker to EOF
                // so the bubble shows what the user actually typed —
                // `@<path>` chips stay clickable via the path linkifier
                // in MarkdownView, no information lost.
                let text = stripGeminiReferencedFileBlock(raw)
                if !text.isEmpty {
                    items.append(.userMessage(id: UUID(), text: text, timestamp: ts))
                }

            case "gemini":
                // Gemini turns can contain both text and tool calls in any
                // order. Flush text first, then each tool call as its own
                // card — matches how Claude's interleaved tool_use renders.
                if let content = rec["content"] as? String {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        items.append(.agentMessage(id: UUID(), text: trimmed, complete: true, timestamp: ts))
                    }
                }
                if let toolCalls = rec["toolCalls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let name = (call["name"] as? String) ?? "tool"
                        let args = (call["args"] as? [String: Any]) ?? [:]
                        let (title, location) = describe(tool: name, args: args)
                        let details = extractDetails(tool: name, args: args)
                        items.append(.toolCall(
                            id: UUID(),
                            kind: kindForTool(name),
                            title: title,
                            status: "completed",
                            locationHint: location,
                            details: details
                        ))
                    }
                }

            default:
                return
            }
        }

        // Bloat affordance: surface oversized-line counts at the top of the
        // transcript so the user knows the chat file is duplicating tool
        // results (root cause is upstream gemini-cli chatRecordingService;
        // patched locally as of 2026-05-18, but pre-patch sessions show
        // their accumulated history here).
        if stats.warnedCount > 0 || stats.skippedCount > 0 {
            let mb = Double(stats.largestLineBytes) / 1_048_576.0
            let mbStr = String(format: "%.1f", mb)
            let parts: [String] = [
                stats.skippedCount > 0
                    ? "\(stats.skippedCount) line\(stats.skippedCount == 1 ? "" : "s") skipped (too large to parse)"
                    : nil,
                stats.warnedCount > 0
                    ? "\(stats.warnedCount) line\(stats.warnedCount == 1 ? "" : "s") over 5MB"
                    : nil,
                "largest \(mbStr) MB",
            ].compactMap { $0 }
            let text = "⚠ chat file bloat — " + parts.joined(separator: ", ")
            items.insert(.status(id: UUID(), text: text), at: 0)
        }

        let deduped = dedupAdjacentToolCalls(items)
        return deduped.isEmpty ? nil : deduped
    }

    // MARK: - path resolution

    /// Find a chat file for `sid` in the project's chats dir. Live files
    /// (`*.jsonl`) win; if none match we fall back to `.bak-<epoch>` and
    /// `.corrupt-<epoch>` siblings — those are the snapshots Soul-Desktop
    /// makes before a `session/load` attempt and the quarantine name for a
    /// file gemini-CLI couldn't parse, respectively. Without the fallback,
    /// Replay on a force-quit-corrupted session shows zero agent content
    /// even though the conversation lives on disk verbatim.
    ///
    /// Largest matching file wins among siblings (the live file shrinks to
    /// a stub on some error paths, but the latest `.bak` carries the real
    /// content). First-line `sessionId` still has to equal `sid` so we
    /// never misread a different session's backup into this row.
    private static func locateTranscript(sessionId sid: String, projectKey: String) -> URL? {
        // Walk every basename-collision sibling: `<projectKey>`, `<projectKey>-1`,
        // `<projectKey>-2`, etc. Gemini-CLI files chats under whichever
        // sibling first claimed the cwd basename; ignoring the `-N` variants
        // is the entire reason desktop-spawned gemini sessions kept showing
        // up as "Session is running elsewhere" — the live chat file existed,
        // we just weren't looking in the right dir.
        let geminiBase = (("~/.gemini/tmp" as NSString)).expandingTildeInPath
        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(atPath: geminiBase) else { return nil }
        let candidateDirs = topEntries.filter { $0 == projectKey || $0.hasPrefix("\(projectKey)-") }

        func isChatFile(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            if name.hasSuffix(".jsonl") || name.hasSuffix(".json") { return true }
            if name.contains(".jsonl.bak-") || name.contains(".jsonl.corrupt-") { return true }
            return false
        }
        let shortId = String(sid.prefix(8))

        // Collect every chat-file candidate across all sibling dirs, then
        // pick the largest match. The live file may have been truncated to
        // a stub on a session/new fallback; a `.bak` snapshot in the same
        // dir carries the real content.
        var allCandidates: [URL] = []
        for dir in candidateDirs {
            let chatsDir = "\(geminiBase)/\(dir)/chats"
            let dirURL = URL(fileURLWithPath: chatsDir)
            guard let entries = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            allCandidates.append(contentsOf: entries.filter(isChatFile))
        }

        let prefixMatches = allCandidates.filter { $0.lastPathComponent.contains(shortId) }
        let largestByPrefix = prefixMatches.max(by: { a, b in
            let aSize = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let bSize = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return aSize < bSize
        })
        if let hit = largestByPrefix, firstLineSessionId(at: hit) == sid {
            return hit
        }
        for url in allCandidates {
            if firstLineSessionId(at: url) == sid { return url }
        }
        return nil
    }

    private static func firstLineSessionId(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 512)
        guard let s = String(data: head, encoding: .utf8) else { return nil }
        guard let nlRange = s.range(of: "\n") else { return nil }
        let firstLine = String(s[..<nlRange.lowerBound])
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["sessionId"] as? String
    }

    // MARK: - tool helpers

    private static func kindForTool(_ name: String) -> String {
        // Map gemini-cli tool names to the kind tokens ToolCallRow's icon /
        // styling switches on. Same vocabulary as HooksReader.kindForTool.
        switch name {
        case "read_file", "read_many_files":  return "read"
        case "edit", "write_file", "replace": return "edit"
        case "run_shell_command":             return "execute"
        case "search_file_content", "glob":   return "search"
        case "google_web_search", "web_fetch": return "fetch"
        case "save_memory":                   return "edit"
        default:                              return "execute"
        }
    }

    /// Build a row title + best-effort location string. For path-bearing
    /// tools we surface the path so FileChipRow lights up; for shell, we
    /// prefer Gemini's `description` arg if present, else the raw command.
    private static func describe(tool name: String, args: [String: Any]) -> (title: String, location: String?) {
        switch name {
        case "read_file":
            let p = (args["absolute_path"] as? String) ?? (args["path"] as? String) ?? name
            return (p, p)
        case "edit", "replace":
            let p = (args["file_path"] as? String) ?? (args["path"] as? String) ?? name
            return (p, p)
        case "write_file":
            let p = (args["file_path"] as? String) ?? (args["path"] as? String) ?? name
            return (p, p)
        case "run_shell_command":
            let cmd = (args["command"] as? String) ?? ""
            let desc = (args["description"] as? String) ?? cmd
            return (desc.isEmpty ? cmd : desc, nil)
        case "search_file_content":
            let pattern = (args["pattern"] as? String) ?? ""
            return ("grep \"\(pattern)\"", args["path"] as? String)
        case "glob":
            return ((args["pattern"] as? String) ?? name, nil)
        default:
            let summary = args.values
                .compactMap { $0 as? String }
                .first(where: { !$0.isEmpty }) ?? name
            return (summary.count > 80 ? String(summary.prefix(80)) + "…" : summary, nil)
        }
    }

    /// Pull old_string / new_string (or content) off the args dict so Edit /
    /// Write rows can expand to show the inline diff card.
    private static func extractDetails(tool name: String, args: [String: Any]) -> ToolCallDetails? {
        if let oldS = args["old_string"] as? String,
           let newS = args["new_string"] as? String {
            return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS))
        }
        if name == "write_file", let content = args["content"] as? String {
            return ToolCallDetails(kind: .write(content: content))
        }
        return nil
    }

    /// Strip Gemini-CLI's auto-expanded `@<path>` reference block from a
    /// user prompt. The CLI appends a `--- Content from referenced files
    /// ---` separator followed by the inlined file content; can balloon a
    /// short prompt to tens or hundreds of KB. We only need the typed
    /// portion — the `@<path>` chip stays in the typed portion and remains
    /// clickable via MarkdownView's path linkifier. Defensive: if the
    /// marker is missing, return the original string unchanged.
    static func stripGeminiReferencedFileBlock(_ s: String) -> String {
        // Gemini-CLI's separator varies: sometimes "\n--- …" (single
        // newline before the dashes), sometimes "\n\n--- …", sometimes
        // raw "--- …" when the typed prompt ends without a newline.
        // Match the marker itself and walk back to the preceding newline.
        let marker = "--- Content from referenced files ---"
        guard let r = s.range(of: marker) else { return s }
        var cut = r.lowerBound
        while cut > s.startIndex {
            let prev = s.index(before: cut)
            let ch = s[prev]
            if ch == "\n" || ch == " " || ch == "\t" {
                cut = prev
            } else {
                break
            }
        }
        return String(s[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
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
}
