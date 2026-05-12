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
    /// Session ID currently open in the canvas; used to highlight the
    /// matching live row so users can see which chat they're inside.
    var activeSessionId: String? = nil
    /// Current harness selection from AppShell. Plumbed into `liveSessions`
    /// so we only surface rows whose recorded provider matches what's
    /// actually going to be spawned at click time.
    var currentProvider: Provider = .geminiCLI
    // Seed projects synchronously from PROJECTS.json so the first render
    // already has data instead of flashing an empty "Projects" + "No chats"
    // header for the ~250ms until the async reload finishes.
    @State private var projects: [SoulProject] = SoulRegistry.activeProjects()
    @State private var sessions: [SoulSession] = []
    @State private var liveSessions: [String: [SoulSession]] = [:]  // project key → live rows
    @State private var chatSourceFilter: String? = nil   // nil = all
    @State private var hideUntitled: Bool = false
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0
    @State private var watcher: RegistryWatcher? = nil

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
                        isSelected: false
                    )
                }
            }
            .padding(.top, 38)
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                sectionHeader("Projects")
                if !projects.isEmpty {
                    Text("\(projects.count)")
                        .font(SoulFont.ui(10, weight: .regular))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SoulColor.surface, in: Capsule())
                }
                Spacer()
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            // Two independent scrollers: projects (with live rows under the
            // selected project) on top, chats below. Each owns its own
            // overflow; neither can paint into the other's region. The cap on
            // the projects pane is a soft ceiling — it'll shrink when content
            // is small, and the chats pane absorbs the remainder.
            GeometryReader { geo in
                // Projects gets the lion's share of the sidebar by default —
                // most users have more projects than they have recent chats to
                // care about. Chats absorbs whatever's left via maxHeight:
                // .infinity, so this is a soft ceiling not a hard limit.
                let projectsCap = max(200, geo.size.height * 0.7)

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(projects) { project in
                                ProjectSidebarRow(
                                    project: project,
                                    // Drop the project's "selected" tint while
                                    // an active session/replay owns the canvas
                                    // — only one row should look selected at a
                                    // time. The folder stays interactive; just
                                    // its highlight defers to the leaf row.
                                    isSelected: selectedProject == project.id
                                        && activeSessionId == nil
                                        && activeReplaySessionId == nil,
                                    onSelect: { selectedProject = project.id },
                                    onNewChat: {
                                        selectedProject = project.id
                                        onNewChat()
                                    }
                                )

                                // Live in-flight chats — disk-derived from
                                // hooks.jsonl dirs without a finalize sibling.
                                // Only show under the currently selected
                                // project; switching projects swaps the
                                // visible set.
                                if project.id == selectedProject,
                                   let lives = liveSessions[project.id] {
                                    // Sub-group by worktree_path. Sessions
                                    // without a recorded worktree go under
                                    // "(main)"; otherwise each worktree gets
                                    // its own indented sub-header with the
                                    // basename of the worktree path as label.
                                    let groups = worktreeGroups(for: lives)
                                    ForEach(groups, id: \.label) { group in
                                        if groups.count > 1 || group.label != mainWorktreeLabel {
                                            WorktreeSubheader(label: group.label)
                                        }
                                        ForEach(group.sessions) { live in
                                            LiveSessionRow(
                                                session: live,
                                                isSelected: live.id == activeSessionId
                                            )
                                                .onTapGesture { onSelectSession(live) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: projectsCap)

                    HStack {
                        sectionHeader("Chats")
                        if !filteredSessions.isEmpty {
                            Text("\(filteredSessions.count)")
                                .font(SoulFont.ui(10, weight: .regular))
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
                    .padding(.top, 12)
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
                        .padding(.leading, 8)
                        // Reserve gutter on the right so the macOS scrollbar overlay
                        // doesn't sit on top of the Replay hover chip / count pill.
                        .padding(.trailing, 14)
                    }
                    .scrollIndicators(.automatic)
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
        .onChange(of: currentProvider) { _, _ in
            // Harness change → re-filter live rows. A row that's valid under
            // Claude isn't valid under Gemini-CLI (and vice-versa).
            Task { await reload() }
        }
        .onChange(of: selectedProject) { _, newKey in
            if let key = newKey {
                // Reactive refresh: watch the sessions directory for the
                // active project. This ensures the sidebar refreshes
                // immediately when the kernel or the app writes a new hook.
                watcher = RegistryWatcher.watchSessions(forProject: key) {
                    Task { await reloadSessions() }
                }
            } else {
                watcher = nil
            }
            Task { await reloadSessions() }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(12))
            .foregroundStyle(SoulColor.fgSubtle)
    }

    /// Sentinel label for sessions without a recorded `worktree_path` (i.e.
    /// started in the main checkout). Kept as a constant so the header
    /// suppression check stays explicit.
    fileprivate var mainWorktreeLabel: String { "(main)" }

    /// Bucket live sessions by their `worktreePath`. Order: main first (so
    /// the common case sits where it always has been), then each worktree
    /// sorted by basename for stable layout. Returned as an array because
    /// SwiftUI ForEach needs deterministic iteration order.
    fileprivate func worktreeGroups(for lives: [SoulSession]) -> [(label: String, sessions: [SoulSession])] {
        var buckets: [String: [SoulSession]] = [:]
        for s in lives {
            let key: String = {
                guard let p = s.worktreePath, !p.isEmpty else { return mainWorktreeLabel }
                return (p as NSString).lastPathComponent
            }()
            buckets[key, default: []].append(s)
        }
        var out: [(label: String, sessions: [SoulSession])] = []
        if let main = buckets.removeValue(forKey: mainWorktreeLabel) {
            out.append((mainWorktreeLabel, main))
        }
        for k in buckets.keys.sorted() {
            out.append((k, buckets[k] ?? []))
        }
        return out
    }

    private func reload() async {
        let projs = SoulRegistry.activeProjects()
        // Resolve live sessions for every visible project so the sidebar can
        // show in-flight rows under any project, not just the selected one.
        var lives: [String: [SoulSession]] = [:]
        for p in projs {
            let l = SoulRegistry.liveSessions(forProject: p.id, projectPath: p.path, currentProvider: currentProvider.rawValue)
            if !l.isEmpty { lives[p.id] = l }
        }
        await MainActor.run {
            self.projects = projs
            self.liveSessions = lives
            if selectedProject == nil || projs.first(where: { $0.id == selectedProject }) == nil {
                selectedProject = projs.first?.id
            }
        }
        await reloadSessions()
    }

    private func reloadSessions() async {
        guard let key = selectedProject else { return }
        let path = projects.first(where: { $0.id == key })?.path

        // 1. Paint cached data instantly so switching feels snappy.
        if let cached = SoulRegistry.cachedSessions(forProject: key) {
            await MainActor.run {
                self.sessions = cached.sessions
                self.liveSessions[key] = cached.live.isEmpty ? nil : cached.live
            }
        }

        // 2. Fresh scan happens off the main actor entirely — the file I/O is
        //    synchronous and ~5 small reads, but isolating it keeps any UI tick
        //    from coupling to disk latency.
        let result: (sessions: [SoulSession], live: [SoulSession]) = await Task.detached(priority: .userInitiated) {
            let providerRaw = currentProvider.rawValue
            let s = SoulRegistry.sessions(forProject: key, limit: 5, projectPath: path)
            let l = SoulRegistry.liveSessions(forProject: key, projectPath: path, currentProvider: providerRaw)
            SoulRegistry.warmCache(forProject: key, sessions: s, live: l)
            return (s, l)
        }.value

        await MainActor.run {
            self.sessions = result.sessions
            self.liveSessions[key] = result.live.isEmpty ? nil : result.live
        }
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
            ZStack(alignment: .topTrailing) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .frame(width: 14)
                if session.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(SoulColor.sidebar, lineWidth: 1))
                        .offset(x: 3, y: -2)
                }
            }
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
            .layoutPriority(1)
            Spacer(minLength: 0)
            if !isActiveReplay && !(hovering && onReplay != nil) {
                EventCountChip(events: session.eventCount, prompts: session.promptCount)
            }
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
                            .font(SoulFont.ui(10, weight: .regular))
                            .foregroundStyle(SoulColor.fg)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(SoulColor.accentMuted, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Replay this session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var sourceIcon: String {
        ProviderIcon.symbol(forSessionSource: session.source)
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
        let noise = CharacterSet(charactersIn: "#[]-*> ")
        while let first = s.unicodeScalars.first, noise.contains(first) {
            s.removeFirst()
        }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        return s.isEmpty ? "untitled" : s
    }
}

/// Project-row variant with a hover-revealed "Start new chat in <project>"
/// affordance. The hint pill floats to the right of the label and a trailing
/// pencil icon takes the click — tapping the row body still just selects the
/// project, so the existing single-click behavior stays intact.
private struct ProjectSidebarRow: View {
    let project: SoulProject
    let isSelected: Bool
    let onSelect: () -> Void
    let onNewChat: () -> Void

    @State private var hovering = false
    @State private var buttonHover = false

    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: "folder", color: isSelected ? SoulColor.accent : SoulColor.fgMuted)
            Text(project.name)
                .font(SoulFont.ui(13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // The pencil button always occupies its slot in the layout so the
            // row's text doesn't shift on hover. Only the opacity changes,
            // which keeps it visually hidden until the user is over the row.
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(buttonHover ? SoulColor.fg : SoulColor.fgMuted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { buttonHover = $0 }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
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
        .onTapGesture(perform: onSelect)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { hovering = h }
        }
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

private struct EventCountChip: View {
    let events: Int
    let prompts: Int

    private var compactLabel: String {
        if prompts > 0 { return "\(prompts)p" }
        if events > 0 { return "\(events)e" }
        return ""
    }

    var body: some View {
        if events == 0 && prompts == 0 {
            EmptyView()
        } else {
            Text(compactLabel)
                .font(SoulFont.code(9))
                .foregroundStyle(SoulColor.fgSubtle)
                .lineLimit(1)
                .fixedSize()
                .help("\(events) kernel events · \(prompts) prompts")
        }
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
        .fixedSize(horizontal: true, vertical: false)
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
                .font(SoulFont.code(10, weight: .regular))
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

/// Tiny indented label under a project that names a git worktree bucket.
/// Rendered only when a project has more than one worktree group or a
/// non-main one — single-main projects keep the original flat look.
private struct WorktreeSubheader: View {
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(SoulColor.fgSubtle)
            Text(label)
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgSubtle)
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }
}

private struct LiveSessionRow: View {
    let session: SoulSession
    var isSelected: Bool = false

    /// Terminal-origin live rows aren't resumable today (the kernel and
    /// gemini-cli minted UUIDs in separate namespaces; SOUL-SOUL-004 is the
    /// real fix). Surface that visually so the click outcome stops being a
    /// surprise: different icon, muted foreground, hover tooltip.
    private var isResumable: Bool { session.origin != .terminal }

    /// Provider-distinguishing glyph for live rows. Falls back to terminal
    /// when we can't resume (no agent file at all).
    private var liveIcon: String {
        guard isResumable else { return "terminal" }
        return ProviderIcon.symbol(forLiveProvider: session.liveProvider)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: liveIcon)
                .font(.system(size: 10))
                .foregroundStyle(iconColor)
                .padding(.leading, 14)
            Text(title)
                .font(SoulFont.ui(12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(relative(session.timestamp))
                .font(SoulFont.code(10))
                .foregroundStyle(SoulColor.fgSubtle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? AnyShapeStyle(SoulColor.accentMuted)
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var iconColor: Color {
        if isSelected { return SoulColor.accent }
        if !isResumable { return SoulColor.fgMuted }
        return SoulColor.fgSubtle
    }

    private var textColor: Color {
        if isSelected { return SoulColor.accent }
        if !isResumable { return SoulColor.fgMuted }
        return SoulColor.fg
    }

    private var tooltip: String {
        isResumable
            ? "Click to resume this conversation."
            : "Started outside Soul-Desktop — clicking will not resume the original conversation (starts fresh)."
    }

    private var title: String {
        let s = (session.intent ?? session.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return "live · \(session.id.prefix(8))…"
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// Central SF Symbol mapping so finalized chats and live rows render with
/// the same provider-distinguishing glyph. Field shapes differ between the
/// two: finalized rows carry `source` ("claude" / "gemini" / "pi-native");
/// live rows carry `liveProvider` ("claude" / "geminiCLI" / nil) which is
/// derived from where the agent's persistence file actually lives.
enum ProviderIcon {
    static func symbol(forSessionSource source: String?) -> String {
        switch source {
        case "claude":    return "hexagon"
        case "gemini":    return "star"
        case "pi-native": return "wand.and.rays"
        default:          return "circle.dotted"
        }
    }

    static func symbol(forLiveProvider liveProvider: String?) -> String {
        switch liveProvider {
        case "claude":    return "hexagon"
        case "geminiCLI": return "star"
        case "pi":        return "wand.and.rays"
        default:          return "circle.dotted"
        }
    }
}
