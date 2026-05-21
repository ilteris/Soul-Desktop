import SwiftUI
import AppKit

struct AppShell: View {
    var registryStore: SoulRegistryStore = LiveSoulRegistryStore.shared
    @State var selectedProject: String? = nil
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
    @State var emptyStateDroppedAttachments: [String] = []
    @State var isImageDropTargeted: Bool = false

    var contextUsage: ContextUsage? {
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
        return registryStore.projects().first { $0.id == key }
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

    private func setFilePreviewPath(_ path: String?) {
        withAnimation(sidePanelAnimation) {
            rightPane.setFilePreviewPath(path)
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
        // ⌘[ / ⌘] — browser-style back / forward through viewed sessions.
        // Cross-project: jumps the sidebar to the target's project too.
        .onReceive(NotificationCenter.default.publisher(for: .soulOlderSession)) { _ in
            navigateHistory(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulNewerSession)) { _ in
            navigateHistory(forward: true)
        }
        .onAppear {
            rightPane.reviewVisible = showReview
            // SOUL-SOUL_DESKTOP-161: warm the @Observable project cache so
            // any view (Composer, Sidebar, Toolbar) reading
            // LiveSoulRegistryStore.shared.cachedActive/cachedProjects hits
            // an in-memory array instead of a disk-stat sweep per body
            // re-eval. Refresh is also triggered on window key-back via the
            // notification below.
            LiveSoulRegistryStore.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // SOUL-SOUL_DESKTOP-161: pick up project additions/archives made
            // outside the app (e.g., direct edits to PROJECTS.json or
            // wizard completions in another window).
            LiveSoulRegistryStore.shared.refresh()
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
                    // SOUL-SOUL_DESKTOP-161: refresh the cached project
                    // list so the new project appears in Composer's
                    // ProjectChip menu without waiting for the next
                    // window-key-back notification.
                    LiveSoulRegistryStore.shared.refresh()
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
