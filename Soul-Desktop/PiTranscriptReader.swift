import Foundation

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
        guard let path = locate(sessionId: sid, cwd: cwd) else { return nil }

        var items: [ThreadItem] = []
        var pendingAgentText: (id: UUID, text: String, ts: Date)? = nil

        // SOUL-SOUL_DESKTOP-161: stream lines + per-line cap — see
        // GeminiTranscriptReader for context.
        enumerateJSONLines(atPath: path) { data in
            guard let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            guard (rec["type"] as? String) == "message",
                  let msg = rec["message"] as? [String: Any],
                  let role = msg["role"] as? String,
                  let blocks = msg["content"] as? [[String: Any]]
            else { return }

            let ts = parseTimestamp(rec["timestamp"] as? String) ?? Date.distantPast

            for block in blocks {
                let kind = block["type"] as? String
                switch kind {
                case "text":
                    let text = (block["text"] as? String) ?? ""
                    if text.isEmpty { continue }
                    if role == "user" {
                        flushAgent(&items, pending: &pendingAgentText)
                        items.append(.userMessage(id: UUID(), text: text, timestamp: ts))
                    } else if role == "assistant" {
                        if pendingAgentText == nil {
                            pendingAgentText = (UUID(), text, ts)
                        } else {
                            pendingAgentText?.text += text
                        }
                    }
                case "toolCall":
                    flushAgent(&items, pending: &pendingAgentText)
                    let name = (block["name"] as? String) ?? "tool"
                    let args = block["arguments"] as? [String: Any]
                    let title = toolCallTitle(name: name, args: args)
                    items.append(.toolCall(
                        id: UUID(),
                        kind: name,
                        title: title,
                        status: "completed",
                        locationHint: locationHint(from: args),
                        details: nil
                    ))
                case "thinking":
                    // Use the dedicated agentThought item — matches the live
                    // `agent_thought_chunk` ACP path which renders as a muted,
                    // italic, collapsible block. Keeps the full text (not a
                    // truncated preview) so expanding gives the user the real
                    // reasoning trace.
                    let text = (block["thinking"] as? String) ?? ""
                    if !text.isEmpty {
                        flushAgent(&items, pending: &pendingAgentText)
                        items.append(.agentThought(id: UUID(), text: text, complete: true, timestamp: ts))
                    }
                default:
                    continue
                }
            }
        }
        flushAgent(&items, pending: &pendingAgentText)
        let deduped = dedupAdjacentToolCalls(items)
        return deduped.isEmpty ? nil : deduped
    }

    /// Pi files sessions under `~/.pi/agent/sessions/<encoded-cwd>/<ts>_<sid>.jsonl`.
    /// Scan the encoded-cwd dir for a filename ending in `_<sid>.jsonl`.
    private static func locate(sessionId sid: String, cwd: String) -> String? {
        let encoded = piEncode(cwd: cwd)
        guard !encoded.isEmpty else { return nil }
        let dir = "\(NSHomeDirectory())/.pi/agent/sessions/\(encoded)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for name in entries where name.hasSuffix("_\(sid).jsonl") {
            return "\(dir)/\(name)"
        }
        return nil
    }

    private static func piEncode(cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        return "--" + parts.joined(separator: "-") + "--"
    }

    private static func flushAgent(_ items: inout [ThreadItem], pending: inout (id: UUID, text: String, ts: Date)?) {
        guard let p = pending else { return }
        items.append(.agentMessage(id: p.id, text: p.text, complete: true, timestamp: p.ts))
        pending = nil
    }

    private static func toolCallTitle(name: String, args: [String: Any]?) -> String {
        switch name {
        case "bash":
            if let cmd = args?["command"] as? String {
                return cmd.split(separator: "\n").first.map(String.init) ?? name
            }
        case "str_replace_editor", "edit", "write":
            if let path = args?["path"] as? String { return path }
        case "read":
            if let path = args?["path"] as? String { return path }
        default: break
        }
        return name
    }

    private static func locationHint(from args: [String: Any]?) -> String? {
        if let path = args?["path"] as? String { return path }
        if let file = args?["file"] as? String { return file }
        return nil
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
