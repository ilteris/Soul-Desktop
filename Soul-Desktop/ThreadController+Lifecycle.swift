import Foundation

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
                guard let client else { return }
                let resumeId = nativeId ?? sid

                let backupPath = Self.backupAgentChatIfPresent(
                    provider: provider,
                    sessionId: resumeId,
                    cwd: project.path
                )
                do {
                    isReplayingLoad = true
                    try await client.loadSession(sessionId: resumeId, cwd: project.path)
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
                            cwd: project.path
                        )
                        if didRestore {
                            items.append(.status(
                                id: UUID(),
                                text: "↻ gemini-cli wrote a stub on cold-spawn; restored your conversation from backup and retrying"
                            ))
                            do {
                                isReplayingLoad = true
                                try await client.loadSession(sessionId: resumeId, cwd: project.path)
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
                            cwd: project.path
                        )
                        if let backfilled = result.uuid, backfilled != resumeId {
                            items.append(.status(
                                id: UUID(),
                                text: "↻ backfilled native session id \(backfilled.prefix(8))… — retrying"
                            ))
                            do {
                                isReplayingLoad = true
                                try await client.loadSession(sessionId: backfilled, cwd: project.path)
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
                                cwd: project.path
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
                    let newSid = try await client.newSession(cwd: project.path)
                    sessionId = newSid
                    nativeSessionId = newSid
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
        finalizeWatcher?.stop()
        finalizeWatcher = nil
        // SOUL-SOUL_DESKTOP-245 (cleanup from -243): cancel any in-flight
        // background warm-up before nilling out client. Without this, a
        // user who clicks a row then immediately switches away leaves a
        // spawn-in-progress Task running against a controller that's
        // being torn down, orphaning a child stdio process.
        ensureSessionTask?.cancel()
        ensureSessionTask = nil
        eventTask?.cancel()
        await client?.stop()
        client = nil
        await codexClient?.stop()
        codexClient = nil
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

    private func _ensureSessionImpl() async throws {
        logLifecycle("ensureSession enter",
                     note: "hasInitialized=\(hasInitialized) client=\(client != nil) codexClient=\(codexClient != nil) sessionId=\(sessionId ?? "nil") nativeSessionId=\(nativeSessionId ?? "nil") pendingResumeOnFirstSend=\(pendingResumeOnFirstSend)")
        if provider == .codex {
            if hasInitialized, codexClient != nil, sessionId != nil { return }
            try await spawnAndInitializeCodex()
            return
        }
        if hasInitialized, client != nil, sessionId != nil { return }

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
            guard let client else { return }
            await stagePreambleForResume(sid: sid, rendered: items)
            try await mintFreshNativeSession(
                client: client,
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
            guard let client else { return }
            try await mintFreshNativeSession(
                client: client,
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
        guard let client else { return }
        let nid = try await client.newSession(cwd: project.path)
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
        nativeSessionId = nid
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
        SoulRegistry.appendHook(projectKey: project.id, sessionId: kernelSid, event: [
            "event": "NativeSessionID",
            "provider": provider.rawValue,
            "nativeId": nid,
            "cwd": project.path,
        ])
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
        client: ACPClient,
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
        let nid = try await client.newSession(cwd: project.path, systemPrompt: systemPrompt)
        nativeSessionId = nid
        hasInitialized = true
        try? kernelSid.write(toFile: "/tmp/soul_last_session_id", atomically: true, encoding: .utf8)
        SoulRegistry.appendHook(projectKey: project.id, sessionId: kernelSid, event: [
            "event": "NativeSessionID",
            "native_session_id": nid,
            "provider": provider.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func spawnAndInitialize(skipNewSession: Bool, resumeSessionId: String? = nil) async throws {
        if provider == .codex {
            try await spawnAndInitializeCodex()
            return
        }
        if client != nil { return }

        guard var spawn = ACPProviderSpawn.resolve(provider, resumeSessionId: resumeSessionId) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no spawn config for \(provider.label)"])
        }

        // Spawn-time bookkeeping (hydration log, initialize handshake,
        // session/new ack) used to write status rows here. They were chatty
        // and told the user nothing actionable when the path was healthy;
        // failures surface as thrown errors or the agent-stderr popover.
        // Keep the work, drop the rows.
        let hydration = await SoulHydration.prepare(
            provider: provider,
            projectKey: project.id,
            projectPath: project.path,
            sessionId: id
        )

        var env = spawn.environment ?? [:]
        for (k, v) in hydration.env { env[k] = v }
        // SOUL_PROJECT contract: declare the desktop-selected project key
        // explicitly so kernel hooks (middleware_runner, soul_trace_commit,
        // pi soul-orchestrator) don't re-derive a different key from cwd
        // and split the ledger across two ~/soul_registry/sessions/<key>/
        // buckets for the same session UUID. See SOUL-PROJECT-KEY-CONTRACT-001.
        env["SOUL_PROJECT"] = project.id
        // SOUL-FINALIZE-PARITY-001: forward the desktop-resolved kernel sid so
        // `soul finalize` (and any other kernel CLI the agent shells out to)
        // writes under the same sid the desktop holds. Without this, the
        // agent's env has GEMINI_SESSION_ID / SOUL_THREAD_ID unset and
        // mint_session_uuid() returns a fresh uuid that latestFinalize()
        // never matches → FinalizeCard never renders.
        //
        // For resumed sessions `sessionId` is set by assignSessionId() before
        // spawn. For fresh sessions the kernel sid is whatever the ACP agent
        // mints in newSession(), which happens after spawn — so we can't pre-
        // populate. The composer-side /finalize expansion picks up the sid
        // at type-time as the fallback for that case.
        if let sid = sessionId {
            env["SOUL_SESSION_ID"] = sid
        }
        spawn.environment = env
        spawn.cwd = project.path

        let client = try ACPClient(spawn: spawn)
        self.client = client
        await client.setAutoAllow(true)
        await client.setPermissionMode(permissionMode)
        try await client.start()

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }

        let initResp = try await client.initialize()
        supportsLoadSession = initResp.agentCapabilities?.loadSession ?? false
    }

}
