import Foundation
import SoulCore
import SoulLedger

/// Stall and per-tool timeout watchdog for a live ThreadController turn.
/// The controller owns UI-visible state, while this file owns polling,
/// timeout classification, and recovery hook emission.
extension ThreadController {

    /// Start a per-turn watchdog. Polls `lastActivityAt` every second while
    /// `isWorking` holds; fires a single StallDetected hook when quiet exceeds
    /// the provider's stall budget, and auto-recovers when quiet exceeds the
    /// hard ceiling. Cheap: one Task, one timer, no observers.
    func startStallWatchdog() {
        stallWatchdog?.cancel()
        stallHookEmittedAt = nil
        lastInProgressToolKind = nil
        let budget = provider.stallBudgetSeconds
        let ceiling = StallPolicy.autoCancelCeilingSeconds
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.tickStallWatchdog(budget: budget, ceiling: ceiling)
            }
        }
    }

    func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        stallHookEmittedAt = nil
        lastInProgressToolKind = nil
        // Drop per-tool-call deadlines at end-of-turn so a stray entry from
        // a never-resolved tool call doesn't leak across turns.
        toolCallStartedAt.removeAll()
        toolCallLastActivityAt.removeAll()
        toolCallTimedOut.removeAll()
        toolCallSignposted.removeAll()
        toolCallPreviousLineCount.removeAll()
    }

    /// One watchdog tick. Runs on @MainActor so it can read `items` /
    /// `isWorking` safely without locks.
    func tickStallWatchdog(budget: Int, ceiling: Int) async {
        guard isWorking else { return }
        let quiet = Int(Date().timeIntervalSince(lastActivityAt))

        // Snapshot the most recent in_progress tool kind for the hook payload.
        // Walking items.reversed() short-circuits on the first match.
        if lastInProgressToolKind == nil {
            for item in items.reversed() {
                if case .toolCall(_, let kind, _, let status, _, _) = item,
                   status == "in_progress" || status == "pending" {
                    lastInProgressToolKind = kind
                    break
                }
            }
        }

        if quiet >= budget && stallHookEmittedAt == nil {
            stallHookEmittedAt = Date()
            ledger.appendHook(
                projectKey: project.id,
                sessionId: sessionId ?? id,
                event: LedgerHookEvent.stallDetected(
                    provider: provider.rawValue,
                    toolKind: lastInProgressToolKind ?? "",
                    stalledSeconds: quiet,
                    threshold: budget
                ).hookDictionary
            )
        }

        if quiet >= ceiling {
            await recoverStalledTurn(source: "auto")
            return
        }

        // SOUL-SOUL_DESKTOP-033: per-tool-call timeout sweep. Independent
        // from the turn-level quiet check — catches the `tail -f` case
        // where a single tool call sits in_progress forever while still
        // emitting enough output to keep `lastActivityAt` fresh.
        let now = Date()
        var expired: [String] = []
        var toSignpost: [(toolId: String, quietFor: Int, threshold: Int)] = []
        // SOUL-SOUL_DESKTOP-079: drive expiry off lastActivityAt, not startedAt.
        for (toolId, lastSeen) in toolCallLastActivityAt where !toolCallTimedOut.contains(toolId) {
            let quietFor = Int(now.timeIntervalSince(lastSeen))
            let toolTimeout = timeoutSeconds(forToolCall: toolId)
            let signpostThreshold = Int(Double(toolTimeout) * StallPolicy.toolCallSignpostFraction)
            if isSubagentToolCall(toolId: toolId) {
                if signpostThreshold > 0,
                   quietFor >= signpostThreshold,
                   !toolCallSignposted.contains(toolId) {
                    emitSubagentSignpost(toolId: toolId, quietFor: quietFor)
                }
                continue
            }
            if quietFor >= toolTimeout {
                expired.append(toolId)
                continue
            }
            // SOUL-SOUL_DESKTOP-110: midway signpost — surface that the tool
            // is still working and how far from cancellation we are. Once per
            // tool per turn; toolCallSignposted dedupes.
            if signpostThreshold > 0,
               quietFor >= signpostThreshold,
               !toolCallSignposted.contains(toolId) {
                toSignpost.append((toolId, quietFor, toolTimeout))
            }
        }
        for entry in toSignpost {
            emitToolCallSignpost(toolId: entry.toolId, quietFor: entry.quietFor, threshold: entry.threshold)
        }
        for toolId in expired {
            await fireToolCallTimeout(toolId: toolId, threshold: timeoutSeconds(forToolCall: toolId))
        }
    }

    /// Effective per-tool timeout. The global setting remains the floor for
    /// short, local tools, but shell/execute calls often run repository-wide
    /// searches or builds that are legitimately quiet for several minutes.
    /// Give those tools the same default headroom as the turn-level ceiling
    /// unless the user has configured an even larger tool timeout.
    private func timeoutSeconds(forToolCall toolId: String) -> Int {
        let base = StallPolicy.toolCallTimeoutSeconds
        guard let uuid = seenToolCallIds[toolId],
              let idx = items.firstIndex(where: { $0.id == uuid }),
              case .toolCall(_, let kind, let title, _, _, _) = items[idx]
        else { return base }
        let label = "\(kind) \(title)".lowercased()
        if label.contains("execute") || label.contains("shell") || label.contains("bash") {
            return max(base, StallPolicy.longRunningToolTimeoutFloorSeconds)
        }
        return base
    }

    /// Soul specialist calls can legitimately run past the generic
    /// per-tool-call timeout without emitting ACP updates while the
    /// delegated agent is reasoning. Classify both canonical
    /// `delegate_to_specialist` cards and Gemini's direct specialist tools
    /// (for example `registry_guardian`) as subagent-like, then let the
    /// parent turn-level watchdog remain the outer safety net.
    private func isSubagentToolCall(toolId: String) -> Bool {
        guard let uuid = seenToolCallIds[toolId],
              let idx = items.firstIndex(where: { $0.id == uuid }),
              case .toolCall(_, let kind, let title, _, _, let details) = items[idx]
        else { return false }
        if details?.isSubagent == true { return true }
        if kind == "delegate_to_specialist" || kind.contains("delegate_to_specialist") {
            return true
        }
        return SpecialistPalette.isKnownSpecialist(kind) || SpecialistPalette.isKnownSpecialist(title)
    }

    /// SOUL-SOUL_DESKTOP-110: emit a one-time "tool still working" status row
    /// when an in_progress tool call has been quiet for half the timeout
    /// budget. Lets the user see the tool is alive and how close it is to
    /// auto-cancel before we yank the turn. Idempotent per (toolId, turn)
    /// via toolCallSignposted; cleared at end-of-turn.
    func emitToolCallSignpost(toolId: String, quietFor: Int, threshold: Int) {
        toolCallSignposted.insert(toolId)
        var label = "tool call"
        if let uuid = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == uuid }),
           case .toolCall(_, let k, let t, _, _, _) = items[idx] {
            let kindPart = k.isEmpty ? "tool" : k
            let titlePart = t.isEmpty ? "" : " \(t)"
            label = "\(kindPart)\(titlePart)"
        }
        let remaining = max(0, threshold - quietFor)
        items.append(.status(
            id: UUID(),
            text: "⏳ \(label) quiet for \(quietFor)s — will auto-cancel in \(remaining)s if no activity"
        ))
        ledger.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: LedgerHookEvent.toolCallSignpost(
                provider: provider.rawValue,
                toolCallID: toolId,
                quietSeconds: quietFor,
                threshold: threshold
            ).hookDictionary
        )
    }

    func emitSubagentSignpost(toolId: String, quietFor: Int) {
        toolCallSignposted.insert(toolId)
        var label = "subagent"
        if let uuid = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == uuid }),
           case .toolCall(_, let k, let t, _, _, let details) = items[idx] {
            if case .subagent(let specialist, _, _, _, _) = details?.kind {
                label = specialist
            } else if SpecialistPalette.isKnownSpecialist(k) {
                label = k
            } else if SpecialistPalette.isKnownSpecialist(t) {
                label = t
            }
        }
        items.append(.status(
            id: UUID(),
            text: "⏳ \(label) still running after \(quietFor)s — specialist delegation can exceed the generic tool timeout"
        ))
        ledger.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: LedgerHookEvent.subagentLongRunning(
                provider: provider.rawValue,
                toolCallID: toolId,
                quietSeconds: quietFor
            ).hookDictionary
        )
    }

    /// Mark a stuck tool call timed out, flip its row to stopped, write the
    /// telemetry hook, and cancel the turn so the agent unblocks. ACP today
    /// has no per-toolCallId cancel surface; the turn-level cancel is the
    /// only tool we have to free the awaiting `client.prompt`. Idempotent
    /// via `toolCallTimedOut`.
    func fireToolCallTimeout(toolId: String, threshold: Int) async {
        guard !toolCallTimedOut.contains(toolId) else { return }
        toolCallTimedOut.insert(toolId)
        let startedAt = toolCallStartedAt[toolId] ?? Date()
        let elapsed = Int(Date().timeIntervalSince(startedAt))

        // Snapshot the row's kind/title for the hook and flip its visible
        // status to stopped so the spinner clears.
        var kindForHook = ""
        var titleForHook = ""
        if let uuid = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == uuid }),
           case .toolCall(let id, let k, let t, _, let loc, let details) = items[idx] {
            kindForHook = k
            titleForHook = t
            items[idx] = .toolCall(
                id: id,
                kind: k,
                title: t,
                status: "stopped",
                locationHint: loc,
                details: details
            )
        }

        // SOUL-SOUL_DESKTOP-078: classify the hang at firing time. If the
        // kernel ledger already has an AfterTool for this toolCallId, it's
        // class B (ACP item/completed never delivered). If not, it's class
        // A (still working — bump helps) or C (app-server stall). Cheap
        // tail scan; we read at most 256KB off the end of hooks.jsonl.
        let afterToolInLedger = ledger.ledgerContainsAfterTool(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            toolId: toolId
        )

        ledger.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: LedgerHookEvent.toolCallTimeout(
                provider: provider.rawValue,
                toolCallID: toolId,
                toolKind: kindForHook,
                toolTitle: titleForHook,
                elapsedSeconds: elapsed,
                threshold: threshold,
                afterToolInLedger: afterToolInLedger
            ).hookDictionary
        )

        items.append(.status(
            id: UUID(),
            text: "⚠ tool call timed out after \(elapsed)s (limit \(threshold)s) — cancelling turn"
        ))

        // Best-effort turn cancel, then tear down the provider process so the
        // awaiting prompt continuation definitely resolves. Tool timeouts are
        // the same class of failure as a quiet stall: continuing on the same
        // child risks overlapping the next prompt with a stuck old turn.
        await cancelActiveProviderTurn()
        await resetProviderProcessAfterInterruptedTurn()
    }
}
