import Foundation

/// One event in a session timeline, paired with the timestamp it actually
/// occurred at. The replay controller uses the inter-event gap (curr.ts -
/// prev.ts) to pace playback — so a session that took 8 real minutes plays
/// back in ~2 minutes at 4× compression, preserving natural rhythm
/// (long pauses stay long, fast tool bursts stay fast).
struct ReplayEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let item: ThreadItem
    var rationale: String? = nil   // kernel-side annotation, future surfacing
    var reward: Double? = nil
    /// Tool name + absolute-path target for working-set accumulation.
    /// Both nil for non-file events (agent text, user prompt, status).
    var toolName: String? = nil
    var target: String? = nil
}

/// Merges the Soul kernel's `hooks.jsonl` (tool calls + agent metadata) with
/// the harness's own transcript (user prompts + agent text) into a single
/// timeline sorted by timestamp. This is the same shape soul_view replays
/// against — see kernel/soul_view.py `_merge_with_prompts`.
enum HooksReader {
    static func events(forSession sid: String, project: SoulProject) -> [ReplayEvent] {
        let hooks = readHooks(projectKey: project.id, sessionId: sid)
        let prompts = readClaudePrompts(sessionId: sid, cwd: project.path)

        // Interleave by timestamp. ThreadItem ids are fresh UUIDs per item.
        var merged: [ReplayEvent] = hooks
        merged.append(contentsOf: prompts)
        merged.sort(by: { (a: ReplayEvent, b: ReplayEvent) -> Bool in
            a.timestamp < b.timestamp
        })
        return merged
    }

    // MARK: - hooks.jsonl

    private static func readHooks(projectKey: String, sessionId: String) -> [ReplayEvent] {
        let path = (("~/soul_registry/sessions/\(projectKey)/\(sessionId)/hooks.jsonl" as NSString))
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }

        var out: [ReplayEvent] = []
        for line in blob.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let ts = parseTimestamp(obj["timestamp"] as? String) else { continue }
            let event = (obj["event"] as? String) ?? ""

            switch event {
            case "AfterTool":
                if let item = toolItem(from: obj) {
                    let tool = (obj["tool"] as? String) ?? ""
                    let target = (obj["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let isPath = target.hasPrefix("/") || target.hasPrefix("~")
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: item,
                        rationale: obj["rationale"] as? String,
                        reward: obj["reward"] as? Double,
                        toolName: tool.isEmpty ? nil : tool,
                        target: isPath ? target : nil
                    ))
                }
            case "AfterAgent":
                let content = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !content.isEmpty {
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .agentMessage(id: UUID(), text: content, complete: true, timestamp: ts),
                        rationale: nil,
                        reward: obj["reward"] as? Double
                    ))
                }
            case "SESSION_START":
                continue   // metadata, skip
            default:
                // Decision events (op/intent/target) and unknowns — render as a
                // status row so the timeline shows them but they don't dominate.
                if let op = obj["op"] as? String,
                   let intent = obj["intent"] as? String {
                    let text = "⌁ \(op) — \(intent)"
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .status(id: UUID(), text: text)
                    ))
                }
            }
        }
        return out
    }

    private static func toolItem(from obj: [String: Any]) -> ThreadItem? {
        let tool = (obj["tool"] as? String) ?? "tool"
        let target = (obj["target"] as? String) ?? ""
        let rationale = (obj["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let kind = kindForTool(tool)
        let title = !rationale.isEmpty ? rationale : (target.isEmpty ? tool : target)
        return .toolCall(
            id: UUID(),
            kind: kind,
            title: title,
            status: "completed",
            locationHint: target.isEmpty ? nil : target,
            details: nil
        )
    }

    private static func kindForTool(_ tool: String) -> String {
        switch tool {
        case "Read":                          return "read"
        case "Edit", "Write", "MultiEdit":    return "edit"
        case "Bash", "Shell":                 return "execute"
        case "Grep", "Glob", "Search":        return "search"
        case "WebFetch", "WebSearch":         return "fetch"
        case "Delete":                        return "delete"
        default:                              return "execute"
        }
    }

    // MARK: - Claude transcript (for user prompts)

    /// We only need user prompts from the Claude transcript; agent text comes
    /// from hooks.jsonl AfterAgent so the kernel reward/alignment annotations
    /// stay attached to the same event.
    private static func readClaudePrompts(sessionId: String, cwd: String) -> [ReplayEvent] {
        guard let items = ClaudeTranscriptReader.transcript(forSession: sessionId, cwd: cwd) else {
            return []
        }
        return items.compactMap { item in
            if case .userMessage(_, _, let ts) = item {
                return ReplayEvent(id: UUID(), timestamp: ts, item: item)
            }
            return nil
        }
    }

    // MARK: - helpers

    /// Two timestamp dialects collide here:
    ///   - Claude transcript: "2026-05-05T14:25:58.912Z"           (UTC, Z-suffixed)
    ///   - hooks.jsonl:        "2026-05-05T10:26:05.386439"        (naive local)
    /// We must detect which kind it is before parsing — treating naive as UTC
    /// shifts hooks events by the local offset (4h in May/EDT) and breaks the
    /// merge sort completely.
    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let hasTZ = s.hasSuffix("Z")
            || s.range(of: "[+-]\\d{2}:?\\d{2}$", options: .regularExpression) != nil

        // Strip fractional seconds — DateFormatter handles 3-digit %SSS, not 6.
        // Slice [start, dot) + [tz, end).
        let normalized: String = {
            guard let dot = s.firstIndex(of: ".") else { return s }
            let afterDot = s[dot...]
            // Find where the fractional part ends (any of Z, +, -)
            let tz = afterDot.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
            return String(s[..<dot]) + (tz.map { String(s[$0...]) } ?? "")
        }()

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = hasTZ ? TimeZone(identifier: "UTC")! : TimeZone.current
        // Try a few common shapes:
        for pattern in [
            hasTZ ? "yyyy-MM-dd'T'HH:mm:ssZ" : "yyyy-MM-dd'T'HH:mm:ss",
            hasTZ ? "yyyy-MM-dd'T'HH:mm:ssXXX" : "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: normalized) { return d }
        }
        return nil
    }
}
