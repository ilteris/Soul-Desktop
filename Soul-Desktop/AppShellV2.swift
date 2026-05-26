import SwiftUI
import Combine
import AppKit

struct AppShellV2: View {
    var registryStore: SoulRegistryStore = LiveSoulRegistryStore.shared

    private static let controlCanvas = Color(hex: 0xF7F6F2)
    private static let operationStallThreshold: TimeInterval = 60
    private let operationClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var selectedProject: String? = nil
    @State private var projects: [SoulProject] = LiveSoulRegistryStore.shared.activeProjects()
    @State private var recentSessions: [SoulSession] = []
    @State private var projectCounts: [String: Int] = [:]
    @State private var selectedProvider: Provider = .geminiCLI
    @StateObject private var activeTask = ActiveTaskStore()
    @StateObject private var taskQueue = SoulTaskQueueStore()
    @StateObject private var specialistStore = SoulSpecialistStore()
    @StateObject private var pulseModel = SoulControlPanelModel()
    @State private var showAllTasks: Bool = false
    @State private var showDispatchBox: Bool = false
    @State private var inspectedOperationID: UUID? = nil
    @State private var operationNow: Date = Date()
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @AppStorage("soul.v2.sidebar.visible") private var showSidebar: Bool = true
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    private var project: SoulProject? {
        guard let selectedProject else { return projects.first }
        return projects.first { $0.id == selectedProject } ?? projects.first
    }

    private var inspectedOperation: SoulOperation? {
        guard let inspectedOperationID else { return nil }
        return pulseModel.operations.first { $0.id == inspectedOperationID }
    }

    private var operationDetailIsPresented: Binding<Bool> {
        Binding(
            get: { inspectedOperationID != nil },
            set: { isPresented in
                if !isPresented { inspectedOperationID = nil }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            controlSidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 480)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                mainSurface

                VStack(alignment: .trailing, spacing: 12) {
                    if showDispatchBox {
                        dispatchBox
                            .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                            showDispatchBox.toggle()
                        }
                    } label: {
                        HStack(spacing: showDispatchBox ? 0 : 9) {
                            Image(systemName: showDispatchBox ? "xmark" : "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                            if !showDispatchBox {
                                Text("Ask")
                                    .font(SoulFont.ui(13, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: showDispatchBox ? 44 : nil, height: 44)
                        .padding(.horizontal, showDispatchBox ? 0 : 15)
                        .background(SoulColor.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
                    }
                    .buttonStyle(.plain)
                    .help(showDispatchBox ? "Close assistant" : "Open control panel assistant")
                }
                .padding(24)
            }
            .background(Self.controlCanvas.ignoresSafeArea())
        }
        .toolbar(removing: .title)
        .background(Self.controlCanvas.ignoresSafeArea())
        .sheet(isPresented: operationDetailIsPresented) {
            if let operation = inspectedOperation {
                operationDetailSheet(operation)
            }
        }
        .onAppear {
            columnVisibility = showSidebar ? .doubleColumn : .detailOnly
            refreshProjects()
            refreshProjectState()
        }
        .onChange(of: columnVisibility) { _, newValue in
            showSidebar = (newValue != .detailOnly)
        }
        .onChange(of: selectedProject) { _, _ in
            refreshProjectState()
        }
        .onReceive(operationClock) { operationNow = $0 }
    }

    private var controlSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                Text("Control Panel")
                    .font(SoulFont.ui(15, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Hide sidebar")
            }
            .padding(.horizontal, 16)
            .padding(.top, 48)
            .padding(.bottom, 14)

            Text("Projects")
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(projects) { p in
                        Button {
                            selectedProject = p.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedProject == p.id ? "folder.fill" : "folder")
                                    .font(.system(size: 12))
                                    .foregroundStyle(selectedProject == p.id ? SoulColor.accent : SoulColor.fgMuted)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                        .font(SoulFont.ui(13, weight: .medium))
                                        .foregroundStyle(SoulColor.fg)
                                        .lineLimit(1)
                                    Text(p.id)
                                        .font(SoulFont.code(10))
                                        .foregroundStyle(SoulColor.fgSubtle)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("\(projectCounts[p.id] ?? 0)")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(SoulColor.fgSubtle)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedProject == p.id ? SoulColor.accent.opacity(0.13) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().background(SoulColor.border.opacity(0.35))
            Button {
                UserDefaults.standard.set("classic", forKey: "soul.appVersion")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Classic Chat")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(SoulFont.ui(13))
                .foregroundStyle(SoulColor.fgMuted)
                .padding(16)
            }
            .buttonStyle(.soulHover)
            .help("Return to the original Soul Desktop interface")
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    readinessBar
                    commandBar
                    projectTimelineCard
                    taskWorkSurface
                    LazyVGrid(columns: [
                        GridItem(.flexible(minimum: 320), spacing: 18),
                        GridItem(.flexible(minimum: 320), spacing: 18)
                    ], alignment: .leading, spacing: 18) {
                        activeTaskCard
                        recentWorkCard
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var dispatchBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                Text("Control Panel Assistant")
                    .font(SoulFont.ui(14, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Text(project?.id ?? "no-project")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    assistantBubble("Ask about this project, the active work, recent runs, or what to do next.", isUser: false)
                    ForEach(pulseModel.assistantMessages) { message in
                        assistantBubble(message.text, isUser: message.isUser)
                    }
                }
            }
            .frame(height: 220)
            .padding(10)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusM))
            .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusM).strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 0.5))

            HStack(spacing: 8) {
                TextField("Ask what needs attention", text: $pulseModel.assistantInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(SoulFont.ui(13))
                    .lineLimit(1...4)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusM))
                    .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusM).strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 0.5))

                Button {
                    askControlPanelAssistant()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(SoulColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(pulseModel.assistantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(pulseModel.assistantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(14)
        .frame(width: 430)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusL))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusL).strokeBorder(SoulColor.border.opacity(0.55), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 10)
    }

    private func assistantBubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            Text(text)
                .font(SoulFont.ui(12))
                .foregroundStyle(isUser ? .white : SoulColor.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(isUser ? SoulColor.accent : SoulColor.bgElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 42) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if !showSidebar {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .doubleColumn }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Show sidebar")
            }

            VStack(alignment: .leading, spacing: 2) {
                projectHeaderMenu
                Text(project?.path ?? "Select a project to operate on")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            providerHeaderMenu

            Button {
                refreshProjects()
                refreshProjectState()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.soulHover)
            .help("Refresh registry state")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Self.controlCanvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.35)).frame(height: 0.5)
        }
    }

    private var projectHeaderMenu: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    selectedProject = p.id
                } label: {
                    HStack {
                        Text(p.name)
                        Text(p.id)
                        if project?.id == p.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(project?.name ?? "No Project")
                    .font(SoulFont.ui(17, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Switch operating project")
    }

    private var providerHeaderMenu: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Provider")
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
            Menu {
                ForEach(Provider.allCases) { provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        HStack {
                            CompactProviderGlyph(provider: provider)
                            Text(provider.label)
                            if provider == selectedProvider {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    CompactProviderGlyph(provider: selectedProvider)
                    Text(selectedProvider.label)
                        .font(SoulFont.ui(13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .foregroundStyle(SoulColor.fgMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SoulColor.surface.opacity(0.6), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Choose provider backend")
        }
    }

    private var readinessBar: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
            Button {
                runVerify()
            } label: {
                statusPill(icon: "checkmark.shield", title: "Health", value: pulseModel.lastVerifySummary)
            }
            .buttonStyle(.plain)
            .help("Run project verification")

            Button {
                openActiveTaskRecord()
            } label: {
                statusPill(icon: "bolt.horizontal", title: "Running", value: "\(pulseModel.runningOperationCount)")
            }
            .buttonStyle(.plain)
            .help("Open current or recommended task record")
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            actionButton("Pulse", icon: "waveform.path.ecg") { runPulse() }
            actionButton("Verify", icon: "checkmark.shield") { runVerify() }
            actionButton("Finalize", icon: "seal") { runFinalCommand("finalize") }
            actionButton("Compact", icon: "rectangle.compress.vertical") { runFinalCommand("compact") }
            actionButton("Doctor", icon: "stethoscope") { runAppServerDoctor() }
            Spacer(minLength: 0)
            actionButton("Refresh", icon: "arrow.clockwise") {
                refreshProjects()
                refreshProjectState()
            }
        }
        .padding(10)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }

    private var projectTimelineCard: some View {
        controlCard(title: "Project Story", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            VStack(alignment: .leading, spacing: 12) {
                Text(projectStoryLead)
                    .font(SoulFont.ui(13, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    storyBlock(
                        title: "Now",
                        icon: "scope",
                        value: currentFocusTitle,
                        detail: currentFocusDetail,
                        action: openActiveTaskRecord
                    )
                    storyBlock(
                        title: "In Motion",
                        icon: "dot.radiowaves.left.and.right",
                        value: liveWorkTitle,
                        detail: liveWorkDetail,
                        action: inspectLatestOperation
                    )
                    storyBlock(
                        title: "Pressure",
                        icon: "exclamationmark.triangle",
                        value: pressureTitle,
                        detail: pressureDetail,
                        action: openPressureTask
                    )
                }

                let entries = projectTimelineEntries
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Recent signals")
                            .font(SoulFont.ui(10, weight: .medium))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .textCase(.uppercase)
                        ForEach(entries.prefix(4)) { entry in
                            timelineRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var projectStoryLead: String {
        let open = taskQueue.openTasks.count
        let high = taskQueue.highPriorityCount
        let running = taskQueue.inProgressCount
        if let recommended = taskQueue.recommendedTask {
            return "\(project?.name ?? "This project") is currently centered on \(recommended.id): \(recommended.subject). The queue has \(open) open task\(open == 1 ? "" : "s"), \(high) high-priority item\(high == 1 ? "" : "s"), and \(running) marked in progress."
        }
        return "\(project?.name ?? "This project") has \(open) open task\(open == 1 ? "" : "s") and \(recentSessions.count) recent session\(recentSessions.count == 1 ? "" : "s") loaded."
    }

    private var currentFocusTitle: String {
        if let activeTaskId = activeTask.taskId { return activeTaskId }
        return taskQueue.recommendedTask?.id ?? "No task selected"
    }

    private var currentFocusDetail: String {
        if let subject = activeTask.subject { return subject }
        return taskQueue.recommendedTask?.subject ?? "Choose a task before launching an agent."
    }

    private var liveWorkTitle: String {
        let running = pulseModel.runningOperationCount
        let live = recentSessions.filter(\.isLive).count
        if running > 0 { return "\(running) operation\(running == 1 ? "" : "s") running" }
        if live > 0 { return "\(live) live session\(live == 1 ? "" : "s")" }
        return "No active run"
    }

    private var liveWorkDetail: String {
        if let op = pulseModel.operations.first(where: { $0.status == .running }) {
            return "\(op.title): \(op.summary)"
        }
        let live = recentSessions.filter(\.isLive)
        if !live.isEmpty {
            let eventCount = live.reduce(0) { $0 + $1.eventCount }
            return "\(eventCount) live events across current project sessions."
        }
        return "Launch an agent or run pulse to create a fresh operating signal."
    }

    private var pressureTitle: String {
        if taskQueue.highPriorityCount > 0 { return "\(taskQueue.highPriorityCount) high priority" }
        if taskQueue.openTasks.isEmpty { return "Clear" }
        return "\(taskQueue.openTasks.count) open"
    }

    private var pressureDetail: String {
        if let firstHigh = taskQueue.openTasks.first(where: { $0.priority == "high" }) {
            return firstHigh.subject
        }
        if taskQueue.openTasks.isEmpty {
            return "No open task pressure detected in the registry."
        }
        return taskQueue.openTasks.first?.subject ?? "Backlog loaded."
    }

    private func storyBlock(title: String, icon: String, value: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .textCase(.uppercase)
                    Text(value)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                    Text(detail)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open details")
    }

    private var projectTimelineEntries: [SoulTimelineEntry] {
        var entries: [SoulTimelineEntry] = []

        for operation in pulseModel.operations {
            entries.append(SoulTimelineEntry(
                kind: .operation,
                icon: operation.kind.icon,
                tint: operation.status.tint,
                title: operation.title,
                detail: operation.summary,
                timestamp: operation.startedAt,
                badge: operation.status.label,
                operationID: operation.id
            ))
        }

        if let activeId = activeTask.taskId {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: "scope",
                tint: SoulColor.accent,
                title: activeTask.subject ?? "Active task",
                detail: activeId,
                timestamp: Date(),
                badge: activeTask.status ?? "active",
                taskID: activeId
            ))
        } else if let recommended = taskQueue.recommendedTask {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: "sparkles",
                tint: SoulColor.accent,
                title: recommended.subject,
                detail: recommended.id,
                timestamp: taskTimestamp(recommended) ?? Date(),
                badge: recommended.status,
                taskID: recommended.id
            ))
        }

        for task in taskQueue.openTasks.prefix(4) where task.id != activeTask.taskId && task.id != taskQueue.recommendedTask?.id {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: task.status == "in_progress" ? "play.fill" : "circle",
                tint: task.status == "in_progress" ? SoulColor.accent : SoulColor.fgMuted,
                title: task.subject,
                detail: task.id,
                timestamp: taskTimestamp(task),
                badge: task.priority,
                taskID: task.id
            ))
        }

        let liveSessions = recentSessions.filter(\.isLive)
        if !liveSessions.isEmpty {
            let providers = liveSessions
                .map { $0.source ?? $0.liveProvider ?? "unknown" }
                .reduce(into: [String: Int]()) { counts, provider in counts[provider, default: 0] += 1 }
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " · ")
            let latest = liveSessions.compactMap { $0.lastActivityAt ?? $0.timestamp }.max()
            let eventCount = liveSessions.reduce(0) { $0 + $1.eventCount }
            entries.append(SoulTimelineEntry(
                kind: .session,
                icon: "dot.radiowaves.left.and.right",
                tint: SoulColor.accent,
                title: "\(liveSessions.count) live session\(liveSessions.count == 1 ? "" : "s")",
                detail: "\(providers) · \(eventCount) events",
                timestamp: latest,
                badge: "live"
            ))
        }

        for session in recentSessions.filter({ !$0.isLive }).prefix(3) {
            entries.append(SoulTimelineEntry(
                kind: .session,
                icon: "bubble.left.and.bubble.right",
                tint: SoulColor.fgMuted,
                title: session.title ?? session.intent ?? session.summary ?? "Untitled session",
                detail: "\(session.source ?? session.liveProvider ?? "unknown") · \(session.eventCount) events",
                timestamp: session.lastActivityAt ?? session.timestamp,
                badge: "session"
            ))
        }

        return entries.sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
    }

    private func timelineRow(_ entry: SoulTimelineEntry) -> some View {
        Button {
            openTimelineEntry(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.tint)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(SoulFont.ui(12, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                        timelineBadge(entry.badge)
                        Spacer(minLength: 8)
                        Text(entry.timestamp.map { timelineTime($0) } ?? "unknown")
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    Text(entry.detail)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open signal")
    }

    private func timelineBadge(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.code(10))
            .foregroundStyle(SoulColor.fgSubtle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(SoulColor.fg.opacity(0.06), in: Capsule())
    }

    private func timelineTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func taskTimestamp(_ task: SoulTaskRecord) -> Date? {
        guard let updatedAt = task.updatedAt else { return nil }
        return Self.timelineTimestampFormatter.date(from: updatedAt)
            ?? Self.timelineTimestampFormatterWithFractionalSeconds.date(from: updatedAt)
    }

    private static let timelineTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let timelineTimestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func statusPill(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SoulColor.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SoulFont.ui(10, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(SoulFont.ui(13, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }

    private var activeTaskCard: some View {
        controlCard(title: "Active Work", icon: "scope") {
            VStack(alignment: .leading, spacing: 12) {
                if let taskId = activeTask.taskId {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activeTask.subject ?? "Untitled task")
                                .font(SoulFont.ui(15, weight: .semibold))
                                .foregroundStyle(SoulColor.fg)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(taskId)
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer()
                        if let status = activeTask.status {
                            Text(status)
                                .font(SoulFont.code(10))
                                .foregroundStyle(SoulColor.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(SoulColor.accent.opacity(0.1), in: Capsule())
                        }
                    }

                    if activeTask.criteria.isEmpty {
                        emptyLine("No done criteria recorded.")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(activeTask.criteria, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(item.done ? SoulColor.accent : SoulColor.fgMuted)
                                        .padding(.top, 1)
                                    Text(item.text)
                                        .font(SoulFont.ui(12))
                                        .foregroundStyle(item.done ? SoulColor.fgSubtle : SoulColor.fg)
                                        .strikethrough(item.done)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    emptyLine("No active task selected for this project.")
                }

                HStack(spacing: 8) {
                    actionButton("Pulse", icon: "waveform.path.ecg") { runPulse() }
                    actionButton("Finalize", icon: "seal") { runFinalCommand("finalize") }
                    actionButton("Compact", icon: "rectangle.compress.vertical") { runFinalCommand("compact") }
                }
            }
        }
    }

    private var taskWorkSurface: some View {
        let recommended = taskQueue.recommendedTask
        let visibleTasks = showAllTasks ? taskQueue.openTasks : Array(taskQueue.openTasks.prefix(6))

        return controlCard(title: "Next Task", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                if taskQueue.openTasks.isEmpty {
                    emptyLine(taskQueue.isLoading ? "Loading tasks..." : "No open tasks in this project.")
                } else {
                    if let recommended {
                        recommendedTaskPanel(recommended)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Backlog")
                                .font(SoulFont.ui(11, weight: .medium))
                                .foregroundStyle(SoulColor.fgSubtle)
                                .textCase(.uppercase)
                            Text("\(taskQueue.openTasks.count) open · \(taskQueue.highPriorityCount) high · \(taskQueue.inProgressCount) running")
                                .font(SoulFont.ui(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                            Spacer()
                            if taskQueue.openTasks.count > 6 {
                                Button(showAllTasks ? "Show less" : "Show all \(taskQueue.openTasks.count)") {
                                    showAllTasks.toggle()
                                }
                                .font(SoulFont.ui(11, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(SoulColor.accent)
                            }
                        }

                        ForEach(visibleTasks) { task in
                            taskQueueRow(task, isRecommended: task.id == recommended?.id)
                        }
                    }
                }
            }
        }
    }

    private func recommendedTaskPanel(_ task: SoulTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        taskStatusChip(task.priority)
                        taskStatusChip(task.status)
                        Text(task.id)
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    Text(task.subject)
                        .font(SoulFont.ui(19, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(task.operatorSummary)
                        .font(SoulFont.ui(12))
                        .foregroundStyle(SoulColor.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                specialistMenu

                Menu {
                    ForEach(Provider.allCases) { provider in
                        Button(provider.label) { selectedProvider = provider }
                    }
                } label: {
                    HStack(spacing: 6) {
                        CompactProviderGlyph(provider: selectedProvider)
                        Text(selectedProvider.label)
                            .font(SoulFont.ui(11, weight: .medium))
                    }
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(SoulColor.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                Toggle("Stream", isOn: $pulseModel.delegateStream)
                    .toggleStyle(.switch)
                    .font(SoulFont.ui(11))

                Spacer(minLength: 0)
                actionButton("Focus", icon: "scope") { selectTask(task) }
                actionButton("Start", icon: "play.fill") { startTask(task) }
                Button {
                    launchTask(task)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Launch Agent")
                            .font(SoulFont.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(SoulColor.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            if let launch = pulseModel.latestLaunchOperation(for: task.id) {
                Divider()
                    .overlay(SoulColor.border.opacity(0.35))
                HStack(alignment: .top, spacing: 8) {
                    statusBadge(launch.status)
                    Text(launch.summary)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(SoulColor.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.accent.opacity(0.24), lineWidth: 0.75))
    }

    private var specialistMenu: some View {
        Menu {
            ForEach(specialistStore.specialists, id: \.self) { specialist in
                Button {
                    pulseModel.delegateSpecialist = specialist
                } label: {
                    HStack {
                        Text(specialist)
                        if specialist == pulseModel.delegateSpecialist {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .medium))
                Text(pulseModel.delegateSpecialist)
                    .font(SoulFont.code(12))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Choose specialist")
    }

    private var providerMenu: some View {
        Menu {
            ForEach(Provider.allCases) { provider in
                Button {
                    selectedProvider = provider
                } label: {
                    HStack {
                        Text(provider.label)
                        if provider == selectedProvider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                CompactProviderGlyph(provider: selectedProvider)
                Text(selectedProvider.label)
                    .font(SoulFont.ui(12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Choose provider")
    }

    private func taskQueueRow(_ task: SoulTaskRecord, isRecommended: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.id == taskQueue.activeTaskId ? "scope" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(task.id == taskQueue.activeTaskId ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 20)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(task.id)
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    taskStatusChip(task.status)
                    taskStatusChip(task.priority)
                }
                Text(task.subject)
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(task.operatorSummary)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    selectTask(task)
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Set active task")

                Button {
                    startTask(task)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Mark in progress")

                Button {
                    launchTask(task)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("Launch")
                            .font(SoulFont.ui(11, weight: .medium))
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.soulHover)
                .help("Launch selected agent on this task")
            }
        }
        .padding(12)
        .background(task.id == taskQueue.activeTaskId ? SoulColor.accent.opacity(0.1) : SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.28), lineWidth: 0.5))
    }

    private func queueMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
            Text(value)
                .font(SoulFont.ui(12, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SoulColor.bgElevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskStatusChip(_ text: String) -> some View {
        Text(text.isEmpty ? "unknown" : text)
            .font(SoulFont.code(10))
            .foregroundStyle(SoulColor.fgSubtle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SoulColor.fg.opacity(0.06), in: Capsule())
    }

    private var operationsCard: some View {
        controlCard(title: "Operations", icon: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                operationButton(title: "Run pulse", detail: "Refresh situational awareness from the registry.", icon: "waveform.path.ecg") {
                    runPulse()
                }
                operationButton(title: "Verify project", detail: "Run Soul integrity checks for the selected project.", icon: "checkmark.shield") {
                    runVerify()
                }
                operationButton(title: "Finalize session", detail: "Commit current work into persistent memory.", icon: "seal") {
                    runFinalCommand("finalize")
                }
                operationButton(title: "App-server doctor", detail: "Inspect daemon, socket, provider, and mobile transport health.", icon: "stethoscope") {
                    runAppServerDoctor()
                }
            }
        }
    }

    private var delegationCard: some View {
        controlCard(title: "Delegate", icon: "person.2.wave.2") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("specialist, e.g. systems_architect", text: $pulseModel.delegateSpecialist)
                    .textFieldStyle(.plain)
                    .font(SoulFont.code(12))
                    .padding(10)
                    .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))

                TextField("Task to assign", text: $pulseModel.delegateTask, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(SoulFont.ui(13))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))

                HStack(spacing: 8) {
                    Toggle("Stream", isOn: $pulseModel.delegateStream)
                        .toggleStyle(.switch)
                        .font(SoulFont.ui(12))
                    Spacer()
                    actionButton("Dry Run", icon: "doc.text.magnifyingglass") {
                        runDelegate(dryRun: true)
                    }
                    actionButton("Launch", icon: "paperplane.fill") {
                        runDelegate(dryRun: false)
                    }
                }
            }
        }
    }

    private var recentWorkCard: some View {
        controlCard(title: "Recent Work", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                if recentSessions.isEmpty {
                    emptyLine("No recent sessions found.")
                } else {
                    ForEach(recentSessions.prefix(8)) { session in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: session.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(session.isLive ? SoulColor.accent : SoulColor.fgMuted)
                                .frame(width: 18)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title ?? session.intent ?? session.summary ?? "Untitled session")
                                    .font(SoulFont.ui(12, weight: .medium))
                                    .foregroundStyle(SoulColor.fg)
                                    .lineLimit(2)
                                Text("\(session.source ?? session.liveProvider ?? "unknown") · \(session.eventCount) events")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(SoulColor.fgSubtle)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var operationsFeedCard: some View {
        controlCard(title: "Operation Feed", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                if pulseModel.operations.isEmpty {
                    emptyLine("Run pulse, verify, delegate, or app-server doctor to start an operation.")
                } else {
                    ForEach(pulseModel.operations) { operation in
                        operationRow(operation)
                    }
                }
            }
        }
    }

    private var floatingActivityStrip: some View {
        let running = pulseModel.operations.filter { $0.status == .running }

        return Group {
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(running.prefix(3))) { operation in
                        floatingActivityRow(operation)
                    }
                    if running.count > 3 {
                        Button {
                            inspectedOperationID = running.first?.id
                        } label: {
                            Text("+\(running.count - 3) more running")
                                .font(SoulFont.ui(10, weight: .medium))
                                .foregroundStyle(SoulColor.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(width: 350, alignment: .leading)
                .background(SoulColor.bgElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
            }
        }
    }

    private func floatingActivityRow(_ operation: SoulOperation) -> some View {
        Button {
            inspectedOperationID = operation.id
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(operation.status.tint.opacity(0.13))
                    Image(systemName: operationIsStalled(operation) ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(operationIsStalled(operation) ? .red : operation.status.tint)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(floatingActivityLabel(operation))
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(operationIsStalled(operation) ? .red : SoulColor.fgSubtle)
                        .textCase(.uppercase)
                    Text(operation.title)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                    Text(operation.summary)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }

                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 24, height: 24)
            }
            .padding(8)
            .background(SoulColor.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Inspect agent activity")
    }

    private func operationDetailSheet(_ operation: SoulOperation) -> some View {
        let events = SoulOperationEvent.parse(operation.logs)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: operation.kind.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(operation.status.tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(operation.title)
                            .font(SoulFont.ui(16, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                        statusBadge(operation.status)
                        if operationIsStalled(operation) {
                            timelineBadge("idle \(idleDurationText(operation))")
                                .foregroundStyle(.red)
                        }
                    }
                    Text(operation.provider?.label ?? operation.project ?? "Soul")
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                Spacer()
                Button {
                    inspectedOperationID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.soulHover)
            }

            if operation.status == .running {
                HStack {
                    Spacer()
                    Button {
                        pulseModel.cancelOperation(operation.id)
                    } label: {
                        Label("Stop Agent", systemImage: "stop.fill")
                    }
                    .font(SoulFont.ui(12, weight: .semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }

            Text(operation.summary)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            operationEventStream(events, operation: operation)

            HStack {
                Text(operation.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Button {
                    openOperationLog(operation)
                } label: {
                    Label("Open Log File", systemImage: "doc.text")
                }
                .font(SoulFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
            }
        }
        .padding(18)
        .frame(width: 720, height: 520)
        .background(SoulColor.bgElevated)
    }

    private func operationEventStream(_ events: [SoulOperationEvent], operation: SoulOperation) -> some View {
        let isRunning = operation.status == .running
        let isStalled = operationIsStalled(operation)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if events.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for stream events...")
                                .font(SoulFont.ui(12))
                                .foregroundStyle(SoulColor.fgMuted)
                        }
                        .padding(12)
                    } else {
                        ForEach(events) { event in
                            operationEventRow(event)
                                .id(event.id)
                        }
                        if isRunning {
                            HStack(spacing: 8) {
                                if isStalled {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.red)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isStalled ? "stream idle for \(idleDurationText(operation))" : "stream open")
                                    .font(SoulFont.code(10))
                                    .foregroundStyle(isStalled ? .red : SoulColor.fgSubtle)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .id("stream-open")
                        }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 320)
            .background(Self.controlCanvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
            .onAppear {
                scrollOperationStream(proxy: proxy, events: events, isRunning: isRunning)
            }
            .onChange(of: events.count) { _, _ in
                scrollOperationStream(proxy: proxy, events: events, isRunning: isRunning)
            }
        }
    }

    private func operationEventRow(_ event: SoulOperationEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(event.tint)
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(event.title)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                    if let badge = event.badge {
                        timelineBadge(badge)
                    }
                    Spacer(minLength: 0)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated.opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.25), lineWidth: 0.5))
    }

    private func scrollOperationStream(proxy: ScrollViewProxy, events: [SoulOperationEvent], isRunning: Bool) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                if isRunning {
                    proxy.scrollTo("stream-open", anchor: .bottom)
                } else if let last = events.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func operationIsStalled(_ operation: SoulOperation) -> Bool {
        operation.status == .running && operationNow.timeIntervalSince(operation.lastUpdatedAt) > Self.operationStallThreshold
    }

    private func floatingActivityLabel(_ operation: SoulOperation) -> String {
        if operationIsStalled(operation) { return "Stalled" }
        return operation.status == .running ? "Working" : "Latest"
    }

    private func idleDurationText(_ operation: SoulOperation) -> String {
        durationText(operationNow.timeIntervalSince(operation.lastUpdatedAt))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func operationRow(_ operation: SoulOperation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(operation.status.tint.opacity(0.12))
                    Image(systemName: operation.kind.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(operation.status.tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(operation.title)
                            .font(SoulFont.ui(13, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                        statusBadge(operation.status)
                    }
                    HStack(spacing: 8) {
                        if let project = operation.project {
                            metadataChip(project, icon: "folder")
                        }
                        if let provider = operation.provider {
                            providerMetadataChip(provider)
                        }
                        metadataChip(operation.startedAt.formatted(date: .omitted, time: .shortened), icon: "clock")
                    }
                }
                Spacer(minLength: 0)
            }

            Text(operation.summary)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !operation.logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup {
                    ScrollView {
                        Text(operation.logs)
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fg.opacity(0.82))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 96, maxHeight: 260)
                    .background(SoulColor.bgElevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
                } label: {
                    Text("Logs")
                        .font(SoulFont.ui(11, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .tint(SoulColor.fgSubtle)
            }
        }
        .padding(12)
        .background(SoulColor.bgElevated.opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.28), lineWidth: 0.5))
    }

    private func statusBadge(_ status: SoulOperation.Status) -> some View {
        HStack(spacing: 5) {
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.label)
                .font(SoulFont.code(10))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.1), in: Capsule())
    }

    private func metadataChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .lineLimit(1)
        }
        .font(SoulFont.code(10))
        .foregroundStyle(SoulColor.fgSubtle)
    }

    private func providerMetadataChip(_ provider: Provider) -> some View {
        HStack(spacing: 4) {
            ProviderGlyph(provider: provider, size: 9, weight: .medium)
            Text(provider.label)
                .lineLimit(1)
        }
        .font(SoulFont.code(10))
        .foregroundStyle(SoulColor.fgSubtle)
    }

    private func controlCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                Text(title)
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }

    private func operationButton(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SoulFont.ui(13, weight: .medium))
                        .foregroundStyle(SoulColor.fg)
                    Text(detail)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(SoulColor.bgElevated.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(SoulFont.ui(11, weight: .medium))
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(12))
            .foregroundStyle(SoulColor.fgSubtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func refreshProjects() {
        LiveSoulRegistryStore.shared.refresh()
        projects = registryStore.activeProjects()
        if selectedProject == nil || !projects.contains(where: { $0.id == selectedProject }) {
            selectedProject = projects.first?.id
        }
        refreshProjectCounts()
    }

    private func refreshProjectState() {
        guard let project else { return }
        activeTask.bind(projectKey: project.id)
        taskQueue.bind(projectKey: project.id)
        specialistStore.bind(projectKey: project.id, selected: pulseModel.delegateSpecialist) { specialist in
            pulseModel.delegateSpecialist = specialist
        }
        if let cached = registryStore.cachedSessions(forProject: project.id) {
            recentSessions = Array(cached.prefix(12))
        } else {
            recentSessions = []
        }
        let projectId = project.id
        let projectPath = project.path
        Task {
            let sessions = await Task.detached(priority: .userInitiated) {
                SoulRegistry.allSessions(forProject: projectId, limit: 12, projectPath: projectPath)
            }.value
            guard self.project?.id == projectId else { return }
            recentSessions = sessions
        }
    }

    private func refreshProjectCounts() {
        let ids = projects.map(\.id)
        Task {
            let counts = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, SoulRegistry.sessionCount(forProject: id))
                })
            }.value
            projectCounts = counts
        }
    }

    private func runPulse() {
        guard let project else { return }
        pulseModel.run(kind: .pulse, title: "Pulse", args: ["pulse", "--output", "text", project.path], project: project.id)
    }

    private func runVerify() {
        guard let project else { return }
        pulseModel.run(kind: .verify, title: "Verify Project", args: ["verify", "--project", project.id], project: project.id) {
            refreshProjectState()
        }
    }

    private func runFinalCommand(_ command: String) {
        guard let project else { return }
        let kind: SoulOperation.Kind = command == "compact" ? .compact : .finalize
        pulseModel.run(kind: kind, title: command.capitalized, args: [command, "--project", project.id], project: project.id) {
            refreshProjectState()
        }
    }

    private func runAppServerDoctor() {
        pulseModel.run(kind: .appServerDoctor, title: "App-server Doctor", args: ["app-server", "doctor"], project: project?.id)
    }

    private func runDelegate(dryRun: Bool) {
        guard let project else { return }
        pulseModel.runDelegate(project: project.id, provider: selectedProvider, dryRun: dryRun)
    }

    private func askControlPanelAssistant() {
        guard let project else { return }
        pulseModel.answerControlPanelQuestion(
            project: project,
            activeTaskId: activeTask.taskId,
            recommendedTask: taskQueue.recommendedTask,
            openTasks: taskQueue.openTasks,
            recentSessions: recentSessions,
            provider: selectedProvider,
            specialist: pulseModel.delegateSpecialist
        )
    }

    private func selectTask(_ task: SoulTaskRecord) {
        pulseModel.run(kind: .task, title: "Focus Task", args: ["task", "select", task.id, "--project", task.project], project: task.project) {
            taskQueue.refresh()
            activeTask.bind(projectKey: task.project)
        }
    }

    private func startTask(_ task: SoulTaskRecord) {
        pulseModel.run(kind: .task, title: "Start Task", args: ["task", "status", "in_progress", "--task_id", task.id, "--project", task.project], project: task.project) {
            refreshTaskQueue()
        }
    }

    private func launchTask(_ task: SoulTaskRecord) {
        pulseModel.runTaskDelegate(task, provider: selectedProvider)
    }

    private func refreshTaskQueue() {
        taskQueue.refresh()
        activeTask.bind(projectKey: project?.id)
    }

    private func openActiveTaskRecord() {
        guard let project else { return }
        let taskId = activeTask.taskId ?? taskQueue.recommendedTask?.id
        guard let taskId else { return }
        openTaskRecord(project: project.id, taskId: taskId)
    }

    private func openPressureTask() {
        guard let project else { return }
        let taskId = taskQueue.openTasks.first(where: { $0.priority == "high" })?.id ?? taskQueue.openTasks.first?.id
        guard let taskId else { return }
        openTaskRecord(project: project.id, taskId: taskId)
    }

    private func openTaskRecord(project: String, taskId: String) {
        let url = SoulTaskRecord.fileURL(project: project, id: taskId)
        NSWorkspace.shared.open(url)
    }

    private func inspectLatestOperation() {
        let latest = pulseModel.operations.first(where: { $0.status == .running }) ?? pulseModel.operations.first
        inspectedOperationID = latest?.id
    }

    private func openTimelineEntry(_ entry: SoulTimelineEntry) {
        if let operationID = entry.operationID {
            inspectedOperationID = operationID
            return
        }
        if let taskID = entry.taskID, let project {
            openTaskRecord(project: project.id, taskId: taskID)
            return
        }
        if entry.kind == .session {
            inspectLatestOperation()
        }
    }

    private func openOperationLog(_ operation: SoulOperation) {
        let body = """
        \(operation.title)
        status: \(operation.status.label)
        started: \(operation.startedAt.formatted(date: .abbreviated, time: .standard))

        \(operation.summary)

        \(operation.logs)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-operation-\(operation.id.uuidString.prefix(8)).log")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SoulControlPanelModel: ObservableObject {
    @Published var operations: [SoulOperation] = []
    @Published var lastVerifySummary: String = "unknown"
    @Published var delegateSpecialist: String = "systems_architect"
    @Published var delegateTask: String = ""
    @Published var delegateStream: Bool = true
    @Published var assistantInput: String = ""
    @Published var assistantMessages: [SoulAssistantMessage] = []

    var runningOperationCount: Int {
        operations.filter { $0.status == .running }.count
    }

    func latestLaunchOperation(for taskID: String) -> SoulOperation? {
        operations.first { $0.title == "Launch \(taskID)" }
    }

    func answerControlPanelQuestion(
        project: SoulProject,
        activeTaskId: String?,
        recommendedTask: SoulTaskRecord?,
        openTasks: [SoulTaskRecord],
        recentSessions: [SoulSession],
        provider: Provider,
        specialist: String
    ) {
        let question = assistantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        assistantInput = ""
        assistantMessages.append(SoulAssistantMessage(isUser: true, text: question))
        assistantMessages.append(SoulAssistantMessage(
            isUser: false,
            text: Self.controlPanelAnswer(
                question: question,
                project: project,
                activeTaskId: activeTaskId,
                recommendedTask: recommendedTask,
                openTasks: openTasks,
                recentSessions: recentSessions,
                provider: provider,
                specialist: specialist
            )
        ))
    }

    func run(
        kind: SoulOperation.Kind,
        title: String,
        args: [String],
        project: String?,
        provider: Provider? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let operationID = startOperation(kind: kind, title: title, project: project, provider: provider)
        Task {
            do {
                let text = try await SoulCLI.runText(args)
                finishOperation(operationID, status: .succeeded, summary: Self.summary(from: text, fallback: "Completed."), logs: text)
                if kind == .verify {
                    lastVerifySummary = text.lowercased().contains("fail") ? "needs attention" : "ok"
                }
                onComplete?()
            } catch {
                finishOperation(operationID, status: .failed, summary: error.localizedDescription, logs: error.localizedDescription)
                if kind == .verify { lastVerifySummary = "failed" }
            }
        }
    }

    func runDelegate(project: String, provider: Provider, dryRun: Bool) {
        let specialist = delegateSpecialist.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = delegateTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !specialist.isEmpty, !task.isEmpty else {
            let operationID = startOperation(kind: .delegate, title: "Delegate", project: project, provider: provider)
            finishOperation(operationID, status: .failed, summary: "Delegate requires a specialist and task.", logs: "")
            return
        }

        var args = [
            "delegate",
            "--project", project,
            "--provider", Self.delegateProviderName(provider),
            "--mode", "async",
            specialist,
            task
        ]
        if dryRun { args.insert("--dry-run", at: 1) }
        if delegateStream && !dryRun { args.insert("--stream", at: 1) }
        if delegateStream && !dryRun {
            runStream(args, title: "Delegate", project: project, provider: provider)
        } else {
            run(kind: .delegate, title: dryRun ? "Delegate Dry Run" : "Delegate", args: args, project: project, provider: provider)
        }
    }

    func runTaskDelegate(_ record: SoulTaskRecord, provider: Provider) {
        let specialist = delegateSpecialist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !specialist.isEmpty else {
            let operationID = startOperation(kind: .delegate, title: "Launch Task", project: record.project, provider: provider)
            finishOperation(operationID, status: .failed, summary: "Launch requires a specialist.", logs: "")
            return
        }

        let brief = Self.taskBrief(from: record)
        var args = [
            "delegate",
            "--project", record.project,
            "--provider", Self.delegateProviderName(provider),
            "--mode", "async",
            specialist,
            brief
        ]
        if delegateStream {
            args.insert("--stream", at: 1)
            runStream(
                args,
                title: "Launch \(record.id)",
                project: record.project,
                provider: provider,
                initialLog: Self.commandLine(args: args)
            )
        } else {
            run(kind: .delegate, title: "Launch \(record.id)", args: args, project: record.project, provider: provider)
        }
    }

    private static func delegateProviderName(_ provider: Provider) -> String {
        switch provider {
        case .geminiCLI: return "gemini"
        case .claude:    return "claude"
        case .pi:        return "pi"
        case .codex:     return "codex"
        }
    }

    private static func taskBrief(from record: SoulTaskRecord) -> String {
        var lines = [
            "Work this Soul task.",
            "",
            "Task ID: \(record.id)",
            "Project: \(record.project)",
            "Status: \(record.status)",
            "Priority: \(record.priority)",
            "Subject: \(record.subject)"
        ]

        if !record.doneCriteria.isEmpty {
            lines.append("")
            lines.append("Definition of Done:")
            for criterion in record.doneCriteria {
                lines.append("- \(criterion)")
            }
        }

        lines.append("")
        lines.append("Return a concise finding with blockers, changed files, and the next concrete action.")
        return lines.joined(separator: "\n")
    }

    private static func controlPanelAnswer(
        question: String,
        project: SoulProject,
        activeTaskId: String?,
        recommendedTask: SoulTaskRecord?,
        openTasks: [SoulTaskRecord],
        recentSessions: [SoulSession],
        provider: Provider,
        specialist: String
    ) -> String {
        let lower = question.lowercased()
        let active = activeTaskId ?? "none"
        let highCount = openTasks.filter { $0.priority == "high" }.count
        let inProgressCount = openTasks.filter { $0.status == "in_progress" }.count
        let top = recommendedTask

        if lower.contains("what") && (lower.contains("next") || lower.contains("do")) {
            if let top {
                return "For \(project.name), I would work \(top.id) next: \(top.subject). It is \(top.status), \(top.priority) priority, with \(top.operatorSummary) Use \(specialist) on \(provider.label) if you want to launch help."
            }
            return "\(project.name) has no open task loaded here. Run Pulse or refresh the queue, then I can point at the next action."
        }

        if lower.contains("project") || lower.contains("where") || lower.contains("context") {
            return "You are operating on \(project.name) (`\(project.id)`) at \(project.path). Active task: \(active). Open tasks: \(openTasks.count), high priority: \(highCount), in progress: \(inProgressCount). Recent sessions loaded: \(recentSessions.count)."
        }

        if lower.contains("task") || lower.contains("queue") || lower.contains("active") {
            guard let top else {
                return "I do not see an open recommended task for \(project.name). The queue may be empty or still loading."
            }
            return "Active task is \(active). The recommended task is \(top.id): \(top.subject). Status \(top.status), priority \(top.priority). \(top.operatorSummary)"
        }

        if lower.contains("agent") || lower.contains("specialist") || lower.contains("provider") {
            return "Current launch defaults are \(specialist) via \(provider.label). For design/product ambiguity use product_shaper or systems_architect; for codebase excavation use code_archaeologist; for registry/data health use registry_guardian."
        }

        if lower.contains("recent") || lower.contains("session") || lower.contains("history") {
            let names = recentSessions.prefix(3).map { $0.intent ?? $0.id }.joined(separator: ", ")
            return names.isEmpty
                ? "No recent sessions are loaded for \(project.name) in this panel."
                : "Recent work for \(project.name): \(names). Use this to decide whether to continue a thread or launch a focused specialist."
        }

        if let top {
            return "I know you are in \(project.name). The control panel is showing \(openTasks.count) open tasks and recommends \(top.id): \(top.subject). Ask me about next action, task queue, recent work, or which specialist to use."
        }
        return "I know you are in \(project.name). Ask me about next action, task queue, recent work, or which specialist to use."
    }

    private func runStream(_ args: [String], title: String, project: String, provider: Provider, initialLog: String? = nil) {
        let operationID = startOperation(kind: .delegate, title: title, project: project, provider: provider)
        if let initialLog {
            appendLog(initialLog + "\n", to: operationID)
        }
        Task {
            do {
                _ = try await SoulCLI.runStream(
                    args,
                    onStart: { pid in
                        Task { @MainActor in
                            self.setOperationProcessID(operationID, pid: pid)
                        }
                    }
                ) { event in
                    let text: String
                    switch event {
                    case .stdout(let chunk): text = chunk
                    case .stderr(let chunk): text = chunk
                    }
                    Task { @MainActor in
                        self.appendLog(text, to: operationID)
                    }
                }
                if operationStatus(operationID) != .cancelled {
                    let logs = operationLogs(operationID)
                    if let failure = Self.streamFailureSummary(from: logs) {
                        finishOperation(operationID, status: .failed, summary: failure, logs: nil)
                    } else {
                        finishOperation(operationID, status: .succeeded, summary: Self.summary(from: logs, fallback: "Delegate completed."), logs: nil)
                    }
                }
            } catch {
                if operationStatus(operationID) != .cancelled {
                    appendLog("\n\(error.localizedDescription)", to: operationID)
                    let logs = operationLogs(operationID)
                    finishOperation(operationID, status: .failed, summary: Self.streamFailureSummary(from: logs) ?? error.localizedDescription, logs: nil)
                }
            }
        }
    }

    private func startOperation(kind: SoulOperation.Kind, title: String, project: String?, provider: Provider?) -> UUID {
        let operation = SoulOperation(
            kind: kind,
            title: title,
            project: project,
            provider: provider,
            status: .running,
            startedAt: Date(),
            lastUpdatedAt: Date(),
            processID: nil,
            endedAt: nil,
            summary: "Running...",
            logs: ""
        )
        operations.insert(operation, at: 0)
        return operation.id
    }

    private func appendLog(_ text: String, to id: UUID) {
        updateOperation(id) { operation in
            operation.logs += text
            operation.lastUpdatedAt = Date()
            operation.summary = Self.summary(from: operation.logs, fallback: "Running...")
        }
    }

    private func finishOperation(_ id: UUID, status: SoulOperation.Status, summary: String, logs: String?) {
        updateOperation(id) { operation in
            operation.status = status
            operation.endedAt = Date()
            operation.lastUpdatedAt = Date()
            operation.summary = summary
            if let logs {
                operation.logs = logs
            }
        }
    }

    func cancelOperation(_ id: UUID) {
        let pid = operations.first { $0.id == id }?.processID
        if let pid {
            SoulCLI.terminateProcessTree(pid: pid)
        }
        updateOperation(id) { operation in
            operation.status = .cancelled
            operation.endedAt = Date()
            operation.lastUpdatedAt = Date()
            operation.summary = "Stopped by user."
            operation.logs += "\n{\"event\":\"cancelled\",\"status\":\"stopped_by_user\"}\n"
        }
    }

    private func operationLogs(_ id: UUID) -> String {
        operations.first { $0.id == id }?.logs ?? ""
    }

    private func operationStatus(_ id: UUID) -> SoulOperation.Status? {
        operations.first { $0.id == id }?.status
    }

    private func setOperationProcessID(_ id: UUID, pid: Int32) {
        updateOperation(id) { operation in
            operation.processID = pid
        }
    }

    private func updateOperation(_ id: UUID, _ body: (inout SoulOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        body(&operations[index])
    }

    private static func summary(from text: String, fallback: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return fallback }
        if first.count <= 180 { return first }
        return String(first.prefix(177)) + "..."
    }

    private static func streamFailureSummary(from text: String) -> String? {
        var latestFailure: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = object["event"] as? String
            else { continue }

            switch event {
            case "subagent_timeout":
                latestFailure = object["reason"] as? String ?? "Delegate timed out waiting for provider output."
            case "subagent_failed":
                latestFailure = object["error"] as? String ?? object["reason"] as? String ?? "Delegate failed."
            default:
                continue
            }
        }
        return latestFailure
    }

    private static func commandLine(args: [String]) -> String {
        let escaped = args.map { arg in
            if arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "$ soul " + escaped.joined(separator: " ")
    }
}

struct SoulOperation: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case pulse
        case verify
        case delegate
        case task
        case finalize
        case compact
        case appServerDoctor

        var icon: String {
            switch self {
            case .pulse: return "waveform.path.ecg"
            case .verify: return "checkmark.shield"
            case .delegate: return "person.2.wave.2"
            case .task: return "checklist"
            case .finalize: return "seal"
            case .compact: return "rectangle.compress.vertical"
            case .appServerDoctor: return "stethoscope"
            }
        }
    }

    enum Status: Hashable {
        case running
        case succeeded
        case failed
        case cancelled

        var label: String {
            switch self {
            case .running: return "running"
            case .succeeded: return "done"
            case .failed: return "failed"
            case .cancelled: return "stopped"
            }
        }

        var tint: Color {
            switch self {
            case .running: return SoulColor.accent
            case .succeeded: return .green
            case .failed: return .red
            case .cancelled: return SoulColor.fgMuted
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var project: String?
    var provider: Provider?
    var status: Status
    var startedAt: Date
    var lastUpdatedAt: Date
    var processID: Int32?
    var endedAt: Date?
    var summary: String
    var logs: String
}

struct SoulOperationEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case command
        case subagent
        case toolStart
        case toolEnd
        case output
        case error
        case raw
    }

    let id: String
    var kind: Kind
    var title: String
    var detail: String
    var badge: String?

    var icon: String {
        switch kind {
        case .command: return "terminal"
        case .subagent: return "person.2.wave.2"
        case .toolStart: return "wrench.and.screwdriver"
        case .toolEnd: return "checkmark.circle"
        case .output: return "text.alignleft"
        case .error: return "exclamationmark.triangle"
        case .raw: return "curlybraces"
        }
    }

    var tint: Color {
        switch kind {
        case .command: return SoulColor.fgMuted
        case .subagent: return SoulColor.accent
        case .toolStart: return SoulColor.accent
        case .toolEnd: return .green
        case .output: return SoulColor.fgMuted
        case .error: return .red
        case .raw: return SoulColor.fgSubtle
        }
    }

    static func parse(_ logs: String) -> [SoulOperationEvent] {
        logs
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .compactMap { index, rawLine in
                parseLine(String(rawLine), index: index)
            }
    }

    private static func parseLine(_ rawLine: String, index: Int) -> SoulOperationEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("$ ") {
            return SoulOperationEvent(
                id: "command-\(index)",
                kind: .command,
                title: "Command",
                detail: line,
                badge: nil
            )
        }

        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return SoulOperationEvent(
                id: "output-\(index)",
                kind: line.lowercased().contains("error") ? .error : .output,
                title: line.lowercased().contains("error") ? "Error" : "Output",
                detail: line,
                badge: nil
            )
        }

        let event = object["event"] as? String ?? "event"
        switch event {
        case "subagent_started":
            let specialist = object["specialist"] as? String ?? "subagent"
            let provider = object["provider"] as? String
            let task = object["task"] as? String ?? ""
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .subagent,
                title: "Started @\(specialist)",
                detail: firstLine(task),
                badge: provider
            )
        case "tool_call_start":
            let name = object["name"] as? String ?? "tool"
            let args = readableArgs(object["args"])
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .toolStart,
                title: toolTitle(name),
                detail: args,
                badge: "start"
            )
        case "tool_call_end":
            let name = object["name"] as? String ?? "tool"
            let status = object["status"] as? String ?? "done"
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .toolEnd,
                title: toolTitle(name),
                detail: status,
                badge: status
            )
        case "subagent_timeout":
            let reason = object["reason"] as? String ?? "No provider stream output before timeout."
            let status = object["status"] as? String ?? "failed"
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .error,
                title: "Subagent Timeout",
                detail: reason,
                badge: status
            )
        case "subagent_failed":
            let detail = object["error"] as? String ?? object["reason"] as? String ?? readablePayload(object)
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .error,
                title: "Subagent Failed",
                detail: detail,
                badge: "failed"
            )
        case "subagent_completed":
            let summary = object["summary"] as? String ?? readablePayload(object)
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .subagent,
                title: "Subagent Completed",
                detail: firstLine(summary),
                badge: "done"
            )
        default:
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: event.lowercased().contains("error") ? .error : .raw,
                title: event.replacingOccurrences(of: "_", with: " ").capitalized,
                detail: readablePayload(object),
                badge: nil
            )
        }
    }

    private static func firstLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? text
    }

    private static func toolTitle(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func readableArgs(_ value: Any?) -> String {
        if let string = value as? String {
            if
                let data = string.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return readablePayload(object)
            }
            return string
        }
        if let value {
            return "\(value)"
        }
        return ""
    }

    private static func readablePayload(_ object: [String: Any]) -> String {
        let preferredKeys = ["description", "command", "file_path", "displayName", "delegation_id", "live_log", "status"]
        let parts = preferredKeys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return "\(key): \(value)"
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

struct SoulTimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case operation
        case task
        case session
    }

    let id = UUID()
    var kind: Kind
    var icon: String
    var tint: Color
    var title: String
    var detail: String
    var timestamp: Date?
    var badge: String
    var operationID: UUID?
    var taskID: String?
}

struct SoulTaskRecord: Identifiable, Hashable, Sendable {
    var id: String
    var project: String
    var subject: String
    var status: String
    var priority: String
    var updatedAt: String?
    var doneCriteria: [String]
    var completedCriteriaCount: Int

    static func fileURL(project: String, id: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("soul_registry")
            .appendingPathComponent("tasks")
            .appendingPathComponent(project)
            .appendingPathComponent("\(id).json")
    }

    var operatorSummary: String {
        guard !doneCriteria.isEmpty else { return "No acceptance criteria recorded." }
        let remaining = max(doneCriteria.count - completedCriteriaCount, 0)
        if remaining == 0 { return "All \(doneCriteria.count) criteria are marked complete." }
        let nextIndex = min(max(completedCriteriaCount, 0), doneCriteria.count - 1)
        return "\(remaining) criteria left. Next check: \(doneCriteria[nextIndex])"
    }
}

struct SoulAssistantMessage: Identifiable, Hashable {
    let id = UUID()
    var isUser: Bool
    var text: String
}

@MainActor
final class SoulSpecialistStore: ObservableObject {
    @Published private(set) var specialists: [String] = SoulSpecialistStore.fallbackSpecialists

    private var boundProject: String? = nil

    func bind(projectKey: String?, selected: String, onSelect: @escaping (String) -> Void) {
        guard projectKey != boundProject else {
            ensureSelection(selected: selected, onSelect: onSelect)
            return
        }
        boundProject = projectKey
        Task {
            let loaded = await Self.load(projectKey: projectKey)
            specialists = loaded
            ensureSelection(selected: selected, onSelect: onSelect)
        }
    }

    private func ensureSelection(selected: String, onSelect: (String) -> Void) {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if specialists.contains(trimmed) { return }
        if specialists.contains("systems_architect") {
            onSelect("systems_architect")
        } else if let first = specialists.first {
            onSelect(first)
        }
    }

    nonisolated private static func load(projectKey: String?) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var discovered: [String] = []
            discovered.append(contentsOf: projectTeam(projectKey: projectKey))
            discovered.append(contentsOf: agentFileSpecialists())
            discovered.append(contentsOf: fallbackSpecialists)
            return orderedUnique(discovered.filter { !$0.isEmpty })
        }.value
    }

    nonisolated private static func projectTeam(projectKey: String?) -> [String] {
        guard let projectKey, !projectKey.isEmpty else { return [] }
        // Single source of truth: `soul project show <key>` (kernel CLI).
        // The legacy dual-path read of ~/dotfiles/soul/config/PROJECTS.json
        // + ~/soul_registry/PROJECTS.json was retired in
        // SOUL-SOUL_DESKTOP-261 — the CLI now handles project-key lookup
        // and harness_config resolution. Returns [] on CLI failure or when
        // the project has no team configured.
        guard let data = SoulCLI.runSync(["project", "show", projectKey]),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let harness = project["harness_config"] as? [String: Any],
              let team = harness["team"] as? [Any]
        else { return [] }

        return team.compactMap { member -> String? in
            if let name = member as? String { return name }
            guard let object = member as? [String: Any] else { return nil }
            return object["persona"] as? String
                ?? object["name"] as? String
                ?? object["specialist"] as? String
                ?? object["id"] as? String
        }
    }

    nonisolated private static func agentFileSpecialists() -> [String] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let directories = [
            home.appendingPathComponent("dotfiles/soul/agents"),
            home.appendingPathComponent("dotfiles/gemini/agents"),
            home.appendingPathComponent(".gemini/agents")
        ]

        var names: [String] = []
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension == "md" {
                if let name = frontMatterName(url: url) {
                    names.append(name)
                } else {
                    names.append(url.deletingPathExtension().lastPathComponent)
                }
            }
        }
        return names
    }

    nonisolated private static func frontMatterName(url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.prefix(1200).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("name:") else { continue }
            return line.dropFirst(5)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        }
        return nil
    }

    nonisolated private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    nonisolated private static let fallbackSpecialists = [
        "systems_architect",
        "information_retriever",
        "code_archaeologist",
        "terrain_mapper",
        "registry_guardian",
        "adversarial_judge",
        "product_shaper",
        "visual_auditor"
    ]
}

@MainActor
final class SoulTaskQueueStore: ObservableObject {
    @Published private(set) var openTasks: [SoulTaskRecord] = []
    @Published private(set) var activeTaskId: String? = nil
    @Published private(set) var isLoading: Bool = false

    private var boundProject: String? = nil

    var recommendedTask: SoulTaskRecord? {
        openTasks.first { $0.id == activeTaskId }
            ?? openTasks.first { $0.status == "in_progress" }
            ?? openTasks.first { $0.priority == "high" }
            ?? openTasks.first
    }

    var highPriorityCount: Int {
        openTasks.filter { $0.priority == "high" }.count
    }

    var inProgressCount: Int {
        openTasks.filter { $0.status == "in_progress" }.count
    }

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        openTasks = []
        activeTaskId = nil
        refresh()
    }

    func refresh() {
        guard let project = boundProject, !project.isEmpty else { return }
        isLoading = true
        Task {
            let snapshot = await Self.load(projectKey: project)
            openTasks = snapshot.tasks
            activeTaskId = snapshot.activeTaskId
            isLoading = false
        }
    }

    private struct Snapshot: Sendable {
        var tasks: [SoulTaskRecord]
        var activeTaskId: String?
    }

    nonisolated private static func load(projectKey: String) async -> Snapshot {
        await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("soul_registry")
                .appendingPathComponent("tasks")
                .appendingPathComponent(projectKey)
            let activeURL = root.appendingPathComponent(".soul_task")
            let active = (try? String(contentsOf: activeURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var tasks: [SoulTaskRecord] = []
            for url in urls where url.pathExtension == "json" {
                guard let task = readTask(url, projectKey: projectKey) else { continue }
                if task.status == "completed" || task.status == "wont_fix" || task.status == "archive" {
                    continue
                }
                tasks.append(task)
            }

            tasks.sort { lhs, rhs in
                let rank: [String: Int] = ["in_progress": 0, "pending": 1, "freezer": 2]
                let lhsRank = rank[lhs.status] ?? 9
                let rhsRank = rank[rhs.status] ?? 9
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.id < rhs.id
            }
            return Snapshot(tasks: tasks, activeTaskId: active?.isEmpty == false ? active : nil)
        }.value
    }

    nonisolated private static func readTask(_ url: URL, projectKey: String) -> SoulTaskRecord? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = (obj["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let subject = (obj["subject"] as? String) ?? (obj["title"] as? String) ?? "Untitled task"
        let project = (obj["project"] as? String) ?? projectKey
        let status = ((obj["status"] as? String) ?? "pending")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let priority = ((obj["priority"] as? String) ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let doneCriteria = (obj["done_criteria"] as? [String]) ?? (obj["definition_of_done"] as? [String]) ?? []
        let completed = (obj["completed_criteria"] as? [String]) ?? []

        return SoulTaskRecord(
            id: id,
            project: project,
            subject: subject,
            status: status,
            priority: priority,
            updatedAt: obj["updated_at"] as? String,
            doneCriteria: doneCriteria,
            completedCriteriaCount: completed.count
        )
    }
}
