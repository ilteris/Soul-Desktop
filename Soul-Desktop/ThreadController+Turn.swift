import Foundation

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
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else { return nil }
        if sessionId == nil {
            sessionId = id
        }

        let messageId = UUID()
        items.append(.userMessage(id: messageId, text: trimmedDisplay, timestamp: Date()))
        openAgentMessageId = nil
        lastActivityAt = Date()
        // User just sent — they want to follow the response. Reset the scroll
        // anchor to "stick to bottom" so ThreadView's items.count auto-scroll
        // pins to the latest content regardless of where the view was before.
        scrollAnchorAtBottom = true
        scrollAnchorItemId = nil

        let prompt = QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent, extraBlocks: extraBlocks)
        appendPromptHook(prompt, sessionId: sessionId ?? id)
        SoulRegistry.flushHooks()

        if isWorking {
            // Already running a turn; stash this for the dispatch loop to
            // pick up. UserPrompt is logged here so the hooks ledger
            // reflects the order the user sent things, not the order the
            // agent processed them.
            queuedPrompts.append(prompt)
            return nil
        }

        isWorking = true
        turnStartedAt = Date()
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
            sourceProvider: sourceProvider,
            targetProvider: targetProvider,
            timestamp: Date()
        ))
        openAgentMessageId = nil
        lastActivityAt = Date()
        scrollAnchorAtBottom = true
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
        SoulRegistry.flushHooks()

        if isWorking {
            queuedPrompts.append(prompt)
            return nil
        }

        isWorking = true
        turnStartedAt = Date()
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
            isWorking = false
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
            try await ensureSession()
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
                    try await sendCodex(text: agentText)

                    // Persist the codex agent's final reply text to the
                    // kernel hooks ledger, same way the ACP branch does.
                    // Without this, a codex session's transcript only has
                    // prompts in the kernel ledger; replay/hydrate shows
                    // empty agent responses. With it, `hydrateFromDisk`
                    // (codex branch below) renders full conversations.
                    if let raw = mostRecentAgentReplyText() {
                        let reply = LedgerPreamble.scrubEchoed(raw)
                        ledger.appendHook(projectKey: project.id, sessionId: sid, event: [
                            "event": "AfterAgent",
                            "content": reply,
                            "provider": provider.rawValue,
                        ])
                        // SOUL-SOUL_DESKTOP-065: AfterAgent is now the canonical
                        // record; the per-chunk file can retire.
                        ledger.retireAgentChunks(projectKey: project.id, sessionId: sid)
                    }

                    // Same finalize-card live injection as the ACP branch.
                    injectFinalizeSummaryIfFresh(sessionId: sid)

                    current = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
                }
                return
            }
            guard let client, let sid = sessionId else { return }
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
                    if steerPending {
                        steerPending = false
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
                do {
                    _ = try await client.prompt(sessionId: nid, text: agentText, extraBlocks: turn.extraBlocks)
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
                    suppressLoadReplay = true
                    isReplayingLoad = true
                    defer {
                        suppressLoadReplay = false
                        isReplayingLoad = false
                    }
                    try await client.loadSession(sessionId: nid, cwd: project.path)
                    // Retry uses agentText (preamble + prompt), not the
                    // bare turn.agent. SOUL-SOUL_DESKTOP-245 audit S1: if
                    // the first attempt failed at the RPC layer the agent
                    // never saw the preamble, and pendingContextPreamble
                    // was already cleared above. Re-sending agentText
                    // makes the recovery idempotent.
                    _ = try await client.prompt(sessionId: nid, text: agentText, extraBlocks: turn.extraBlocks)
                }

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
                let agentMsgCount = items.filter { if case .agentMessage = $0 { return true } else { return false } }.count
                NSLog("[ledger] AfterAgent gate: replyLen=\(reply?.count ?? -1) sid=\(sid) project=\(project.id) provider=\(provider.rawValue) agentMessagesInItems=\(agentMsgCount)")
                if let reply, !reply.isEmpty {
                    NSLog("[ledger] writing AfterAgent → \(project.id)/\(sid)")
                    ledger.appendHook(projectKey: project.id, sessionId: sid, event: [
                        "event": "AfterAgent",
                        "content": reply,
                        "provider": provider.rawValue,
                    ])
                    // SOUL-SOUL_DESKTOP-065: AfterAgent now holds the canonical
                    // reply text; the per-chunk file can retire so it doesn't
                    // grow unbounded across a long session.
                    ledger.retireAgentChunks(projectKey: project.id, sessionId: sid)
                } else {
                    NSLog("[ledger] SKIPPED AfterAgent write — mostRecentAgentReplyText returned nil for sid=\(sid)")
                }

                // If this turn was a `/finalize` (the agent just wrote a
                // finalize JSON to the registry), inject the structured
                // FinalizeCard inline so the user sees the Quad rendered
                // without having to re-open the session from the sidebar.
                injectFinalizeSummaryIfFresh(sessionId: sid)

                // Post-turn title generation only on the very first user turn
                // of a fresh chat. Skip when draining queued prompts.
                let userPrompts = items.filter { if case .userMessage = $0 { return true } else { return false } }.count
                if userPrompts == 1 && customTitle == nil {
                    Task { await generateTitle() }
                }

                // Pop the next queued turn. Re-check on each iteration so
                // sends that arrived during this loop's await get drained
                // without needing a separate dispatcher.
                current = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
            }
        } catch {
            NSLog("[ledger] dispatchPending CATCH: \(error) — AfterAgent write was bypassed by this throw")
            if suppressNextInterruptedTurnError {
                suppressNextInterruptedTurnError = false
            } else {
                let msg = Self.humanReadable(error)
                items.append(.error(id: UUID(), text: msg))
                lastError = msg
            }
        }

        // Queue draining happens in the defer above, after `isWorking` has
        // flipped false. Draining while this send still owns the active turn
        // can re-enter `send()` and re-queue the same prompt, or worse, open
        // a second provider prompt on the same child process after recovery.
    }

    private func appendPromptHook(_ turn: QueuedPrompt, sessionId sid: String) {
        switch turn.ledgerEvent {
        case .userPrompt:
            ledger.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": QueuedPrompt.LedgerEvent.userPrompt.rawValue,
                "text": turn.display,
            ])
        case .branchSummary:
            var event: [String: Any] = [
                "event": QueuedPrompt.LedgerEvent.branchSummary.rawValue,
                "summary": turn.display,
            ]
            if let sourceProvider = turn.sourceProvider {
                event["from_provider"] = sourceProvider.rawValue
            }
            if let targetProvider = turn.targetProvider {
                event["to_provider"] = targetProvider.rawValue
            }
            ledger.appendHook(projectKey: project.id, sessionId: sid, event: event)
        }
    }

    func cancel() async {
        // SOUL-204: diagnostic so a user-reported "Stop is unresponsive" has
        // an audit trail. If this line never appears in the agent log on a
        // click, the button isn't even routing onCancel through.
        logLifecycle("cancel.invoked", note: "queued=\(queuedPrompts.count) isWorking=\(isWorking) client=\(client != nil ? "live" : "nil")")
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
        queuedPrompts.removeAll()
        markInFlightToolCallsStopped()
        appendCancelStatusIfNeeded()
        isWorking = false
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
        let stalledSeconds = Int(Date().timeIntervalSince(lastActivityAt))
        markInFlightToolCallsStopped()
        let label = source == "auto" ? "⏱ auto-recovered stalled turn (\(stalledSeconds)s)"
                                     : "⏭ recovered stalled turn (\(stalledSeconds)s)"
        items.append(.status(id: UUID(), text: label))
        ledger.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "StallRecovered",
            "provider": provider.rawValue,
            "tool_kind": lastInProgressToolKind ?? "",
            "stalled_seconds": stalledSeconds,
            "recovery_source": source,
        ])
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
        guard !queuedPrompts.isEmpty else { return }
        await recoverStalledTurn(source: "manual")
    }


}
