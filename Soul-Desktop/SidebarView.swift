import SwiftUI

struct SidebarView: View {
    @Binding var selectedProject: String?
    var onSelectSession: (SoulSession) -> Void = { _ in }
    var onReplaySession: (SoulSession) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var activeReplaySessionId: String? = nil
    var replayProgress: Double = 0
    var replayIndex: Int = 0
    var replayTotal: Int = 0
    var replayPrompts: Int = 0
    var replayReplies: Int = 0
    @State private var projects: [SoulProject] = []
    @State private var sessions: [SoulSession] = []
    @State private var showingAllProjects = false
    @State private var visibleProjectCount: Int = 0
    @State private var chatSourceFilter: String? = nil   // nil = all
    @State private var hideUntitled: Bool = false
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    private var filterIsActive: Bool { chatSourceFilter != nil || hideUntitled }

    private var filteredSessions: [SoulSession] {
        sessions.filter { s in
            if let f = chatSourceFilter, (s.source ?? "") != f { return false }
            if hideUntitled {
                let title = (s.intent ?? s.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { return false }
            }
            return true
        }
    }

    private let topActions: [(icon: String, label: String, shortcut: String?)] = [
        ("square.and.pencil", "New chat", "⌘N"),
        ("magnifyingglass", "Search", nil),
        ("square.grid.2x2", "Skills", nil),
        ("waveform.path.ecg", "Heartbeats", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(topActions, id: \.label) { action in
                    SidebarRow(
                        icon: action.icon,
                        label: action.label,
                        trailing: action.shortcut,
                        isSelected: action.label == "New chat"
                    )
                }
            }
            .padding(.top, 38)
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                sectionHeader("Projects")
                if !projects.isEmpty {
                    Text("\(projects.count)")
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SoulColor.surface, in: Capsule())
                }
                Spacer()
                if visibleProjectCount > 0 && visibleProjectCount < projects.count {
                    Button {
                        showingAllProjects.toggle()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Show all \(projects.count) projects")
                    .popover(isPresented: $showingAllProjects, arrowEdge: .leading) {
                        AllProjectsPopover(
                            projects: projects,
                            selectedProject: selectedProject,
                            onSelect: { id in
                                selectedProject = id
                                showingAllProjects = false
                            }
                        )
                    }
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            GeometryReader { geo in
                let rowHeight: CGFloat = 28
                let projectsHeight = max(140, geo.size.height * 0.55)
                let fitCount = max(1, Int(projectsHeight / rowHeight))

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(projects.prefix(fitCount)) { project in
                            SidebarRow(
                                icon: "folder",
                                label: project.name,
                                isSelected: selectedProject == project.id
                            )
                            .onTapGesture { selectedProject = project.id }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: projectsHeight, alignment: .top)
                    .onAppear {
                        visibleProjectCount = min(fitCount, projects.count)
                    }
                    .onChange(of: projects.count) { _, _ in
                        visibleProjectCount = min(fitCount, projects.count)
                    }
                    .onChange(of: geo.size.height) { _, _ in
                        visibleProjectCount = min(fitCount, projects.count)
                    }

                    HStack {
                        sectionHeader("Chats")
                        if !filteredSessions.isEmpty {
                            Text("\(filteredSessions.count)")
                                .font(SoulFont.ui(10, weight: .medium))
                                .foregroundStyle(SoulColor.fgSubtle)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(SoulColor.surface, in: Capsule())
                        }
                        Spacer()
                        Menu {
                            Picker("Source", selection: $chatSourceFilter) {
                                Text("All sources").tag(String?.none)
                                Text("Claude").tag(String?.some("claude"))
                                Text("Gemini").tag(String?.some("gemini"))
                                Text("Pi").tag(String?.some("pi-native"))
                            }
                            Toggle("Hide untitled", isOn: $hideUntitled)
                        } label: {
                            Image(systemName: filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                                .font(.system(size: 12))
                                .foregroundStyle(filterIsActive ? SoulColor.accent : SoulColor.fgMuted)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Filter chats")

                        Button(action: onNewChat) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(SoulColor.fgMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New chat")
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 16)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if filteredSessions.isEmpty {
                                Text(sessions.isEmpty ? "No chats" : "No chats match filter")
                                    .font(SoulFont.ui(13))
                                    .foregroundStyle(SoulColor.fgSubtle)
                                    .padding(.top, 6)
                                    .padding(.horizontal, 16)
                            } else {
                                ForEach(filteredSessions) { session in
                                    ChatRow(
                                        session: session,
                                        onReplay: { onReplaySession(session) },
                                        isActiveReplay: session.id == activeReplaySessionId,
                                        replayProgress: replayProgress,
                                        replayIndex: replayIndex,
                                        replayTotal: replayTotal,
                                        replayPrompts: replayPrompts,
                                        replayReplies: replayReplies
                                    )
                                        .contentShape(Rectangle())
                                        .onTapGesture { onSelectSession(session) }
                                        .contextMenu {
                                            Button("Open chat") { onSelectSession(session) }
                                            Button("Replay…") { onReplaySession(session) }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: .infinity)
                }
            }

            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    SoulIcon(name: "gear", color: SoulColor.fgMuted)
                    Text("Settings").font(SoulFont.ui(13)).foregroundStyle(SoulColor.fg)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(SoulColor.sidebar)
        .task { await reload() }
        .onChange(of: selectedProject) { _, _ in
            Task { await reloadSessions() }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(12))
            .foregroundStyle(SoulColor.fgSubtle)
    }

    private func reload() async {
        let projs = SoulRegistry.activeProjects()
        await MainActor.run {
            self.projects = projs
            if selectedProject == nil || projs.first(where: { $0.id == selectedProject }) == nil {
                selectedProject = projs.first?.id
            }
        }
        await reloadSessions()
    }

    private func reloadSessions() async {
        guard let key = selectedProject else { return }
        let s = SoulRegistry.sessions(forProject: key, limit: 30)
        await MainActor.run { self.sessions = s }
    }
}

private struct AllProjectsPopover: View {
    let projects: [SoulProject]
    let selectedProject: String?
    let onSelect: (String) -> Void
    @State private var query: String = ""

    private var filtered: [SoulProject] {
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgSubtle)
                TextField("Search projects", text: $query)
                    .textFieldStyle(.plain)
                    .font(SoulFont.ui(12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { project in
                        Button {
                            onSelect(project.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SoulColor.fgMuted)
                                Text(project.name)
                                    .font(SoulFont.ui(13))
                                    .foregroundStyle(SoulColor.fg)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                                if selectedProject == project.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(SoulColor.accent)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                selectedProject == project.id
                                    ? AnyShapeStyle(SoulColor.surface)
                                    : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No matches")
                            .font(SoulFont.ui(12))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(8)
        .frame(width: 280)
    }
}

struct ChatRow: View {
    let session: SoulSession
    var onReplay: (() -> Void)? = nil
    var isActiveReplay: Bool = false
    var replayProgress: Double = 0
    var replayIndex: Int = 0
    var replayTotal: Int = 0
    var replayPrompts: Int = 0
    var replayReplies: Int = 0
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sourceIcon)
                .font(.system(size: 11))
                .foregroundStyle(SoulColor.fgSubtle)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(cleanTitle(session.intent ?? session.summary))
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(relative(session.timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            Spacer(minLength: 0)
            if isActiveReplay {
                ReplayProgressChip(
                    progress: replayProgress,
                    index: replayIndex,
                    total: replayTotal,
                    prompts: replayPrompts,
                    replies: replayReplies
                )
            } else if hovering, let onReplay {
                Button(action: onReplay) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(SoulColor.accent)
                        Text("Replay")
                            .font(SoulFont.ui(10, weight: .medium))
                            .foregroundStyle(SoulColor.fg)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(SoulColor.accentMuted, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Replay this session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var sourceIcon: String {
        switch session.source {
        case "claude":     return "circle.hexagongrid"
        case "gemini":     return "sparkles"
        case "pi-native":  return "terminal"
        default:           return "circle"
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func cleanTitle(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return "untitled"
        }
        // Drop leading markdown noise: #, [, ], -, *, > and stray whitespace.
        let noise = CharacterSet(charactersIn: "#[]-*> ")
        while let first = s.unicodeScalars.first, noise.contains(first) {
            s.removeFirst()
        }
        // Take the first line only — markdown summaries often span paragraphs.
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        return s.isEmpty ? "untitled" : s
    }
}

struct SidebarRow: View {
    let icon: String
    let label: String
    var trailing: String? = nil
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: icon, color: isSelected ? SoulColor.accent : SoulColor.fgMuted)
            Text(label)
                .font(SoulFont.ui(13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AnyShapeStyle(SoulColor.accentMuted)
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
    }
}

private struct ReplayProgressChip: View {
    let progress: Double
    let index: Int
    let total: Int
    let prompts: Int
    let replies: Int

    var body: some View {
        HStack(spacing: 0) {
            label
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SoulColor.surface)
                    Capsule()
                        .fill(SoulColor.accent.opacity(0.35))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * clampedProgress)))
                }
            }
        }
        .clipShape(Capsule())
        .help("\(index) of \(total) · \(prompts) prompts · \(replies) replies")
    }

    private var clampedProgress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, progress))
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
                .font(.system(size: 8))
                .foregroundStyle(SoulColor.accent)
            Text("\(index)/\(total)")
                .font(SoulFont.code(10, weight: .medium))
                .foregroundStyle(SoulColor.fg)
            Text("·")
                .font(SoulFont.ui(9))
                .foregroundStyle(SoulColor.fgSubtle)
            Text("\(prompts)p \(replies)r")
                .font(SoulFont.code(10))
                .foregroundStyle(SoulColor.fgMuted)
        }
    }
}
