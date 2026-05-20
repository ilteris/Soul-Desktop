import SwiftUI

extension AppShell {
    func startThread(display: String, agent: String) {
        guard let project = currentProject() else { return }
        sessions.draftSession = nil
        let controller = ThreadController(provider: harness, project: project)
        controller.permissionMode = pendingPermissionMode
        sessions.mount(controller)
        newChatNonce &+= 1
        Task { await controller.send(display: display, agent: agent) }
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
            return
        }
        sessions.draftSession = nil
        guard let project = registryStore.projects().first(where: { $0.id == session.project })
                ?? currentProject()
        else { return }
        if selectedProject != session.project {
            selectedProject = session.project
        }
        let provider = providerForSession(session)
        if sessions.pendingActiveId == session.id, sessions.activeThreadKey != nil {
            return
        }
        sessions.pendingActiveId = session.id

        if let existing = sessions.existingThread(sessionId: session.id) {
            harness = existing.provider
            sessions.setActiveThread(existing.id)
            return
        }
        if session.id.hasPrefix("thread-") {
            if let existing = sessions.existingThread(syntheticSessionId: session.id) {
                harness = existing.provider
                sessions.setActiveThread(existing.id)
                sessions.pendingActiveId = nil
                return
            }
        }

        if !session.canSafelyResume {
            sessions.pendingActiveId = nil
            externalLiveSession = session
            return
        }

        var discoveredCwdOverride: String? = nil
        if !session.loadable, session.replayable {
            if let hit = SessionLoadability.discover(sessionId: session.id) {
                discoveredCwdOverride = hit.cwd
            } else if session.promptCount == 0 {
                sessions.pendingActiveId = nil
                externalLiveSession = session
                return
            }
        }

        harness = provider
        var routedProject = project
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
        if let seed = (session.intent ?? session.summary)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty {
            controller.customTitle = seed
        }
        controller.lastActivityAt = session.timestamp
        controller.assignSessionId(session.id)
        sessions.mount(controller)
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
                try? await controller.ensureSession()
            }
        } else {
            Task { await controller.loadSession(id: session.id) }
        }
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
        prompt = ""
        if let targetProjectID, targetProjectID != selectedProject {
            selectedProject = targetProjectID
        }
        let resolvedProject: SoulProject? = {
            if let id = targetProjectID {
                return registryStore.projects().first { $0.id == id }
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

    func closeThread(_ key: String) {
        sessions.closeThread(key)
        if sessions.activeThreadKey == nil { prompt = "" }
    }

    func startReplay(_ session: SoulSession) {
        guard let project = currentProject() else { return }
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
}
