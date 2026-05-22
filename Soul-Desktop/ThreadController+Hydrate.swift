import Foundation

/// Read-first hydration + finalize-summary injection helpers, lifted out
/// of ThreadController. The big `hydrateFromDisk(id:)` method that
/// rebuilds an archived session's transcript from the kernel ledger
/// lives here, along with the recovery affordances around it (Claude/
/// Gemini chat backup + quarantine, slash-prompt re-injection) and the
/// FinalizeCard injection routines triggered by the FinalizeWatcher.
///
/// Pure file shuffle, no behavior change. Refactor 7/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
extension ThreadController {

    func hydrateFromDisk(id sid: String) async {
        guard !hasInitialized else { return }
        let hydrateInterval = SoulSignposts.beginInterval("ThreadController.hydrateFromDisk", id: sid)
        // SOUL-SOUL_DESKTOP-231: gate the ThreadView skeleton overlay. Set
        // true on entry, flipped false in `defer` so EVERY return path
        // (success, empty-history, error, codex short-circuit, all of them)
        // clears it. The skeleton flashes off the moment hydrate is done
        // and the LazyVStack takes over with fully-populated items.
        isHydrating = true
        defer {
            isHydrating = false
            SoulSignposts.endInterval("ThreadController.hydrateFromDisk", state: hydrateInterval)
        }
        // Hydrate handles all four providers. Claude / Gemini-CLI try their
        // dedicated transcript readers first and fall back to the kernel
        // hooks ledger when those return nil. Codex / Pi go straight to the
        // kernel ledger — neither has a provider-side transcript reader,
        // and pi-acp's chat file format isn't wired in yet (see -123).
        guard provider == .claude || provider == .geminiCLI || provider == .codex || provider == .pi else {
            await loadSession(id: sid)
            return
        }
        // SOUL-205: don't reject non-UUID sids. Pi-acp historically returned
        // its own id format before SOUL-196 minted a UUID kernel sid; those
        // legacy registry directories are still on disk and the user can't
        // reach them otherwise. The kernel ledger is happy with any non-empty
        // filesystem-safe string. Only bail on empty.
        guard !sid.isEmpty else {
            items.append(.error(id: UUID(), text: "missing session id"))
            return
        }
        // Establish kernel identity immediately so subsequent appendHooks
        // (e.g. a fast send() before hydrate finishes) write under the right
        // directory.
        sessionId = sid

        // Off-main: a 33h Claude transcript is multi-MB of JSONL. Parsing on
        // the main actor would beach-ball the sidebar click; mirror the
        // ReplayController pattern and hand the file work to a detached task.
        let proj = project
        let prov = provider
        struct HydrateResult {
            var history: [ThreadItem]?
            var title: String?
            var nativeId: String?
            var slashPrompts: [(text: String, timestamp: Date)] = []
        }
        let result: HydrateResult = await Task.detached(priority: .userInitiated) {
            var r = HydrateResult()
            // Native UUID lookup happens *before* the transcript read because
            // terminal-origin Gemini sessions are filed under a gemini-side
            // UUID that differs from the kernel UUID. Claude's identity-
            // mapped sessions use sid for both — passing sid through still
            // works when nativeId is nil.
            r.nativeId = SoulRegistry.findNativeSessionID(projectKey: proj.id, sessionId: sid, provider: prov.rawValue)
            let lookupId = r.nativeId ?? sid
            switch prov {
            case .claude:
                r.history = ClaudeTranscriptReader.transcript(forSession: lookupId, cwd: proj.path)
            case .geminiCLI:
                r.history = GeminiTranscriptReader.transcript(forSession: lookupId, projectKey: proj.id)
            case .pi:
                // Try pi-acp's own chat file first (SOUL-SOUL_DESKTOP-140).
                // Matches the Claude/Gemini happy path: rich content from
                // the provider transcript when we have its native UUID,
                // kernel-ledger fallback when we don't. The fallback runs
                // in the empty-history block below.
                r.history = PiTranscriptReader.transcript(forSession: lookupId, cwd: proj.path)
            case .codex:
                // Codex has no off-disk transcript file we can read (no
                // rollout reader yet), but the kernel hooks ledger carries
                // every UserPrompt (always) and every AfterAgent reply
                // (for sessions created/used after the codex AfterAgent
                // capture landed). Render those so a click on a codex row
                // shows prior content instead of a blank fresh thread.
                let events = HooksReader.events(forSession: sid, project: proj)
                r.history = events.map { $0.item }
            }
            r.title = SoulRegistry.findTitle(projectKey: proj.id, sessionId: sid)
            r.slashPrompts = SoulRegistry.slashCommandPrompts(projectKey: proj.id, sessionId: sid)
            return r
        }.value

        // Transcript reader returned nothing. Before falling through to the
        // ACP eager loadSession (which fails noisily for externally-authored
        // sessions whose provider-side UUID we never recorded), try the
        // kernel hooks ledger — same Codex-style fallback. Externally-authored
        // Claude/Gemini sessions have UserPrompt + AfterTool + AfterAgent in
        // our hooks.jsonl; rendering those gives the user a visible canvas
        // instead of staring at an empty thread. First send spawns a fresh
        // provider session (no nativeId to resume against), matching Codex.
        if result.history == nil || result.history?.isEmpty == true {
            let ledgerItems = HooksReader.events(forSession: sid, project: proj).map { $0.item }
            if !ledgerItems.isEmpty {
                if let t = result.title, !t.isEmpty { customTitle = t }
                nativeSessionId = result.nativeId
                historicalIDs.formUnion(ledgerItems.lazy.map(\.id))
                items.append(contentsOf: ledgerItems)
                injectSlashCommandPrompts(result.slashPrompts)
                injectFinalizeSummary(sessionId: sid)
                // SOUL-SOUL_DESKTOP-245 (Phase B): mint preamble from the
                // ledger items so the fresh provider session gets the
                // prior conversation as inline context on first send.
                // Previously this branch had no resume path at all — the
                // agent started cold and the user had to recap manually.
                // Don't await — detach to a background Task so the
                // kernel CLI (potentially 20s when summarizing) doesn't
                // pin hydrate's loading state. ensureSession awaits this
                // before reading pendingContextPreamble/Channel.
                preambleStagingTask?.cancel()
                let stagingSid = sid
                let stagingItems = items
                preambleStagingTask = Task { [weak self] in
                    await self?.stagePreambleForResume(sid: stagingSid, rendered: stagingItems)
                }
                pendingResumeOnFirstSend = true
                return
            }
            // SOUL-SOUL_DESKTOP-245 follow-up: hooks.jsonl exists but every
            // event has empty text/content (kernel writer payload-drop bug —
            // see SOUL-SOUL_DESKTOP-247). HooksReader filters those out so
            // ledgerItems is empty even though the session had real turns.
            // Previously this fell through to `await loadSession(id:)` which
            // is the pre-Phase-B legacy ACP path — that await pinned
            // isHydrating=true and the canvas stayed on the skeleton
            // forever. Take the same preamble-staged path the populated-
            // hooks branch uses; finalize JSON injection still surfaces
            // the session's Intent/Summary/Next so the canvas isn't
            // truly empty, and ensureSession on first send mints a fresh
            // provider session instead of spawning + loading.
            let hooksPath = SoulRegistry.hooksPath(projectKey: proj.id, sessionId: sid)
            if FileManager.default.fileExists(atPath: hooksPath) {
                if let t = result.title, !t.isEmpty { customTitle = t }
                nativeSessionId = result.nativeId
                injectFinalizeSummary(sessionId: sid)
                items.append(.status(id: UUID(), text: "ℹ session ledger present but turn content was dropped at write-time — finalize summary above; new turns start fresh"))
                preambleStagingTask?.cancel()
                let stagingSid = sid
                let stagingItems = items
                preambleStagingTask = Task { [weak self] in
                    await self?.stagePreambleForResume(sid: stagingSid, rendered: stagingItems)
                }
                pendingResumeOnFirstSend = true
                return
            }
            if let t = result.title, !t.isEmpty { customTitle = t }
            nativeSessionId = result.nativeId
            items.append(.status(id: UUID(), text: "ℹ this session has no offline transcript on this machine — type to start a fresh chat"))
            return
        }
        let history = result.history!

        // Preserve a caller-seeded title (AppShell sets customTitle from the
        // session row before this Task starts). Only overwrite if the
        // registry returned a non-empty title — a nil/empty value here used
        // to stomp the seed and leave the synthetic sidebar row reading
        // "New chat".
        if let t = result.title, !t.isEmpty { customTitle = t }
        nativeSessionId = result.nativeId
        // SOUL-SOUL_DESKTOP-097: bulk-update; see commit 88aead0.
        historicalIDs.formUnion(history.lazy.map(\.id))
        items.append(contentsOf: history)
        // Slash-command UserPrompt hooks (captured by the kernel before the
        // model API ever saw them) don't appear in the Claude transcript —
        // merge them in by timestamp so chip rendering stays consistent.
        injectSlashCommandPrompts(result.slashPrompts)
        // Surface the Quad from any finalize JSON for this session. The
        // structured summary (Intent / Summary / Rationale / Fixed / Next)
        // lives in `~/soul_registry/sessions/<project>/<ts>_<sid>.json` —
        // recorded by `/finalize` but otherwise never rendered to the user.
        // Injecting it at the tail of the loaded transcript means clicking
        // a finalized row immediately answers "what did we accomplish here?"
        // without anyone needing to `cat` the JSON.
        injectFinalizeSummary(sessionId: sid)
        // SOUL-SOUL_DESKTOP-245 (Phase B): bypass-first resume. Render
        // the prior items into a text preamble that gets prefixed to the
        // user's first prompt in dispatchPending. This replaces the old
        // session/load resume path that re-fed the entire transcript to
        // the agent and overflowed the context window on long sessions.
        //
        // SOUL-245 hotfix (followup): detach the preamble staging so
        // `hydrateFromDisk`'s defer fires immediately after items are
        // populated. The `soul preamble --summarize` kernel CLI can take
        // 30-60s on heavy sessions (92 turns / 200+ tool calls); awaiting
        // it inline pinned `isHydrating = true` for that entire window and
        // left the canvas stuck on the skeleton overlay. The fallback
        // paths above already detach via `preambleStagingTask`; this
        // mirrors that. ensureSession awaits the same task before reading
        // pendingContextPreamble, so the resume preamble still lands on
        // the first user send.
        preambleStagingTask?.cancel()
        let stagingSid = sid
        let stagingItems = items
        preambleStagingTask = Task { [weak self] in
            await self?.stagePreambleForResume(sid: stagingSid, rendered: stagingItems)
        }
        pendingResumeOnFirstSend = true
    }

    /// SOUL-SOUL_DESKTOP-245 SPEC-245-K (Phase A step 2). Build the
    /// preamble via the kernel CLI (`soul preamble`) instead of running
    /// the Swift renderer. Kernel reads hooks.jsonl + finalize JSON,
    /// caches the result, and returns text-or-truncated-flag. The Swift
    /// renderer (LedgerPreamble.build) remains as a fallback for the
    /// CLI-unavailable case, since this method runs on the click path
    /// and degrading to "no preamble" is worse than degrading to a
    /// stale-by-one-turn render.
    func stagePreambleForResume(sid: String, rendered: [ThreadItem]) async {
        do {
            let payload = try await SoulCLI.runJSON(
                ["preamble", "--session", sid, "--project", project.id,
                 "--provider", provider.rawValue,
                 "--format", "json", "--summarize"],
                as: PreamblePayload.self
            )
            guard !payload.preamble.isEmpty else { return }
            pendingContextPreamble = payload.preamble
            // SPEC-245-K step 4: record the kernel-decided channel so
            // mintFreshNativeSession (system-meta path) or dispatchPending
            // (user-prefix path) consumes the preamble at the right moment.
            pendingPreambleChannel = payload.resolvedChannel
            return
        } catch SoulCLIError.nonZeroExit(let code, let stderr) where code == 2 {
            // Exit 2 = ledger exceeded --max-chars and summarizer is not
            // ready (Phase A step 3). Surface honestly; agent starts fresh.
            items.append(.status(
                id: UUID(),
                text: "ℹ prior context too large for direct injection — agent will start fresh until summarizer ships"
            ))
            _ = stderr
            pendingContextPreamble = nil
            return
        } catch SoulCLIError.executableNotFound {
            // Kernel not on PATH. Don't strand the user — fall through to
            // the Swift renderer so resume still works.
            logLifecycle("preamble.cli.missing", note: "falling back to Swift renderer")
        } catch SoulCLIError.nonZeroExit(let code, let stderr) {
            // Exit 3 (no hooks.jsonl), 4 (summarizer fail), or unknown.
            // Log and fall through to the Swift renderer.
            logLifecycle("preamble.cli.error", note: "code=\(code) stderr=\(stderr.prefix(200))")
        } catch {
            logLifecycle("preamble.cli.error", note: "\(error)")
        }
        // Fallback: Swift renderer against the in-memory items. Matches
        // the Phase B behavior so a kernel hiccup doesn't kill resume.
        guard let built = LedgerPreamble.build(from: rendered) else { return }
        if built.truncated {
            items.append(.status(
                id: UUID(),
                text: "ℹ prior context too large for direct injection (\(built.turnCount) turns) — agent will start fresh until summarization ships"
            ))
            pendingContextPreamble = nil
            return
        }
        pendingContextPreamble = built.text
    }

    /// SOUL-SOUL_DESKTOP-245 (Phase B, visibility helper). Records the
    /// preamble payload to two places so you can actually see what got
    /// sent: a one-line summary into the lifecycle log (visible in the
    /// right-panel agent log AND ~/Library/Logs/Soul-Desktop/acp-
    /// protocol.jsonl), plus the full text to
    /// `<SOUL_HOME>/sessions/<project>/<sid>/preamble.txt` — a
    /// plain file you can `cat` after the click. Overwritten on each
    /// injection so the latest send is always what's there.
    func recordPreambleInjection(_ preamble: String) {
        logLifecycle(
            "preamble.inject",
            note: "chars=\(preamble.count) sessionId=\(sessionId ?? "nil") — see \(SoulRegistry.primarySessionsRoot)/\(project.id)/\(sessionId ?? "")/preamble.txt"
        )
        guard let sid = sessionId else { return }
        let dir = URL(fileURLWithPath: SoulRegistry.primarySessionsRoot)
            .appendingPathComponent(project.id)
            .appendingPathComponent(sid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("preamble.txt")
        try? preamble.write(to: path, atomically: true, encoding: .utf8)
    }

    static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Render a JSONValue payload as a compact string for the error row.
    /// We don't try to be cute about it — JSON-encode and truncate so any
    /// shape lands as a single readable line the user can copy back.
    static func describeJSONValue(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) {
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        }
        return ""
    }

    /// SOUL-SOUL_DESKTOP-103: matches the "agent doesn't know this sid"
    /// rpcError surface across providers. Gemini-CLI raises -32602 / -32603
    /// with messages mentioning "invalid session" or "session id"; Claude
    /// raises -32002 with "resource not found." Used by both the session/load
    /// recovery path (SOUL-SOUL_DESKTOP-022) and the mid-conversation
    /// session/prompt recovery path (SOUL-SOUL_DESKTOP-103).
    static func isInvalidSessionRPC(_ rpc: JSONRPCError) -> Bool {
        let lowerMsg = rpc.message.lowercased()
        return rpc.code == -32602
            || rpc.code == -32002
            || lowerMsg.contains("invalid session")
            || lowerMsg.contains("session id")
            || lowerMsg.contains("resource not found")
    }

    /// Best-effort snapshot of the agent's chat file before a resume attempt.
    /// Copies `<chatsDir>/session-…-<first8>.json{,l}` → `<file>.bak-<epoch>`.
    /// Returns the backup path if a copy was made, nil otherwise. Failures
    /// are silent — this is belt-and-suspenders, not a correctness gate.
    static func backupAgentChatIfPresent(provider: Provider, sessionId: String, cwd: String) -> String? {
        guard provider == .geminiCLI else { return nil }
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }
        let needle = String(sessionId.prefix(8))
        let candidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl"))
        }
        // Pick the largest matching file — that's the one with real history,
        // not a previous-attempt stub.
        let resolved = candidates.max(by: { a, b in
            let aSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(a)")[.size] as? Int) ?? 0
            let bSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(b)")[.size] as? Int) ?? 0
            return aSize < bSize
        })
        guard let match = resolved else { return nil }
        let src = "\(chatsDir)/\(match)"
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = "\(src).bak-\(stamp)"
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// SOUL-SOUL_DESKTOP-153: detect-and-undo gemini-cli's destructive-stub
    /// behavior on cold-spawn session/load. When `client.loadSession(sid)`
    /// is issued against a freshly-spawned gemini-cli process, the server's
    /// `ChatRecordingService.initialize()` else branch (verified at
    /// chatRecordingService.ts:368-436) writes a new header-only file with
    /// a fresh timestamp + the requested sid AND drops the original. The
    /// subsequent session/prompt rpcErrors with `Invalid session identifier`
    /// because that stub has `hasUserOrAssistantMessage: false` and is
    /// filtered out of `listSessions()` (sessionUtils.ts:283).
    ///
    /// Recovery: if the backup we took before the failed loadSession is
    /// strictly larger than any live chat file matching this sid, restore
    /// the backup over the stub. The next session/load retry sees the
    /// real history.
    ///
    /// Returns true if a restore happened.
    static func restoreBackupOverStubIfPresent(
        backupPath: String,
        sessionId sid: String,
        cwd: String
    ) -> Bool {
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return false }
        let needle = String(sid.prefix(8))
        let liveCandidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl")) &&
            !$0.contains(".bak-") && !$0.contains(".corrupt-")
        }
        guard let backupSize = (try? fm.attributesOfItem(atPath: backupPath)[.size] as? Int),
              backupSize > 0
        else { return false }

        var restored = false
        for entry in liveCandidates {
            let livePath = "\(chatsDir)/\(entry)"
            guard let liveSize = (try? fm.attributesOfItem(atPath: livePath)[.size] as? Int)
            else { continue }
            // Heuristic: a stub is dramatically smaller than the backup
            // (just a single header line, typically <500 bytes vs multi-KB
            // for a real conversation). Use strict less-than so we never
            // overwrite a real file that's somehow grown larger than what
            // we snapshotted.
            if liveSize < backupSize {
                do {
                    try fm.removeItem(atPath: livePath)
                    try fm.copyItem(atPath: backupPath, toPath: livePath)
                    restored = true
                } catch {
                    continue
                }
            }
        }
        return restored
    }

    /// Move a broken gemini-cli chat file out of the way so future click-to-
    /// resume attempts don't keep failing on the same parse error. The
    /// matching file (selected the same way as `backupAgentChatIfPresent`)
    /// is renamed to `.corrupt-<epoch>` alongside the `.bak` snapshot. After
    /// this, `SessionLoadability.canLoadFromDisk` returns false for the row,
    /// so the loadability gate in `AppShell.loadSession` routes the next
    /// click to the Replay sheet instead of another fruitless `session/load`.
    /// Returns the quarantined path on success.
    ///
    /// Called only after a `session/load` rpcError with a `.bak` already
    /// produced — never on a healthy file.
    static func quarantineCorruptGeminiChat(sessionId: String, cwd: String) -> String? {
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }
        let needle = String(sessionId.prefix(8))
        let candidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl"))
        }
        let resolved = candidates.max(by: { a, b in
            let aSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(a)")[.size] as? Int) ?? 0
            let bSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(b)")[.size] as? Int) ?? 0
            return aSize < bSize
        })
        guard let match = resolved else { return nil }
        let src = "\(chatsDir)/\(match)"
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = "\(src).corrupt-\(stamp)"
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// When ACP resume isn't possible, hydrate the canvas from the harness's own
    /// transcript file so the user at least sees the conversation they clicked on.
    /// New turns will go through session/new — no replay into the agent.
    func renderHistoryIfAvailable(sid: String) {
        guard provider == .claude else { return }
        // SOUL-IDENTITY-SPLIT: resolve to the live transcript id. Without
        // this, post-/compact sessions would replay the frozen pre-compact
        // file because the kernel sid never moves but Claude rotates the
        // on-disk filename.
        let transcriptId = SoulRegistry.findProviderTranscriptID(projectKey: project.id, sessionId: sid, provider: "claude")
            ?? SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid, provider: "claude")
            ?? sid
        guard let history = ClaudeTranscriptReader.transcript(forSession: transcriptId, cwd: project.path),
              !history.isEmpty
        else { return }

        // SOUL-SOUL_DESKTOP-097: bulk-update; see commit 88aead0.
        historicalIDs.formUnion(history.lazy.map(\.id))
        items.append(contentsOf: history)
        items.append(.status(id: UUID(), text: "─ history above (read-only) ─"))
    }


    /// Live-canvas variant: after a turn completes, peek at the registry's
    /// finalize JSON for this session and append a FinalizeCard IFF a
    /// newer finalize was recorded than the last one we injected. Works
    /// for any provider — the finalize JSON is written by the kernel's
    /// `/finalize` flow (whatever agent ran it), and Soul-Desktop just
    /// reads it and renders the Quad as a structured card. Without this,
    /// the user would only ever see the card on session reopen (via
    /// `hydrateFromDisk`); same session where /finalize ran would never
    /// surface the structured summary.
    func injectFinalizeSummaryIfFresh(sessionId sid: String) {
        // SOUL-SOUL_DESKTOP-100: trace each branch.
        let provLabel = "\(provider.rawValue):\(String(sid.prefix(8)))"
        guard let rec = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) else {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.miss", "\(provLabel)")
            return
        }
        let hasContent = (rec.intent?.isEmpty == false)
            || (rec.summary?.isEmpty == false)
            || (rec.rationale?.isEmpty == false)
            || (rec.fixed?.isEmpty == false)
            || (rec.nextStep?.isEmpty == false)
        guard hasContent else {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.empty", "\(provLabel)")
            return
        }
        // Dedup: only inject if this is a NEWER finalize than what we
        // already rendered. First inject after spawn / hydrate always
        // counts (lastFinalizeInjectedAt nil → unconditional first push).
        if let ts = rec.timestamp,
           let prev = lastFinalizeInjectedAt,
           ts <= prev {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.stale", "\(provLabel)")
            return
        }
        // SOUL-IDENTITY-SPLIT: delegate to the chronological-insert
        // helper instead of `items.append`. When re-finalize happens
        // mid-session, the new card must land AFTER the chip + tool
        // calls + agent reply that produced it — not floating around
        // wherever `items.endIndex` happens to be. `injectFinalizeSummary`
        // owns the insert-at-correct-position logic and updates
        // `lastFinalizeInjectedAt` itself.
        injectFinalizeSummary(sessionId: sid)
        SoulSignposts.event("injectFinalizeSummaryIfFresh.delegated", "\(provLabel)")
    }

    /// Insert a `.finalize` card into the canvas at its chronological
    /// position based on the recorded finalize timestamp. No-op when no
    /// finalize has been recorded. Marked historical so it gets the
    /// muted/read-only styling alongside the rest of the loaded transcript.
    ///
    /// SOUL-SOUL_DESKTOP-235: previously appended unconditionally at the
    /// end of `items`, which was wrong when `/finalize` was invoked
    /// mid-session and the conversation continued afterward. On reload the
    /// transcript loaded in chronological order then the finalize card got
    /// pinned to the bottom, placing it after later turns. Now we find the
    /// first item whose timestamp is strictly after the finalize record
    /// and insert before it.
    func injectFinalizeSummary(sessionId sid: String) {
        // SOUL-SOUL_DESKTOP-100: trace each branch.
        let provLabel = "\(provider.rawValue):\(String(sid.prefix(8)))"
        guard let rec = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) else {
            SoulSignposts.event("injectFinalizeSummary.miss", "\(provLabel)")
            return
        }
        let hasContent = (rec.intent?.isEmpty == false)
            || (rec.summary?.isEmpty == false)
            || (rec.rationale?.isEmpty == false)
            || (rec.fixed?.isEmpty == false)
            || (rec.nextStep?.isEmpty == false)
        guard hasContent else {
            SoulSignposts.event("injectFinalizeSummary.empty", "\(provLabel)")
            return
        }
        let id = UUID()
        let finalizeTs = rec.timestamp ?? Date()
        let card = ThreadItem.finalize(
            id: id,
            intent: rec.intent,
            summary: rec.summary,
            rationale: rec.rationale,
            fixed: rec.fixed,
            nextStep: rec.nextStep,
            timestamp: finalizeTs
        )
        // Find the first item whose recorded timestamp is strictly after
        // the finalize. Items without timestamps (toolCall, plan, status)
        // don't anchor placement; we let them flow with the adjacent
        // timestamped item. If no item is later than finalize, append.
        let insertAt = items.firstIndex(where: { item in
            guard let ts = ThreadController.itemTimestamp(item) else { return false }
            return ts > finalizeTs
        }) ?? items.endIndex
        historicalIDs.insert(id)
        items.insert(card, at: insertAt)
        // Remember this finalize so the post-turn live-injection helper
        // doesn't push a duplicate card after the next turn completes.
        lastFinalizeInjectedAt = finalizeTs
        SoulSignposts.event("injectFinalizeSummary.appended", "\(provLabel)")
    }

    /// SOUL-SOUL_DESKTOP-235: extract a comparable timestamp from any
    /// ThreadItem variant that carries one. Returns nil for variants that
    /// don't (toolCall, plan, status, toolCallGroup, error) — callers
    /// treat those as position-anchored to neighbors, not as ordering
    /// keys in their own right.
    static func itemTimestamp(_ item: ThreadItem) -> Date? {
        switch item {
        case .userMessage(_, _, let ts): return ts
        case .agentMessage(_, _, _, let ts): return ts
        case .agentThought(_, _, _, let ts): return ts
        case .branchSummary(_, _, _, _, let ts): return ts
        case .finalize(_, _, _, _, _, _, let ts): return ts
        case .toolCall, .plan, .status, .error, .toolCallGroup: return nil
        }
    }

    /// SOUL-SOUL_DESKTOP-038: merge slash-command UserPrompt hooks back into
    /// the canvas after a Claude session/load. Terminal Claude Code expands
    /// `/decision` etc. client-side before the model API sees them, so the
    /// ACP transcript Claude streams back has no record of the literal
    /// invocation. The Soul harness captures them into hooks.jsonl; we
    /// re-inject so the chip rendering in UserMessageRow stays consistent
    /// across surfaces.
    func injectSlashCommandPrompts(_ prompts: [(text: String, timestamp: Date)]) {
        guard !prompts.isEmpty else { return }

        for prompt in prompts {
            // Skip if an existing userMessage already carries the same
            // literal text near the same time — protects against double
            // injection on a retry or a re-load.
            let dedupWindow: TimeInterval = 2
            let alreadyPresent = items.contains { item in
                if case .userMessage(_, let text, let ts) = item,
                   text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.text,
                   abs(ts.timeIntervalSince(prompt.timestamp)) <= dedupWindow {
                    return true
                }
                return false
            }
            if alreadyPresent { continue }

            // Find the first user/agent message in items whose timestamp is
            // strictly after the hook's. Insert before it so narrative order
            // is preserved. If none later, append at the end of the
            // historical block (right before the load-complete status row).
            let id = UUID()
            let inserted: ThreadItem = .userMessage(id: id, text: prompt.text, timestamp: prompt.timestamp)
            historicalIDs.insert(id)

            var insertAt: Int? = nil
            for (i, item) in items.enumerated() {
                let ts: Date? = {
                    if case .userMessage(_, _, let t) = item { return t }
                    if case .agentMessage(_, _, _, let t) = item { return t }
                    return nil
                }()
                if let ts, ts > prompt.timestamp {
                    insertAt = i
                    break
                }
            }
            if let i = insertAt {
                items.insert(inserted, at: i)
            } else {
                items.append(inserted)
            }
        }
    }

}
