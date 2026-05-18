import Foundation

/// Turn-lifecycle methods lifted out of ThreadController: `send` and its
/// two-channel variant, the queue drain that fires after each turn
/// completes, manual + auto turn cancellation, the stall watchdog
/// (turn-level "quiet for Ns" + ceiling auto-cancel), and the per-tool
/// timeout sweep that fires when an individual tool call stays
/// in_progress past its own deadline.
///
/// Pure file shuffle, no behavior change. Refactor 8/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
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
    func send(display: String, agent: String) async {
        guard let pending = acceptUserPrompt(display: display, agent: agent) else { return }
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
    func acceptUserPrompt(display: String, agent: String) -> QueuedPrompt? {
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else { return nil }

        let messageId = UUID()
        items.append(.userMessage(id: messageId, text: trimmedDisplay, timestamp: Date()))
        openAgentMessageId = nil
        lastActivityAt = Date()
        // User just sent — they want to follow the response. Reset the scroll
        // anchor to "stick to bottom" so ThreadView's items.count auto-scroll
        // pins to the latest content regardless of where the view was before.
        scrollAnchorAtBottom = true
        scrollAnchorItemId = nil

        let prompt = QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent)

        if isWorking {
            // Already running a turn; stash this for the dispatch loop to
            // pick up. UserPrompt is logged here so the hooks ledger
            // reflects the order the user sent things, not the order the
            // agent processed them.
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
                "event": "UserPrompt",
                "text": trimmedDisplay,
            ])
            queuedPrompts.append(prompt)
            return nil
        }

        isWorking = true
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
            stopStallWatchdog()
            drainQueuedPromptAfterTurn()
            suppressNextInterruptedTurnError = false
            
            NotificationManager.shared.sendTurnCompletedNotification(
                threadTitle: displayTitle,
                project: project.name
            )
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
                        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                            "event": "UserPrompt",
                            "text": turn.display,
                        ])
                    } else {
                        relocateQueuedBubbleToEnd(turn)
                    }
                    isFirstTurn = false
                    try await sendCodex(text: turn.agent)

                    // Persist the codex agent's final reply text to the
                    // kernel hooks ledger, same way the ACP branch does.
                    // Without this, a codex session's transcript only has
                    // prompts in the kernel ledger; replay/hydrate shows
                    // empty agent responses. With it, `hydrateFromDisk`
                    // (codex branch below) renders full conversations.
                    if let reply = mostRecentAgentReplyText() {
                        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                            "event": "AfterAgent",
                            "content": reply,
                            "provider": provider.rawValue,
                        ])
                        // SOUL-SOUL_DESKTOP-065: AfterAgent is now the canonical
                        // record; the per-chunk file can retire.
                        SoulRegistry.retireAgentChunks(projectKey: project.id, sessionId: sid)
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
                    SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                        "event": "UserPrompt",
                        "text": turn.display,
                    ])
                } else {
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
                do {
                    _ = try await client.prompt(sessionId: nid, text: turn.agent)
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
                    _ = try await client.prompt(sessionId: nid, text: turn.agent)
                }

                // Persist the agent's full reply text to the kernel hooks
                // ledger. Without this, the conversation only lives in the
                // provider's chat file (gemini-cli's `~/.gemini/tmp/.../chats/`
                // or Claude's `~/.claude/projects/...`) — and if that file
                // gets corrupted, rotated, or force-quit-truncated, Replay
                // shows the prompts with empty bodies. With this row, every
                // Soul-Desktop session is replayable from our own ledger
                // alone, regardless of agent-side disk state.
                if let reply = mostRecentAgentReplyText() {
                    SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                        "event": "AfterAgent",
                        "content": reply,
                        "provider": provider.rawValue,
                    ])
                    // SOUL-SOUL_DESKTOP-065: AfterAgent now holds the canonical
                    // reply text; the per-chunk file can retire so it doesn't
                    // grow unbounded across a long session.
                    SoulRegistry.retireAgentChunks(projectKey: project.id, sessionId: sid)
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

    private func drainQueuedPromptAfterTurn() {
        guard !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        Task { [weak self] in
            await self?.send(display: next.display, agent: next.agent)
        }
    }

    private func markInFlightToolCallsStopped() {
        items = items.map { item in
            if case .toolCall(let id, let kind, let title, let status, let loc, let details) = item,
               status == "in_progress" || status == "pending" {
                return .toolCall(id: id, kind: kind, title: title, status: "stopped", locationHint: loc, details: details)
            }
            return item
        }
    }

    private func resetProviderProcessAfterInterruptedTurn() async {
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

    private func cancelActiveProviderTurn() async {
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

    private func appendCancelStatusIfNeeded() {
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
    private func relocateQueuedBubbleToEnd(_ turn: QueuedPrompt) {
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
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
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

    func cancel() async {
        // Drop any queued prompts — cancelling means "stop, don't keep going."
        queuedPrompts.removeAll()
        await cancelActiveProviderTurn()
        // Flip any still-running tool calls to a terminal "stopped" status so
        // the row stops claiming work is happening. Without this the orange
        // "in_progress" pill lingers indefinitely after the agent acks cancel.
        markInFlightToolCallsStopped()
        // Guard against duplicate "cancel sent" rows when the user mashes the
        // cancel button.
        appendCancelStatusIfNeeded()
        await resetProviderProcessAfterInterruptedTurn()
        isWorking = false
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
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
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

    /// Start a per-turn watchdog. Polls `lastActivityAt` every second while
    /// `isWorking` holds; fires a single StallDetected hook when quiet exceeds
    /// the provider's stall budget, and auto-recovers when quiet exceeds the
    /// hard ceiling. Cheap: one Task, one timer, no observers.
    private func startStallWatchdog() {
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

    private func stopStallWatchdog() {
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
    private func tickStallWatchdog(budget: Int, ceiling: Int) async {
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
            SoulRegistry.appendHook(
                projectKey: project.id,
                sessionId: sessionId ?? id,
                event: [
                    "event": "StallDetected",
                    "provider": provider.rawValue,
                    "tool_kind": lastInProgressToolKind ?? "",
                    "stalled_seconds": quiet,
                    "threshold": budget,
                ]
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
        let toolTimeout = StallPolicy.toolCallTimeoutSeconds
        let signpostThreshold = Int(Double(toolTimeout) * StallPolicy.toolCallSignpostFraction)
        let now = Date()
        var expired: [String] = []
        var toSignpost: [(toolId: String, quietFor: Int)] = []
        // SOUL-SOUL_DESKTOP-079: drive expiry off lastActivityAt, not startedAt.
        for (toolId, lastSeen) in toolCallLastActivityAt where !toolCallTimedOut.contains(toolId) {
            let quietFor = Int(now.timeIntervalSince(lastSeen))
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
                toSignpost.append((toolId, quietFor))
            }
        }
        for entry in toSignpost {
            emitToolCallSignpost(toolId: entry.toolId, quietFor: entry.quietFor, threshold: toolTimeout)
        }
        for toolId in expired {
            await fireToolCallTimeout(toolId: toolId, threshold: toolTimeout)
        }
    }

    /// SOUL-SOUL_DESKTOP-110: emit a one-time "tool still working" status row
    /// when an in_progress tool call has been quiet for half the timeout
    /// budget. Lets the user see the tool is alive and how close it is to
    /// auto-cancel before we yank the turn. Idempotent per (toolId, turn)
    /// via toolCallSignposted; cleared at end-of-turn.
    private func emitToolCallSignpost(toolId: String, quietFor: Int, threshold: Int) {
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
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: [
                "event": "ToolCallSignpost",
                "provider": provider.rawValue,
                "tool_call_id": toolId,
                "quiet_seconds": quietFor,
                "threshold": threshold,
            ]
        )
    }

    /// Mark a stuck tool call timed out, flip its row to stopped, write the
    /// telemetry hook, and cancel the turn so the agent unblocks. ACP today
    /// has no per-toolCallId cancel surface; the turn-level cancel is the
    /// only tool we have to free the awaiting `client.prompt`. Idempotent
    /// via `toolCallTimedOut`.
    private func fireToolCallTimeout(toolId: String, threshold: Int) async {
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
        let afterToolInLedger = SoulRegistry.ledgerContainsAfterTool(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            toolId: toolId
        )

        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: [
                "event": "ToolCallTimeout",
                "provider": provider.rawValue,
                "tool_call_id": toolId,
                "tool_kind": kindForHook,
                "tool_title": titleForHook,
                "elapsed_seconds": elapsed,
                "threshold": threshold,
                "afterTool_in_ledger": afterToolInLedger,
            ]
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
