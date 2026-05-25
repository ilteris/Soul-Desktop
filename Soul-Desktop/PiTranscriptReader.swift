import Foundation
import SoulLedger

/// Reads a pi-acp session transcript JSONL into ThreadItems for read-only display.
///
/// Source: ~/.pi/agent/sessions/<encoded-cwd>/<ts>_<sessionId>.jsonl
/// Encoding mirrors SessionLoadability.piEncode — drop leading/trailing
/// slashes, join with `-`, surround with `--`
/// (so /Users/ilteris/Code/Foo → `--Users-ilteris-Code-Foo--`).
///
/// Line shapes we consume:
///   - {"type":"session", "id":"<uuid>", ...}                  — header (skipped, sid is in the filename)
///   - {"type":"message", "message": {"role": "user"|"assistant", "content": [...] }}
///       content blocks: {"type":"text","text":"..."}
///                       {"type":"thinking","thinking":"..."}
///                       {"type":"toolCall","id":"...","name":"...","arguments":{...}}
///
/// Tool calls in pi's chat file carry the invocation but not the result —
/// pi-acp emits results out-of-band over ACP `session/update` events. Render
/// the call with `status: "completed"` so the row doesn't look stuck;
/// finalized rows in the kernel ledger will overlay AfterTool content via
/// the existing tool-grouping pipeline if the user expands.
enum PiTranscriptReader {
    static func transcript(forSession sid: String, cwd: String) -> [ThreadItem]? {
        SoulSignposts.interval("PiTranscriptReader.transcript", id: sid) {
            _transcript(forSession: sid, cwd: cwd)
        }
    }

    private static func _transcript(forSession sid: String, cwd: String) -> [ThreadItem]? {
        guard let result = readPiTranscriptTurns(sessionId: sid, cwd: cwd) else { return nil }
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
            return .toolCall(
                id: UUID(),
                kind: tool.name,
                title: toolCallTitle(tool),
                status: "completed",
                locationHint: locationHint(from: tool),
                details: nil
            )
        case .thought(let text, let ts):
            return .agentThought(id: UUID(), text: text, complete: true, timestamp: ts)
        case .status(let text):
            return .status(id: UUID(), text: text)
        }
    }

    private static func toolCallTitle(_ tool: LedgerToolRecord) -> String {
        switch tool.name {
        case "bash":
            if let cmd = tool.string("command") {
                return cmd.split(separator: "\n").first.map(String.init) ?? tool.name
            }
        case "str_replace_editor", "edit", "write":
            if let path = tool.string("path") { return path }
        case "read":
            if let path = tool.string("path") { return path }
        default: break
        }
        return tool.name
    }

    private static func locationHint(from tool: LedgerToolRecord) -> String? {
        tool.string("path") ?? tool.string("file")
    }
}
