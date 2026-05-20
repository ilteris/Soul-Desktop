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
            if thread != nil { newChat() }
            harness = picked
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
