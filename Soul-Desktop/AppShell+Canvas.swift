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
        ZStack {
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // One unified drop affordance: the overlay lights up whether the
            // drag is over the transcript (SwiftUI .onDrop → isImageDropTargeted)
            // or over the composer text field (AppKit drag → the active
            // controller's isComposerDropActive). Without the second term the
            // composer read as a separate, differently-styled drop zone.
            if (isImageDropTargeted || (sessions.activeThread?.isComposerDropActive ?? false)) && !replay.isActive {
                CanvasDropOverlay()
                    .zIndex(10_000)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(
            of: DropAttachmentHandler.acceptedTypes,
            isTargeted: Binding(
                get: { self.isImageDropTargeted && !self.replay.isActive },
                set: { self.isImageDropTargeted = $0 }
            )
        ) { providers in
            guard !self.replay.isActive else { return false }
            if let activeCtrl = self.sessions.activeThread {
                guard activeCtrl.canAcceptComposerInput else { return false }
                Task { @MainActor in
                    let new = await DropAttachmentHandler.process(
                        providers: providers,
                        projectPath: activeCtrl.project.path,
                        existing: activeCtrl.droppedAttachments
                    )
                    activeCtrl.droppedAttachments.append(contentsOf: new)
                }
                return true
            } else {
                let path = self.currentProject()?.path
                Task { @MainActor in
                    let new = await DropAttachmentHandler.process(
                        providers: providers,
                        projectPath: path,
                        existing: self.emptyStateDroppedAttachments
                    )
                    self.emptyStateDroppedAttachments.append(contentsOf: new)
                }
                return true
            }
        }
    }

    @ViewBuilder
    var mountedThreadsCanvas: some View {
        ZStack {
            // Render exactly one ThreadView. Keeping inactive ThreadViews
            // mounted at opacity 0 preserves per-session NSScrollView state,
            // but SwiftUI still lays those invisible trees out. During live
            // streaming that multiplied NavigationStack/MoveLayout work and
            // produced the 100% CPU beachball sampled on 2026-06-03. The
            // controller remains mounted in AppSessionCoordinator; only the
            // SwiftUI layout tree is single-active.
            if let ctrl = sessions.activeThread {
                ThreadView(
                    controller: ctrl,
                    prompt: sessions.bindingForDraft(ctrl.id),
                    onCancel: { cancelTurn() },
                    onPickHarness: onPickHarness,
                    onBranchFromDisabled: { provider in branchFrom(ctrl, to: provider) },
                    branchSeedLoading: branchSeedLoading,
                    terminalActive: showTerminal,
                    onToggleTerminal: toggleTerminal,
                    onAddReminder: { openReminderSheet(thread: ctrl) }
                )
                .environment(\.autoCompactController, autoCompact)
                .id(ctrl.id)
            }
            if let loading = sessions.loadingThread {
                ThreadOpenLoadingView(pending: loading)
                    .zIndex(120)
            } else if sessions.activeThreadKey == nil {
                let project = currentProject()
                let selectedProjectId = workspace.selectedProjectId ?? ""
                let phase = workspace.snapshot.phase
                switch phase {
                case .booting:
                    SparkleSpinner(tint: SoulColor.fgMuted, size: 12)
                        .zIndex(100)
                case .empty, .failed, .ready:
                    HeroEmptyState(
                        projectName: project?.name ?? "your project",
                        projectPath: project?.path,
                        currentProjectID: selectedProjectId,
                        prompt: $prompt,
                        onSend: { display, agent, extraBlocks in startThread(display: display, agent: agent, extraBlocks: extraBlocks) },
                        onSelectProject: { workspace.selectProject($0) },
                        onNewProject: openNewProjectWizard,
                        devCommand: project?.devCommand,
                        devURL: project?.devURL,
                        devRunning: devServerRunning,
                        onRunLocal: runLocal,
                        onAddReminder: { openReminderSheet(thread: nil) },
                        pendingPermissionMode: $pendingPermissionMode,
                        provider: harness,
                        onPickHarness: onPickHarness,
                        branchSeedLoading: branchSeedLoading,
                        droppedAttachments: $emptyStateDroppedAttachments
                    )
                    .zIndex(100)
                }
            }
        }
    }

    @ViewBuilder
    var sidebarPane: some View {
        ZStack(alignment: .leading) {
            SidebarView(
                workspace: workspace,
                selectedProject: Binding(
                    get: { workspace.selectedProjectId },
                    set: { workspace.selectProject($0) }
                ),
                onSelectSession: loadSession,
                onReplaySession: startReplay,
                onNewChat: { target in newChat(targetProjectID: target) },
                onNewProject: openNewProjectWizard,
                onArchive: { session in archiveSession(session) },
                onBranch: { session, target in handleBranch(session: session, target: target) },
                onPrewarmSessions: prewarmSessionHydration,
                onOpenSettings: { showSettings = true },
                onToggleSidebar: toggleSidebar,
                activeReplaySessionId: replay.controller?.sessionId,
                replayProgress: replay.fraction,
                replayIndex: replay.controller?.index ?? 0,
                replayTotal: replay.controller?.total ?? 0,
                replayPrompts: replay.controller?.promptCount ?? 0,
                replayReplies: replay.controller?.replyCount ?? 0,
                activeSessionId: sessions.pendingActiveId ?? thread?.sessionId,
                activeProjectId: sessions.pendingActiveProjectId ?? thread?.project.id ?? replay.controller?.project.id ?? sessions.draftSession?.project,
                currentProvider: harness,
                draftSession: sessions.draftSession,
                activeThreads: sessions.mountedThreads,
                liveRecords: sessions.sidebarLiveRecords,
                newChatNonce: newChatNonce,
                repairToast: $repairToast
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ThreadOpenLoadingView: View {
    let pending: PendingThreadOpen

    var body: some View {
        VStack(spacing: 8) {
            Text("Loading transcript")
                .font(SoulFont.ui(13, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
            if let title = pending.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Text(pending.provider.label)
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.6), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoulColor.bg.opacity(0.92))
        .allowsHitTesting(true)
    }
}

private struct CanvasDropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(SoulColor.accent.opacity(0.08))
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                .strokeBorder(
                    SoulColor.accent,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
