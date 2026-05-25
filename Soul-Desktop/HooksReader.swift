import Foundation
import SoulLedger

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
/// SOUL-SOUL_DESKTOP-174: hydrate-time dedup. Mirrors the live-stream
/// dedup in `ThreadController+ACP.insertToolCall` (-170/-172/-173).
/// Transcript files on disk can contain duplicated tool_use blocks
/// when an older Claude Code (pre-v2.1.132 streaming-retry bug) wrote
/// the same logical Edit multiple times. We can't rewrite the
/// transcript, but we can dedup at read time so the canvas shows one
/// row per logical call regardless of how many copies the file holds.
///
/// Collapses consecutive toolCall items with matching
/// `(kind, title, locationHint, lineCount-fingerprint of details)`.
/// Non-toolCall items (user/agent messages, status rows) break the
/// run — only adjacent dups collapse, which keeps a legitimate
/// "Edit-then-Edit-again-later" pair separated by a model reply
/// intact.
/// Collapses repeated toolCall fingerprints within a sliding window.
/// Live repro: a Gemini turn that retries the same Edit-A-then-Edit-B pair
/// many times shows fingerprints like `write|71`, `write|67`, `write|71`,
/// `write|67` … Adjacent-only dedup never matches because A and B keep
/// alternating. A sliding window of 8 toolCalls covers the realistic
/// retry-loop length without collapsing legitimately-distinct edits that
/// happen to share a line count many turns apart.
///
/// Any non-toolCall (user/agent message, status row) clears the window —
/// a turn boundary resets dedup so a separate later turn making the same
/// edit isn't suppressed.
func dedupAdjacentToolCalls(_ items: [ThreadItem]) -> [ThreadItem] {
    var out: [ThreadItem] = []
    out.reserveCapacity(items.count)
    // Sliding window of recently-emitted toolCall fingerprints. FIFO; size
    // capped so the search stays O(1).
    var recentFingerprints: [String] = []
    let windowSize = 8
    var collapsedCount = 0
    for item in items {
        guard case .toolCall(_, let kind, let title, _, let loc, let details) = item else {
            // Don't reset the window on non-toolCall items. Transcript
            // readers interleave tool_result user-records and agent text
            // between consecutive Edits; resetting here meant the window
            // was always empty when the next Edit arrived and dedup never
            // matched (live repro: collapsed=0 on a transcript with 38
            // identical-fingerprint edits). The windowSize cap is the
            // natural decay; we don't need an explicit boundary signal.
            out.append(item)
            continue
        }
        let fingerprint = toolCallFingerprint(kind: kind, title: title, loc: loc, details: details)
        if let fp = fingerprint, recentFingerprints.contains(fp) {
            collapsedCount += 1
            continue
        }
        out.append(item)
        if let fp = fingerprint {
            recentFingerprints.append(fp)
            if recentFingerprints.count > windowSize {
                recentFingerprints.removeFirst()
            }
        }
    }
    return out
}

private func toolCallFingerprint(kind: String, title: String, loc: String?, details: ToolCallDetails?) -> String? {
    // Without details we have no safe way to distinguish two real edits
    // from two duplicates — bail out and let the row through.
    guard let d = details else { return nil }
    let body: String
    switch d.kind {
    case .edit(let oldS, let newS):
        body = "edit|\(transcriptLineCount(oldS))|\(transcriptLineCount(newS))"
    case .write(let content):
        body = "write|\(transcriptLineCount(content))"
    case .output(let text):
        body = "output|\(text.count)"
    case .subagent, .claudeAgent:
        body = "subagent"
    }
    return "\(kind)|\(title)|\(loc ?? "")|\(body)"
}

private func transcriptLineCount(_ s: String) -> Int {
    if s.isEmpty { return 0 }
    var n = s.components(separatedBy: "\n").count
    if s.hasSuffix("\n") { n -= 1 }
    return max(n, 1)
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
        // Gemini sessions: kept for terminal-spawned sessions where Soul-Desktop
        // is not the writer. Desktop-spawned Gemini sessions persist agent
        // reply text to the hooks ledger via `AfterAgent` events (see
        // ThreadController+Turn.swift:244 — SOUL-SOUL_DESKTOP-065). For
        // those, this merge is belt-and-suspenders. For terminal sessions,
        // the chat file is the only source of agent reply text and this is
        // load-bearing. The locator falls back to `.bak-*` and `.corrupt-*`
        // siblings if the live file is missing or stubbed.
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
        let path = "\(SoulRegistry.sessionDir(projectKey: projectKey, sessionId: sessionId))/agent_chunks.jsonl"
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        // Aggregate chunks by bubble id, preserving first-seen timestamp.
        struct Accum { var firstTs: Date; var text: String }
        var byBubble: [String: Accum] = [:]
        var order: [String] = []
        for record in readAgentChunkRecords(atPath: path) {
            let ts = record.timestamp ?? Date()
            if byBubble[record.bubbleId] == nil {
                byBubble[record.bubbleId] = Accum(firstTs: ts, text: record.chunk)
                order.append(record.bubbleId)
            } else {
                byBubble[record.bubbleId]!.text += record.chunk
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
        let path = SoulRegistry.hooksPath(projectKey: projectKey, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let records = readLedgerReplayRecords(atPath: path)

        var out: [ReplayEvent] = []
        for record in records {
            let ts = record.timestamp

            switch record.kind {
            case .afterTool(let payload):
                if let item = toolItem(from: payload) {
                    let target = payload.target.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isPath = target.hasPrefix("/") || target.hasPrefix("~")
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: item,
                        rationale: payload.rationale,
                        reward: payload.reward,
                        toolName: payload.tool.isEmpty ? nil : payload.tool,
                        target: isPath ? target : nil
                    ))
                }
            case .afterAgent(let payload):
                let content = payload.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .agentMessage(id: UUID(), text: content, complete: true, timestamp: ts),
                        rationale: nil,
                        reward: payload.reward
                    ))
                }
            case .userPrompt(let payload):
                // Soul-Desktop writes the user's literal prompt into hooks
                // when it owns the session (no terminal-side Claude transcript
                // to read from). Without this case, a gemini session whose
                // only artifact is the kernel hooks ledger replays as empty
                // even though it contains the full prompt log.
                let trimmed = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .userMessage(id: UUID(), text: trimmed, timestamp: ts)
                    ))
                }
            case .branchSummary(let payload):
                let trimmed = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let source = Provider(rawValue: payload.fromProvider ?? "") ?? .claude
                    let target = Provider(rawValue: payload.toProvider ?? "") ?? .geminiCLI
                    out.append(ReplayEvent(
                        id: UUID(),
                        timestamp: ts,
                        item: .branchSummary(
                            id: UUID(),
                            summary: trimmed,
                            sourceProvider: source,
                            targetProvider: target,
                            timestamp: ts
                        )
                    ))
                }
            case .delegationStarted(let payload, let completed):
                if let item = delegationItem(from: payload, completed: completed) {
                    out.append(ReplayEvent(id: UUID(), timestamp: ts, item: item))
                }
            case .codexApproval(let payload):
                out.append(ReplayEvent(
                    id: UUID(),
                    timestamp: ts,
                    item: .status(id: UUID(), text: "⌁ \(payload.op) — \(payload.intent)")
                ))
            case .decision(let payload):
                // Decision events (op/intent/target) and unknowns — render as a
                // status row so the timeline shows them but they don't dominate.
                let text = "⌁ \(payload.op) — \(payload.intent)"
                out.append(ReplayEvent(
                    id: UUID(),
                    timestamp: ts,
                    item: .status(id: UUID(), text: text)
                ))
            }
        }
        return out
    }

    private static func delegationItem(
        from payload: LedgerDelegationStartedPayload,
        completed: LedgerDelegationCompletedPayload?
    ) -> ThreadItem? {
        let delegationId = payload.delegationId
        let specialist = payload.specialist
        let objective = payload.objective
        guard !delegationId.isEmpty else { return nil }

        let status: String = {
            switch completed?.event {
            case "DelegationCompleted": return "completed"
            case "DelegationFailed": return "failed"
            default: return "in_progress"
            }
        }()
        let findingPath = completed?.findingPath ?? payload.findingPath
        let colorHex = parseHexColor(completed?.color ?? payload.color)
        let title = "@\(specialist)"

        return .toolCall(
            id: UUID(),
            kind: "delegate",
            title: title,
            status: status,
            locationHint: objective,
            details: ToolCallDetails(
                kind: .subagent(
                    specialist: specialist,
                    objective: objective,
                    subagentId: delegationId,
                    colorHex: colorHex,
                    findingPath: findingPath
                )
            )
        )
    }

    private static func parseHexColor(_ raw: String?) -> UInt32? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("#") { raw.removeFirst() }
        return UInt32(raw, radix: 16)
    }

    private static func toolItem(from payload: LedgerAfterToolPayload) -> ThreadItem? {
        let target = payload.target
        let rationale = payload.rationale?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let kind = kindForTool(payload.tool)
        let title = !rationale.isEmpty ? rationale : (target.isEmpty ? payload.tool : target)
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
}
