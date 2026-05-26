import SwiftUI
import UniformTypeIdentifiers

extension AppShell {
    @ViewBuilder
    var sidebarToggleOverlay: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(showSidebar ? SoulColor.accent : SoulColor.fg.opacity(0.75))
                .frame(width: 32, height: 22)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(SoulColor.fg.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Toggle sidebar (⌘B)")
        .padding(.leading, 78)
        .padding(.top, 8)
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
            // SOUL-249: CanvasToolbar removed — items now live in the native
            // window .toolbar { } block on AppShell. If the native toolbar
            // is reverted, restore the CanvasToolbar(...) call here.
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
        .onDrop(
            of: DropAttachmentHandler.acceptedTypes,
            isTargeted: Binding(
                get: { self.isImageDropTargeted && !self.replay.isActive },
                set: { self.isImageDropTargeted = $0 }
            )
        ) { providers in
            guard !self.replay.isActive else { return false }
            if let activeCtrl = self.sessions.activeThread {
                let new = DropAttachmentHandler.process(
                    providers: providers,
                    projectPath: activeCtrl.project.path,
                    existing: activeCtrl.droppedAttachments
                )
                guard !new.isEmpty else { return false }
                activeCtrl.droppedAttachments.append(contentsOf: new)
                return true
            } else {
                let path = self.currentProject()?.path
                let new = DropAttachmentHandler.process(
                    providers: providers,
                    projectPath: path,
                    existing: self.emptyStateDroppedAttachments
                )
                guard !new.isEmpty else { return false }
                self.emptyStateDroppedAttachments.append(contentsOf: new)
                return true
            }
        }
        .overlay {
            if isImageDropTargeted && !replay.isActive {
                ZStack {
                    SoulColor.accent.opacity(0.08)
                    RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                        .strokeBorder(
                            SoulColor.accent,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                        )
                        .padding(8)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    var mountedThreadsCanvas: some View {
        ZStack {
            if let ctrl = sessions.activeThread {
                ThreadView(
                    controller: ctrl,
                    prompt: sessions.bindingForDraft(ctrl.id),
                    onCancel: { cancelTurn() },
                    onPickHarness: onPickHarness,
                    branchSeedLoading: branchSeedLoading,
                    terminalActive: showTerminal,
                    onToggleTerminal: toggleTerminal,
                    isImageDropTargeted: $isImageDropTargeted
                )
                .environment(\.autoCompactController, autoCompact)
                .zIndex(1)
            }
            if sessions.activeThreadKey == nil {
                HeroEmptyState(
                    projectName: currentProject()?.name ?? "your project",
                    projectPath: currentProject()?.path,
                    currentProjectID: selectedProject ?? "",
                    prompt: $prompt,
                    onSend: { display, agent, extraBlocks in startThread(display: display, agent: agent, extraBlocks: extraBlocks) },
                    onSelectProject: { selectedProject = $0 },
                    onNewProject: openNewProjectWizard,
                    devCommand: currentProject()?.devCommand,
                    devURL: currentProject()?.devURL,
                    devRunning: devServerRunning,
                    onRunLocal: runLocal,
                    pendingPermissionMode: $pendingPermissionMode,
                    provider: harness,
                    onPickHarness: onPickHarness,
                    branchSeedLoading: branchSeedLoading,
                    droppedAttachments: $emptyStateDroppedAttachments,
                    isImageDropTargeted: $isImageDropTargeted
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
                onArchive: { session in archiveSession(session) },
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
