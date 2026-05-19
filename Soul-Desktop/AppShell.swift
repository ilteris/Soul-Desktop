import SwiftUI
import AppKit

struct AppShell: View {
    @State private var selectedProject: String? = nil
    /// User's appearance preference. Values: "system", "light", "dark".
    /// `system` means follow the macOS appearance (the SoulColor tokens
    /// already do that via dynamic NSColor); the other two force a side.
    @AppStorage("soul.appearance") private var appearancePref: String = "system"
    /// Multiplex: every opened conversation gets its own ThreadController and
    /// stays alive until explicitly closed. Switching sessions is a pointer
    /// swap, not a teardown — agent processes keep streaming in the
    /// background, no re-spawn, no re-hydration.
    @State private var sessions = AppSessionCoordinator()
    @State private var replay = AppReplayCoordinator()
    /// Optimistic selection: the live-row ID the user just tapped, used for
    /// sidebar highlight before the spawn completes and `thread.sessionId`
    /// is real. Cleared once the thread's own session ID catches up.
    /// SOUL-SOUL_DESKTOP-138: nonce bumped every time the user initiates a
    /// new chat (composer-send into empty hero or sidebar "+ New chat"
    /// button). SidebarView observes this and auto-expands the parent
    /// project of the new thread. Restored-at-launch sessions don't bump
    /// this, so launch UX stays "all projects collapsed."
    @State private var newChatNonce: Int = 0
    /// Pre-thread composer text. Used by HeroEmptyState (no thread yet) and
    /// while the draft-session row is selected. Once a real thread exists,
    /// each ThreadController owns its own `composerDraft` so keystrokes
    /// don't invalidate AppShell.body.
    @State private var prompt: String = ""
    /// True while a background `claude -p` subprocess is composing a branch-
    /// seed sentence for a freshly-spawned cross-provider draft. The composer
    /// uses this to show a "Summarizing previous chat…" placeholder while the
    /// LLM is thinking; the seed populates `prompt` when it lands.
    @State private var branchSeedLoading: Bool = false
    @State private var showSmoke = false
    @State private var codexSmokeModel = CodexSmokeViewModel()
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var harness: Provider = .geminiCLI

    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)

    @StateObject private var terminalModel = TerminalPanelModel()
    @State private var showTerminal: Bool = false
    @AppStorage("soul.review.visible") var showReview: Bool = false
    @State var rightPane = AppRightPaneCoordinator()
    @AppStorage("soul.sidebar.visible") private var showSidebar: Bool = true
    /// SOUL-208: NavigationSplitView visibility binding.
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var devServerRunning: Bool = false
    @AppStorage("soul.terminal.height") private var terminalHeight: Double = 260
    @State private var dragStartHeight: Double? = nil
    /// Mode chosen before any thread exists — persists across new chats so
    /// the hero composer remembers the user's safety preference.
    @State private var pendingPermissionMode: PermissionMode = .fullAccess
    /// SOUL-SOUL_DESKTOP-035: when the user clicks a live row owned by an
    /// external writer (terminal Claude/Gemini-CLI), we refuse to ACP-load
    /// and surface a sheet offering the read-only Replay path instead.
    @State private var externalLiveSession: SoulSession? = nil
    /// Remembers whether the sidebar was open before the preview pane took
    /// over the canvas width, so closing the preview restores prior layout.
    @State private var sidebarWasOpenBeforePreview: Bool = true
    /// Lifted from SidebarView so the repair-session toast renders at the
    /// top center of the whole window instead of being clipped inside the
    /// 320pt sidebar column. SidebarView writes here via Binding.
    @State private var repairToast: String? = nil

    private var contextUsage: ContextUsage? {
        if let replay = replay.controller {
            // During replay, simulate the context window filling as events
            // reveal — sum text bytes from `visible` (the prefix of all
            // events played so far) rather than the static end-of-session
            // value. The chip animates 0% → final-fill in lockstep with
            // the timeline scrubber.
            return ContextUsage.estimateFromReplayItems(replay.visible)
        }
        if let thread, let sid = thread.sessionId {
            // Codex streams precise token usage through the
            // `thread/tokenUsage/updated` notification, which the controller
            // captures into `codexTokenUsage`. Read it directly here so the
            // chip stays live instead of falling through to the on-disk
            // rollout parser (which we haven't written yet).
            if thread.provider == .codex,
               let tokens = thread.codexTokensUsed,
               let budget = thread.codexContextWindow {
                return ContextUsage(tokens: tokens, max: budget, isEstimate: false)
            }
            return ContextUsage.compute(provider: thread.provider, sessionId: sid, cwd: thread.project.path)
        }
        return nil
    }

    var sidePanelAnimation: Animation {
        .easeInOut(duration: 0.22)
    }

    func currentProject() -> SoulProject? {
        guard let key = selectedProject else { return nil }
        return SoulRegistry.projects().first { $0.id == key }
    }

    /// The thread the canvas is currently showing. Multiple controllers
    /// coexist in the session coordinator; only one paints at a time.
    private var thread: ThreadController? {
        sessions.activeThread
    }

    /// Binding for the active controller's `pendingRecovery`. Extracted out
    /// of the body to keep the chained `.sheet(...)` modifiers type-checking
    /// in reasonable time.
    private var recoveryBinding: Binding<ThreadController.RecoveryContext?> {
        Binding(
            get: { thread?.pendingRecovery },
            set: { thread?.pendingRecovery = $0 }
        )
    }

    private func startThread(display: String, agent: String) {
        guard let project = currentProject() else { return }
        sessions.draftSession = nil
        let controller = ThreadController(provider: harness, project: project)
        controller.permissionMode = pendingPermissionMode
        sessions.mount(controller)
        newChatNonce &+= 1
        Task { await controller.send(display: display, agent: agent) }
    }

    private func loadSession(_ session: SoulSession) {
        if let draft = sessions.draftSession, draft.id == session.id {
            // Tapping the draft row keeps the hero composer up — no agent
            // spawn until the user actually sends.
            replay.stop()
            sessions.activeThreadKey = nil
            sessions.pendingActiveId = draft.id
            return
        }
        sessions.draftSession = nil
        // SOUL-SOUL_DESKTOP-043: route by the session's own project, NOT the
        // sidebar's currently-selected project. Clicking a chat row in
        // SidebarView doesn't first re-select the parent project, so
        // `currentProject()` here could still point at whatever was previously
        // active. A Soul-Desktop session opened while Truss Labs was last
        // selected used to spawn the agent in /Code/truss-labs (wrong cwd →
        // session/load misses → recovery cascade). The session record knows
        // its own project; trust it. We also nudge `selectedProject` so the
        // sidebar visibly follows.
        guard let project = SoulRegistry.projects().first(where: { $0.id == session.project })
                ?? currentProject()
        else { return }
        if selectedProject != session.project {
            selectedProject = session.project
        }
        let provider: Provider = {
            // Finalized rows carry `source` (set by the kernel at /finalize).
            switch session.source {
            case "claude":    return .claude
            case "gemini":    return .geminiCLI
            case "pi-native": return .pi
            default: break
            }
            // Live rows don't have `source` — derive from where the agent's
            // persistence file actually lives so a Claude session clicked
            // under the Gemini harness auto-switches instead of dead-ending.
            switch session.liveProvider {
            case "claude":    return .claude
            case "geminiCLI": return .geminiCLI
            default: break
            }
            // SOUL-SOUL_DESKTOP-043: last resort — read the recorded provider
            // from the session's hooks ledger. Without this, an archived
            // Gemini row clicked while Claude is the active harness defaults
            // to Claude, then session/load fails against a UUID Claude never
            // minted and we cascade into a destructive "starting fresh"
            // recovery. The ledger is the only authoritative source for what
            // agent actually owned this session.
            if let recorded = SoulRegistry.findProvider(projectKey: session.project, sessionId: session.id) {
                switch recorded {
                case "claude":    return .claude
                case "geminiCLI": return .geminiCLI
                case "pi":        return .pi
                case "codex":     return .codex
                default: break
                }
            }
            return harness
        }()
        // Guard against rapid double-clicks: if a controller for this session
        // is already mounted (matched by sessionId once hydrate sets it, OR by
        // a pending active ID when sessionId hasn't resolved yet), surface it
        // instead of spawning a duplicate.
        // Without this, two clicks in <1s create two ThreadControllers, each
        // calling hydrateFromDisk, and the dedup in the sidebar only masks
        // one of them.
        if sessions.pendingActiveId == session.id, sessions.activeThreadKey != nil {
            return
        }
        sessions.pendingActiveId = session.id

        // If this session is already open in a live ThreadController, just
        // surface it. No teardown, no re-load, no agent re-spawn. This is the
        // entire point of the multiplexer.
        if let existing = sessions.existingThread(sessionId: session.id) {
            harness = existing.provider
            sessions.setActiveThread(existing.id)
            return
        }
        // SOUL-SOUL_DESKTOP-214: branched sessions don't have a real
        // sessionId yet (the agent assigns one on first send), so the
        // sidebar synthesizes a row with id "thread-<ctrl.id>". Match
        // those by parsing the synthetic prefix — without this we fall
        // through to session/load and ship the synthetic id to Claude,
        // which rejects it ("not a UUID and does not match any session
        // title").
        if session.id.hasPrefix("thread-") {
            if let existing = sessions.existingThread(syntheticSessionId: session.id) {
                harness = existing.provider
                sessions.setActiveThread(existing.id)
                sessions.pendingActiveId = nil
                return
            }
        }

        // Refuse to ACP-load a session whose hooks.jsonl is being actively
        // appended by an external writer (terminal Claude/Gemini/Pi/Codex).
        // session/load would stream the entire transcript back and we'd end
        // up with two writers on the same session — corruption + a SwiftUI
        // storm. The `canSafelyResume` gate generalizes the prior pair of
        // rules (SOUL-035 terminal-origin block + SOUL-058/059 stale-Gemini
        // exception) into a single provider-agnostic check:
        //   - finalized: always safe
        //   - desktop-authored live: safe (we own the writer in-process)
        //   - externally-authored live, idle ≥1h: safe (writer likely gone)
        //   - externally-authored live, recently active: unsafe → Replay
        if !session.canSafelyResume {
            sessions.pendingActiveId = nil
            externalLiveSession = session
            return
        }

        // Loadability gate, now UUID-keyed across ALL four providers
        // (Claude, Gemini-CLI, Pi, Codex). The fast `session.loadable`
        // check looks for the transcript bound to the row's project
        // bucket. When that misses, fall through to a global UUID scan
        // before routing to the recovery sheet — this unblocks clicks on
        // split-ledger rows (same sid, two buckets) and cross-project
        // resumes where the transcript lives elsewhere on disk.
        //
        // When the global scan finds a hit, overlay its discovered cwd
        // onto the routed project so the agent spawns where its transcript
        // actually was authored, regardless of which sidebar bucket the
        // user clicked from.
        var discoveredCwdOverride: String? = nil
        if !session.loadable, session.replayable {
            if let hit = SessionLoadability.discover(sessionId: session.id) {
                discoveredCwdOverride = hit.cwd
            } else if session.promptCount > 0 {
                // SOUL-SOUL_DESKTOP-161 follow-up: the agent-side transcript
                // is missing (rotated, force-quit, trashed — or in the
                // gemini-cli-bloat case, we just quarantined a 2 GB chat
                // file out of `~/.gemini/tmp`), but the kernel ledger has
                // real conversation content. Hydrate already renders from
                // the ledger and surfaces a clear "first send starts a
                // fresh provider session" status row — better UX than
                // dead-ending the user into the recovery sheet when we
                // have N prompts of authoritative history to show them.
            } else {
                sessions.pendingActiveId = nil
                externalLiveSession = session
                return
            }
        }

        harness = provider
        // SOUL-SOUL_DESKTOP-021: if the session was started inside a git
        // worktree, spawn the agent in that worktree, not the main project
        // checkout. The project key (registry partitioning) stays the same;
        // only `path` (cwd) is overlaid. Without this, a worktree-tagged
        // session loads in the wrong directory and the agent sees a
        // different file tree than the session was authored against.
        var routedProject = project
        if let wt = session.worktreePath,
           !wt.isEmpty,
           FileManager.default.fileExists(atPath: wt) {
            routedProject.path = wt
        }
        // If the global UUID scan discovered the transcript in a different
        // cwd than the sidebar bucket suggests (split-ledger / cross-project
        // resume), override the spawn cwd so the agent finds its own
        // session file. Worktree-overlay still wins when both apply.
        if let override = discoveredCwdOverride,
           session.worktreePath?.isEmpty ?? true,
           FileManager.default.fileExists(atPath: override) {
            routedProject.path = override
        }
        let controller = ThreadController(provider: provider, project: routedProject)
        // Anchor the session-length chip to the original session start —
        // prefer the first hooks.jsonl event, fall back to the SoulSession's
        // own timestamp so we never show "0s" for a loaded session.
        if let origin = SoulRegistry.firstHookTimestamp(projectKey: routedProject.id, sessionId: session.id) {
            controller.startedAt = origin
        } else {
            controller.startedAt = session.timestamp
        }
        // Seed the controller's title from the clicked session row so the
        // sidebar's synthetic row inherits the right label immediately. Without
        // this, the synthetic shows "New chat" for the brief window before
        // hydrateFromDisk fills customTitle from the registry — and during
        // that window, dedup picks the synthetic ("New chat 1 sec ago") over
        // the finalized row, making the clicked session visually disappear
        // and replaced by a fake-new-chat at the top. lastActivityAt anchored
        // to the session's own timestamp keeps the row in its natural slot
        // until real activity bumps it.
        if let seed = (session.intent ?? session.summary)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty {
            controller.customTitle = seed
        }
        controller.lastActivityAt = session.timestamp
        // Stake out the session id BEFORE handing off to the async hydrate
        // task. The sidebar's synthetic row keys off ctrl.sessionId; without
        // this synchronous assignment the first render after click uses the
        // fallback id ("thread-<uuid>") and renders a phantom duplicate row
        // alongside the finalized one until the async first-line of
        // hydrateFromDisk lands on the MainActor.
        controller.assignSessionId(session.id)
        sessions.mount(controller)
        // SOUL-SOUL_DESKTOP-043: Claude / Gemini-CLI sessions render from the
        // on-disk transcript without spawning the agent. The agent process is
        // started lazily on the user's first send via ensureSession(). The
        // earlier `session.isLive && origin == .terminal` branch already
        // short-circuited into externalLiveSessionSheet, so anything reaching
        // here is either finalized or desktop-origin-live (typically a chat
        // someone abandoned without /finalize). Both shapes are safe to read
        // from disk — the kernel marks them "live" purely because the dir
        // hasn't been finalized, not because an agent is actively writing.
        // Codex joins the read-first path: even though codex has no
        // `session/load`, we can re-render its kernel hooks ledger
        // (UserPrompts + AfterAgent rows) so reopening a codex row shows
        // the prior conversation instead of dropping the user into a blank
        // fresh thread. Pi stays on the spawn-first path until we wire a
        // hydrate reader for it.
        let useReadFirst = provider == .claude || provider == .geminiCLI || provider == .codex || provider == .pi
        if useReadFirst {
            Task { await controller.hydrateFromDisk(id: session.id) }
        } else {
            Task { await controller.loadSession(id: session.id) }
        }
    }

    /// Resolve a SoulSession to a live ThreadController (if currently open
    /// in-process) and trigger the branch flow. For v0.1 only the
    /// already-open case is supported — branching from an unopen session
    /// would need a kernel-ledger hydrate first, which we defer to a
    /// follow-up. Provides quiet no-op when target == source's provider.
    private func handleBranch(session: SoulSession, target: Provider) {
        guard let source = sessions.existingThread(sessionId: session.id) else {
            // Source isn't open. Open it first; user re-clicks to branch.
            // Surfacing a sheet here would over-engineer v0.1 — the user
            // typically branches a session they're already chatting in.
            loadSession(session)
            return
        }
        guard target != source.provider else { return }
        branchFrom(source, to: target)
    }

    /// Cross-provider branch: spawn a fresh draft session in `target` and
    /// kick off a background LLM that summarizes `source`'s conversation
    /// into a 1-3 sentence opener. When the opener lands it pre-fills the
    /// composer, ready for the user to edit + send. Original `source`
    /// session is left intact (true branch semantics — two rows in the
    /// sidebar, both continuable).
    ///
    /// Why an LLM seed instead of a deterministic concat: empirically the
    /// user's own one-line bridge prompt is what makes cross-provider
    /// handoff work. A model produces that bridge from intent + current
    /// state better than any static template; the user just edits/sends.
    private func branchFrom(_ source: ThreadController, to target: Provider) {
        let items = source.items
        let sourceProvider = source.provider
        // Mark the source's transcript + ledger so when the user returns to
        // the parent later they can see they branched away from this point.
        // The new child session has no sid yet (draft until first send) — we
        // can't link to_session here. Future enhancement can backfill once
        // ensureSession lands the new sid.
        let atTurn = items.reduce(into: 0) { acc, item in
            if case .userMessage = item { acc += 1 }
        }
        source.items.append(.status(
            id: UUID(),
            text: "↗ branched to \(target.label)"
        ))
        if let sourceSid = source.sessionId {
            SoulRegistry.appendHook(
                projectKey: source.project.id,
                sessionId: sourceSid,
                event: [
                    "event": "BranchedTo",
                    "from_provider": sourceProvider.rawValue,
                    "to_provider": target.rawValue,
                    "at_turn": atTurn,
                ]
            )
        }
        // Spawn a real ThreadController upfront (not a draftSession routed
        // through HeroEmptyState). Branch should land the user in a
        // proper ThreadView with empty transcript + pre-filled composer,
        // not on the "What should we build in <project>?" welcome screen.
        // The draft path is only appropriate for fresh "New chat" where
        // the user might never send.
        harness = target
        if selectedProject != source.project.id { selectedProject = source.project.id }
        let project = source.project
        let controller = ThreadController(provider: target, project: project)
        controller.permissionMode = pendingPermissionMode
        sessions.mount(controller)
        sessions.draftSession = nil
        newChatNonce &+= 1
        branchSeedLoading = true
        controller.composerDraft = ""
        Task { @MainActor in
            let seed = await ComposeBranchSeed.run(
                items: items,
                sourceProvider: sourceProvider,
                targetProvider: target
            )
            branchSeedLoading = false
            guard !seed.isEmpty else { return }
            // Auto-dispatch the seed as the first turn instead of asking
            // the user to edit + send. The new provider's first reply
            // BECOMES the summary + next-step suggestion — exactly what
            // the user would have asked for if they'd typed the seed
            // themselves. Two-channel send: the user bubble shows the
            // clean seed text; the agent payload appends an explicit
            // "summarize where we are + propose next step" nudge so the
            // first reply lands in the right shape.
            let displayText = seed
            let agentText = seed + "\n\n(Continuing from \(sourceProvider.label) — give me a quick summary of where we are and propose the immediate next step.)"
            guard let pending = controller.acceptUserPrompt(display: displayText, agent: agentText) else { return }
            await controller.dispatchPending(pending)
        }
    }

    /// SOUL-SOUL_DESKTOP-179: drop the active controller and re-click its
    /// session, forcing a fresh `hydrateFromDisk` pass. Recovery for the
    /// empty-canvas-after-reload case — when a prior hydrate completed but
    /// populated no content rows (race, silent transcript read failure,
    /// agent process disappeared mid-load), there was no UI affordance to
    /// re-try short of restarting the app. Now: ⋯ menu → Reload session.
    private func reloadActiveSession() {
        guard let key = sessions.activeThreadKey,
              let controller = sessions.threads[key],
              let sid = controller.sessionId
        else { return }
        let projectKey = controller.project.id
        // Lazy session lookup — we need the canonical SoulSession for
        // loadSession's loadability / canSafelyResume gating.
        guard let session = SoulRegistry.cachedSessions(forProject: projectKey)?
                .first(where: { $0.id == sid })
        else { return }
        _ = sessions.removeThread(key)
        Task { await controller.teardown() }
        // Re-enter the normal click path. fresh controller → fresh hydrate.
        loadSession(session)
    }

    private func newChat(targetProjectID: String? = nil) {
        replay.stop()
        sessions.activeThreadKey = nil
        prompt = ""
        // Resolve the target up front. Callers (per-project "+" button) pass
        // an explicit id so we don't race the @Binding write-back via
        // selectedProject inside the same SwiftUI transaction.
        if let targetProjectID, targetProjectID != selectedProject {
            selectedProject = targetProjectID
        }
        let resolvedProject: SoulProject? = {
            if let id = targetProjectID {
                return SoulRegistry.projects().first { $0.id == id }
            }
            return currentProject()
        }()
        if let project = resolvedProject {
            let draft = SoulSession(
                id: "draft-\(UUID().uuidString)",
                project: project.id,
                timestamp: Date(),
                intent: "New chat",
                summary: nil,
                source: nil,
                status: nil,
                isLive: true,
                writer: .soulDesktop
            )
            sessions.draftSession = draft
            sessions.pendingActiveId = draft.id
            newChatNonce &+= 1
        } else {
            sessions.draftSession = nil
            sessions.pendingActiveId = nil
        }
    }

    /// Explicit close — only path that actually tears an agent down. Wired
    /// into a close affordance on threads (sidebar row context menu, future
    /// tab close). Without an explicit close, threads live until the
    /// coordinator evicts them.
    private func closeThread(_ key: String) {
        sessions.closeThread(key)
        if sessions.activeThreadKey == nil { prompt = "" }
    }

    @ViewBuilder
    private func externalLiveSessionSheet(_ session: SoulSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(SoulColor.accent)
                Text(session.writer == .external ? "Session is running elsewhere" : "Session can't be loaded here")
                    .font(SoulFont.ui(15)).bold()
            }
            Text(session.writer == .external
                ? "This chat is being driven by a terminal Claude/Gemini/Pi/Codex session, not by Soul-Desktop. Loading it here would spawn a second writer on the same session and stream the entire transcript back. You can open it in read-only Replay instead."
                : "The agent transcript for this session isn't available on disk — it may have been rotated out, force-quit, or never written. You can replay the kernel hooks ledger (prompts + decisions) in read-only mode.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                let rawTitle = (session.intent ?? session.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = SoulRegistry.stripCommandTags(rawTitle)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    Text(title)
                        .font(SoulFont.ui(12)).bold()
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(session.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Cancel") { externalLiveSession = nil }
                Spacer()
                Button("Open Replay") {
                    externalLiveSession = nil
                    startReplay(session)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    /// Recovery sheet for gemini-CLI sessions whose chat file got corrupted
    /// (typically force-quit mid-write). Surfaces three concrete actions —
    /// Replay the kernel ledger read-only, reveal the safe `.bak` snapshot
    /// in Finder, or start a fresh chat that inherits this row's title.
    /// Replaces the previous "rename the .bak file yourself" status-row
    /// dead-end with single-click recovery.
    @ViewBuilder
    private func corruptedSessionSheet(_ ctx: ThreadController.RecoveryContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
                Text("Session can't be resumed")
                    .font(SoulFont.ui(15)).bold()
            }
            Text("Gemini-CLI couldn't parse this session's chat file — most likely the app was force-quit while it was being written. Your conversation is safe in the backup; pick how you'd like to continue.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    Text(ctx.sessionId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                HStack(alignment: .top) {
                    Text("Parser said")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    Text(ctx.rpcMessage)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Replay (read-only)") {
                    let cap = ctx
                    thread?.pendingRecovery = nil
                    if let project = currentProject(),
                       let session = synthesizeSessionRow(forContext: cap, project: project) {
                        startReplay(session)
                    }
                }
                Button("Reveal backup in Finder") {
                    let url = URL(fileURLWithPath: ctx.backupPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Spacer()
                Button("Start fresh chat") {
                    _ = ctx
                    let projectId = thread?.project.id
                    thread?.pendingRecovery = nil
                    if let key = sessions.activeThreadKey {
                        closeThread(key)
                    }
                    newChat(targetProjectID: projectId)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    /// Build a transient `SoulSession` from a recovery context so the
    /// existing Replay path (which expects a `SoulSession`) can consume it.
    /// We don't reach into the registry here — the kernel ledger row keyed
    /// by `ctx.sessionId` is what Replay reads, and that already exists.
    private func synthesizeSessionRow(forContext ctx: ThreadController.RecoveryContext, project: SoulProject) -> SoulSession? {
        SoulSession(
            id: ctx.sessionId,
            project: project.id,
            timestamp: Date(),
            intent: ctx.title,
            source: "gemini",
            isLive: true,
            writer: .soulDesktop
        )
    }

    private func startReplay(_ session: SoulSession) {
        guard let project = currentProject() else { return }
        replay.start(
            session: session,
            project: project,
            sidebarVisible: showSidebar,
            setSidebarVisible: setSidebarVisible
        )
    }

    private func exitReplay() {
        replay.exit(sidebarVisible: showSidebar, setSidebarVisible: setSidebarVisible)
    }

    private func cancelTurn() {
        Task { await thread?.cancel() }
    }

    private func openNewProjectWizard() {
        showNewProject = true
    }

    private func runLocal(_ command: String, _ url: String?) {
        if devServerRunning {
            // Ctrl-C interrupts the foreground process in the panel's shell.
            terminalModel.requestSend("\u{03}")
            devServerRunning = false
            return
        }
        let cwd = currentProject()?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        terminalModel.ensureSeeded(with: cwd)
        if !showTerminal {
            withAnimation(.easeOut(duration: 0.26)) { showTerminal = true }
        }
        // Give the freshly-seeded shell a beat to be ready for input before piping the command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            terminalModel.requestSend(command + "\n")
        }
        if let url, let nsURL = URL(string: url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSWorkspace.shared.open(nsURL)
            }
        }
        devServerRunning = true
    }

    private func toggleSidebar() {
        // SOUL-208: drive NavigationSplitView's column directly; onChange
        // syncs the showSidebar AppStorage so other readers stay current.
        // SOUL-208: NavigationSplitView's reopen path is `.doubleColumn`
        // (not `.all`) on macOS — setting `.all` after `.detailOnly` is a
        // documented no-op for two-column splits.
        withAnimation(sidePanelAnimation) {
            columnVisibility = (columnVisibility == .detailOnly) ? .doubleColumn : .detailOnly
        }
    }

    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(sidePanelAnimation) { showSidebar = visible }
    }

    private func toggleReview() {
        withAnimation(sidePanelAnimation) {
            rightPane.toggleReview()
            showReview = rightPane.reviewVisible
        }
    }

    private func setFilePreviewPath(_ path: String?) {
        withAnimation(sidePanelAnimation) {
            rightPane.setFilePreviewPath(path)
        }
    }

    private func toggleTerminal() {
        if showTerminal {
            withAnimation(.easeInOut(duration: 0.22)) { withAnimation(.easeInOut(duration: 0.22)) { showTerminal = false } }
            return
        }
        let cwd = currentProject()?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        terminalModel.ensureSeeded(with: cwd)
        withAnimation(.easeOut(duration: 0.26)) { showTerminal = true }
    }

    private var terminalSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SoulColor.border.opacity(0.4))
                .frame(height: 1)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(height: 6)
                )
                .onHover { inside in
                    if inside {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartHeight == nil { dragStartHeight = terminalHeight }
                            let proposed = (dragStartHeight ?? terminalHeight) - Double(value.translation.height)
                            terminalHeight = min(max(proposed, 120), 800)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
            TerminalPanel(model: terminalModel) { withAnimation(.easeInOut(duration: 0.22)) { showTerminal = false } }
                .frame(height: CGFloat(terminalHeight))
        }
    }

    /// Window-level top-leading control cluster: sidebar toggle + provider
    /// picker. Lives in the empty strip above the sidebar pane so the two
    /// primary controls share one visual row (same horizontal line as the
    /// right-side toolbar icons). Position is fixed via `.padding(.leading,
    /// 20)` regardless of sidebar open/closed state.
    @ViewBuilder
    private var sidebarToggleOverlay: some View {
        // Harness picker moved to the composer toolbar next to the
        // PermissionModePicker — keeps related controls (which agent +
        // what permissions) co-located instead of split across the
        // top-left overlay and the bottom composer.
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(showSidebar ? SoulColor.accent : SoulColor.fgMuted)
        }
        .buttonStyle(SoulHoverButtonStyle(isActive: showSidebar))
        .help("Toggle sidebar (⌘\\)")
        .padding(.leading, 32)
        .padding(.top, 10)
        .opacity(replay.isActive ? 0.35 : 1)
    }

    /// Closure handed to every composer surface (ThreadView, HeroEmptyState)
    /// so the user can switch harness from the bottom toolbar. Mirrors the
    /// old sidebar-overlay behavior: changing harness mid-thread starts a
    /// new chat because a Claude session can't be continued by Pi etc.
    private var onPickHarness: (Provider) -> Void {
        { picked in
            if thread != nil { newChat() }
            harness = picked
        }
    }

    private var mainCanvas: some View {
        VStack(spacing: 0) {
            CanvasToolbar(
                harness: harness,
                onPickHarness: { picked in
                    if thread != nil { newChat() }
                    harness = picked
                },
                onSmokeTest: { showSmoke = true },
                onNewChat: { newChat() },
                onBranch: { provider in
                    if let source = thread { branchFrom(source, to: provider) }
                },
                onReload: { reloadActiveSession() },
                onToggleSidebar: toggleSidebar,
                onToggleTerminal: toggleTerminal,
                onToggleReview: toggleReview,
                threadActive: thread != nil || replay.isActive,
                sidebarActive: showSidebar,
                terminalActive: showTerminal,
                reviewActive: rightPane.reviewVisible,
                replayActive: replay.isActive,
                contextUsage: contextUsage,
                thread: thread
            )
            ZStack {
                SoulColor.bg.ignoresSafeArea()
                if let replay = replay.controller {
                    ReplayView(controller: replay, onExit: exitReplay)
                } else {
                    // Mount every open thread regardless of which one (if any)
                    // is active. Switching between threads is a visibility
                    // toggle — no teardown, no rebuild, no re-parse. When
                    // activeThreadKey is nil (e.g. user clicked "New chat"),
                    // every thread sits at opacity 0 and the HeroEmptyState
                    // composer renders on top so the new-chat composer is
                    // available without tearing down the background threads.
                    ZStack {
                        ForEach(sessions.mountedThreads, id: \.id) { ctrl in
                            let isActive = sessions.activeThreadKey == ctrl.id
                            ThreadView(
                                controller: ctrl,
                                prompt: sessions.bindingForDraft(ctrl.id),
                                onCancel: { if isActive { cancelTurn() } },
                                onPickHarness: onPickHarness,
                                branchSeedLoading: isActive && branchSeedLoading,
                                terminalActive: showTerminal,
                                onToggleTerminal: toggleTerminal
                            )
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                            .zIndex(isActive ? 1 : 0)
                        }
                        if sessions.activeThreadKey == nil {
                            HeroEmptyState(
                                projectName: currentProject()?.name ?? "your project",
                                projectPath: currentProject()?.path,
                                currentProjectID: selectedProject ?? "",
                                prompt: $prompt,
                                onSend: { display, agent in startThread(display: display, agent: agent) },
                                onSelectProject: { selectedProject = $0 },
                                onNewProject: openNewProjectWizard,
                                devCommand: currentProject()?.devCommand,
                                devURL: currentProject()?.devURL,
                                devRunning: devServerRunning,
                                onRunLocal: runLocal,
                                pendingPermissionMode: $pendingPermissionMode,
                                provider: harness,
                                onPickHarness: onPickHarness,
                                branchSeedLoading: branchSeedLoading
                            )
                            .zIndex(100)
                        }
                    }
                }
            }
            if showTerminal {
                terminalSection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // SOUL-SOUL_DESKTOP-054: hover-revealed branch+artifacts card.
            // Suppressed when:
            //  - a right-side pane is open (FilePreview / Review fight for
            //    the right edge), or
            //  - the canvas is in Replay mode (the overlay's git/branch
            //    actions don't apply to a read-only chapter view)
            if !rightPane.isOpen, !replay.isActive {
                CanvasInfoOverlay(
                    projectPath: thread?.project.path ?? currentProject()?.path,
                    projectName: thread?.project.name ?? currentProject()?.name,
                    projectKey: thread?.project.id ?? currentProject()?.id
                )
                .allowsHitTesting(true)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .geometryGroup()
    }

    @ViewBuilder
    private var sidebarPane: some View {
        ZStack(alignment: .leading) {
            SidebarView(
                selectedProject: $selectedProject,
                onSelectSession: loadSession,
                onReplaySession: startReplay,
                onNewChat: { target in newChat(targetProjectID: target) },
                onBranch: { session, target in handleBranch(session: session, target: target) },
                onOpenSettings: { showSettings = true },
                onToggleSidebar: toggleSidebar,
                activeReplaySessionId: replay.controller?.sessionId,
                replayProgress: replay.fraction,
                replayIndex: replay.controller?.index ?? 0,
                replayTotal: replay.controller?.total ?? 0,
                replayPrompts: replay.controller?.promptCount ?? 0,
                replayReplies: replay.controller?.replyCount ?? 0,
                activeSessionId: thread?.sessionId ?? sessions.pendingActiveId,
                activeProjectId: thread?.project.id ?? replay.controller?.project.id ?? sessions.draftSession?.project,
                currentProvider: harness,
                draftSession: sessions.draftSession,
                activeThreads: sessions.mountedThreads,
                newChatNonce: newChatNonce,
                repairToast: $repairToast
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // SOUL-208: NavigationSplitView owns the column width and
        // visibility; old fixed-width + zero-on-hide clipping retired.
    }

    var body: some View {
        // SOUL-208: NavigationSplitView for native macOS chrome; AppKit
        // toolbar items are installed by SoulAppDelegate and routed back
        // here via NotificationCenter.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarPane
                .navigationSplitViewColumnWidth(min: 280, ideal: SoulMetric.sidebarWidth, max: 480)
        } detail: {
            HStack(spacing: 0) {
                mainCanvas
                rightSidePanels
            }
            // SOUL-208: paint the canvas bg on the detail pane ONLY so
            // the sidebar column's .sidebar vibrancy stays continuous
            // up under the traffic lights.
            .background(SoulColor.bg.ignoresSafeArea())
            // SOUL-215 (reverted): the leading-edge gradient overlay
            // (LinearGradient + .frame(width: 18) inside .overlay)
            // pushed SwiftUI's layout negotiation into a non-converging
            // recursion (StackLayout ↔ _FlexFrameLayout) under
            // NavigationSplitView, causing the Release build to spin
            // at 100% CPU on layout passes. Sample showed thousands of
            // frames deep in sizeThatFits with no Soul-Desktop frames.
            // Keeping the neutral-gray palette change which is enough
            // on its own to soften the divider shadow.
        }
        .toolbar(removing: .title)
        // SOUL-208: NSToolbar managed by SoulAppDelegate owns the items
        // (sidebar + right-pane toggles). NO SwiftUI ToolbarItem block
        // here — adding one creates a BarAppearanceBridge KVO observer
        // that panics on toggle-driven relayout because its toolbar
        // reference is stale after our window.toolbar swap.
        .onChange(of: columnVisibility) { _, newValue in
            showSidebar = (newValue != .detailOnly)
        }
        // SOUL-208: NSToolbar items in the unified titlebar post these
        // notifications; route them to the same toggle handlers that
        // would fire from a SwiftUI button click.
        .onReceive(NotificationCenter.default.publisher(for: SoulAppDelegate.toggleSidebarNotification)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: SoulAppDelegate.toggleReviewNotification)) { _ in
            toggleReview()
        }
        .onAppear {
            rightPane.reviewVisible = showReview
        }
        // Top-center toast banner (lifted from SidebarView). Renders here
        // so it spans the whole window — visible regardless of which pane
        // the action was triggered from.
        .overlay(alignment: .top) {
            if let toast = repairToast {
                Text(toast)
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: repairToast)
        .animation(sidePanelAnimation, value: showSidebar)
        .animation(sidePanelAnimation, value: rightPane.reviewVisible)
        .animation(sidePanelAnimation, value: rightPane.filePreviewPath)
        .environment(\.openFilePreview) { raw in
            // Strip `:LINE` or `:LINE:COL` suffixes that the linkifier
            // produces for tool-call rows like `ThreadController.swift:1470`.
            // Without this, the resolver looks for a file literally named
            // `…swift:1470` and reports "file not found."
            let stripped = stripLineSuffix(raw)
            // Resolve relative paths (e.g. `Config/Channel-Dev.xcconfig`,
            // bare `GEMINI.md`) against the active project's working dir.
            // Absolute and tilde paths pass through untouched.
            let resolved: String = {
                if stripped.hasPrefix("/") { return stripped }
                if stripped.hasPrefix("~") { return (stripped as NSString).expandingTildeInPath }
                let base = thread?.project.path
                    ?? replay.controller?.project.path
                    ?? currentProject()?.path
                guard let base else { return stripped }
                return (base as NSString).appendingPathComponent(stripped)
            }()
            // Some upstream text (e.g. agent responses) elides long filenames
            // with U+2026 ellipsis like `…_097e4d72-…json`. Glob the parent
            // dir for a single match before giving up.
            var final = resolveEllipsisPath(resolved)
            // Agents often prefix relative paths with the project basename
            // (e.g. "soul/README.md" inside the ~/dotfiles/soul project),
            // producing a doubled segment after join. If the join missed and
            // the relative path's first segment matches the project base,
            // retry by dropping that segment.
            if !FileManager.default.fileExists(atPath: final),
               !stripped.hasPrefix("/"), !stripped.hasPrefix("~"),
               let base = thread?.project.path ?? replay.controller?.project.path ?? currentProject()?.path {
                let baseName = (base as NSString).lastPathComponent
                let parts = stripped.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0] == Substring(baseName) {
                    let retry = (base as NSString).appendingPathComponent(String(parts[1]))
                    if FileManager.default.fileExists(atPath: retry) {
                        final = retry
                    }
                }
            }
            // Bare filenames sometimes belong to a different project than the
            // active one (e.g. agent references a file in another project it
            // just mentioned). If the resolved path doesn't exist but the
            // input was a bare filename, search known project roots for a
            // single match before falling through to a "file not found."
            if !FileManager.default.fileExists(atPath: final),
               !stripped.hasPrefix("/"), !stripped.hasPrefix("~"), !stripped.contains("/") {
                if let match = findFileInKnownProjects(filename: stripped) {
                    final = match
                }
            }
            if rightPane.filePreviewPath == nil {
                sidebarWasOpenBeforePreview = showSidebar
                if showSidebar {
                    setSidebarVisible(false)
                }
            }
            setFilePreviewPath(final)
        }
        .onChange(of: rightPane.filePreviewPath) { _, new in
            if new == nil, sidebarWasOpenBeforePreview, !showSidebar {
                setSidebarVisible(true)
            }
        }
        .toolbar(.hidden)
        .sheet(isPresented: $showSmoke) {
            if harness == .codex {
                CodexSmokeView(
                    model: codexSmokeModel,
                    onDismiss: { showSmoke = false }
                )
            } else {
                ACPSmokeView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(harness: $harness, onDismiss: { showSettings = false })
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectWizard(
                onCreated: { newKey in
                    showNewProject = false
                    selectedProject = newKey
                },
                onCancel: { showNewProject = false }
            )
        }
        .sheet(item: $externalLiveSession) { session in
            externalLiveSessionSheet(session)
        }
        // Recovery sheet for gemini-CLI sessions whose chat file got
        // corrupted (force-quit mid-write, etc.). Bound to the active
        // controller's pendingRecovery so the sheet appears the moment
        // loadSession finishes failing, not on a re-click.
        .sheet(item: recoveryBinding) { ctx in
            corruptedSessionSheet(ctx)
        }
        .background {
            Button("") { showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("") { toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .background(SoulColor.bg)
        .preferredColorScheme(appearancePref == "dark" ? .dark : appearancePref == "light" ? .light : nil)
        .onChange(of: selectedProject) { _, newKey in
            // Project switch is purely a sidebar filter now — active threads
            // belong to their own project (carried on the ThreadController),
            // so clicking around in the sidebar doesn't tear them down.
            devServerRunning = false
            sessions.clearDraftIfProjectChanged(to: newKey)
        }
        .onChange(of: showTerminal) { _, isOpen in
            if !isOpen { devServerRunning = false }
        }
    }
}
