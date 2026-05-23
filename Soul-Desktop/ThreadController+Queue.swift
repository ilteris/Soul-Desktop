import Foundation

/// Queue and interruption helpers for ThreadController turn flow.
/// Keeps prompt parking, bubble relocation, steer, and process-reset logic
/// separate from the send loop so queue semantics can evolve independently.
extension ThreadController {

func drainQueuedPromptAfterTurn() {
        guard !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        Task { [weak self] in
            await self?.send(display: next.display, agent: next.agent)
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

    func resetProviderProcessAfterInterruptedTurn() async {
        logLifecycle("resetProviderProcessAfterInterruptedTurn", note: "tearing down client; nativeSessionId preserved")
        suppressNextInterruptedTurnError = true
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.stop()
            self.client = nil
        }
        if let codexClient {
            await codexClient.stop()
            self.codexClient = nil
        }
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

    func cancelActiveProviderTurn() async {
        if provider == .codex {
            if let codex = codexClient,
               let tid = nativeSessionId ?? sessionId,
               let turnId = codexActiveTurnId {
                try? await codex.turnInterrupt(threadId: tid, turnId: turnId)
            }
            return
        }

        if let client, let sid = sessionId {
            let nid = nativeSessionId ?? sid
            try? await client.cancel(sessionId: nid)
        }
    }

    func appendCancelStatusIfNeeded() {
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
    func steerToNextQueued() async {
        guard isWorking, !queuedPrompts.isEmpty else { return }
        suppressNextInterruptedTurnError = true
        steerPending = true
        await cancelActiveProviderTurn()
        markInFlightToolCallsStopped()
        ledger.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
            "event": "TurnSteered",
            "provider": provider.rawValue,
            "queued_count": queuedPrompts.count,
        ])
    }

    /// Drop any queued-but-not-yet-sent prompts. Wired into `cancel()` and
    /// surfaced via a clear-X on the queue chip in the composer.
    func clearQueue() {
        queuedPrompts.removeAll()
        steerPending = false
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
        queuedPrompts[qIdx] = QueuedPrompt(itemId: original.itemId, display: trimmed, agent: trimmed)
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
        items.removeAll {
            if case .userMessage(let id, _, _) = $0 { return id == itemId }
            return false
        }
    }

}
