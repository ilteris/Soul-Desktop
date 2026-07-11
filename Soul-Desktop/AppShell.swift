import SwiftUI
import AppKit
import Combine

struct AppShell: View {
    var registryStore: SoulRegistryStore = LiveSoulRegistryStore.shared
    @State var workspace = SoulWorkspaceModel()
    /// User's appearance preference. Values: "system", "light", "dark".
    /// `system` means follow the macOS appearance (the SoulColor tokens
    /// already do that via dynamic NSColor); the other two force a side.
    @AppStorage("soul.appearance") private var appearancePref: String = "system"
    /// Multiplex: every opened conversation gets its own ThreadController and
    /// stays alive until explicitly closed. Switching sessions is a pointer
    /// swap, not a teardown — agent processes keep streaming in the
    /// background, no re-spawn, no re-hydration.
    @State var sessions = AppSessionCoordinator()
    @State var replay = AppReplayCoordinator()
    @State var hydrationCache = SessionHydrationCache()
    /// Browser-style cross-project view history. ⌘[ / ⌘] walk this stack.
    @State var viewHistory = SessionViewHistory()
    /// True while `loadSession` is being driven by `goBack`/`goForward`. The
    /// session-flow path checks this to avoid re-pushing onto the history
    /// stack (which would corrupt the back/forward semantics).
    @State var isNavigatingHistory: Bool = false
    /// Optimistic selection: the live-row ID the user just tapped, used for
    /// sidebar highlight before the spawn completes and `thread.sessionId`
    /// is real. Cleared once the thread's own session ID catches up.
    /// SOUL-SOUL_DESKTOP-138: nonce bumped every time the user initiates a
    /// new chat (composer-send into empty hero or sidebar "+ New chat"
    /// button). SidebarView observes this and auto-expands the parent
    /// project of the new thread. Restored-at-launch sessions don't bump
    /// this, so launch UX stays "all projects collapsed."
    @State var newChatNonce: Int = 0
    /// Pre-thread composer text. Used by HeroEmptyState (no thread yet) and
    /// while the draft-session row is selected. Once a real thread exists,
    /// each ThreadController owns its own `composerDraft` so keystrokes
    /// don't invalidate AppShell.body.
    @State var prompt: String = ""
    /// True while a background `claude -p` subprocess is composing a branch-
    /// seed sentence for a freshly-spawned cross-provider draft. The composer
    /// uses this to show a "Summarizing previous chat…" placeholder while the
    /// LLM is thinking; the seed populates `prompt` when it lands.
    @State var branchSeedLoading: Bool = false
    @State var showSmoke = false
    @State private var codexSmokeModel = CodexSmokeViewModel()
    @State var showSettings = false
    @State var showNewProject = false
    @State var projectPathOverrides: [String: String] = [:]
    @State var harness: Provider = .geminiCLI

    /// SOUL-SOUL_DESKTOP-237: presented when the user picks a different
    /// provider in the composer harness picker while an active thread
    /// already has items. Sheet asks: continue (closes current, fresh
    /// draft in new harness) or branch (preserve current, fork into a
    /// new session via branchFrom). Nil when no decision is pending.
    @State var pendingHarnessSwitch: HarnessSwitchContext? = nil
    /// Per-session opt-out for the harness-switch sheet. Resets on app
    /// relaunch (not @AppStorage by design — the prompt is the safety
    /// rail, and forgetting an opt-out on next launch is correct).
    @State var skipHarnessSwitchSheet: Bool = false

    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)

    @StateObject var terminalModel = TerminalPanelModel()
    @State var showTerminal: Bool = false
    @AppStorage("soul.review.visible") var showReview: Bool = false
    @AppStorage("soul.computerUse.visible") var showComputerUse: Bool = false
    @State var rightPane = AppRightPaneCoordinator()
    @AppStorage("soul.sidebar.visible") var showSidebar: Bool = true
    /// SOUL-208: NavigationSplitView visibility binding.
    @State var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State var devServerRunning: Bool = false
    @AppStorage("soul.terminal.height") var terminalHeight: Double = 260
    @State var dragStartHeight: Double? = nil
    /// Mode chosen before any thread exists — persists across new chats so
    /// the hero composer remembers the user's safety preference.
    @State var pendingPermissionMode: PermissionMode = .fullAccess
    /// SOUL-SOUL_DESKTOP-035: when the user clicks a live row owned by an
    /// external writer (terminal Claude/Gemini-CLI), we refuse to ACP-load
    /// and surface a sheet offering the read-only Replay path instead.
    @State var externalLiveSession: SoulSession? = nil
    /// Remembers whether the sidebar was open before the preview pane took
    /// over the canvas width, so closing the preview restores prior layout.
    @State private var sidebarWasOpenBeforePreview: Bool = true
    /// Lifted from SidebarView so the repair-session toast renders at the
    /// top center of the whole window instead of being clipped inside the
    /// 320pt sidebar column. SidebarView writes here via Binding.
    @State var repairToast: String? = nil
    /// Provider-side context-compaction watcher. Shells out to
    /// `soul autocompact` when the usage fraction crosses the shared
    /// compact_policy threshold, dispatches the returned directive
    /// (slash command, native compact, or toast). One instance lives
    /// for the AppShell's lifetime;
    /// it short-circuits when no thread is active.
    @State var autoCompact = AutoCompactController()
    @State var emptyStateDroppedAttachments: [String] = []
    @State var isImageDropTargeted: Bool = false
    @State var cachedContextUsage: ContextUsage? = nil
    @State var cachedContextUsageRequestID: String? = nil
    @State var reminderStore = ReminderStore.shared
    @State var pendingReminderContext: SoulReminderContext? = nil

    var contextUsage: ContextUsage? {
        if let replay = replay.controller {
            // During replay, simulate the context window filling as events
            // reveal — sum text bytes from `visible` (the prefix of all
            // events played so far) rather than the static end-of-session
            // value. The chip animates 0% → final-fill in lockstep with
            // the timeline scrubber.
            return ContextUsage.estimateFromReplayItems(replay.visible)
        }
        if let thread, thread.sessionId != nil {
            // Codex streams precise token usage through the
            // `thread/tokenUsage/updated` notification, which the controller
            // captures into `codexTokenUsage`. Read it directly here so the
            // chip stays live instead of falling through to the on-disk
            // rollout parser (which we haven't written yet).
            if thread.provider == .codex,
               let tokens = thread.codexTokensUsed,
               let budget = thread.codexContextWindow {
                return ContextUsage(
                    tokens: tokens, max: budget, isEstimate: false,
                    breakdown: ContextUsage.Breakdown(
                        model: "codex",
                        input: tokens,
                        cacheCreate: nil,
                        cacheRead: nil,
                        source: "Streamed live from Codex `thread/tokenUsage/updated`."
                    )
                )
            }
            return cachedContextUsage
        }
        return nil
    }

    var contextUsageRequest: ContextUsageRequest? {
        guard !replay.isActive,
              let thread,
              thread.provider != .codex,
              let sid = thread.sessionId
        else { return nil }
        return ContextUsageRequest(
            providerRawValue: thread.provider.rawValue,
            sessionId: sid,
            cwd: thread.project.path,
            projectKey: thread.project.id
        )
    }

    var sidePanelAnimation: Animation {
        .easeInOut(duration: 0.22)
    }

    func projectWithPathOverride(_ project: SoulProject?) -> SoulProject? {
        guard var project else { return nil }
        if let override = projectPathOverrides[project.id],
           FileManager.default.fileExists(atPath: override) {
            project.path = override
        }
        return project
    }

    func currentProject() -> SoulProject? {
        projectWithPathOverride(workspace.selectedProject)
    }

    private func previewBasePath() -> String? {
        if let replayController = replay.controller {
            let cachedReplayWorktreePath: String? = {
                registryStore.cachedSessions(forProject: replayController.project.id)?
                    .first(where: { $0.id == replayController.sessionId })?
                    .worktreePath
            }()
            let replayProjectOverridePath = projectPathOverrides[replayController.project.id]
            return Self.preferredPreviewBasePath(
                sessionWorktreePath: cachedReplayWorktreePath,
                projectOverridePath: replayProjectOverridePath,
                threadProjectPath: nil,
                replayProjectPath: replayController.project.path,
                currentProjectPath: nil
            )
        } else {
            let cachedWorktreePath: String? = {
                guard let thread,
                      let sessionId = thread.sessionId
                else { return nil }
                return registryStore.cachedSessions(forProject: thread.project.id)?
                    .first(where: { $0.id == sessionId })?
                    .worktreePath
            }()
            let projectOverridePath = thread
                .flatMap { projectPathOverrides[$0.project.id] }
                ?? workspace.selectedProjectId.flatMap { projectPathOverrides[$0] }
            return Self.preferredPreviewBasePath(
                sessionWorktreePath: cachedWorktreePath,
                projectOverridePath: projectOverridePath,
                threadProjectPath: thread?.activeProjectPath,
                replayProjectPath: nil,
                currentProjectPath: currentProject()?.path
            )
        }
    }

    func openReminderSheet(thread: ThreadController?) {
        guard let context = reminderContext(thread: thread) else { return }
        pendingReminderContext = context
    }

    private func reminderContext(thread: ThreadController?) -> SoulReminderContext? {
        if let thread {
            return SoulReminderContext(
                projectId: thread.project.id,
                projectName: thread.project.name,
                projectPath: thread.project.path,
                threadId: thread.sessionId,
                threadTitle: thread.displayTitle,
                provider: thread.provider.rawValue
            )
        }
        guard let project = currentProject() else { return nil }
        return SoulReminderContext(
            projectId: project.id,
            projectName: project.name,
            projectPath: project.path,
            threadId: nil,
            threadTitle: nil,
            provider: harness.rawValue
        )
    }


    /// The thread the canvas is currently showing. Multiple controllers
    /// coexist in the session coordinator; only one paints at a time.
    var thread: ThreadController? {
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

    func toggleSidebar() {
        // SOUL-208: drive NavigationSplitView's column directly; onChange
        // syncs the showSidebar AppStorage so other readers stay current.
        // SOUL-208: NavigationSplitView's reopen path is `.doubleColumn`
        // (not `.all`) on macOS — setting `.all` after `.detailOnly` is a
        // documented no-op for two-column splits.
        withAnimation(sidePanelAnimation) {
            columnVisibility = (columnVisibility == .detailOnly) ? .doubleColumn : .detailOnly
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        withAnimation(sidePanelAnimation) { showSidebar = visible }
    }

    func toggleReview() {
        withAnimation(sidePanelAnimation) {
            rightPane.toggleReview()
            showReview = rightPane.reviewVisible
        }
    }

    func toggleComputerUse() {
        withAnimation(sidePanelAnimation) {
            rightPane.toggleComputerUse()
            showComputerUse = rightPane.computerUseVisible
        }
    }

    private func setFilePreviewPath(_ path: String?) {
        withAnimation(sidePanelAnimation) {
            rightPane.setFilePreviewPath(path)
        }
    }

    private func setWebPreviewURL(_ url: URL?) {
        withAnimation(sidePanelAnimation) {
            rightPane.setWebPreviewURL(url)
        }
    }

    func openPreviewPath(_ raw: String) {
        let stripped = stripLineSuffix(raw)
        let resolved = resolvePreviewPath(stripped)
        var final = resolveEllipsisPath(resolved)
        final = resolveProjectPrefixedPreviewPath(final, stripped: stripped)
        final = resolveBarePreviewPath(final, stripped: stripped)
        switch PreviewPathTarget.resolve(final) {
        case .directory(let path):
            if let preview = rightPane.filePreviewPath,
               Self.sameFilesystemPath(preview, path) {
                setFilePreviewPath(nil)
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            return
        case .file(let path):
            final = path
        }
        if rightPane.filePreviewPath == nil {
            sidebarWasOpenBeforePreview = showSidebar
            if showSidebar {
                setSidebarVisible(false)
            }
        }
        setFilePreviewPath(final)
    }

    func openWebPreview(_ url: URL) {
        if rightPane.webPreviewURL == nil {
            sidebarWasOpenBeforePreview = showSidebar
            if showSidebar {
                setSidebarVisible(false)
            }
        }
        setWebPreviewURL(url)
    }

    private func resolvePreviewPath(_ stripped: String) -> String {
        Self.resolvePreviewPath(stripped, base: previewBasePath())
    }

    private func resolveProjectPrefixedPreviewPath(_ current: String, stripped: String) -> String {
        guard !FileManager.default.fileExists(atPath: current),
              !stripped.hasPrefix("/"), !stripped.hasPrefix("~"),
              let base = previewBasePath()
        else { return current }
        let baseName = (base as NSString).lastPathComponent
        let parts = stripped.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(baseName) else { return current }
        let retry = (base as NSString).appendingPathComponent(String(parts[1]))
        return FileManager.default.fileExists(atPath: retry) ? retry : current
    }

    static func preferredPreviewBasePath(
        sessionWorktreePath: String?,
        projectOverridePath: String?,
        threadProjectPath: String?,
        replayProjectPath: String?,
        currentProjectPath: String?,
        fileManager: FileManager = .default
    ) -> String? {
        for candidate in [sessionWorktreePath, projectOverridePath, threadProjectPath, replayProjectPath, currentProjectPath] {
            guard let path = candidate, !path.isEmpty else { continue }
            let expanded = (path as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return expanded
            }
        }
        return threadProjectPath ?? replayProjectPath ?? currentProjectPath
    }

    static func resolvePreviewPath(_ stripped: String, base: String?) -> String {
        if stripped.hasPrefix("/") { return stripped }
        if stripped.hasPrefix("~") { return (stripped as NSString).expandingTildeInPath }
        guard let base else { return stripped }
        return (base as NSString).appendingPathComponent(stripped)
    }

    private func resolveBarePreviewPath(_ current: String, stripped: String) -> String {
        guard Self.shouldSearchKnownProjectsForBarePreview(
                currentExists: FileManager.default.fileExists(atPath: current),
                stripped: stripped,
                base: previewBasePath()
              ),
              let match = findFileInKnownProjects(filename: stripped)
        else { return current }
        return match
    }

    static func shouldSearchKnownProjectsForBarePreview(currentExists: Bool, stripped: String, base: String?) -> Bool {
        guard !currentExists,
              !stripped.hasPrefix("/"),
              !stripped.hasPrefix("~"),
              !stripped.contains("/")
        else { return false }
        return base?.isEmpty ?? true
    }

    static func sameFilesystemPath(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: (lhs as NSString).expandingTildeInPath)
            .standardizedFileURL
        let right = URL(fileURLWithPath: (rhs as NSString).expandingTildeInPath)
            .standardizedFileURL
        return left == right
    }

    enum PreviewPathTarget: Equatable {
        case file(String)
        case directory(String)

        static func resolve(_ path: String, fileManager: FileManager = .default) -> PreviewPathTarget {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .directory(expanded)
            }
            return .file(expanded)
        }
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
        // ⌘N — Soul is a single-window session browser. Replace the system
        // New Window command with a draft session in the current project.
        .onReceive(NotificationCenter.default.publisher(for: .soulNewChat)) { _ in
            newChat()
        }
        // ⌘[ / ⌘] — browser-style back / forward through viewed sessions.
        // Cross-project: jumps the sidebar to the target's project too.
        .onReceive(NotificationCenter.default.publisher(for: .soulOlderSession)) { _ in
            navigateHistory(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulNewerSession)) { _ in
            navigateHistory(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationManager.openSessionFromNotification)) { note in
            guard
                let sid = note.userInfo?["sessionId"] as? String,
                let key = note.userInfo?["projectKey"] as? String
            else { return }
            openSessionFromNotification(sessionId: sid, projectKey: key)
        }
        .onAppear {
            rightPane.reviewVisible = showReview
            rightPane.computerUseVisible = showComputerUse
        }
        .task {
            await workspace.start()
        }
        .task(id: contextUsageRequest) {
            await refreshContextUsage(for: contextUsageRequest)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await workspace.refreshProjects() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            reminderStore.now = now
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
        .overlay(alignment: .topTrailing) {
            DueReminderBanner(
                reminders: reminderStore.dueReminders,
                onComplete: { reminderStore.complete($0) },
                onDismiss: { reminderStore.dismiss($0) }
            )
            .padding(.top, 54)
            .padding(.trailing, 24)
        }
        .animation(.easeInOut(duration: 0.18), value: repairToast)
        .autoCompactBridge(
            controller: autoCompact,
            fraction: contextUsage?.fraction,
            activeThread: thread,
            contextUsage: contextUsage,
            onBranch: { provider in
                if let thread { branchFrom(thread, to: provider) }
            }
        )
        .previewRouting(
            filePreviewPath: rightPane.filePreviewPath,
            webPreviewURL: rightPane.webPreviewURL,
            openFile: { raw in openPreviewPath(raw) },
            openWeb: { url in openWebPreview(url) },
            restoreSidebarIfNeeded: { restoreSidebarAfterPreviewClose() }
        )
        .toolbar { mainToolbarContent }
        // SOUL-249: hide the unified toolbar's glass bezel so our own
        // capsule chips render flat instead of being double-wrapped in
        // a system-supplied white pill.
        .toolbarBackground(.hidden, for: .windowToolbar)
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
                onCreated: { newKey, workspacePathOverride in
                    showNewProject = false
                    Task { @MainActor in
                        // SOUL-SOUL_DESKTOP-326: project creation mutates the
                        // registry outside the sidebar, so explicitly refresh
                        // both workspace selection state and SidebarView's
                        // local project snapshot. Without this, the new
                        // project is present on disk but invisible until app
                        // reload / key-window refresh.
                        if let workspacePathOverride {
                            projectPathOverrides[newKey] = workspacePathOverride
                        } else {
                            projectPathOverrides.removeValue(forKey: newKey)
                        }
                        await workspace.handleProjectMutationCompleted()
                        workspace.selectProject(newKey)
                    }
                },
                onCancel: { showNewProject = false }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { pendingReminderContext != nil },
                set: { if !$0 { pendingReminderContext = nil } }
            )
        ) {
            if let context = pendingReminderContext {
                ReminderSheet(
                    context: context,
                    onSave: { draft in
                        _ = reminderStore.create(draft)
                        pendingReminderContext = nil
                    },
                    onCancel: { pendingReminderContext = nil }
                )
            }
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
        // SOUL-SOUL_DESKTOP-237: harness-switch confirmation. Presented
        // when the user picks a provider in the composer harness picker
        // that differs from the active thread's provider AND the thread
        // already has items. See AppShell+Canvas.swift:onPickHarness.
        .sheet(item: $pendingHarnessSwitch) { ctx in
            HarnessSwitchSheet(
                context: ctx,
                onContinue: { remember in
                    confirmContinueHarnessSwitch(target: ctx.target, rememberChoice: remember)
                },
                onBranch: { remember in
                    confirmBranchHarnessSwitch(target: ctx.target, rememberChoice: remember)
                },
                onCancel: {
                    pendingHarnessSwitch = nil
                }
            )
        }
        .background {
            Button("") { showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("") { toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .background(SoulColor.bg)
        .preferredColorScheme(appearancePref == "dark" ? .dark : appearancePref == "light" ? .light : nil)
        .onChange(of: workspace.selectedProjectId) { _, newKey in
            // Selecting a project row should route the composer to that
            // project. Mounted threads stay alive in the background, but a
            // different project's thread must not keep owning the canvas or
            // the next send will append to the wrong session.
            devServerRunning = false
            if sessions.loadingThread?.projectId == newKey {
                return
            }
            if let active = sessions.activeThread, active.project.id != newKey {
                sessions.showProjectDraftOrEmpty(projectId: newKey)
            }
        }
        .onChange(of: showTerminal) { _, isOpen in
            if !isOpen { devServerRunning = false }
        }
    }

    private func restoreSidebarAfterPreviewClose() {
        if sidebarWasOpenBeforePreview, !showSidebar {
            setSidebarVisible(true)
        }
    }
}
