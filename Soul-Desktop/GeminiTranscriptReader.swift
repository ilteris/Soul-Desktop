import Foundation
import SoulLedger

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
        guard let result = readGeminiTranscriptTurns(sessionId: sid, projectKey: projectKey) else { return nil }
        let items = result.turns.compactMap(item)
        let deduped = dedupAdjacentToolCalls(items)
        return deduped.isEmpty ? nil : deduped
    }

    private static func item(from turn: LedgerTranscriptTurn) -> ThreadItem? {
        switch turn.content {
        case .message(.user, let text, let ts):
            return .userMessage(id: UUID(), text: text, timestamp: ts)
        case .message(.assistant, let text, let ts):
            return .agentMessage(id: UUID(), text: text, complete: true, timestamp: ts)
        case .tool(let tool, _):
            let (title, location) = describe(tool: tool.name, args: tool.arguments)
            return .toolCall(
                id: UUID(),
                kind: kindForTool(tool.name),
                title: title,
                status: "completed",
                locationHint: location,
                details: extractDetails(tool: tool)
            )
        case .status(let text):
            return .status(id: UUID(), text: text)
        case .thought:
            return nil
        }
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
    private static func describe(tool name: String, args: [String: LedgerJSONValue]) -> (title: String, location: String?) {
        switch name {
        case "read_file":
            let p = args["absolute_path"]?.stringValue ?? args["path"]?.stringValue ?? name
            return (p, p)
        case "edit", "replace":
            let p = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? name
            return (p, p)
        case "write_file":
            let p = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? name
            return (p, p)
        case "run_shell_command":
            let cmd = args["command"]?.stringValue ?? ""
            let desc = args["description"]?.stringValue ?? cmd
            return (desc.isEmpty ? cmd : desc, nil)
        case "search_file_content":
            let pattern = args["pattern"]?.stringValue ?? ""
            return ("grep \"\(pattern)\"", args["path"]?.stringValue)
        case "glob":
            return (args["pattern"]?.stringValue ?? name, nil)
        default:
            let summary = args.values
                .compactMap(\.stringValue)
                .first(where: { !$0.isEmpty }) ?? name
            return (summary.count > 80 ? String(summary.prefix(80)) + "…" : summary, nil)
        }
    }

    /// Pull old_string / new_string (or content) off the args dict so Edit /
    /// Write rows can expand to show the inline diff card.
    private static func extractDetails(tool: LedgerToolRecord) -> ToolCallDetails? {
        if let oldS = tool.string("old_string"),
           let newS = tool.string("new_string") {
            return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS))
        }
        if tool.name == "write_file", let content = tool.string("content") {
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
        stripLedgerGeminiReferencedFileBlock(s)
    }
}
