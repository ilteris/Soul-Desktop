import Foundation
import SoulCore

/// One event in a session timeline, paired with the timestamp it actually
/// occurred at. The replay controller uses the inter-event gap (curr.ts -
/// prev.ts) to pace playback — so a session that took 8 real minutes plays
/// back in ~2 minutes at 4× compression, preserving natural rhythm
/// (long pauses stay long, fast tool bursts stay fast).
public struct ReplayEvent: Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let item: ThreadItem
    public var rationale: String?   // kernel-side annotation, future surfacing
    public var reward: Double?
    /// Tool name + absolute-path target for working-set accumulation.
    /// Both nil for non-file events (agent text, user prompt, status).
    public var toolName: String?
    public var target: String?

    public init(
        id: UUID,
        timestamp: Date,
        item: ThreadItem,
        rationale: String? = nil,
        reward: Double? = nil,
        toolName: String? = nil,
        target: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.item = item
        self.rationale = rationale
        self.reward = reward
        self.toolName = toolName
        self.target = target
    }
}

// MARK: - adjacent tool-call dedup (shared by the transcript readers)

/// Collapses repeated toolCall fingerprints within a sliding window.
/// Live repro: a Gemini turn that retries the same Edit-A-then-Edit-B pair
/// many times shows fingerprints like `write|71`, `write|67`, `write|71`,
/// `write|67` … Adjacent-only dedup never matches because A and B keep
/// alternating. A sliding window of 8 toolCalls covers the realistic
/// retry-loop length without collapsing legitimately-distinct edits that
/// happen to share a line count many turns apart.
func dedupAdjacentToolCalls(_ items: [ThreadItem]) -> [ThreadItem] {
    var out: [ThreadItem] = []
    out.reserveCapacity(items.count)
    var recentFingerprints: [String] = []
    let windowSize = 8
    for item in items {
        guard case .toolCall(_, let kind, let title, _, let loc, let details) = item else {
            // Don't reset the window on non-toolCall items. Transcript
            // readers interleave tool_result user-records and agent text
            // between consecutive Edits; resetting here meant the window
            // was always empty when the next Edit arrived and dedup never
            // matched. The windowSize cap is the natural decay.
            out.append(item)
            continue
        }
        let fingerprint = toolCallFingerprint(kind: kind, title: title, loc: loc, details: details)
        if let fp = fingerprint, recentFingerprints.contains(fp) {
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
    case .patch(let lines):
        body = "patch|\(lines.filter { $0.kind == .removed }.count)|\(lines.filter { $0.kind == .added }.count)"
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

// MARK: - timeline merge

/// Merges the Soul kernel's `hooks.jsonl` (tool calls + agent metadata) with
/// the harness's own transcript (user prompts + agent text) into a single
/// timeline sorted by timestamp. Packageable: callers resolve the on-disk
/// paths (via the app's registry layer) and pass them in, so this stays free
/// of registry/SwiftUI dependencies (SOUL-360). The empty→finalize fallback
/// lives in the app adapter, which owns the registry's finalize lookup.
public enum LedgerReplayMerge {
    public static func merge(
        sessionId sid: String,
        projectKey: String,
        projectPath: String,
        hooksPath: String,
        sessionDir: String
    ) -> [ReplayEvent] {
        SoulSignposts.interval("LedgerReplayMerge.merge", id: sid) {
            let hooks = SoulSignposts.interval("LedgerReplayMerge.readHooks", id: sid) {
                readHooks(hooksPath: hooksPath)
            }
            let prompts = readClaudePrompts(sessionId: sid, cwd: projectPath)
            // Gemini sessions: kept for terminal-spawned sessions where Soul-Desktop
            // is not the writer. For desktop-spawned Gemini this is belt-and-
            // suspenders (agent text also lands in hooks via AfterAgent); for
            // terminal sessions the chat file is the only source of reply text.
            let geminiTurns = SoulSignposts.interval("LedgerReplayMerge.readGeminiTurns", id: sid) {
                readGeminiTurns(sessionId: sid, projectKey: projectKey)
            }
            // Recovered agent reply bodies from a stream-time chunk file that
            // survived an abrupt child teardown (the AfterAgent rollup never
            // landed). Skipped per-bubble when hooks already has the AfterAgent.
            let recoveredAgentTurns = readAgentChunks(sessionDir: sessionDir, hooks: hooks)

            var merged: [ReplayEvent] = hooks
            merged.append(contentsOf: prompts)
            merged.append(contentsOf: geminiTurns)
            merged.append(contentsOf: recoveredAgentTurns)
            // De-dup transcript bubbles written by multiple sources (provider
            // merge + the attached-Codex double-writer case).
            merged = dedupeTranscriptMessages(merged)
            merged.sort(by: { (a: ReplayEvent, b: ReplayEvent) -> Bool in
                a.timestamp < b.timestamp
            })
            return merged
        }
    }

    /// Stitch any agent_chunks.jsonl entries that have no corresponding
    /// AfterAgent row in the hooks ledger into synthetic agent message events.
    private static func readAgentChunks(sessionDir: String, hooks: [ReplayEvent]) -> [ReplayEvent] {
        let path = "\(sessionDir)/agent_chunks.jsonl"
        guard FileManager.default.fileExists(atPath: path) else { return [] }

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
        // envelopes; close-enough dedupe for the recovery path.
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
            case .toolCall:
                // Tool calls from the chat file carry no kernel timestamp; they'd
                // land at distantPast and pollute chapter ordering. Drop them.
                return nil
            default:
                return nil
            }
        }
    }

    /// Remove duplicate transcript events that appear through multiple writers.
    /// Same role + normalized text + close timestamp = same bubble. Keeps the
    /// first occurrence; the small window avoids collapsing a legitimate
    /// repeated "ok" prompt or reply later in the conversation.
    private static func dedupeTranscriptMessages(_ events: [ReplayEvent]) -> [ReplayEvent] {
        var seen: [(role: String, text: String, ts: Date)] = []
        var out: [ReplayEvent] = []
        for e in events {
            let candidate: (role: String, text: String, ts: Date)?
            if case .userMessage(_, let text, let ts) = e.item {
                candidate = ("user", normalizedTranscriptText(text), ts)
            } else if case .agentMessage(_, let text, _, let ts) = e.item {
                candidate = ("agent", normalizedTranscriptText(text), ts)
            } else {
                candidate = nil
            }
            if let candidate, !candidate.text.isEmpty {
                if seen.contains(where: {
                    $0.role == candidate.role
                        && $0.text == candidate.text
                        && abs($0.ts.timeIntervalSince(candidate.ts)) < 2
                }) {
                    continue
                }
                seen.append(candidate)
            }
            out.append(e)
        }
        return out
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - hooks.jsonl

    private static func readHooks(hooksPath path: String) -> [ReplayEvent] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        let records = readLedgerReplayRecords(atPath: path)
        var out: [ReplayEvent] = []
        var currentTurnDelegations: [DelegationContentSanitizerContext] = []
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
                let content = DelegationContentSanitizer.sanitizeAgentText(
                    payload.content,
                    contexts: currentTurnDelegations
                )
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
                currentTurnDelegations.removeAll(keepingCapacity: true)
                // Soul-Desktop writes the user's literal prompt into hooks when
                // it owns the session (no terminal-side Claude transcript). Without
                // this, a gemini session whose only artifact is the kernel hooks
                // ledger replays as empty even though it has the full prompt log.
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
                    let source = AgentProvider(rawValue: payload.fromProvider ?? "") ?? .claude
                    let target = AgentProvider(rawValue: payload.toProvider ?? "") ?? .geminiCLI
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
                currentTurnDelegations.append(delegationContext(from: payload, completed: completed))
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

    private static func delegationContext(
        from payload: LedgerDelegationStartedPayload,
        completed: LedgerDelegationCompletedPayload?
    ) -> DelegationContentSanitizerContext {
        DelegationContentSanitizerContext(
            specialist: payload.specialist,
            delegationId: payload.delegationId,
            findingPath: completed?.findingPath ?? payload.findingPath
        )
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
