import Foundation
import SoulACP
import SoulCore
import SoulLedger
import SoulRuntime

/// Session-resume + spawn + teardown lifecycle methods lifted out of
/// ThreadController. `loadSession(id:)` handles click-on-existing-row
/// resumption (ACP `session/load` with provider-specific fallbacks),
/// `teardown` cleanly shuts the agent child + watchers, the async
/// `ensureSession()` is the lazy "spawn if not yet spawned" guard used
/// by the send path, and `spawnAndInitialize` runs the actual provider
/// child + ACP handshake.
///
/// Pure file shuffle, no behavior change. Refactor 9/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
extension ThreadController {

    func loadSession(id sid: String) async {
        guard !hasInitialized else { return }
        let loadSessionInterval = SoulSignposts.beginInterval("ThreadController.loadSession", id: sid)
        isWorking = true
        defer {
            isWorking = false
            SoulSignposts.endInterval("ThreadController.loadSession", state: loadSessionInterval)
        }
        // SOUL-205: see ThreadController+Hydrate.swift — relax UUID gate so
        // legacy Pi sessions (saved before the UUID-mint fix) can still open.
        guard !sid.isEmpty else {
            items.append(.error(id: UUID(), text: "missing session id"))
            return
        }
        // Establish kernel identity before any ACP work. Every appendHook
        // from here on persists under the original kernel UUID, even if the
        // agent's native UUID diverges and gets stored in nativeSessionId.
        sessionId = sid

        // Off-main: metadata fetches scan hooks.jsonl.
        let proj = project
        let prov = provider.rawValue
        struct LoadMetadata {
            var nativeId: String?
            var title: String?
            var slashPrompts: [(text: String, timestamp: Date)] = []
        }
        let meta: LoadMetadata = await Task.detached(priority: .userInitiated) {
            LoadMetadata(
                nativeId: SoulRegistry.findNativeSessionID(projectKey: proj.id, sessionId: sid, provider: prov),
                title: SoulRegistry.findTitle(projectKey: proj.id, sessionId: sid),
                slashPrompts: SoulRegistry.slashCommandPrompts(projectKey: proj.id, sessionId: sid)
            )
        }.value

        if let t = meta.title, !t.isEmpty {
            customTitle = t
        }
        let nativeId = meta.nativeId

        do {
            switch provider {
            case .claude, .geminiCLI, .pi:
                try await spawnAndInitialize(skipNewSession: true)
                guard let runtime = runtimes.acp else { return }
                let resumeId = nativeId ?? sid

                let backupPath = Self.backupAgentChatIfPresent(
                    provider: provider,
                    sessionId: resumeId,
                    cwd: activeProjectPath
                )
                do {
                    isReplayingLoad = true
                    let loadRequest = runtimeLoadRequest(requestedSessionID: resumeId)
                    try await runtime.loadSession(loadRequest)
                    isReplayingLoad = false
                    nativeSessionId = resumeId
                    hasInitialized = true
                    injectSlashCommandPrompts(meta.slashPrompts)
                } catch ACPClientError.rpcError(let rpc) {
                    isReplayingLoad = false
                    let lowerMsg = rpc.message.lowercased()
                    let isInvalidSession = rpc.code == -32602
                        || rpc.code == -32002
                        || lowerMsg.contains("invalid session")
                        || lowerMsg.contains("session id")
                        || lowerMsg.contains("resource not found")
                    
                    // SOUL-SOUL_DESKTOP-153: gemini-cli destructive-stub recovery.
                    // Source-trace (gemini-cli chatRecordingService.ts:368-436)
                    // confirms the failure path writes a header-only stub with
                    // our requested sid. If the backup we took before this call
                    // is larger than the stub, restore it and retry session/load
                    // once. Claude + Pi don't have this bug — Claude reads
                    // append-only transcripts; pi-acp throws cleanly before
                    // any write (verified pi-acp/dist/index.js:2086-2088).
                    if isInvalidSession, provider == .geminiCLI, let backupPath {
                        let didRestore = Self.restoreBackupOverStubIfPresent(
                            backupPath: backupPath,
                            sessionId: resumeId,
                            cwd: activeProjectPath
                        )
                        if didRestore {
                            items.append(.status(
                                id: UUID(),
                                text: "↻ gemini-cli wrote a stub on cold-spawn; restored your conversation from backup and retrying"
                            ))
                            do {
                                isReplayingLoad = true
                                let loadRequest = runtimeLoadRequest(requestedSessionID: resumeId)
                                try await runtime.loadSession(loadRequest)
                                isReplayingLoad = false
                                nativeSessionId = resumeId
                                hasInitialized = true
                                injectSlashCommandPrompts(meta.slashPrompts)
                                return
                            } catch {
                                isReplayingLoad = false
                                // Retry failed; fall through to existing backfill.
                            }
                        }
                    }

                    if isInvalidSession {
                        let result = SoulRegistry.backfillNativeSessionID(
                            projectKey: project.id,
                            sessionId: sid,
                            provider: provider.rawValue,
                            cwd: activeProjectPath
                        )
                        if let backfilled = result.uuid, backfilled != resumeId {
                            items.append(.status(
                                id: UUID(),
                                text: "↻ backfilled native session id \(backfilled.prefix(8))… — retrying"
                            ))
                            do {
                                isReplayingLoad = true
                                let loadRequest = runtimeLoadRequest(requestedSessionID: backfilled)
                                try await runtime.loadSession(loadRequest)
                                isReplayingLoad = false
                                nativeSessionId = backfilled
                                hasInitialized = true
                                injectSlashCommandPrompts(meta.slashPrompts)
                                return
                            } catch {
                                isReplayingLoad = false
                            }
                        }
                    }

                    let dataStr = Self.describeJSONValue(rpc.data)
                    let suffix = dataStr.isEmpty ? "" : " · data: \(dataStr)"
                    let recoverable = isInvalidSession && provider == .claude
                    if recoverable {
                        items.append(.status(
                            id: UUID(),
                            text: "ℹ \(rpc.message) — session not on agent, recovering"
                        ))
                    } else if provider != .geminiCLI {
                        items.append(.error(
                            id: UUID(),
                            text: "session/load rpcError code=\(rpc.code) message=\(rpc.message)\(suffix)"
                        ))
                    }

                    if provider == .geminiCLI {
                        let quarantinedPath: String? = {
                            guard isInvalidSession, backupPath != nil else { return nil }
                            return Self.quarantineCorruptGeminiChat(
                                sessionId: resumeId,
                                cwd: activeProjectPath
                            )
                        }()
                        if let backupPath {
                            pendingRecovery = RecoveryContext(
                                sessionId: sid,
                                backupPath: backupPath,
                                quarantinedPath: quarantinedPath,
                                rpcMessage: rpc.message,
                                title: customTitle
                            )
                        }
                        return
                    }

                    renderHistoryIfAvailable(sid: sid)
                    items.append(.status(id: UUID(), text: "ℹ session could not be resumed — starting fresh"))
                    let newSessionRequest = runtimeNewSessionRequest()
                    let newSessionResult = try await runtime.startNewSession(newSessionRequest)
                    // Keep `sessionId` pinned to the original disk UUID so subsequent
                    // hook writes append to the existing ledger and the sidebar row
                    // merges back onto the resumed disk row instead of splitting into
                    // a duplicate. The provider's freshly-allocated handle belongs
                    // only in `nativeSessionId`; every ACP call site reads it as
                    // `nativeSessionId ?? sessionId`.
                    applyRuntimeNewSessionResult(newSessionResult)
                    hasInitialized = true
                }
            case .codex:
                try await spawnAndInitializeCodex()
            }
        } catch {
            isReplayingLoad = false
            items.append(.error(id: UUID(), text: "load failed: \(error)"))
        }
    }

    /// SOUL-SOUL_DESKTOP-043: render an archived session straight from the
    /// on-disk Claude transcript without spawning an agent. The agent process
    /// is started lazily by `ensureSession()` on the user's first `send()`,
    /// which is when they're already expecting a beat anyway. Versus the
    /// existing `loadSession` path this skips: process spawn (~1–3s),
    /// ACP initialize handshake, and the agent's `session/load` recap stream.
    ///
    /// Claude-only for now; other providers fall through to `loadSession`.
    /// If the on-disk transcript is missing/empty we also fall through so
    /// the user is never stuck staring at an empty canvas.

    func teardown() async {
        logLifecycle("teardown", note: "controller torn down (e.g. row deselected)")
        isTornDown = true
        finalizeWatcher?.stop()
        finalizeWatcher = nil
        // SOUL-SOUL_DESKTOP-245 (cleanup from -243): cancel any in-flight
        // background warm-up before nilling out client. Without this, a
        // user who clicks a row then immediately switches away leaves a
        // spawn-in-progress Task running against a controller that's
        // being torn down, orphaning a child stdio process.
        ensureSessionTask?.cancel()
        // SPEC-245-K hotfix: cancel any in-flight preamble staging so a
        // gemini summarizer call doesn't outlive the controller and burn
        // tokens for nobody.
        preambleStagingTask?.cancel()
        preambleStagingTask = nil
        ensureSessionTask = nil
        eventTask?.cancel()
        await runtimes.stopAll()
        if let cont = codexTurnContinuation {
            codexTurnContinuation = nil
            cont.resume(throwing: NSError(domain: "Codex", code: 99,
                                          userInfo: [NSLocalizedDescriptionKey: "thread torn down"]))
        }
    }

    // MARK: - private

    func ensureSession() async throws {
        // SOUL-SOUL_DESKTOP-243: serialize concurrent callers through one
        // Task. Background spawn-on-click (AppShell+SessionFlow.swift) and
        // a user-initiated first-send can race; without this the second
        // caller would re-enter and double-spawn before the first set
        // hasInitialized = true. Idempotent fast path stays at the top of
        // _ensureSessionImpl for the warm case.
        if let existing = ensureSessionTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self._ensureSessionImpl()
        }
        ensureSessionTask = task
        defer { ensureSessionTask = nil }
        try await task.value
    }

    /// SOUL-SOUL_DESKTOP-358: `ensureSession()` can throw an invalid-session
    /// rpcError — `session/new` or `session/load` failing during stop/stall
    /// recovery or resume. That throw used to escape straight to
    /// `dispatchPending`'s generic catch and paint a raw "Invalid params" row,
    /// bypassing the transparent recovery the prompt loop already performs
    /// (`ThreadController+Turn.swift`, the `isInvalidSessionRPC` catch).
    ///
    /// Retry once on a clean fresh session: tear the child down, drop the
    /// stale native id and the resume flag so the retry takes the plain
    /// `session/new` path (no stale id to re-reject), and surface a status
    /// row matching the prompt-loop UX. If the retry also fails, the error
    /// propagates to the caller's catch and is surfaced as before — we don't
    /// loop indefinitely.
    func ensureSessionResilient() async throws {
        do {
            try await ensureSession()
        } catch ACPClientError.rpcError(let rpc) where Self.isInvalidSessionRPC(rpc) {
            logLifecycle("ensureSessionResilient.retry", note: "code=\(rpc.code) msg=\(rpc.message)")
            items.append(.status(id: UUID(), text: "ℹ \(rpc.message) — re-establishing session"))
            await resetProviderProcessAfterInterruptedTurn()
            // No in-flight prompt was awaiting here (the failure was at session
            // establishment, before any prompt), so don't let the teardown's
            // suppress flag swallow a genuine error on the retry turn.
            suppressNextInterruptedTurnError = false
            nativeSessionId = nil
            pendingResumeOnFirstSend = false
            try await ensureSession()
        }
    }

    private func _ensureSessionImpl() async throws {
        logLifecycle("ensureSession enter",
                     note: "hasInitialized=\(hasInitialized) runtimes.acp=\(runtimes.acp != nil) runtimes.codex=\(runtimes.codex != nil) sessionId=\(sessionId ?? "nil") nativeSessionId=\(nativeSessionId ?? "nil") pendingResumeOnFirstSend=\(pendingResumeOnFirstSend)")
        // SOUL-364 block guarantee: if per-session worktree provisioning failed
        // under the .block policy, refuse to spawn. Without this, a resend after
        // the blocked first turn would route through here and silently spawn in
        // the shared checkout — the exact collision isolation is meant to
        // prevent. `.notAttempted` (resumed sessions, non-git projects) is a
        // no-op. Not an rpcError, so ensureSessionResilient won't retry it.
        if case .blocked(let reason) = worktreeProvisionState {
            throw GitWorktreeError.custom(
                "Isolated worktree unavailable (\(reason)). Resolve the git error and start a new chat, or enable worktree fallback in settings."
            )
        }
        if provider == .codex {
            if hasInitialized, runtimes.codex != nil, sessionId != nil { return }
            try await spawnAndInitializeCodex()
            return
        }
        if hasInitialized, runtimes.acp != nil, sessionId != nil { return }

        // SPEC-245-K hotfix: hydrate kicks off preamble staging in a
        // background Task. Await it here so pendingContextPreamble +
        // pendingPreambleChannel are populated before mintFreshNativeSession
        // reads them. Free for fast verbatim renders (~76ms) and visible
        // to the user as a brief "thinking" state for summarizer calls
        // (~16s) — but only on the first send, not on the canvas paint.
        if let task = preambleStagingTask {
            await task.value
            preambleStagingTask = nil
        }

        // SOUL-SOUL_DESKTOP-245 (Phase B): stop / stall recovery. Manual
        // cancel tears down the child process; on the next send we used
        // to call session/load to re-register the prior native sid with
        // the agent. That worked but re-fed the entire transcript to the
        // model — same overflow class as the archive-open path. Now we
        // mint a fresh native sid and stage a preamble built from the
        // current in-canvas items so the agent picks up where it left off
        // without re-reading every prior turn. Kernel sid preserved.
        if let sid = sessionId, nativeSessionId != nil {
            try await spawnAndInitialize(skipNewSession: true)
            guard runtimes.acp != nil else { return }
            // Stop-recovery path: we already have a live session AND a
            // user prompt waiting. Awaiting here is fine — there's no
            // hydrate-skeleton race because the canvas was already
            // painted in a prior turn. Latency hits the spinner the
            // user expects when they hit "Send" anyway.
            await stagePreambleForResume(sid: sid, rendered: items)
            try await mintFreshNativeSession(
                kernelSid: sid,
                reason: "stop/stall recovery — Phase B fresh-session bypass",
                variant: .phaseBBypass
            )
            return
        }

        // SOUL-SOUL_DESKTOP-245 (Phase B): bypass-first resume. We
        // hydrated the canvas from the kernel ledger; rather than asking
        // the agent to `session/load` and replay the full transcript
        // (which overflows the context window on long sessions and forces
        // the user to watch an AI recap they didn't ask for), mint a
        // fresh native session and let the preamble we staged in hydrate
        // carry the prior conversation as inline context on first send.
        // Kernel sid is preserved by mintFreshNativeSession — same row,
        // same ledger, new agent process.
        if pendingResumeOnFirstSend, let sid = sessionId {
            pendingResumeOnFirstSend = false
            try await spawnAndInitialize(skipNewSession: true)
            guard runtimes.acp != nil else { return }
            try await mintFreshNativeSession(
                kernelSid: sid,
                reason: pendingContextPreamble != nil
                    ? "Phase B bypass — preamble carries prior context"
                    : "Phase B bypass — no preamble (empty / too large)",
                variant: .phaseBBypass
            )
            return
        }

        logLifecycle("ensureSession.newSession",
                     note: "no live client, no native id — minting fresh session via client.newSession")
        try await spawnAndInitialize(skipNewSession: false)
        guard let runtime = runtimes.acp else { return }
        let newSessionRequest = runtimeNewSessionRequest()
        let newSessionResult = try await runtime.startNewSession(newSessionRequest)
        let nid = newSessionResult.nativeSessionID
        // SOUL-SOUL_DESKTOP-161 follow-up: preserve the kernel sessionId
        // when this controller was rehydrated from a kernel ledger. The
        // kernel sid is the durable identity; the native sid is a
        // per-provider cache key. Without this guard, the orphan-
        // transcript resume path (hydrate from hooks.jsonl + first send)
        // would clobber the original kernel UUID with the fresh native
        // UUID, splitting the ledger across two registry dirs and
        // producing a duplicate sidebar row for what's logically one
        // conversation. Matches the same pattern Codex already uses in
        // `spawnAndInitializeCodex` (ThreadController+Codex.swift:58).
        if sessionId == nil {
            // Kernel sid MUST be a UUID — the rest of the app (hydrate
            // guard at ThreadController+Hydrate.swift:28, loadSession
            // guard at Lifecycle.swift:24, sidebar row routing) keys off
            // that invariant. Claude/Gemini return UUIDs from
            // session/new; pi-acp returns its own id format which fails
            // the strict UUID check and produces "session id is not a
            // UUID; cannot resume" on subsequent opens (SOUL-196).
            // Mint a UUID kernel sid when the provider's id isn't one;
            // pi-acp's value lives on as nativeSessionId.
            sessionId = Self.looksLikeUUID(nid) ? nid : UUID().uuidString.lowercased()
        }
        applyRuntimeNewSessionResult(newSessionResult)
        hasInitialized = true
        guard let kernelSid = sessionId else { return }

        // SOUL-FINALIZE-PARITY-001: write the kernel sid to
        // /tmp/soul_last_session_id so a `soul finalize` call from the spawned
        // agent (which didn't have SOUL_SESSION_ID at spawn time) hits the
        // kernel's existing fallback path (soul_finalize.sh line ~104) and
        // tags its JSON with the desktop's sid. Best-effort write — the
        // worst case is the script falls back to mint_session_uuid() and the
        // FinalizeCard fails to match, which is the pre-fix status quo.
        try? kernelSid.write(toFile: "/tmp/soul_last_session_id", atomically: true, encoding: .utf8)

        // Persist the provider's native sessionId alongside the kernel ledger
        // for this session. For kernel-ledger-resumed sessions this mapping
        // is load-bearing: without it `findNativeSessionID(kernelSid)` can't
        // resolve back to the freshly-minted provider UUID, the transcript
        // readers miss the new chat file, and the next reopen re-renders the
        // pre-resume ledger as if nothing happened.
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: kernelSid,
            event: LedgerHookEvent.nativeSessionID(
                provider: provider.rawValue,
                nativeID: nid,
                cwd: activeProjectPath
            ).hookDictionary
        )
        // SOUL-IDENTITY-SPLIT: same watcher init as the fresh-session path.
        ensureTranscriptWatcher()
    }

    /// Recovery helper: the saved native UUID was rejected by the agent
    /// (transcript rotated, user trashed it, agent process forgot it).
    /// Mint a fresh session/new under the existing kernel sid and persist
    /// the mapping so future resumes hit the new UUID. Adds an inline
    /// status row so the user knows the resume failed silently and new
    /// turns will be in a fresh agent session.
    /// Variant marker for the status row. SOUL-SOUL_DESKTOP-245 (Phase B)
    /// callers shouldn't surface "resume failed" — they never tried to
    /// resume in the first place, they intentionally bypassed loadSession.
    enum MintReason {
        case staleResume   // legacy: loadSession rpcError, falling through
        case phaseBBypass  // happy path: deliberate bypass of session/load
    }

    private func mintFreshNativeSession(
        kernelSid: String,
        reason: String,
        variant: MintReason = .staleResume
    ) async throws {
        logLifecycle("ensureSession.mintFreshNativeSession", note: reason)
        switch variant {
        case .staleResume:
            items.append(.status(
                id: UUID(),
                text: "ℹ resume failed (\(reason)) — starting a fresh \(provider.rawValue) session for new turns"
            ))
        case .phaseBBypass:
            // Happy path: canvas is already painted from the ledger and
            // the preamble (if any) is queued for first send. No user-
            // visible status row — the experience should feel like the
            // session just opened.
            break
        }
        // SPEC-245-K step 4: if hydrate staged a preamble for the
        // claude_system_meta channel, send it via _meta.systemPrompt on
        // session/new instead of prefixing it to the first user prompt.
        // claude-agent-acp consumes _meta.systemPrompt as the session's
        // system message; other providers ignore unknown _meta keys, so
        // the kernel only routes claude here today. Clear after consume
        // so dispatchPending doesn't double-inject.
        let systemPrompt: String?
        if pendingPreambleChannel == .claudeSystemMeta,
           let pre = pendingContextPreamble {
            systemPrompt = pre
            pendingContextPreamble = nil
            logLifecycle("preamble.system_inject", note: "chars=\(pre.count) channel=claude_system_meta")
        } else {
            systemPrompt = nil
        }
        let newSessionRequest = runtimeNewSessionRequest(systemPrompt: systemPrompt)
        guard let runtime = runtimes.acp else { return }
        let newSessionResult = try await runtime.startNewSession(newSessionRequest)
        let nid = newSessionResult.nativeSessionID
        applyRuntimeNewSessionResult(newSessionResult)
        hasInitialized = true
        try? kernelSid.write(toFile: "/tmp/soul_last_session_id", atomically: true, encoding: .utf8)
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: kernelSid,
            event: LedgerHookEvent.nativeSessionIDRecovery(
                provider: provider.rawValue,
                nativeSessionID: nid,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ).hookDictionary
        )
        // SOUL-IDENTITY-SPLIT: start watching the encoded Claude dir for
        // post-/compact transcript rotations. No-op for non-Claude.
        ensureTranscriptWatcher()
    }

    private func spawnAndInitialize(skipNewSession: Bool, resumeSessionId: String? = nil) async throws {
        ComputerUseMCPConfig.reconcileEnabledProvider(for: provider)
        if provider == .codex {
            try await spawnAndInitializeCodex()
            return
        }
        if await runtimes.acp?.isStarted == true { return }

        // SOUL-FINALIZE-PARITY-001 + SOUL-SPLIT-LEDGER-001: forward the
        // desktop-resolved kernel sid so `soul finalize` AND every kernel
        // hook the agent fires (middleware_runner.py, tracer.py) writes
        // under the same sid Soul-Desktop already holds. Two bugs sharing
        // one fix slot:
        //   1. Finalize sid mismatch: without SOUL_SESSION_ID the kernel's
        //      mint_session_uuid() fallback returns a fresh uuid that
        //      latestFinalize() never matches → FinalizeCard never renders.
        //   2. Split-ledger (the gemini-cli case): kernel middleware writes
        //      hooks.jsonl under input_data["session_id"] = gemini's
        //      native ISO_UUIDv7 id, while Soul-Desktop writes under the
        //      kernel UUID. Two sibling dirs for the same turn. With
        //      SOUL_SESSION_ID present at spawn, middleware_runner.py
        //      rewrites input_data["session_id"] before the persist hop,
        //      so both writers land in the same kernel-UUID dir.
        //
        // Resumed sessions have `sessionId` from assignSessionId(). Fresh
        // sessions previously got it post-spawn (after session/new), too
        // late for the first hook fire. Pre-mint here so the env var is
        // populated at spawn time; line 342 ("if sessionId == nil ...")
        // will be a no-op when we pre-mint.
        if sessionId == nil {
            // The controller id is already the provisional kernel id used by
            // early UI/queue code before ensureSession runs. Adopt it rather
            // than minting a second UUID here, or the first turn can split:
            // UserPrompt under controller.id, provider hooks under the new
            // SOUL_SESSION_ID.
            sessionId = Self.looksLikeUUID(id) ? id : UUID().uuidString.lowercased()
        }
        let runtime = runtimes.acp ?? ACPProviderRuntimeAdapter(
            provider: provider.agentProvider,
            projectKey: project.id,
            provisionalSessionID: id,
            spawnResolver: runtimeSpawnResolver(),
            hydrationPreparer: runtimeHydrationPreparer()
        )
        runtimes.acp = runtime
        let startResult = try await runtime.start(runtimeStartRequest(
            skipNewSession: skipNewSession,
            resumeSessionId: resumeSessionId
        ))

        guard let stream = await runtime.eventStream() else { return }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }
        applyRuntimeStartResult(startResult)
    }

}
