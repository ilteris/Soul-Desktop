import SwiftUI
import SoulCore
import SoulACP

extension AppShell {
    func startThread(display: String, agent: String, extraBlocks: [ContentBlock] = []) -> Bool {
        guard let project = currentProject() else { return false }
        sessions.draftSession = nil
        let controller = ThreadController(provider: harness, project: project)
        controller.permissionMode = pendingPermissionMode
        // startThread owns its first item synchronously via acceptUserPrompt
        // below — no read-from-disk happens. Opt out of the default
        // isHydrating=true so the skeleton overlay doesn't paint over the
        // user's own message at mount.
        controller.isHydrating = false
        // Contract: a fresh controller must not be mounted until the first
        // prompt has been synchronously accepted. Mounting before acceptance
        // creates a visible "New chat" shell that can race sidebar refreshes
        // and provider NativeSessionID hooks, producing a persisted session
        // row with no user turn content.
        guard let pending = controller.acceptUserPrompt(display: display, agent: agent, extraBlocks: extraBlocks) else { return false }
        sessions.mount(controller)
        newChatNonce &+= 1
        Task {
            // SOUL-364: provision a per-session Git worktree before the first
            // spawn so concurrent sessions on one project never share a working
            // tree. The kernel sid is already set (acceptUserPrompt adopted
            // controller.id), and the agent's cwd resolves from project.path,
            // so mutating it here routes the spawn into the isolated worktree.
            await SessionWorktreeProvisioner.provision(controller: controller)
            // Under the default .block policy a provisioning failure must NOT
            // fall through to the shared checkout. The error row is already
            // surfaced; skip dispatch so no turn runs in the main tree.
            if case .blocked = controller.worktreeProvisionState { return }
            await controller.dispatchPending(pending)
        }
        return true
    }

    /// ⌘[ (forward: false) / ⌘] (forward: true) — pop one off the corresponding
    /// view-history stack and load it. No-op when the stack is empty.
    func navigateHistory(forward: Bool) {
        guard let target = forward ? viewHistory.goForward() : viewHistory.goBack()
        else { return }
        isNavigatingHistory = true
        loadSession(target)
        isNavigatingHistory = false
    }

    func loadSession(_ session: SoulSession) {
        // Browser-style view history: every user-initiated open pushes here.
        // Loads triggered by ⌘[ / ⌘] navigation set `isNavigatingHistory`
        // and skip the push (otherwise back would just retrace itself).
        if !isNavigatingHistory {
            viewHistory.push(session)
        }
        if let draft = sessions.draftSession, draft.id == session.id {
            replay.stop()
            sessions.activeThreadKey = nil
            sessions.pendingActiveId = draft.id
            sessions.pendingActiveProjectId = draft.project
            sessions.loadingThread = nil
            return
        }
        sessions.draftSession = nil
        guard let project = workspace.project(id: session.project)
                ?? registryStore.projects().first(where: { $0.id == session.project })
                ?? currentProject()
        else { return }
        if workspace.selectedProjectId != session.project {
            workspace.selectProject(session.project)
        }
        let provider = providerForSession(session)
        if sessions.pendingActiveId == session.id, sessions.activeThreadKey != nil {
            return
        }
        sessions.pendingActiveId = session.id
        sessions.pendingActiveProjectId = session.project

        if let existing = sessions.existingThread(sessionId: session.id) {
            harness = existing.provider
            sessions.setActiveThread(existing.id)
            return
        }
        if session.id.hasPrefix("thread-") {
            if let existing = sessions.existingThread(syntheticSessionId: session.id) {
                harness = existing.provider
                sessions.setActiveThread(existing.id)
                sessions.clearPendingSelection(sessionId: session.id)
                return
            }
        }

        // Dual-writer hazard: only block when we have positive evidence
        // someone else owns the writer (`writer == .external`). The original
        // gate used `!canSafelyResume`, which also tripped for
        // `writer == .unknown` on a live, recently-touched ledger — and
        // .unknown is the default for sessions whose Title/SessionStart
        // hooks didn't land (SOUL-247 payload-drop class), so it slammed
        // the modal on rows the user legitimately wants to open. For
        // .unknown we have no real evidence of another writer; trust the
        // click.
        if !session.canSafelyResume, session.writer == .external {
            sessions.clearPendingSelection(sessionId: session.id)
            externalLiveSession = session
            return
        }

        var discoveredCwdOverride: String? = nil
        if !session.loadable, session.replayable {
            // Cross-project transcript discovery: a Claude/Gemini/Pi/Codex
            // session whose UUID lives under a different cwd than the
            // project bucket we filed it in. If we find a hit, route the
            // spawn at that cwd instead of the bucket's project path.
            if let hit = SessionLoadability.discover(sessionId: session.id) {
                discoveredCwdOverride = hit.cwd
            }
            // SOUL-247 follow-up: do NOT raise the "can't be loaded"
            // recovery sheet here. The kernel ledger is `replayable`
            // (hooks.jsonl exists), so hydrateFromDisk will paint whatever
            // it has — even if the SOUL-247 payload-drop bug zeroed out
            // promptCount or the substantive flag. The prior promptCount-
            // and substantive-based gates falsely tripped on sessions
            // whose Title hook landed but whose UserPrompt content was
            // dropped (sidebar showed "3 turns" via transcriptTurns
            // fallback, but the modal still slammed the canvas shut).
            // The `canSafelyResume` gate above already protects against
            // live external writers — that's the real dual-writer hazard.
            // Worst case here is an empty canvas the user can type into.
        }

        harness = provider
        var routedProject = projectWithPathOverride(project) ?? project
        if let wt = session.worktreePath,
           !wt.isEmpty,
           FileManager.default.fileExists(atPath: wt) {
            routedProject.path = wt
        }
        if let override = discoveredCwdOverride,
           session.worktreePath?.isEmpty ?? true,
           FileManager.default.fileExists(atPath: override) {
            routedProject.path = override
        }
        let controller = ThreadController(provider: provider, project: routedProject)
        if let origin = registryStore.firstHookTimestamp(projectKey: routedProject.id, sessionId: session.id) {
            controller.startedAt = origin
        } else {
            controller.startedAt = session.timestamp
        }
        if let seed = (session.title ?? session.intent ?? session.summary)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty {
            controller.customTitle = seed
        }
        controller.lastActivityAt = session.lastActivityAt ?? session.timestamp
        let sessionTurnCount = session.visibleTurnCount > 0
            ? session.visibleTurnCount
            : max(session.promptCount, session.transcriptTurns)
        controller.sessionTurnCountHint = sessionTurnCount > 0 ? sessionTurnCount : nil
        controller.assignSessionId(session.id)
        let loadedFromSnapshot: Bool
        if let snapshot = hydrationCache.snapshot(project: routedProject, sessionId: session.id, provider: provider) {
            controller.applyHydratedSnapshot(snapshot)
            sessions.mount(controller)
            loadedFromSnapshot = true
        } else {
            let pending = PendingThreadOpen(
                sessionId: session.id,
                projectId: session.project,
                title: session.title ?? session.intent ?? session.summary,
                provider: provider
            )
            sessions.beginLoading(pending)
            sessions.mount(controller, activate: false)
            loadedFromSnapshot = false
        }
        let useReadFirst = provider == .claude || provider == .geminiCLI || provider == .codex || provider == .pi
        if useReadFirst {
            // SOUL-SOUL_DESKTOP-243 (phase 1): chain background spawn-and-resume
            // after the hydrate paints the canvas. By the time the user finishes
            // reading the transcript and types, ensureSession is a no-op (the
            // idempotency check in ThreadController+Lifecycle.swift:228 returns
            // early once hasInitialized + client + sessionId are set). Any ACP
            // replay that loadSession streams back is suppressed via
            // suppressLoadReplay during the spawn, so it never paints on the
            // canvas. Background-spawn errors are swallowed here — the user
            // hasn't taken action yet, and the next user send re-enters
            // ensureSession and will surface a real error then.
            Task {
                await controller.hydrateFromDisk(id: session.id)
                if !loadedFromSnapshot {
                    guard sessions.activateLoadedThread(controller.id, sessionId: session.id) else { return }
                } else {
                    guard sessions.activeThreadKey == controller.id else { return }
                }
                try? await controller.ensureSession()
            }
        } else {
            Task {
                await controller.loadSession(id: session.id)
                if !loadedFromSnapshot {
                    _ = sessions.activateLoadedThread(controller.id, sessionId: session.id)
                }
            }
        }
    }

    func prewarmSessionHydration(_ rows: [SoulSession]) {
        let projects = registryStore.projects()
        hydrationCache.prewarm(
            sessions: rows.filter { !$0.isLive && $0.replayable },
            projects: projects,
            providerForSession: providerForSession
        )
    }

    func handleBranch(session: SoulSession, target: Provider) {
        guard let source = sessions.existingThread(sessionId: session.id) else {
            loadSession(session)
            return
        }
        guard target != source.provider else { return }
        branchFrom(source, to: target)
    }

    func branchFrom(_ source: ThreadController, to target: Provider) {
        let items = source.items
        let sourceProvider = source.provider
        let atTurn = items.reduce(into: 0) { acc, item in
            if case .userMessage = item { acc += 1 }
        }
        source.items.append(.status(
            id: UUID(),
            text: "↗ branched to \(target.label)"
        ))
        if let sourceSid = source.sessionId {
            registryStore.appendHook(
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
        harness = target
        if workspace.selectedProjectId != source.project.id { workspace.selectProject(source.project.id) }
        let project = source.project
        let controller = ThreadController(provider: target, project: project)
        controller.permissionMode = pendingPermissionMode
        // Branch flow uses its own loading affordance (`branchSeedLoading`
        // below) instead of the hydration skeleton. Opt out of the default
        // isHydrating=true so the two loading states don't double-paint.
        controller.isHydrating = false
        sessions.mount(controller)
        sessions.draftSession = nil
        newChatNonce &+= 1
        branchSeedLoading = true
        controller.composerDraft = ""
        Task { @MainActor in
            let generatedSeed = await ComposeBranchSeed.run(
                items: items,
                sourceProvider: sourceProvider,
                targetProvider: target
            )
            let seed = generatedSeed.isEmpty
                ? ComposeBranchSeed.fallbackSeed(
                    sourceTitle: source.displayTitle,
                    sourceProvider: sourceProvider,
                    targetProvider: target
                )
                : generatedSeed
            branchSeedLoading = false
            guard !seed.isEmpty else { return }
            let agentText = seed + "\n\n(Continuing from \(sourceProvider.label) — give me a quick summary of where we are and propose the immediate next step.)"
            guard let pending = controller.acceptBranchSummaryPrompt(
                summary: seed,
                sourceProvider: sourceProvider,
                targetProvider: target,
                agent: agentText
            ) else { return }
            await controller.dispatchPending(pending)
        }
    }

    /// Route a turn-completed notification click to its originating session.
    /// Looks the session up in the registry (cache or fresh scan) and
    /// delegates to `loadSession`. If we're already on the right thread, the
    /// guard inside loadSession makes this a no-op past the activate.
    func openSessionFromNotification(sessionId: String, projectKey: String) {
        if let activeKey = sessions.activeThreadKey,
           let controller = sessions.threads[activeKey],
           controller.sessionId == sessionId {
            return
        }
        let projectPath = registryStore.projects().first { $0.id == projectKey }?.path
        let candidates = registryStore.cachedSessions(forProject: projectKey)
            ?? registryStore.allSessions(forProject: projectKey, projectPath: projectPath)
        guard let session = candidates.first(where: { $0.id == sessionId }) else { return }
        loadSession(session)
    }

    func reloadActiveSession() {
        guard let key = sessions.activeThreadKey,
              let controller = sessions.threads[key],
              let sid = controller.sessionId
        else { return }
        let projectKey = controller.project.id
        guard let session = registryStore.cachedSessions(forProject: projectKey)?
                .first(where: { $0.id == sid })
        else { return }
        _ = sessions.removeThread(key)
        Task { await controller.teardown() }
        loadSession(session)
    }

    func newChat(targetProjectID: String? = nil) {
        replay.stop()
        sessions.activeThreadKey = nil
        sessions.loadingThread = nil
        prompt = ""
        if let targetProjectID, targetProjectID != workspace.selectedProjectId {
            workspace.selectProject(targetProjectID)
        }
        let resolvedProject: SoulProject? = {
            if let id = targetProjectID {
                return projectWithPathOverride(workspace.project(id: id) ?? registryStore.projects().first { $0.id == id })
            }
            return currentProject()
        }()
        if let project = resolvedProject {
            let draft = SoulSession(
                id: "draft-\(UUID().uuidString)",
                project: project.id,
                timestamp: Date(),
                title: "New chat",
                summary: nil,
                source: nil,
                status: nil,
                isLive: true,
                writer: .soulDesktop
            )
            sessions.draftSession = draft
            sessions.pendingActiveId = draft.id
            sessions.pendingActiveProjectId = draft.project
            newChatNonce &+= 1
        } else {
            sessions.draftSession = nil
            sessions.pendingActiveId = nil
            sessions.pendingActiveProjectId = nil
        }
    }

    func closeThread(_ key: String) {
        sessions.closeThread(key)
        if sessions.activeThreadKey == nil { prompt = "" }
    }

    /// Tear down the canvas thread when the user archives the session
    /// currently open. Without this the sidebar row vanishes (archived
    /// rows hide unless "Show archived" is toggled) but the chat stays
    /// painted, leaving the user with a thread they can no longer find
    /// in the sidebar.
    func archiveSession(_ session: SoulSession) {
        sessions.forgetLiveRecord(sessionId: session.id)
        if let existing = sessions.existingThread(sessionId: session.id) {
            closeThread(existing.id)
        } else if let synthetic = sessions.existingThread(syntheticSessionId: session.id) {
            closeThread(synthetic.id)
        }
        if sessions.draftSession?.id == session.id {
            sessions.draftSession = nil
            sessions.clearPendingSelection(sessionId: session.id)
        }
    }

    func startReplay(_ session: SoulSession) {
        guard var project = projectWithPathOverride(workspace.project(id: session.project))
                ?? currentProject()
        else { return }
        if let wt = session.worktreePath,
           !wt.isEmpty,
           FileManager.default.fileExists(atPath: wt) {
            project.path = wt
        }
        replay.start(
            session: session,
            project: project,
            sidebarVisible: showSidebar,
            setSidebarVisible: setSidebarVisible
        )
    }

    func exitReplay() {
        replay.exit(sidebarVisible: showSidebar, setSidebarVisible: setSidebarVisible)
    }

    func cancelTurn() {
        Task { await thread?.cancel() }
    }

    func openNewProjectWizard() {
        showNewProject = true
    }

    private func providerForSession(_ session: SoulSession) -> Provider {
        if let provider = session.provider {
            switch provider {
            case "claude":    return .claude
            case "gemini", "geminiCLI": return .geminiCLI
            case "pi", "pi-native": return .pi
            case "codex":     return .codex
            default: break
            }
        }
        // SOUL-SOUL_DESKTOP-237: defensive provider inference. The kernel
        // ledger's first NativeSessionID event is the most authoritative
        // signal of who CREATED this kernel sid. Prefer it over
        // session.source, which can be stamped wrong by `/finalize` when
        // the user's runtime harness disagrees with the actual writer
        // (SOUL-SOUL-030). Falls through to the previous heuristics when
        // the ledger has no NativeSessionID events to anchor identity.
        let tally = SoulRegistry.providerTally(projectKey: session.project, sessionId: session.id)
        if let anchored = tally.firstAuthor {
            switch anchored {
            case "claude":    return .claude
            case "geminiCLI": return .geminiCLI
            case "pi":        return .pi
            case "codex":     return .codex
            default: break
            }
        }
        switch session.source {
        case "claude":    return .claude
        case "gemini":    return .geminiCLI
        case "pi-native": return .pi
        default: break
        }
        switch session.liveProvider {
        case "claude":    return .claude
        case "geminiCLI": return .geminiCLI
        default: break
        }
        if let recorded = registryStore.findProvider(projectKey: session.project, sessionId: session.id) {
            switch recorded {
            case "claude":    return .claude
            case "geminiCLI": return .geminiCLI
            case "pi":        return .pi
            case "codex":     return .codex
            default: break
            }
        }
        return harness
    }

    func forkActiveSessionIntoWorktree() {
        guard let thread else { return }
        Task {
            await thread.forkToWorktree()
        }
    }
}
