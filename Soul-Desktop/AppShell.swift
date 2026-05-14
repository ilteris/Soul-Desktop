import SwiftUI
import AppKit

struct AppShell: View {
    @State private var selectedProject: String? = nil
    /// User's appearance preference. Values: "system", "light", "dark".
    /// `system` means follow the macOS appearance (the SoulColor tokens
    /// already do that via dynamic NSColor); the other two force a side.
    @AppStorage("soul.appearance") private var appearancePref: String = "system"
    /// Multiplex: every opened conversation gets its own ThreadController and
    /// stays alive in `threads` until explicitly closed. Switching sessions
    /// is a pointer swap (`activeThreadKey`), not a teardown — agent
    /// processes keep streaming in the background, no re-spawn, no
    /// re-hydration. Keyed by `ThreadController.id` because fresh new chats
    /// don't have a sessionId until the first send resolves.
    @State private var threads: [String: ThreadController] = [:]
    @State private var activeThreadKey: String? = nil
    @State private var replay: ReplayController? = nil
    /// Optimistic selection: the live-row ID the user just tapped, used for
    /// sidebar highlight before the spawn completes and `thread.sessionId`
    /// is real. Cleared once the thread's own session ID catches up.
    @State private var pendingActiveId: String? = nil
    /// Per-thread composer drafts. The thread that's active reads/writes
    /// `prompt`; switching threads swaps drafts in and out.
    @State private var draftsByThread: [String: String] = [:]
    @State private var prompt: String = ""
    @State private var showSmoke = false
    @State private var codexSmokeModel = CodexSmokeViewModel()
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var harness: Provider = .geminiCLI

    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)

    @StateObject private var terminalModel = TerminalPanelModel()
    @State private var showTerminal: Bool = false
    @AppStorage("soul.review.visible") private var showReview: Bool = false
    @AppStorage("soul.sidebar.visible") private var showSidebar: Bool = true
    @State private var devServerRunning: Bool = false
    @AppStorage("soul.terminal.height") private var terminalHeight: Double = 260
    @State private var dragStartHeight: Double? = nil
    @State private var sidebarWasOpenBeforeReplay: Bool = true
    /// Mode chosen before any thread exists — persists across new chats so
    /// the hero composer remembers the user's safety preference.
    @State private var pendingPermissionMode: PermissionMode = .fullAccess
    /// SOUL-SOUL_DESKTOP-035: when the user clicks a live row owned by an
    /// external writer (terminal Claude/Gemini-CLI), we refuse to ACP-load
    /// and surface a sheet offering the read-only Replay path instead.
    @State private var externalLiveSession: SoulSession? = nil
    /// Phantom sidebar row for a fresh "New chat" composer before any send
    /// has resolved a real session id. Dropped when startThread() actually
    /// spawns a controller, or when the user navigates to another session.
    @State private var draftSession: SoulSession? = nil
    /// SOUL-SOUL_DESKTOP-041: path of the file currently open in the right-
    /// side preview pane. Set by FileChipRow taps via the Environment
    /// `openFilePreview` callback; cleared by the panel's X button.
    @State private var filePreviewPath: String? = nil
    /// Remembers whether the sidebar was open before the preview pane took
    /// over the canvas width, so closing the preview restores prior layout.
    @State private var sidebarWasOpenBeforePreview: Bool = true

    private var replayFraction: Double {
        guard let replay, replay.total > 0 else { return 0 }
        return Double(replay.index) / Double(replay.total)
    }

    private var contextUsage: ContextUsage? {
        if let replay {
            // Replay rows don't carry a provider — try claude first (precise
            // usage), fall back to hooks-byte estimate so the chip still
            // shows something for gemini/pi replays.
            return ContextUsage.compute(provider: .claude, sessionId: replay.sessionId, cwd: replay.project.path)
                ?? ContextUsage.compute(provider: .pi, sessionId: replay.sessionId, cwd: replay.project.path)
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

    private var sidePanelAnimation: Animation {
        .easeInOut(duration: 0.22)
    }

    /// Single tabbed right pane. Both Review and the File Preview live in
    /// one container with one width animation. Opening either, or both,
    /// expands the same pane; only the active tab's content renders.
    private enum RightTab: Hashable { case review, file }
    @State private var activeRightTab: RightTab = .review

    private var openRightTabs: [RightTab] {
        var tabs: [RightTab] = []
        if showReview { tabs.append(.review) }
        if filePreviewPath != nil { tabs.append(.file) }
        return tabs
    }

    private var rightPaneOpen: Bool { !openRightTabs.isEmpty }

    private var rightPaneWidth: CGFloat {
        rightPaneOpen ? 541 : 0
    }

    private func currentProject() -> SoulProject? {
        guard let key = selectedProject else { return nil }
        return SoulRegistry.projects().first { $0.id == key }
    }

    /// The thread the canvas is currently showing. Computed from the active
    /// key — multiple threads coexist in `threads`; only one paints at a time.
    private var thread: ThreadController? {
        guard let key = activeThreadKey else { return nil }
        return threads[key]
    }

    /// Switch the active thread, stashing the outgoing draft and loading the
    /// incoming one. No teardown, no re-spawn — the previous thread keeps its
    /// agent process and continues streaming in the background.
    /// Per-thread composer draft binding. Each ThreadView reads/writes its
    /// own slot in `draftsByThread` directly, so multiple mounted threads
    /// don't fight over a shared `prompt` state.
    private func bindingForDraft(_ id: String) -> Binding<String> {
        Binding(
            get: { draftsByThread[id] ?? "" },
            set: { draftsByThread[id] = $0 }
        )
    }

    private func setActiveThread(_ key: String?) {
        if let oldKey = activeThreadKey {
            draftsByThread[oldKey] = prompt
        }
        activeThreadKey = key
        prompt = key.flatMap { draftsByThread[$0] } ?? ""
    }

    private func startThread(display: String, agent: String) {
        guard let project = currentProject() else { return }
        draftSession = nil
        let controller = ThreadController(provider: harness, project: project)
        controller.permissionMode = pendingPermissionMode
        threads[controller.id] = controller
        setActiveThread(controller.id)
        Task { await controller.send(display: display, agent: agent) }
    }

    private func loadSession(_ session: SoulSession) {
        if let draft = draftSession, draft.id == session.id {
            // Tapping the draft row keeps the hero composer up — no agent
            // spawn until the user actually sends.
            replay?.stop()
            replay = nil
            activeThreadKey = nil
            prompt = draftsByThread[draft.id] ?? ""
            pendingActiveId = draft.id
            return
        }
        draftSession = nil
        guard let project = currentProject() else { return }
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
            default:          return harness
            }
        }()
        pendingActiveId = session.id

        // If this session is already open in a live ThreadController, just
        // surface it. No teardown, no re-load, no agent re-spawn. This is the
        // entire point of the multiplexer.
        if let existing = threads.values.first(where: { $0.sessionId == session.id }) {
            harness = existing.provider
            setActiveThread(existing.id)
            return
        }

        // SOUL-SOUL_DESKTOP-035: refuse to ACP-load a live session that's
        // owned by an external writer (terminal-origin row whose hooks.jsonl
        // is being actively appended by Claude / Gemini-CLI in a terminal).
        // session/load would stream the entire transcript back and we'd end
        // up with two writers on the same session — a SwiftUI layout storm
        // AND a semantic disaster. Offer Replay (read-only) instead.
        if session.isLive, session.origin == .terminal {
            pendingActiveId = nil
            externalLiveSession = session
            return
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
        let controller = ThreadController(provider: provider, project: routedProject)
        // Anchor the session-length chip to the original session start —
        // prefer the first hooks.jsonl event, fall back to the SoulSession's
        // own timestamp so we never show "0s" for a loaded session.
        if let origin = SoulRegistry.firstHookTimestamp(projectKey: routedProject.id, sessionId: session.id) {
            controller.startedAt = origin
        } else {
            controller.startedAt = session.timestamp
        }
        threads[controller.id] = controller
        setActiveThread(controller.id)
        // SOUL-SOUL_DESKTOP-043: Claude / Gemini-CLI sessions render from the
        // on-disk transcript without spawning the agent. The agent process is
        // started lazily on the user's first send via ensureSession(). The
        // earlier `session.isLive && origin == .terminal` branch already
        // short-circuited into externalLiveSessionSheet, so anything reaching
        // here is either finalized or desktop-origin-live (typically a chat
        // someone abandoned without /finalize). Both shapes are safe to read
        // from disk — the kernel marks them "live" purely because the dir
        // hasn't been finalized, not because an agent is actively writing.
        let useReadFirst = provider == .claude || provider == .geminiCLI
        if useReadFirst {
            Task { await controller.hydrateFromDisk(id: session.id) }
        } else {
            Task { await controller.loadSession(id: session.id) }
        }
    }

    private func newChat(targetProjectID: String? = nil) {
        replay?.stop()
        replay = nil
        if let oldKey = activeThreadKey {
            draftsByThread[oldKey] = prompt
        }
        activeThreadKey = nil
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
                origin: .desktop
            )
            draftSession = draft
            pendingActiveId = draft.id
        } else {
            draftSession = nil
            pendingActiveId = nil
        }
    }

    /// Explicit close — only path that actually tears an agent down. Wired
    /// into a close affordance on threads (sidebar row context menu, future
    /// tab close). Without an explicit close, threads live for the app's
    /// lifetime.
    private func closeThread(_ key: String) {
        guard let controller = threads[key] else { return }
        threads.removeValue(forKey: key)
        draftsByThread.removeValue(forKey: key)
        if activeThreadKey == key { activeThreadKey = nil; prompt = "" }
        Task { await controller.teardown() }
    }

    @ViewBuilder
    private func externalLiveSessionSheet(_ session: SoulSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(SoulColor.accent)
                Text("Session is running elsewhere")
                    .font(SoulFont.ui(15)).bold()
            }
            Text("This chat is being driven by a terminal Claude/Gemini-CLI session, not by Soul-Desktop. Loading it here would spawn a second writer on the same session and stream the entire transcript back. You can open it in read-only Replay instead.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(session.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
            }
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

    private func startReplay(_ session: SoulSession) {
        guard let project = currentProject() else { return }
        sidebarWasOpenBeforeReplay = showSidebar
        if showSidebar {
            setSidebarVisible(false)
        }
        // Replay is a separate view — it doesn't replace the active thread.
        // The thread keeps running; switching back via exitReplay reveals it.
        replay?.stop()
        replay = ReplayController(sessionId: session.id, project: project)
    }

    private func exitReplay() {
        // Cancel playback synchronously so no driver Task touches the
        // controller while it's being torn down.
        replay?.stop()
        // Move the deallocation off the main thread. For a 33h Claude
        // session `allEvents`/`visible` hold hundreds of ThreadItems with
        // megabyte text payloads; releasing those refs on main beach-balls
        // the click. Detached task drops the last strong ref off-main.
        if let outgoing = replay {
            replay = nil
            Task.detached(priority: .utility) {
                _ = outgoing  // hold then drop off-main
            }
        }
        if sidebarWasOpenBeforeReplay && !showSidebar {
            setSidebarVisible(true)
        }
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
        setSidebarVisible(!showSidebar)
    }

    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(sidePanelAnimation) { showSidebar = visible }
    }

    private func toggleReview() {
        withAnimation(sidePanelAnimation) {
            showReview.toggle()
            if showReview { activeRightTab = .review }
        }
    }

    private func setFilePreviewPath(_ path: String?) {
        withAnimation(sidePanelAnimation) {
            filePreviewPath = path
            if path != nil { activeRightTab = .file }
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
                onToggleSidebar: toggleSidebar,
                onToggleTerminal: toggleTerminal,
                onToggleReview: toggleReview,
                threadActive: thread != nil || replay != nil,
                sidebarActive: showSidebar,
                terminalActive: showTerminal,
                reviewActive: showReview,
                replayActive: replay != nil,
                contextUsage: contextUsage,
                thread: thread
            )
            ZStack {
                SoulColor.bg.ignoresSafeArea()
                if let replay {
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
                        ForEach(Array(threads.values), id: \.id) { ctrl in
                            let isActive = activeThreadKey == ctrl.id
                            ThreadView(
                                controller: ctrl,
                                prompt: bindingForDraft(ctrl.id),
                                onCancel: { if isActive { cancelTurn() } }
                            )
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                            .zIndex(isActive ? 1 : 0)
                        }
                        if activeThreadKey == nil {
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
                                provider: harness
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
            // Suppressed while a right-side pane is open so it doesn't fight
            // the FilePreview / Review surfaces for the right edge.
            if !rightPaneOpen {
                CanvasInfoOverlay(
                    projectPath: thread?.project.path ?? currentProject()?.path,
                    projectName: thread?.project.name ?? currentProject()?.name
                )
                .allowsHitTesting(true)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .geometryGroup()
    }

    @ViewBuilder
    private var rightSidePanels: some View {
        ZStack(alignment: .leading) {
            if rightPaneOpen {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(SoulColor.border.opacity(0.5))
                        .frame(width: 1)
                    rightPaneContent
                        .frame(width: 540)
                }
            }
        }
        .frame(width: rightPaneWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(SoulColor.bg)
        .clipped()
    }

    private var rightPaneContent: some View {
        VStack(spacing: 0) {
            rightPaneTabStrip
            Divider().background(SoulColor.border.opacity(0.5))
            // Render whichever tab is active. We keep the inactive tab's
            // content unmounted (computationally cheap to remount, and
            // ReviewPanel has its own load lifecycle).
            ZStack {
                if effectiveActiveRightTab == .review, showReview {
                    ReviewPanel(
                        projectPath: currentProject()?.path,
                        onClose: { closeRightTab(.review) },
                        embedded: true
                    )
                } else if effectiveActiveRightTab == .file, let preview = filePreviewPath {
                    FilePreviewPanel(
                        path: preview,
                        onClose: { closeRightTab(.file) },
                        embedded: true
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Falls back to the first available tab if the user's last selection
    /// is no longer open (e.g. they closed the file tab while it was active).
    private var effectiveActiveRightTab: RightTab {
        let tabs = openRightTabs
        if tabs.contains(activeRightTab) { return activeRightTab }
        return tabs.first ?? .review
    }

    private var rightPaneTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(openRightTabs, id: \.self) { tab in
                rightPaneTabButton(tab)
            }
            Spacer()
            Button(action: closeRightPane) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close pane")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SoulColor.bg)
    }

    private func closeRightPane() {
        withAnimation(sidePanelAnimation) {
            showReview = false
            filePreviewPath = nil
        }
    }

    @ViewBuilder
    private func rightPaneTabButton(_ tab: RightTab) -> some View {
        let isActive = effectiveActiveRightTab == tab
        HStack(spacing: 6) {
            Button(action: { activeRightTab = tab }) {
                HStack(spacing: 5) {
                    Image(systemName: tab == .review ? "checklist" : "doc.text")
                        .font(.system(size: 10))
                    Text(rightPaneTabLabel(tab))
                        .font(SoulFont.ui(11, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isActive ? SoulColor.fg : SoulColor.fgMuted)
            }
            .buttonStyle(.plain)

            Button(action: { closeRightTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isActive ? SoulColor.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? SoulColor.border.opacity(0.6) : Color.clear,
                    lineWidth: 0.5
                )
        )
    }

    private func rightPaneTabLabel(_ tab: RightTab) -> String {
        switch tab {
        case .review: return "Review"
        case .file:
            guard let p = filePreviewPath else { return "File" }
            return (p as NSString).lastPathComponent
        }
    }

    private func closeRightTab(_ tab: RightTab) {
        withAnimation(sidePanelAnimation) {
            switch tab {
            case .review: showReview = false
            case .file:   filePreviewPath = nil
            }
        }
    }

    private var sidebarPane: some View {
        ZStack(alignment: .leading) {
            SidebarView(
                selectedProject: $selectedProject,
                onSelectSession: loadSession,
                onReplaySession: startReplay,
                onNewChat: { target in newChat(targetProjectID: target) },
                onOpenSettings: { showSettings = true },
                activeReplaySessionId: replay?.sessionId,
                replayProgress: replayFraction,
                replayIndex: replay?.index ?? 0,
                replayTotal: replay?.total ?? 0,
                replayPrompts: replay?.promptCount ?? 0,
                replayReplies: replay?.replyCount ?? 0,
                activeSessionId: thread?.sessionId ?? pendingActiveId,
                activeProjectId: thread?.project.id ?? replay?.project.id ?? draftSession?.project,
                currentProvider: harness,
                draftSession: draftSession
            )
            .frame(width: SoulMetric.sidebarWidth)
            .frame(maxHeight: .infinity)
        }
        // Top + bottom insets stay constant so the sidebar's height doesn't
        // bob during the open/close animation — only the WIDTH and the
        // LEADING margin animate so the canvas can reclaim the full window
        // width when closed.
        .frame(width: showSidebar ? SoulMetric.sidebarWidth : 0, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .padding(.leading, showSidebar ? 24 : 0)
        .padding(.top, 40)
        .padding(.bottom, 24)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
            mainCanvas
            rightSidePanels
        }
        // Paint the window background in the canvas color so where the
        // sidebar's rounded trailing corner curves away, the cut-out shows
        // the same surface as the canvas instead of the system window
        // background bleeding through.
        .background(SoulColor.bg.ignoresSafeArea())
        .animation(sidePanelAnimation, value: showSidebar)
        .animation(sidePanelAnimation, value: showReview)
        .animation(sidePanelAnimation, value: filePreviewPath)
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
                    ?? replay?.project.path
                    ?? currentProject()?.path
                guard let base else { return stripped }
                return (base as NSString).appendingPathComponent(stripped)
            }()
            // Some upstream text (e.g. agent responses) elides long filenames
            // with U+2026 ellipsis like `…_097e4d72-…json`. Glob the parent
            // dir for a single match before giving up.
            var final = resolveEllipsisPath(resolved)
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
            if filePreviewPath == nil {
                sidebarWasOpenBeforePreview = showSidebar
                if showSidebar {
                    setSidebarVisible(false)
                }
            }
            setFilePreviewPath(final)
        }
        .onChange(of: filePreviewPath) { _, new in
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
            if let draft = draftSession, draft.project != newKey {
                draftSession = nil
                if pendingActiveId == draft.id { pendingActiveId = nil }
            }
        }
        .onChange(of: showTerminal) { _, isOpen in
            if !isOpen { devServerRunning = false }
        }
    }
}

private struct CanvasToolbar: View {
    var harness: Provider
    var onPickHarness: (Provider) -> Void = { _ in }
    var onSmokeTest: () -> Void = {}
    var onNewChat: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onToggleTerminal: () -> Void = {}
    var onToggleReview: () -> Void = {}
    var threadActive: Bool = false
    var sidebarActive: Bool = true
    var terminalActive: Bool = false
    var reviewActive: Bool = false
    var replayActive: Bool = false
    var contextUsage: ContextUsage? = nil
    var thread: ThreadController? = nil

    /// Debug-affordance gate. Off by default; users who need the smoke-test
    /// harness can flip it on in Settings (or via `defaults write`). Keeps
    /// the main toolbar uncluttered for the 99% who never touch it.
    @AppStorage("soul.debug.showSmoke") private var showSmoke: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ToolbarIcon(name: "sidebar.left", isActive: sidebarActive, action: onToggleSidebar)
                .padding(.trailing, 6)
                .disabled(replayActive)
                .opacity(replayActive ? 0.35 : 1)
            if threadActive {
                Button(action: onNewChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                        Text("New chat")
                            .font(SoulFont.ui(12, weight: .regular))
                    }
                    .foregroundStyle(SoulColor.fgMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SoulColor.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(replayActive)
                .opacity(replayActive ? 0.35 : 1)
            }

            // Title cluster — codex-style header merged into the toolbar.
            // Only renders once the thread has a real session id (i.e. not a
            // brand-new chat that's still on the hero/empty state), so we
            // don't show an orphan rename button.
            if let thread, thread.sessionId != nil, !replayActive {
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 8)
                ThreadTitleCluster(controller: thread, onSmokeTest: onSmokeTest)
            }

            Spacer()

            // Stats group — moved to the right so the title cluster gets
            // primary visual weight on the left. Order: context fill ·
            // session stats · agent log.
            if threadActive {
                if let usage = contextUsage {
                    ContextUsageChip(usage: usage)
                        .padding(.trailing, 6)
                }
                if let thread {
                    SessionStatsChip(controller: thread)
                        .padding(.trailing, 6)
                    AgentLogChip(controller: thread)
                        .padding(.trailing, 10)
                }
            }

            HStack(spacing: 14) {
                HarnessPicker(selection: harness, onSelect: onPickHarness)
                    .disabled(replayActive)
                if showSmoke {
                    Button(action: onSmokeTest) {
                        Image(systemName: "ladybug")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(replayActive)
                    .help("Smoke-test the active provider (Debug)")
                }
                ToolbarIcon(name: "terminal", isActive: terminalActive, action: onToggleTerminal)
                    .disabled(replayActive)
                ToolbarIcon(name: "sidebar.right", isActive: reviewActive, action: onToggleReview)
                    .disabled(replayActive)
            }
            .opacity(replayActive ? 0.35 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(SoulColor.bg)
    }
}

/// SOUL-SOUL_DESKTOP-047: title cluster that lives inline in the toolbar.
/// Replaces the per-thread `ThreadHeader` row that used to sit between the
/// toolbar and the canvas. Layout: pencil (rename) · title text · ⋯ menu.
/// High-frequency action (rename) is inline; copy/coming-soon actions
/// retreat into the overflow menu.
private struct ThreadTitleCluster: View {
    @Bindable var controller: ThreadController
    var onSmokeTest: () -> Void = {}
    @AppStorage("soul.debug.showSmoke") private var showSmoke: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { controller.requestRename() }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename chat")

            // Suppress the title text while it still reads "New chat" — the
            // adjacent New chat pill already says it, and the redundancy is
            // distracting until the title sniffer lands a real title.
            if controller.displayTitle != "New chat" {
                Text(controller.displayTitle)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                Text("Untitled")
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .italic()
                    .frame(maxWidth: 320, alignment: .leading)
            }

            Menu {
                Button("Rename chat") { controller.requestRename() }
                Divider()
                Button("Copy session ID") { controller.copySessionIdToPasteboard() }
                Button("Copy as Markdown") { controller.copyMarkdownToPasteboard() }
                Divider()
                Section("Debug") {
                    Toggle("Show smoke-test button", isOn: $showSmoke)
                    Button("Run smoke test now", action: onSmokeTest)
                }
                Divider()
                Section("Coming soon") {
                    Button("Fork into new worktree") {}.disabled(true)
                    Button("Open side chat") {}.disabled(true)
                    Button("Open in new window") {}.disabled(true)
                    Button("Copy deeplink") {}.disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct HarnessPicker: View {
    var selection: Provider
    var onSelect: (Provider) -> Void

    var body: some View {
        Menu {
            ForEach(Provider.allCases) { p in
                Button {
                    onSelect(p)
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: p.icon)
                            Text(p.label)
                            if selection == p { Image(systemName: "checkmark") }
                        }
                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(selection.label)
                    .font(SoulFont.ui(12, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.surface.opacity(0.6), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ToolbarIcon: View {
    let name: String
    var isActive: Bool = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? SoulColor.accentMuted : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Always-on log surface tied to the active thread's agent log. Tap to open
/// the same popover the stall badge uses — useful when you want to peek at
/// what the agent is doing without waiting 30s for the stall threshold.
private struct AgentLogChip: View {
    @Bindable var controller: ThreadController
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scroll")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(controller.agentLog.count)")
                    .font(SoulFont.code(11))
                    .foregroundStyle(controller.agentLog.isEmpty ? SoulColor.fgSubtle : SoulColor.fg)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SoulColor.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Agent log (\(controller.agentLog.count) lines)")
        .popover(isPresented: $showing, arrowEdge: .top) {
            AgentLogPanel(lines: controller.agentLog)
        }
    }
}

private struct ContextUsageChip: View {
    let usage: ContextUsage

    private var tone: Color {
        if usage.fraction >= 0.9 { return .red }
        if usage.fraction >= 0.7 { return .orange }
        return SoulColor.fgMuted
    }

    private var maxLabel: String {
        if usage.max >= 1_000_000 { return "\(usage.max / 1_000_000)M" }
        return "\(usage.max / 1_000)k"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.bottomhalf.filled")
                .font(.system(size: 10))
                .foregroundStyle(tone)
            Text("\(usage.shortLabel)")
                .font(SoulFont.code(11, weight: .regular))
                .foregroundStyle(SoulColor.fg)
            Text("/ \(maxLabel)")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgSubtle)
            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)
            Text("\(Int(usage.fraction * 100))%")
                .font(SoulFont.code(11))
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SoulColor.surface, in: Capsule())
        .help(usage.isEstimate
              ? "≈\(usage.tokens) tokens (estimated from transcript bytes — provider doesn't expose precise usage)"
              : "\(usage.tokens) tokens (precise — last-turn prompt size from the Claude transcript)")
    }
}

/// Compact chip showing how "fat" the active thread has gotten: tool calls so
/// far, user-prompt chapters, and elapsed wall-clock since the thread was
/// instantiated. Elapsed time refreshes once per second via TimelineView so
/// we never schedule our own Timer / re-render the whole toolbar.
private struct SessionStatsChip: View {
    @Bindable var controller: ThreadController

    private var toolCount: Int {
        controller.items.reduce(into: 0) { acc, item in
            if case .toolCall = item { acc += 1 }
        }
    }

    private var chapterCount: Int {
        controller.items.reduce(into: 0) { acc, item in
            if case .userMessage = item { acc += 1 }
        }
    }

    private func elapsedLabel(now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(controller.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h\(rem)m"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            HStack(spacing: 6) {
                Image(systemName: "wrench.adjustable")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(toolCount)")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1).fixedSize()
                Text("·")
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1).fixedSize()
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(chapterCount)")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1).fixedSize()
                Text("·")
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1).fixedSize()
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(elapsedLabel(now: ctx.date))
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1).fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.surface, in: Capsule())
            .help("\(toolCount) tool calls · \(chapterCount) prompts · running \(elapsedLabel(now: ctx.date))")
        }
    }
}

/// Strips trailing `:LINE` or `:LINE:COL` from a path token. The linkifier
/// in MarkdownView captures the full `file.swift:1470` form so that hover
/// preview text shows the line number, but the file-preview path resolver
/// only wants the filesystem path. Returns the input unchanged if it
/// doesn't end with a numeric `:N` suffix.
private func stripLineSuffix(_ path: String) -> String {
    var result = path
    for _ in 0..<2 {
        if let colon = result.lastIndex(of: ":"),
           result.index(after: colon) < result.endIndex,
           result[result.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            result = String(result[..<colon])
        } else {
            break
        }
    }
    return result
}

/// Searches the top level of every active project's root directory for a
/// file matching `filename` exactly. Returns the absolute path when exactly
/// one match exists across all roots — anything ambiguous (zero / multi)
/// returns nil so the caller falls through to its "not found" path. Bounded
/// to a single readdir per project; no recursion.
private func findFileInKnownProjects(filename: String) -> String? {
    let projects = SoulRegistry.activeProjects()
    var hits: [String] = []
    for p in projects {
        guard !p.path.isEmpty else { continue }
        let candidate = (p.path as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: candidate) {
            hits.append(candidate)
            if hits.count > 1 { return nil }
        }
    }
    return hits.first
}

/// If `path` contains a U+2026 ellipsis (LLM- or kernel-elided filename),
/// glob the parent directory for a single file matching the surrounding
/// fixed segments. Returns the resolved match, or the original path if
/// there's no ellipsis, no unique match, or the parent dir doesn't exist.
private func resolveEllipsisPath(_ path: String) -> String {
    guard path.contains("…") else { return path }
    let parent = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    guard !parent.isEmpty,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: parent)
    else { return path }
    let parts = name.split(separator: "…", omittingEmptySubsequences: false).map(String.init)
    // Heuristic: every non-empty segment must appear in the candidate, in
    // order. Anchor first segment to prefix and last to suffix when present.
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return path }
    let prefix = parts.first ?? ""
    let suffix = parts.last ?? ""
    let matches = entries.filter { candidate in
        if !prefix.isEmpty && !candidate.hasPrefix(prefix) { return false }
        if !suffix.isEmpty && !candidate.hasSuffix(suffix) { return false }
        var idx = candidate.startIndex
        for seg in nonEmpty {
            guard let r = candidate.range(of: seg, range: idx..<candidate.endIndex) else { return false }
            idx = r.upperBound
        }
        return true
    }
    guard matches.count == 1 else { return path }
    return (parent as NSString).appendingPathComponent(matches[0])
}

#Preview {
    AppShell()
        .frame(width: 1200, height: 820)
}
