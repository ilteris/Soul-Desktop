import Foundation
import SoulACP
import SoulCore
import SoulLedger
import SoulRuntime

/// Queue and interruption helpers for ThreadController turn flow.
/// Keeps prompt parking, bubble relocation, steer, and process-reset logic
/// separate from the send loop so queue semantics can evolve independently.
extension ThreadController {

func drainQueuedPromptAfterTurn() {
        guard let next = popNextQueuedPromptForDispatch() else { return }
        beginQueuedRedispatch(next)
        Task { [weak self] in
            await self?.dispatchPending(next)
        }
    }

    /// Synchronous prep to re-dispatch a prompt that was already accepted and
    /// logged when it was queued. Reclaims the active turn, restarts the stall
    /// watchdog, and moves the parked bubble to the end — mirroring the
    /// in-loop queued-turn setup in `dispatchPending`.
    ///
    /// SOUL-SOUL_DESKTOP-357: the previous drain re-sent through `send()`,
    /// which re-entered `acceptUserPrompt` and wrote a SECOND identical
    /// `UserPrompt` hook (and appended a second bubble) ~250ms after the
    /// queue-time write — the "doubled prompt / doubled session" symptom.
    /// `next` is already in the ledger and `dispatchPending` never re-logs,
    /// so dispatching it directly keeps the safety-net drain without the dup.
    func beginQueuedRedispatch(_ next: QueuedPrompt) {
        isWorking = true
        beginQueuedTurnDispatch(next)
        startStallWatchdog()
    }

    func beginQueuedTurnDispatch(_ turn: QueuedPrompt) {
        let now = Date()
        turnStartedAt = now
        lastActivityAt = now
        relocateQueuedBubbleToEnd(turn)
        consumeSteerPendingIfNeeded(for: turn)
    }

    func consumeSteerPendingIfNeeded(for turn: QueuedPrompt) {
        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        guard queueState.consumeSteerPending() else { return }
        steerPending = queueState.steerPending
        if let idx = items.firstIndex(where: { $0.id == turn.itemId }) {
            items.insert(.status(id: UUID(), text: "↪ steered to next prompt"), at: idx)
        } else {
            items.append(.status(id: UUID(), text: "↪ steered to next prompt"))
        }
    }

    func popNextQueuedPromptForDispatch() -> QueuedPrompt? {
        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        guard queueState.claimQueuedPromptForDispatch() else { return nil }
        return queuedPrompts.removeFirst()
    }

    /// A steered prompt is removed from `queuedPrompts` as soon as the send
    /// loop claims it, but it must keep rendering outside the frozen queued
    /// snapshot while the provider works on that turn. Clear the marker only
    /// after that dispatched turn has reached a safe boundary.
    func finishSteeredPromptDispatch(_ turn: QueuedPrompt) {
        if steeredVisiblePromptId == turn.itemId {
            steeredVisiblePromptId = nil
        }
    }

    func markInFlightToolCallsStopped() {
        items = items.map { item in
            if case .toolCall(let id, let kind, let title, let status, let loc, let details) = item,
               status == "in_progress" || status == "pending" {
                return .toolCall(id: id, kind: kind, title: title, status: "stopped", locationHint: loc, details: details)
            }
            return item
        }
    }

    func inFlightToolCallIDs() -> Set<String> {
        Set(seenToolCallIds.compactMap { toolId, itemId in
            guard let idx = items.firstIndex(where: { $0.id == itemId }),
                  case .toolCall(_, _, _, let status, _, _) = items[idx],
                  status == "in_progress" || status == "pending"
            else {
                return nil
            }
            return toolId
        })
    }

    func resetProviderProcessAfterInterruptedTurn() async {
        logLifecycle("resetProviderProcessAfterInterruptedTurn", note: "tearing down client; nativeSessionId preserved")
        suppressNextInterruptedTurnError = true
        eventTask?.cancel()
        eventTask = nil
        await runtimes.stopAll()
        if let cont = codexTurnContinuation {
            codexTurnContinuation = nil
            cont.resume(throwing: NSError(
                domain: "Codex",
                code: 98,
                userInfo: [NSLocalizedDescriptionKey: "turn interrupted by recovery"]
            ))
        }
        hasInitialized = false
        supportsLoadSession = false
        codexActiveTurnId = nil
        openAgentMessageId = nil
        openAgentThoughtId = nil
        seenToolCallIds.removeAll(keepingCapacity: true)
        codexItemMap.removeAll(keepingCapacity: true)
    }

    func markProviderProcessTerminated(cause: String) {
        logLifecycle("providerProcessTerminated", note: cause)
        eventTask = nil
        switch provider {
        case .codex:
            runtimes.codex = nil
            codexActiveTurnId = nil
            if let cont = codexTurnContinuation {
                codexTurnContinuation = nil
                cont.resume(throwing: NSError(
                    domain: "Codex",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: cause]
                ))
            }
        case .claude, .geminiCLI, .pi:
            runtimes.acp = nil
            supportsLoadSession = false
        }
        hasInitialized = false
        openAgentMessageId = nil
        openAgentThoughtId = nil
        seenToolCallIds.removeAll(keepingCapacity: true)
        codexItemMap.removeAll(keepingCapacity: true)
    }

    func cancelActiveProviderTurn() async {
        let cancelRequest = ProviderRuntimeCancelRequest(
            session: runtimeSessionSnapshot(),
            activeTurnID: codexActiveTurnId
        )
        if provider == .codex {
            await runtimes.codex?.cancel(cancelRequest)
            return
        }

        if cancelRequest.session.rpcSessionID != nil {
            await runtimes.acp?.cancel(cancelRequest)
        }
    }

    func appendCancelStatusIfNeeded() {
        // SOUL-SOUL_DESKTOP-379 (A): drain coalesced content first so the
        // "cancel sent" marker lands after whatever streamed before it.
        flushPendingStreamUpdates()
        materializeBufferedAgentStreams()
        if case .status(_, let last)? = items.last, last == "■ cancel sent" {
            return
        }
        items.append(.status(id: UUID(), text: "■ cancel sent"))
    }

    /// Move a queued user bubble out of its insertion position (mid-prior-turn
    /// in `items[]`, where it was appended at queue time) to the end of
    /// `items[]` with a fresh timestamp. Without this, the bubble re-renders
    /// wedged between the previous turn's agent chunks once it's popped from
    /// `queuedItemIDs` — the "vanished queue" rendering bug in
    /// SOUL-SOUL_DESKTOP-066. Keeps the original `itemId` so the QueuedPrompt
    /// → ThreadItem linkage stays intact.
    func relocateQueuedBubbleToEnd(_ turn: QueuedPrompt) {
        if let oldIdx = items.firstIndex(where: { $0.id == turn.itemId }) {
            items.remove(at: oldIdx)
        }
        items.append(.userMessage(id: turn.itemId, text: turn.display, timestamp: Date()))
    }

    /// Cancel the in-flight ACP turn over the wire and let the outer send()'s
    /// while-loop pop the queue and dispatch the next prompt on the *same*
    /// provider process. Shares `cancelActiveProviderTurn()` with Stop
    /// (`cancel()`) — the difference is Stop drops the queue and tears down
    /// the child, while Steer keeps both. Wired to the Steer button on the
    /// composer's queue chip.
    ///
    /// Why no `resetProviderProcessAfterInterruptedTurn` here: ACP's
    /// `session/cancel` resolves the in-flight `client.prompt` with
    /// stopReason=cancelled, leaving the session alive. Killing the child
    /// (as Stop and recoverStalledTurn do) would force the next queued
    /// prompt's send() to spawn a new process and call `session/load` —
    /// which fails with "invalid session identifier" on a fresh session
    /// whose session file the agent hasn't had time to persist yet.
    /// The teardown is appropriate for Stop (user wants out) and for
    /// recoverStalledTurn (agent is unresponsive). Steer is neither.
    var canSteerToNextQueued: Bool {
        TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        ).canSkipAhead && !steerPending && isWorking
    }

    @discardableResult
    func beginSteerToNextQueued() -> Bool {
        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        guard queueState.requestSteerToNextQueuedPrompt() else { return false }
        if let next = queuedPrompts.first {
            steeredVisiblePromptId = next.itemId
            relocateQueuedBubbleToEnd(next)
        }
        suppressNextInterruptedTurnError = true
        steerPending = queueState.steerPending
        steerCancellingToolCallIds = inFlightToolCallIDs()
        return true
    }

    func finishSteerToNextQueued() async {
        await cancelActiveProviderTurn()
        markInFlightToolCallsStopped()
        ledger.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: LedgerHookEvent.turnSteered(
                provider: provider.rawValue,
                queuedCount: queuedPrompts.count
            ).hookDictionary
        )
    }

    func steerToNextQueued() async {
        guard beginSteerToNextQueued() else { return }
        await finishSteerToNextQueued()
    }

    /// Drop any queued-but-not-yet-sent prompts. Wired into `cancel()` and
    /// surfaced via a clear-X on the queue chip in the composer.
    func clearQueue() {
        let queuedItemIDs = Set(queuedPrompts.map(\.itemId))
        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        queueState.clearQueuedPrompts()
        queuedPrompts.removeAll()
        steeredVisiblePromptId = nil
        removeUserMessageBubbles(ids: queuedItemIDs)
        steerPending = queueState.steerPending
    }

    func removeUserMessageBubbles(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { item in
            if case .userMessage(let id, _, _) = item {
                return ids.contains(id)
            }
            return false
        }
    }

    /// SOUL-SOUL_DESKTOP-199: edit a queued (not-yet-dispatched) user prompt
    /// in place. Updates both the QueuedPrompt entry (so the agent sees the
    /// new text when the queue drains) and the visible userMessage bubble
    /// in `items[]` (so the UI redraws). No-op if the prompt has already
    /// shipped — by the time the row leaves the queued state the agent's
    /// turn is in flight.
    @discardableResult
    func editQueuedPrompt(itemId: UUID, newText: String) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let qIdx = queuedPrompts.firstIndex(where: { $0.itemId == itemId }) else { return false }
        let original = queuedPrompts[qIdx]
        queuedPrompts[qIdx] = QueuedPrompt(
            itemId: original.itemId,
            display: trimmed,
            agent: trimmed,
            extraBlocks: original.extraBlocks,
            ledgerEvent: original.ledgerEvent,
            sourceProvider: original.sourceProvider,
            targetProvider: original.targetProvider
        )
        if let iIdx = items.firstIndex(where: { $0.id == itemId }),
           case .userMessage(let id, _, let ts) = items[iIdx] {
            items[iIdx] = .userMessage(id: id, text: trimmed, timestamp: ts)
        }
        return true
    }

    /// Drop a queued prompt before it dispatches. Removes both the
    /// QueuedPrompt entry (so the next steer/turn won't ship it) and the
    /// matching userMessage bubble from `items` (so the row vanishes from
    /// the canvas). No-op if the prompt has already shipped.
    func removeQueuedPrompt(itemId: UUID) {
        guard queuedPrompts.contains(where: { $0.itemId == itemId }) else { return }
        queuedPrompts.removeAll { $0.itemId == itemId }
        if steeredVisiblePromptId == itemId {
            steeredVisiblePromptId = nil
        }
        items.removeAll {
            if case .userMessage(let id, _, _) = $0 { return id == itemId }
            return false
        }
    }

}
