import SwiftUI
import AppKit

struct AppShell: View {
    @State private var selectedProject: String? = nil
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
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var harness: Provider = .geminiCLI

    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)

    @StateObject private var terminalModel = TerminalPanelModel()
    @State private var showTerminal: Bool = false
    @AppStorage("soul.review.visible") private var showReview: Bool = false
    @AppStorage("soul.sidebar.visible") private var showSidebar: Bool = true
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
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
            return ContextUsage.compute(provider: thread.provider, sessionId: sid, cwd: thread.project.path)
        }
        return nil
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
    private func setActiveThread(_ key: String?) {
        if let oldKey = activeThreadKey {
            draftsByThread[oldKey] = prompt
        }
        activeThreadKey = key
        prompt = key.flatMap { draftsByThread[$0] } ?? ""
    }

    private func startThread(display: String, agent: String) {
        guard let project = currentProject() else { return }
        let controller = ThreadController(provider: harness, project: project)
        controller.permissionMode = pendingPermissionMode
        threads[controller.id] = controller
        setActiveThread(controller.id)
        Task { await controller.send(display: display, agent: agent) }
    }

    private func loadSession(_ session: SoulSession) {
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
        Task { await controller.loadSession(id: session.id) }
    }

    private func newChat() {
        pendingActiveId = nil
        replay?.stop()
        replay = nil
        // New chat = open a fresh empty thread; existing threads stay alive
        // in the background. Composer clears for the new draft.
        if let oldKey = activeThreadKey {
            draftsByThread[oldKey] = prompt
        }
        activeThreadKey = nil
        prompt = ""
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
            withAnimation(.easeInOut(duration: 0.22)) {
                showSidebar = false
                splitVisibility = .detailOnly
            }
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
            withAnimation(.easeOut(duration: 0.26)) {
                showSidebar = true
                splitVisibility = .all
            }
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
        if showSidebar {
            withAnimation(.easeInOut(duration: 0.22)) {
                showSidebar = false
                splitVisibility = .detailOnly
            }
        } else {
            withAnimation(.easeOut(duration: 0.26)) {
                showSidebar = true
                splitVisibility = .all
            }
        }
    }

    private func toggleReview() {
        if showReview {
            withAnimation(.easeInOut(duration: 0.22)) { showReview = false }
        } else {
            withAnimation(.easeOut(duration: 0.26)) { showReview = true }
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

    var body: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            SidebarView(
                selectedProject: $selectedProject,
                onSelectSession: loadSession,
                onReplaySession: startReplay,
                onNewChat: newChat,
                onOpenSettings: { showSettings = true },
                activeReplaySessionId: replay?.sessionId,
                replayProgress: replayFraction,
                replayIndex: replay?.index ?? 0,
                replayTotal: replay?.total ?? 0,
                replayPrompts: replay?.promptCount ?? 0,
                replayReplies: replay?.replyCount ?? 0,
                activeSessionId: thread?.sessionId ?? pendingActiveId,
                currentProvider: harness
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: SoulMetric.sidebarWidth, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CanvasToolbar(
                        harness: harness,
                        onPickHarness: { picked in
                            if thread != nil { newChat() }
                            harness = picked
                        },
                        onSmokeTest: { showSmoke = true },
                        onNewChat: newChat,
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
                        } else if let thread {
                            ThreadView(
                                controller: thread,
                                prompt: $prompt,
                                onCancel: cancelTurn
                            )
                                // Force a fresh view identity per thread so
                                // SwiftUI tears down the ScrollView on switch
                                // and our `.onAppear` restore actually fires.
                                // Without this, SwiftUI reuses the same view
                                // structure across thread swaps and the
                                // ScrollView retains the previous thread's
                                // internal NSScrollView offset.
                                .id(thread.id)
                        } else {
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
                        }
                    }
                    if showTerminal {
                        terminalSection
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                if showReview {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(SoulColor.border.opacity(0.5))
                            .frame(width: 1)
                        ReviewPanel(
                            projectPath: currentProject()?.path,
                            onClose: { withAnimation(.easeInOut(duration: 0.22)) { showReview = false } }
                        )
                        .frame(minWidth: 380, idealWidth: 460, maxWidth: 720)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .toolbar(.hidden)
            .sheet(isPresented: $showSmoke) { ACPSmokeView() }
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
        .onAppear { splitVisibility = showSidebar ? .all : .detailOnly }
        .navigationSplitViewStyle(.balanced)
        .background(SoulColor.bg)
        .preferredColorScheme(.light)
        .onChange(of: selectedProject) { _, _ in
            // Project switch is purely a sidebar filter now — active threads
            // belong to their own project (carried on the ThreadController),
            // so clicking around in the sidebar doesn't tear them down.
            devServerRunning = false
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
                if let usage = contextUsage {
                    ContextUsageChip(usage: usage)
                        .padding(.leading, 6)
                }
                if let thread {
                    SessionStatsChip(controller: thread)
                        .padding(.leading, 6)
                    AgentLogChip(controller: thread)
                        .padding(.leading, 6)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                HarnessPicker(selection: harness, onSelect: onPickHarness)
                    .disabled(replayActive)
                Button(action: onSmokeTest) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(replayActive)
                ToolbarIcon(name: "chevron.down.square")
                    .disabled(replayActive)
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
        .help("Agent stderr log (\(controller.agentLog.count) lines)")
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
                Text("·")
                    .foregroundStyle(SoulColor.fgSubtle)
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(chapterCount)")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                Text("·")
                    .foregroundStyle(SoulColor.fgSubtle)
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(elapsedLabel(now: ctx.date))
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.surface, in: Capsule())
            .help("\(toolCount) tool calls · \(chapterCount) prompts · running \(elapsedLabel(now: ctx.date))")
        }
    }
}

#Preview {
    AppShell()
        .frame(width: 1200, height: 820)
}
