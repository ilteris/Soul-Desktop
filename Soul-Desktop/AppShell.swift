import SwiftUI
import AppKit

struct AppShell: View {
    @State private var selectedProject: String? = nil
    @State private var thread: ThreadController? = nil
    @State private var replay: ReplayController? = nil
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

    private var replayFraction: Double {
        guard let replay, replay.total > 0 else { return 0 }
        return Double(replay.index) / Double(replay.total)
    }

    private var contextUsage: ContextUsage? {
        if let replay {
            return ContextUsage.compute(forSession: replay.sessionId, cwd: replay.project.path)
        }
        if let thread, let sid = thread.sessionId, thread.provider == .claude {
            return ContextUsage.compute(forSession: sid, cwd: thread.project.path)
        }
        return nil
    }

    private func currentProject() -> SoulProject? {
        guard let key = selectedProject else { return nil }
        return SoulRegistry.projects().first { $0.id == key }
    }

    private func startThread(with text: String) {
        guard let project = currentProject() else { return }
        let controller = ThreadController(provider: harness, project: project)
        thread = controller
        Task { await controller.send(text) }
    }

    private func loadSession(_ session: SoulSession) {
        guard let project = currentProject() else { return }
        let provider: Provider = {
            switch session.source {
            case "claude":    return .claude
            case "gemini":    return .geminiCLI
            case "pi-native": return .pi
            default:          return harness
            }
        }()
        Task {
            await thread?.teardown()
            thread = nil
            harness = provider
            let controller = ThreadController(provider: provider, project: project)
            thread = controller
            await controller.loadSession(id: session.id)
        }
    }

    private func newChat() {
        Task {
            await thread?.teardown()
            thread = nil
            replay?.stop()
            replay = nil
            prompt = ""
        }
    }

    private func startReplay(_ session: SoulSession) {
        guard let project = currentProject() else { return }
        Task {
            await thread?.teardown()
            thread = nil
            replay?.stop()
            replay = ReplayController(sessionId: session.id, project: project)
        }
    }

    private func exitReplay() {
        replay?.stop()
        replay = nil
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
                replayReplies: replay?.replyCount ?? 0
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
                        contextUsage: contextUsage
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
                        } else {
                            HeroEmptyState(
                                projectName: currentProject()?.name ?? "your project",
                                projectPath: currentProject()?.path,
                                currentProjectID: selectedProject ?? "",
                                prompt: $prompt,
                                onSend: { text in startThread(with: text) },
                                onSelectProject: { selectedProject = $0 },
                                onNewProject: openNewProjectWizard,
                                devCommand: currentProject()?.devCommand,
                                devURL: currentProject()?.devURL,
                                devRunning: devServerRunning,
                                onRunLocal: runLocal
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
            newChat()
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
    var contextUsage: ContextUsage? = nil

    var body: some View {
        HStack(spacing: 0) {
            ToolbarIcon(name: "sidebar.left", isActive: sidebarActive, action: onToggleSidebar)
                .padding(.trailing, 6)
            if threadActive {
                Button(action: onNewChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                        Text("New chat")
                            .font(SoulFont.ui(12, weight: .medium))
                    }
                    .foregroundStyle(SoulColor.fgMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SoulColor.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                if let usage = contextUsage {
                    ContextUsageChip(usage: usage)
                        .padding(.leading, 6)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                HarnessPicker(selection: harness, onSelect: onPickHarness)
                Button(action: onSmokeTest) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                ToolbarIcon(name: "chevron.down.square")
                ToolbarIcon(name: "terminal", isActive: terminalActive, action: onToggleTerminal)
                ToolbarIcon(name: "sidebar.right", isActive: reviewActive, action: onToggleReview)
            }
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
                    .font(SoulFont.ui(12, weight: .medium))
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
                .font(SoulFont.code(11, weight: .medium))
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
        .help("Last-turn prompt size, sampled from the Claude transcript.")
    }
}

#Preview {
    AppShell()
        .frame(width: 1200, height: 820)
}
