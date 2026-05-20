import SwiftUI

extension AppShell {
    @ViewBuilder
    var sidebarToggleOverlay: some View {
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

    var onPickHarness: (Provider) -> Void {
        { picked in
            // SOUL-SOUL_DESKTOP-237: if a populated thread is active and the
            // user is picking a DIFFERENT provider, show a confirmation sheet.
            // The user's mental model is usually "branch into a new session"
            // but today's behavior is "close current, fresh draft in new
            // harness." Without the sheet that mismatch silently produces
            // sessions whose finalize JSON gets a misleading `source` field
            // (see SOUL-SOUL-030 for the kernel-side root cause); on next
            // reload the wrong-provider controller picks up the original sid
            // and pollutes the ledger.
            //
            // Skipped when: no thread, same provider, thread is empty, or
            // user opted out for the session.
            if let activeThread = thread,
               !activeThread.items.isEmpty,
               picked != activeThread.provider,
               !skipHarnessSwitchSheet {
                pendingHarnessSwitch = HarnessSwitchContext(source: activeThread, target: picked)
                return
            }
            if thread != nil { newChat() }
            harness = picked
        }
    }

    /// SOUL-SOUL_DESKTOP-237: invoked by the sheet's "Continue" choice.
    /// Mirrors today's pre-sheet behavior: close the active thread, fresh
    /// draft in the new harness. Source session is untouched on disk.
    func confirmContinueHarnessSwitch(target: Provider, rememberChoice: Bool) {
        if rememberChoice { skipHarnessSwitchSheet = true }
        pendingHarnessSwitch = nil
        if thread != nil { newChat() }
        harness = target
    }

    /// SOUL-SOUL_DESKTOP-237: invoked by the sheet's "Branch" choice.
    /// Routes through branchFrom to fork into a new session, preserving
    /// the source's ledger and creating a fresh sid for the new agent.
    func confirmBranchHarnessSwitch(target: Provider, rememberChoice: Bool) {
        if rememberChoice { skipHarnessSwitchSheet = true }
        pendingHarnessSwitch = nil
        if let source = thread {
            branchFrom(source, to: target)
        } else {
            // Defensive: shouldn't happen because the sheet only fires when
            // a thread is active, but if state shifted, fall through to
            // continue-style behavior.
            harness = target
        }
    }

    var mainCanvas: some View {
        VStack(spacing: 0) {
            CanvasToolbar(
                harness: harness,
                onPickHarness: onPickHarness,
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
                    mountedThreadsCanvas
                }
            }
            if showTerminal {
                terminalSection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
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
    var mountedThreadsCanvas: some View {
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

    @ViewBuilder
    var sidebarPane: some View {
        ZStack(alignment: .leading) {
            SidebarView(
                selectedProject: $selectedProject,
                onSelectSession: loadSession,
                onReplaySession: startReplay,
                onNewChat: { target in newChat(targetProjectID: target) },
                onNewProject: openNewProjectWizard,
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
    }
}
