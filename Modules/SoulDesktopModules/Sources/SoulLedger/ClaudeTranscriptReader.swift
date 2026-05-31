import Foundation
import SoulCore

/// Reads a Claude Code session transcript JSONL into ThreadItems for read-only display.
///
/// Source: ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
/// The cwd encoding replaces "/" with "-" (so /Users/ilteris/Code/Foo → -Users-ilteris-Code-Foo).
///
/// We only consume `type: "user"` and `type: "assistant"` records. Other record kinds
/// (system, attachment, permission-mode, file-history-snapshot, ai-title, last-prompt)
/// are skipped — they're internal bookkeeping, not turns.
public enum ClaudeTranscriptReader {
    public static func transcript(forSession sid: String, cwd: String) -> [ThreadItem]? {
        SoulSignposts.interval("ClaudeTranscriptReader.transcript", id: sid) {
            _transcript(forSession: sid, cwd: cwd)
        }
    }

    private static func _transcript(forSession sid: String, cwd: String) -> [ThreadItem]? {
        guard let result = readClaudeTranscriptTurns(sessionId: sid, cwd: cwd) else { return nil }
        let items = result.turns.compactMap(item)
        let deduped = dedupAdjacentToolCalls(items)
        return deduped.isEmpty ? nil : deduped
    }

    // MARK: - helpers

    private static func item(from turn: LedgerTranscriptTurn) -> ThreadItem? {
        switch turn.content {
        case .message(.user, let text, let ts):
            switch LocalCommandClassifier.classify(text) {
            case .skip:
                return nil
            case .status(let inner):
                return .status(id: UUID(), text: inner)
            case .message(let cleaned):
                let stripped = GeminiTranscriptReader.stripGeminiReferencedFileBlock(cleaned)
                let content = sanitizeUserContent(stripped)
                return content.isEmpty ? nil : .userMessage(id: UUID(), text: content, timestamp: ts)
            }
        case .message(.assistant, let text, let ts):
            return .agentMessage(id: UUID(), text: text, complete: true, timestamp: ts)
        case .tool(let tool, _):
            let (title, location) = describe(tool: tool.name, input: tool.arguments)
            return .toolCall(
                id: UUID(),
                kind: tool.name,
                title: title,
                status: "completed",
                locationHint: location,
                details: details(from: tool)
            )
        case .thought, .status:
            return nil
        }
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

    private static func describe(tool name: String, input: [String: LedgerJSONValue]) -> (title: String, location: String?) {
        // Best-effort summaries that match what the live ToolCallRow expects.
        switch name {
        case "Read", "Edit", "Write", "MultiEdit":
            let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? name
            return (path, path)
        case "Bash":
            let cmd = input["command"]?.stringValue ?? ""
            let desc = input["description"]?.stringValue ?? cmd
            return (desc.isEmpty ? cmd : desc, nil)
        case "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            let path = input["path"]?.stringValue
            return ("grep \"\(pattern)\"", path)
        case "Glob":
            let pattern = input["pattern"]?.stringValue ?? ""
            return (pattern, nil)
        default:
            // Generic fallback: first short string-valued key.
            let summary = input.values
                .compactMap(\.stringValue)
                .first(where: { !$0.isEmpty }) ?? name
            return (summary.count > 80 ? String(summary.prefix(80)) + "…" : summary, nil)
        }
    }

    private static func details(from tool: LedgerToolRecord) -> ToolCallDetails? {
        if let oldS = tool.string("old_string"),
           let newS = tool.string("new_string") {
            return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS))
        }
        if let content = tool.string("content") {
            return ToolCallDetails(kind: .write(content: content))
        }
        return nil
    }
}
