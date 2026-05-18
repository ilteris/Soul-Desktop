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
/// Hard per-line cap for the streaming transcript readers. Lines over this
/// are dropped — no legitimate transcript line is this big, and parsing one
/// would OOM the process (SOUL-SOUL_DESKTOP-161 incident: Gemini-CLI
/// re-serialized a tool result into a single line, ballooned the chat file
/// to 2.17 GB, and `String(contentsOf:)` aborted on click).
let SoulTranscriptMaxLineBytes: Int = 32 * 1024 * 1024  // 32 MB

/// Soft per-line cap. Lines over this are still parsed (we can handle the
/// memory hit) but counted so the UI can surface a warning — a 5 MB line is
/// almost certainly bloat (cumulative tool-result re-serialization), not
/// real content.
let SoulTranscriptWarnLineBytes: Int = 5 * 1024 * 1024  // 5 MB

/// Stats returned by `enumerateJSONLines` so the caller can surface bloat
/// to the UI without re-walking the file.
struct JSONLineStats {
    var warnedCount: Int = 0       // lines > 5 MB (still parsed)
    var skippedCount: Int = 0      // lines > 32 MB (dropped, parser unsafe)
    var largestLineBytes: Int = 0
}

/// Iterate JSONL lines from `path` without slurping the whole file. Yields
/// each line as `Data` (caller decodes as needed). Lines over
/// `SoulTranscriptMaxLineBytes` are skipped — protects the parser from
/// pathological mega-lines that would OOM the process.
///
/// Reads in 1 MB chunks, accumulates a per-line buffer until a `\n`
/// terminator lands, then yields the line and resets. Bounded memory:
/// O(largest legitimate line) regardless of total file size.
@discardableResult
func enumerateJSONLines(atPath path: String, _ body: (Data) -> Void) -> JSONLineStats {
    var stats = JSONLineStats()
    guard let handle = FileHandle(forReadingAtPath: path) else { return stats }
    defer { try? handle.close() }
    let chunkSize = 1 << 20  // 1 MB
    var buffer = Data()
    buffer.reserveCapacity(chunkSize)
    var skipUntilNewline = false  // set when current line exceeded the cap
    while true {
        let chunk: Data
        do {
            guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
            chunk = next
        } catch { break }
        var start = chunk.startIndex
        while let nl = chunk[start..<chunk.endIndex].firstIndex(of: 0x0A) {
            if skipUntilNewline {
                skipUntilNewline = false
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(chunk[start..<nl])
                let lineBytes = buffer.count
                stats.largestLineBytes = max(stats.largestLineBytes, lineBytes)
                if lineBytes > SoulTranscriptWarnLineBytes {
                    stats.warnedCount += 1
                }
                if !buffer.isEmpty { body(buffer) }
                buffer.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: nl)
        }
        if start < chunk.endIndex {
            if skipUntilNewline { continue }
            let remaining = chunk[start..<chunk.endIndex]
            if buffer.count + remaining.count > SoulTranscriptMaxLineBytes {
                let oversize = buffer.count + remaining.count
                stats.skippedCount += 1
                stats.largestLineBytes = max(stats.largestLineBytes, oversize)
                SoulSignposts.event("TranscriptReader.skipOversizeLine", "bytes=\(oversize)")
                buffer.removeAll(keepingCapacity: true)
                skipUntilNewline = true
            } else {
                buffer.append(remaining)
            }
        }
    }
    // Trailing line without newline
    if !skipUntilNewline, !buffer.isEmpty, buffer.count <= SoulTranscriptMaxLineBytes {
        let lineBytes = buffer.count
        stats.largestLineBytes = max(stats.largestLineBytes, lineBytes)
        if lineBytes > SoulTranscriptWarnLineBytes {
            stats.warnedCount += 1
        }
        body(buffer)
    }
    return stats
}

enum HooksReader {
    static func events(forSession sid: String, project: SoulProject) -> [ReplayEvent] {
        return SoulSignposts.interval("HooksReader.events", id: sid) {
            _events(forSession: sid, project: project)
        }
    }

    private static func _events(forSession sid: String, project: SoulProject) -> [ReplayEvent] {
        let hooks = SoulSignposts.interval("HooksReader.readHooks", id: sid) {
            readHooks(projectKey: project.id, sessionId: sid)
        }
        let prompts = readClaudePrompts(sessionId: sid, cwd: project.path)
        // Gemini sessions: the kernel hooks ledger doesn't carry agent reply
        // text (only prompts + decisions), so without reading the chat file
        // Replay would render the prompts but no responses. The locator
        // falls back to `.bak-*` and `.corrupt-*` siblings if the live file
        // is missing or stubbed.
        let geminiTurns = SoulSignposts.interval("HooksReader.readGeminiTurns", id: sid) {
            readGeminiTurns(sessionId: sid, projectKey: project.id)
        }
        // SOUL-SOUL_DESKTOP-065: recovered agent reply bodies from a
        // stream-time chunk file that survived an abrupt child teardown
        // (the AfterAgent rollup never landed). Skipped per-bubble when
        // hooks.jsonl already has the matching AfterAgent.
        let recoveredAgentTurns = readAgentChunks(
            projectKey: project.id,
            sessionId: sid,
            hooks: hooks
        )

        // Interleave by timestamp. ThreadItem ids are fresh UUIDs per item.
        var merged: [ReplayEvent] = hooks
        merged.append(contentsOf: prompts)
        merged.append(contentsOf: geminiTurns)
        merged.append(contentsOf: recoveredAgentTurns)
        // De-dup user prompts: hooks `UserPrompt` and gemini chat `user`
        // turns describe the same event from two writers. Prefer the gemini
        // version when text matches within 2s, since it carries the full
        // content (hooks sometimes only get the slash-command prefix).
        merged = dedupeUserPrompts(merged)
        merged.sort(by: { (a: ReplayEvent, b: ReplayEvent) -> Bool in
            a.timestamp < b.timestamp
        })
        if merged.isEmpty,
           let finalize = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) {
            let ts = finalize.timestamp ?? Date()
            merged.append(ReplayEvent(
                id: UUID(),
                timestamp: ts,
                item: .finalize(
                    id: UUID(),
                    intent: finalize.intent,
                    summary: finalize.summary,
                    rationale: finalize.rationale,
                    fixed: finalize.fixed,
                    nextStep: finalize.nextStep,
                    timestamp: ts
                )
            ))
        }
        return merged
    }

    /// SOUL-SOUL_DESKTOP-065: stitch any agent_chunks.jsonl entries that
    /// have no corresponding AfterAgent row in the hooks ledger into
    /// synthetic agent message events. The chunk file is the stream-time
    /// capture path; AfterAgent is the end-of-turn rollup. If the rollup
    /// happened the chunks were retired, and this is a no-op. If the
    /// rollup didn't (child crashed / Soul-Desktop force-quit / OS sleep
    /// mid-turn), the chunk file survived and we reconstruct the reply
    /// here so Replay still shows it.
    private static func readAgentChunks(projectKey: String, sessionId: String, hooks: [ReplayEvent]) -> [ReplayEvent] {
        let path = (("~/soul_registry/sessions/\(projectKey)/\(sessionId)/agent_chunks.jsonl" as NSString))
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }

        // Aggregate chunks by bubble id, preserving first-seen timestamp.
        struct Accum { var firstTs: Date; var text: String }
        var byBubble: [String: Accum] = [:]
        var order: [String] = []
        for raw in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bubbleId = obj["bubble_id"] as? String,
                  let chunk = obj["chunk"] as? String
            else { continue }
            let ts = parseTimestamp(obj["ts"] as? String) ?? Date()
            if byBubble[bubbleId] == nil {
                byBubble[bubbleId] = Accum(firstTs: ts, text: chunk)
                order.append(bubbleId)
            } else {
                byBubble[bubbleId]!.text += chunk
            }
        }

        // Skip any bubble whose text already lives in hooks as an AfterAgent.
        // Match by first-256-chars prefix to allow for trailing trace
        // envelopes etc.; close-enough dedupe for the recovery path.
        let afterAgentPrefixes: Set<String> = Set(hooks.compactMap { e in
            if case .agentMessage(_, let text, _, _) = e.item {
                return String(text.prefix(256))
            }
            return nil
        })

        var out: [ReplayEvent] = []
        for bid in order {
            guard let acc = byBubble[bid] else { continue }
            let prefix = String(acc.text.prefix(256))
            if afterAgentPrefixes.contains(prefix) { continue }
            out.append(ReplayEvent(
                id: UUID(),
                timestamp: acc.firstTs,
                item: .agentMessage(id: UUID(), text: acc.text, complete: true, timestamp: acc.firstTs)
            ))
        }
        return out
    }

    private static func readGeminiTurns(sessionId sid: String, projectKey: String) -> [ReplayEvent] {
        guard let items = GeminiTranscriptReader.transcript(forSession: sid, projectKey: projectKey) else {
            return []
        }
        return items.compactMap { item in
            switch item {
            case .userMessage(_, _, let ts):
                return ReplayEvent(id: UUID(), timestamp: ts, item: item)
            case .agentMessage(_, _, _, let ts):
                return ReplayEvent(id: UUID(), timestamp: ts, item: item)
            case .toolCall(_, _, _, _, let location, _):
                // Tool calls from the chat file carry no kernel timestamp;
                // approximate with the nearest message timestamp if needed.
                // For now drop them — they'd land at distantPast and pollute
                // chapter ordering.
                _ = location
                return nil
            default:
                return nil
            }
        }
    }

    /// Remove duplicate user-prompt events that appear in both the hooks
    /// ledger and the gemini chat file. Same text + within 2s = same turn.
    /// Keeps the FIRST occurrence (which, after the sort, will be whichever
    /// timestamp lands earlier). Two-pass: index by normalized text, then
    /// filter.
    private static func dedupeUserPrompts(_ events: [ReplayEvent]) -> [ReplayEvent] {
        var seen: [(text: String, ts: Date)] = []
        var out: [ReplayEvent] = []
        for e in events {
            if case .userMessage(_, let text, let ts) = e.item {
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if seen.contains(where: { $0.text == key && abs($0.ts.timeIntervalSince(ts)) < 2 }) {
                    continue
                }
                seen.append((key, ts))
            }
            out.append(e)
        }
        return out
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
            case "UserPrompt", "UserMessage":
                // Soul-Desktop writes the user's literal prompt into hooks
                // when it owns the session (no terminal-side Claude transcript
                // to read from). Without this case, a gemini session whose
                // only artifact is the kernel hooks ledger replays as empty
                // even though it contains the full prompt log.
                let text = (obj["text"] as? String)
                    ?? (obj["content"] as? String)
                    ?? (obj["prompt"] as? String)
                    ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .userMessage(id: UUID(), text: trimmed, timestamp: ts)
                    ))
                }
            case "CodexApproval":
                let op = obj["op"] as? String ?? "APPROVAL"
                let intent = obj["intent"] as? String ?? "Codex command approval handled"
                out.append(ReplayEvent(
                    id: UUID(),
                    timestamp: ts,
                    item: .status(id: UUID(), text: "⌁ \(op) — \(intent)")
                ))
            case "SESSION_START", "NativeSessionID", "Title":
                continue   // metadata / linkage rows, skip from the timeline
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
