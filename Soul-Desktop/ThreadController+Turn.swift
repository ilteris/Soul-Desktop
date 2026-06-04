import Foundation
import SoulACP
import SoulCore
import SoulLedger
import SoulRuntime

/// Turn-lifecycle send loop for ThreadController.
/// Queue mechanics live in ThreadController+Queue.swift; stall and per-tool
/// timeout polling lives in ThreadController+Watchdog.swift.
extension ThreadController {

    func send(_ text: String) async {
        await send(display: text, agent: text)
    }

    /// Two-channel send: `display` is what the user sees in their own bubble;
    /// `agent` is what we actually ship over ACP. They diverge when a slash
    /// command expands client-side — the bubble keeps the bare `/cmd` chip
    /// while the agent receives the skill's full instructions + any args.
    ///
    /// While a turn is already in flight, additional sends queue rather than
    /// step on the live prompt. They paint as user bubbles immediately so the
    /// canvas reads chronologically, and dispatch to the agent in order once
    /// the current turn resolves. The behavior switch (queue vs steer-via-
    /// cancel) is the future home for a user setting; the queue side is the
    /// safe default.
    func send(display: String, agent: String, extraBlocks: [ContentBlock] = []) async {
        guard let pending = acceptUserPrompt(display: display, agent: agent, extraBlocks: extraBlocks) else { return }
        await dispatchPending(pending)
    }

    /// Synchronous half of `send`: paint the user bubble, log the prompt,
    /// and either queue onto an in-flight turn or claim `isWorking`. Returns
    /// the prompt the caller should dispatch, or nil if it was queued (the
    /// in-flight turn's drain loop will pick it up).
    ///
    /// Splitting the sync prefix out lets ComposerView's submit() flow paint
    /// the bubble on the same runloop tick as the Enter keystroke instead of
    /// waiting for the `Task { await send(...) }` body to be scheduled —
    /// previously perceptible as a brief freeze before the bubble appeared.
    func acceptUserPrompt(display: String, agent: String, extraBlocks: [ContentBlock] = []) -> QueuedPrompt? {
        SoulSignposts.event("Flash.acceptUserPrompt.enter", "len=\(display.count) itemsBefore=\(items.count)")
        guard canAcceptComposerInput else { return nil }
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        // SOUL-SOUL-096: guard both display AND agent text. Guarding only
        // agent allowed empty-display sends to write hollow UserPrompt
        // rows to hooks.jsonl. soul/35d273e1 had 10 empties between two
        // real prompts. Mirrors event_mapper.substantive() in
        // ~/dotfiles/soul/app_server/event_mapper.py:71.
        guard !trimmedDisplay.isEmpty, (!trimmedAgent.isEmpty || !extraBlocks.isEmpty) else { return nil }
        if sessionId == nil {
            sessionId = id
        }

        let messageId = UUID()
        items.append(.userMessage(id: messageId, text: trimmedDisplay, timestamp: Date()))
        openAgentMessageId = nil
        lastActivityAt = Date()
        // User just sent; clear the saved read-position anchor so live
        // follow can drive this new turn.
        scrollAnchorItemId = nil

        let prompt = QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent, extraBlocks: extraBlocks)
        appendPromptHook(prompt, sessionId: sessionId ?? id)

        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        switch queueState.acceptPrompt() {
        case .queued:
            // Already running a turn; stash this for the dispatch loop to
            // pick up. UserPrompt is logged here so the hooks ledger
            // reflects the order the user sent things, not the order the
            // agent processed them.
            queuedPrompts.append(prompt)
            return nil
        case .dispatchNow:
            isWorking = queueState.isWorking
        }

        turnStartedAt = Date()
        agentStreamBuffer.clear()
        liveStreamPreview = nil
        startStallWatchdog()
        return prompt
    }

    func acceptBranchSummaryPrompt(
        summary: String,
        sourceProvider: Provider,
        targetProvider: Provider,
        agent: String
    ) -> QueuedPrompt? {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty, !trimmedAgent.isEmpty else { return nil }

        let messageId = UUID()
        items.append(.branchSummary(
            id: messageId,
            summary: trimmedSummary,
            sourceProvider: sourceProvider.agentProvider,
            targetProvider: targetProvider.agentProvider,
            timestamp: Date()
        ))
        openAgentMessageId = nil
        lastActivityAt = Date()
        scrollAnchorItemId = nil

        let prompt = QueuedPrompt(
            itemId: messageId,
            display: trimmedSummary,
            agent: trimmedAgent,
            ledgerEvent: .branchSummary,
            sourceProvider: sourceProvider,
            targetProvider: targetProvider
        )
        appendPromptHook(prompt, sessionId: sessionId ?? id)

        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        switch queueState.acceptPrompt() {
        case .queued:
            queuedPrompts.append(prompt)
            return nil
        case .dispatchNow:
            isWorking = queueState.isWorking
        }

        turnStartedAt = Date()
        agentStreamBuffer.clear()
        liveStreamPreview = nil
        startStallWatchdog()
        return prompt
    }

    /// Async half of `send`: ensure a live session, then dispatch the
    /// accepted prompt (and drain any prompts queued while this turn runs).
    /// Must be called on a prompt obtained from `acceptUserPrompt` — that
    /// method owns the `isWorking` flip; this method owns the matching
    /// teardown via defer.
    func dispatchPending(_ initial: QueuedPrompt) async {
        defer {
            // SOUL-SOUL_DESKTOP-379 (A): drain any coalesced updates left in
            // the buffer before tearing the turn down, so the final frame of
            // streamed content is committed even if the turn ended between
            // coalesce ticks.
            flushPendingStreamUpdates()
            materializeBufferedAgentStreams()
            isWorking = false
            liveStreamPreview = nil
            agentStreamBuffer.clear()
            turnStartedAt = nil
            stopStallWatchdog()
            drainQueuedPromptAfterTurn()
            suppressNextInterruptedTurnError = false

            // SOUL-WRITER-DRAIN: force the hook-write queue to drain so
            // this turn's UserPrompt + AfterTool + AfterAgent are durable
            // on disk before we relinquish control. Without this, a
            // force-quit (or pkill, or mac sleep + close) between turns
            // could lose the in-flight writes — exactly what dropped
            // the 23:01-23:03 /finalize events in 6c842dc8.
            SoulRegistry.flushHooks()

            if let sid = sessionId {
                NotificationManager.shared.sendTurnCompletedNotification(
                    threadTitle: displayTitle,
                    project: project.name,
                    sessionId: sid,
                    projectKey: project.id
                )
            }
        }

        // First turn dispatches immediately; subsequent queued turns are
        // drained from `queuedPrompts` while we still hold `isWorking`.
        // `isFirstTurn` toggles after the initial iteration so popped turns
        // can take the queue-consumption path (relocate bubble, skip the
        // dispatch-time UserPrompt hook since it was already logged at
        // queue time at line ~471).
        var current: QueuedPrompt? = initial
        var isFirstTurn = true
        do {
            try await ensureSessionResilient()
            // Codex path: parallel client + event semantics, see sendCodex.
            if provider == .codex {
                guard let sid = sessionId else { return }
                while let turn = current {
                    if isFirstTurn {
                        // UserPrompt was persisted synchronously when the
                        // visible bubble was created.
                    } else {
                        turnStartedAt = Date()
                        relocateQueuedBubbleToEnd(turn)
                    }
                    isFirstTurn = false
                    // SOUL-SOUL_DESKTOP-245 (Phase B): inject preamble on
                    // first dispatch for resumed codex sessions too.
                    let agentText: String = {
                        if let pre = pendingContextPreamble {
                            pendingContextPreamble = nil
                            let prefixed = LedgerPreamble.prefix(pre, to: turn.agent)
                            recordPreambleInjection(prefixed)
                            return prefixed
                        }
                        return turn.agent
                    }()
                    let promptRequest = ProviderRuntimePromptRequest<ContentBlock>(
                        session: runtimeSessionSnapshot(),
                        text: agentText,
                        attachments: turn.extraBlocks
                    )
                    guard promptRequest.canDispatch else { return }
                    try await sendCodex(promptRequest)
                    materializeBufferedAgentStreams()

                    // Persist the codex agent's final reply text to the
                    // kernel hooks ledger, same way the ACP branch does.
                    // Without this, a codex session's transcript only has
                    // prompts in the kernel ledger; replay/hydrate shows
                    // empty agent responses. With it, `hydrateFromDisk`
                    // (codex branch below) renders full conversations.
                    if let raw = mostRecentAgentReplyText() {
                        let reply = LedgerPreamble.scrubEchoed(raw)
                        ledger.appendHook(
                            projectKey: project.id,
                            sessionId: sid,
                            event: LedgerHookEvent.afterAgent(
                                content: reply,
                                provider: provider.rawValue
                            ).hookDictionary
                        )
                        // SOUL-SOUL_DESKTOP-065: AfterAgent is now the canonical
                        // record; the per-chunk file can retire.
                        ledger.retireAgentChunks(projectKey: project.id, sessionId: sid)
                    }

                    // Same finalize-card live injection as the ACP branch.
                    injectFinalizeSummaryIfFresh(sessionId: sid)
                    generateTitleAfterFirstSubstantiveTurnIfNeeded()

                    current = popNextQueuedPromptForDispatch()
                }
                return
            }
            guard let runtime = runtimes.acp, let sid = sessionId else { return }
            // ACP id used for prompt/cancel — may differ from kernel sid
            // when the session was resumed via backfill.
            let nid = nativeSessionId ?? sid

            while let turn = current {
                if isFirstTurn {
                    // UserPrompt was persisted synchronously when the
                    // visible bubble was created.
                } else {
                    turnStartedAt = Date()
                    relocateQueuedBubbleToEnd(turn)
                    var queueState = TurnQueueState(
                        isWorking: isWorking,
                        queuedCount: queuedPrompts.count,
                        steerPending: steerPending
                    )
                    if queueState.consumeSteerPending() {
                        steerPending = queueState.steerPending
                        if let idx = items.firstIndex(where: { $0.id == turn.itemId }) {
                            items.insert(.status(id: UUID(), text: "↪ steered to next prompt"), at: idx)
                        } else {
                            items.append(.status(id: UUID(), text: "↪ steered to next prompt"))
                        }
                    }
                }
                isFirstTurn = false
                // SOUL-SOUL_DESKTOP-245 (Phase B): if hydrate staged a
                // preamble for this resumed session, prefix it to the
                // agent-channel text on the first dispatch and clear so
                // subsequent turns don't re-send it. Display text is
                // untouched — the canvas already shows the prior items.
                let agentText: String = {
                    if let pre = pendingContextPreamble {
                        pendingContextPreamble = nil
                        let prefixed = LedgerPreamble.prefix(pre, to: turn.agent)
                        recordPreambleInjection(prefixed)
                        return prefixed
                    }
                    return turn.agent
                }()
                // SOUL-IDENTITY-SPLIT: open the FSEvents window right
                // before the prompt lands so the watcher catches Claude
                // rotating its on-disk transcript filename (the post-
                // /compact case). No-op for non-Claude.
                armTranscriptWatcher()
                let promptRequest = ProviderRuntimePromptRequest<ContentBlock>(
                    session: runtimeSessionSnapshot(),
                    text: agentText,
                    attachments: turn.extraBlocks
                )
                guard promptRequest.canDispatch else { return }
                do {
                    try await runtime.prompt(promptRequest)
                } catch ACPClientError.rpcError(let rpc) where Self.isInvalidSessionRPC(rpc) {
                    // SOUL-SOUL_DESKTOP-103: Gemini-CLI rotates / drops the
                    // session mid-conversation (observed: session loaded fine,
                    // ran tools, then a later session/prompt fails with
                    // "Invalid session identifier" on the same sid we just
                    // used). Same class as SOUL-SOUL_DESKTOP-060 / -022 but at
                    // the prompt boundary instead of the load boundary. Try a
                    // transparent recovery: re-issue session/load on the held
                    // sid (the agent re-registers it in its session map), then
                    // retry the prompt once. If that also fails we fall through
                    // to the outer catch and surface the original error.
                    items.append(.status(
                        id: UUID(),
                        text: "ℹ \(rpc.message) — re-registering session and retrying"
                    ))
                    // SOUL-SOUL_DESKTOP-379 (A): drain any coalesced live
                    // updates before entering the suppressed replay window —
                    // otherwise they'd flush under suppress=true and be
                    // dropped, or after the defer resets it and double.
                    flushPendingStreamUpdates()
                    suppressLoadReplay = true
                    isReplayingLoad = true
                    defer {
                        suppressLoadReplay = false
                        isReplayingLoad = false
                    }
                    let loadRequest = runtimeLoadRequest(requestedSessionID: nid)
                    try await runtime.loadSession(loadRequest)
                    // Retry uses agentText (preamble + prompt), not the
                    // bare turn.agent. SOUL-SOUL_DESKTOP-245 audit S1: if
                    // the first attempt failed at the RPC layer the agent
                    // never saw the preamble, and pendingContextPreamble
                    // was already cleared above. Re-sending agentText
                    // makes the recovery idempotent.
                    try await runtime.prompt(promptRequest)
                }

                // SOUL-SOUL_DESKTOP-379 (A): the prompt has resolved, so the
                // agent's final chunks have been delivered — but with stream
                // coalescing some may still sit in the pending buffer. Drain
                // it synchronously before reading `items` so the AfterAgent
                // ledger write captures the complete reply, never a truncated
                // tail. The kernel ledger is authoritative; this flush is the
                // contract that keeps it whole.
                flushPendingStreamUpdates()
                materializeBufferedAgentStreams()

                // Persist the agent's full reply text to the kernel hooks
                // ledger. Without this, the conversation only lives in the
                // provider's chat file (gemini-cli's `~/.gemini/tmp/.../chats/`
                // or Claude's `~/.claude/projects/...`) — and if that file
                // gets corrupted, rotated, or force-quit-truncated, Replay
                // shows the prompts with empty bodies. With this row, every
                // Soul-Desktop session is replayable from our own ledger
                // alone, regardless of agent-side disk state.
                let rawReply = mostRecentAgentReplyText()
                let reply = rawReply.map(LedgerPreamble.scrubEchoed)
                if let reply, !reply.isEmpty {
                    ledger.appendHook(
                        projectKey: project.id,
                        sessionId: sid,
                        event: LedgerHookEvent.afterAgent(
                            content: reply,
                            provider: provider.rawValue
                        ).hookDictionary
                    )
                    // SOUL-SOUL_DESKTOP-065: AfterAgent now holds the canonical
                    // reply text; the per-chunk file can retire so it doesn't
                    // grow unbounded across a long session.
                    ledger.retireAgentChunks(projectKey: project.id, sessionId: sid)
                }

                // If this turn was a `/finalize` (the agent just wrote a
                // finalize JSON to the registry), inject the structured
                // FinalizeCard inline so the user sees the Quad rendered
                // without having to re-open the session from the sidebar.
                injectFinalizeSummaryIfFresh(sessionId: sid)

                generateTitleAfterFirstSubstantiveTurnIfNeeded()

                // Pop the next queued turn. Re-check on each iteration so
                // sends that arrived during this loop's await get drained
                // without needing a separate dispatcher.
                current = popNextQueuedPromptForDispatch()
            }
        } catch {
            if suppressNextInterruptedTurnError {
                suppressNextInterruptedTurnError = false
            } else {
                let msg = Self.humanReadable(error)
                materializeBufferedAgentStreams()
                items.append(.error(id: UUID(), text: msg))
                lastError = msg
            }
        }

        // Queue draining happens in the defer above, after `isWorking` has
        // flipped false. Draining while this send still owns the active turn
        // can re-enter `send()` and re-queue the same prompt, or worse, open
        // a second provider prompt on the same child process after recovery.
    }

    private func generateTitleAfterFirstSubstantiveTurnIfNeeded() {
        // Post-turn title generation only on the first substantive user turn.
        // Harness scaffolds can be ledgered as user messages before the user's
        // actual prompt, so raw count is not a safe trigger.
        let substantiveUserPrompts = items.compactMap { item -> String? in
            guard case .userMessage(_, let text, _) = item else { return nil }
            let stripped = SoulRegistry.stripCommandTags(text)
            let cleaned = SessionTitleResolver.titleCandidateText(fromPrompt: stripped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .prose = SessionTitleResolver.classify(cleaned),
                  !SessionTitleResolver.isPlaceholderTitle(cleaned)
            else { return nil }
            return cleaned
        }
        let commandOnlyPromptCount = items.filter { item in
            guard case .userMessage(_, let text, _) = item else { return false }
            let stripped = SoulRegistry.stripCommandTags(text)
            let cleaned = SessionTitleResolver.titleCandidateText(fromPrompt: stripped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if case .bareSlash = SessionTitleResolver.classify(cleaned) {
                return true
            }
            return false
        }.count
        let hasAgentResponse = items.contains { item in
            guard case .agentMessage(_, let text, _, _) = item else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasUsableCustomTitle: Bool = {
            guard let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  !SessionTitleResolver.isPlaceholderTitle(title),
                  case .prose = SessionTitleResolver.classify(title)
            else { return false }
            if SessionTitleResolver.isPromptCopyTitle(title, prompts: substantiveUserPrompts) { return false }
            return true
        }()
        let shouldGenerateFromProse = substantiveUserPrompts.count == 1
        let shouldGenerateFromCommandOnly = substantiveUserPrompts.isEmpty
            && commandOnlyPromptCount == 1
            && hasAgentResponse
        if (shouldGenerateFromProse || shouldGenerateFromCommandOnly) && !hasUsableCustomTitle && !titleGenerationInFlight {
            titleGenerationInFlight = true
            Task { await generateTitle() }
        }
    }

    private func appendPromptHook(_ turn: QueuedPrompt, sessionId sid: String) {
        switch turn.ledgerEvent {
        case .userPrompt:
            ledger.appendHook(
                projectKey: project.id,
                sessionId: sid,
                event: LedgerHookEvent.userPrompt(text: turn.display).hookDictionary
            )
        case .branchSummary:
            ledger.appendHook(
                projectKey: project.id,
                sessionId: sid,
                event: LedgerHookEvent.branchSummary(
                    summary: turn.display,
                    sourceProvider: turn.sourceProvider?.rawValue,
                    targetProvider: turn.targetProvider?.rawValue
                ).hookDictionary
            )
        }
    }

    func cancel() async {
        // SOUL-204: diagnostic so a user-reported "Stop is unresponsive" has
        // an audit trail. If this line never appears in the agent log on a
        // click, the button isn't even routing onCancel through.
        logLifecycle("cancel.invoked", note: "queued=\(queuedPrompts.count) isWorking=\(isWorking) runtimes.acp=\(runtimes.acp != nil ? "live" : "nil")")
        // Paint UI feedback FIRST — the async cancel below hops to the
        // ACPClient actor, which while a turn is streaming is busy decoding
        // session/update notifications. If we await it first, the Stop
        // button feels unresponsive (no row, no pill flip) until that actor
        // queue drains. Flip the visible state synchronously so the click
        // registers immediately; the wire-level cancel + child teardown
        // run after.
        // SOUL-210: gate event delivery FIRST — before any await — so
        // session/update notifications already in-flight on the actor
        // queue can't append more rows after the click.
        isCancelling = true
        var queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        queueState.cancelActiveTurnAndClearQueue()
        queuedPrompts.removeAll()
        steerPending = queueState.steerPending
        markInFlightToolCallsStopped()
        appendCancelStatusIfNeeded()
        isWorking = queueState.isWorking
        stopStallWatchdog()
        // Suppress the upcoming "prompt turn interrupted" error that the
        // in-flight `client.prompt` will throw once the transport tears
        // down — the user already saw "■ cancel sent".
        suppressNextInterruptedTurnError = true
        await cancelActiveProviderTurn()
        logLifecycle("cancel.providerTurnCancelled", note: "moving to process teardown")
        await resetProviderProcessAfterInterruptedTurn()
        isCancelling = false
        logLifecycle("cancel.complete", note: "child terminated, isWorking=false")
    }

    /// Cancel the current stalled turn. If the queue has more prompts, dispatch
    /// the next one ("skip ahead"); otherwise just unblock the thread so the
    /// user can type. Wired to the WorkingIndicator's "Recover" capsule and
    /// also invoked by the watchdog when the hard auto-cancel ceiling is hit.
    ///
    /// SOUL-SOUL_DESKTOP-024: this used to require a non-empty queue. That
    /// gate meant five-hour `swarm-status.py --oneshot` hangs had no in-UI
    /// recovery affordance unless the user happened to type a follow-up first.
    /// Now the only precondition is an active session.
    func recoverStalledTurn(source: String = "manual") async {
        guard let sid = sessionId else { return }
        await cancelActiveProviderTurn()
        // SOUL-SOUL_DESKTOP-379 (A): drain any coalesced stream buffer before we
        // mutate `items`, so the recovery status row can't paint ahead of the
        // last frame of streamed content still queued. Mirrors the flush in
        // appendCancelStatusIfNeeded on the cancel path. The await above can let
        // more chunks buffer, so flush here (after it), not before.
        flushPendingStreamUpdates()
        materializeBufferedAgentStreams()
        let stalledSeconds = Int(Date().timeIntervalSince(lastActivityAt))
        markInFlightToolCallsStopped()
        let label = source == "auto" ? "⏱ auto-recovered stalled turn (\(stalledSeconds)s)"
                                     : "⏭ recovered stalled turn (\(stalledSeconds)s)"
        items.append(.status(id: UUID(), text: label))
        ledger.appendHook(
            projectKey: project.id,
            sessionId: sid,
            event: LedgerHookEvent.stallRecovered(
                provider: provider.rawValue,
                toolKind: lastInProgressToolKind ?? "",
                stalledSeconds: stalledSeconds,
                recoverySource: source
            ).hookDictionary
        )
        // Tear the provider process down so the awaiting prompt/turn
        // continuation resolves. The original send() defer will then flip
        // `isWorking` off and drain exactly one queued prompt. Dispatching
        // here would overlap a new prompt with the still-awaiting old turn.
        await resetProviderProcessAfterInterruptedTurn()
        stopStallWatchdog()
    }

    /// Compat shim — older call sites still reference the previous name. The
    /// behavior matches the legacy method (requires a queued prompt) so any
    /// external caller keeps working; new UI uses `recoverStalledTurn`.
    func skipStalledTurn() async {
        let queueState = TurnQueueState(
            isWorking: isWorking,
            queuedCount: queuedPrompts.count,
            steerPending: steerPending
        )
        guard queueState.canSkipAhead else { return }
        await recoverStalledTurn(source: "manual")
    }


}
