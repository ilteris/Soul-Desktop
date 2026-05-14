import SwiftUI

struct SidebarView: View {
    @Binding var selectedProject: String?
    var onSelectSession: (SoulSession) -> Void = { _ in }
    var onReplaySession: (SoulSession) -> Void = { _ in }
    var onNewChat: (_ targetProjectID: String?) -> Void = { _ in }
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
    /// Project ID owning the active session. Used to keep the parent
    /// project row visually marked as active even when a session inside
    /// it is selected, and to auto-expand that project so the session
    /// row is on-screen for the user to see.
    var activeProjectId: String? = nil
    /// Current harness selection from AppShell. Plumbed into `liveSessions`
    /// so we only surface rows whose recorded provider matches what's
    /// actually going to be spawned at click time.
    var currentProvider: Provider = .geminiCLI
    /// Phantom row owned by AppShell representing a fresh "New chat" composer.
    /// Merged into its project's chat list so the user has a sidebar anchor
    /// for the draft before any send has resolved a real session id.
    var draftSession: SoulSession? = nil
    // Seed projects synchronously from PROJECTS.json so the first render
    // already has data instead of flashing an empty "Projects" + "No chats"
    // header for the ~250ms until the async reload finishes.
    @State private var projects: [SoulProject] = SoulRegistry.activeProjects()
    @State private var sessions: [SoulSession] = []
    @State private var liveSessions: [String: [SoulSession]] = [:]  // project key → live rows
    /// Finalized sessions for every project, loaded up front in `reload()`.
    /// Replaces the old single-project `sessions` state for the merged
    /// chat list under each expanded project node.
    @State private var finalizedByProject: [String: [SoulSession]] = [:]
    @State private var chatSourceFilter: String? = nil   // nil = all
    @State private var hideUntitled: Bool = false
    /// When false (default), the sidebar hides session rows whose content
    /// cannot actually be loaded — orphan kernel UUIDs whose provider chat
    /// file is missing or stub-only. The filter menu has a toggle to flip
    /// this on for cases where the user still wants to see the history
    /// record even if the transcript itself is gone.
    @AppStorage("soul.sidebar.showUnreadable") private var showUnreadable: Bool = false
    /// Loadable session IDs computed off-main on each reload. Both live
    /// rows (under expanded projects) and the bottom Chats list filter
    /// against this set when `showUnreadable` is false.
    @State private var loadableIDs: Set<String> = []
    /// Per-project session count for the sidebar badge. Persisted to
    /// UserDefaults so subsequent launches paint instantly; the fresh scan
    /// then runs in the background and overwrites stale entries.
    @State private var sessionCounts: [String: Int] = Self.cachedSessionCounts()

    private static let sessionCountsCacheKey = "soul.sidebar.sessionCounts.v1"
    private static func cachedSessionCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: sessionCountsCacheKey) as? [String: Int]) ?? [:]
    }
    private static func writeSessionCountsCache(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: sessionCountsCacheKey)
    }
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0
    @State private var watcher: RegistryWatcher? = nil
    /// SOUL-SOUL_DESKTOP-036: per-project expand/collapse state, persisted
    /// to UserDefaults keyed by project id. Default = expanded for the
    /// selected project, collapsed for others. Mirrored into local state so
    /// SwiftUI animates the toggle and the chevron stays in sync.
    @State private var projectExpanded: [String: Bool] = [:]
    @State private var repairToast: String? = nil
    @State private var repairToastTaskId: UUID = UUID()
    @State private var ambiguousRepair: AmbiguousRepairContext? = nil

    /// Context bag for the ambiguous-result popover. Carries the candidate
    /// list plus the session metadata we need to write the chosen mapping.
    struct AmbiguousRepairContext: Identifiable {
        let id = UUID()
        let projectKey: String
        let sessionId: String
        let provider: String
        let cwd: String
        let candidates: [String]
    }

    private var filterIsActive: Bool { chatSourceFilter != nil || hideUntitled }

    private var filteredSessions: [SoulSession] {
        sessions.filter { s in
            if let f = chatSourceFilter, (s.source ?? "") != f { return false }
            if hideUntitled {
                let title = (s.intent ?? s.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { return false }
            }
            // Bottom Chats list = finalized sessions. These always have
            // replay value (the finalize JSON carries summary/intent + the
            // hooks ledger is intact), so we don't apply the transcript
            // loadability filter here. Only the live rows under expanded
            // projects use that filter to hide orphan kernel dirs.
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Only "New chat" has a wired handler today; the
                        // others are placeholders for upcoming surfaces.
                        if action.label == "New chat" { onNewChat(nil) }
                    }
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

            // Single scroller: projects with their merged chat lists nested
            // under each expanded project. The old "Chats" section at the
            // bottom is gone — live vs finalized was an internal-state
            // distinction users don't care about. A chat is a chat.
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Menu {
                        Picker("Source", selection: $chatSourceFilter) {
                            Text("All sources").tag(String?.none)
                            Text("Claude").tag(String?.some("claude"))
                            Text("Gemini").tag(String?.some("gemini"))
                            Text("Pi").tag(String?.some("pi-native"))
                        }
                        Toggle("Hide untitled", isOn: $hideUntitled)
                        Toggle("Show unreadable sessions", isOn: $showUnreadable)
                    } label: {
                        Image(systemName: filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                            .font(.system(size: 12))
                            .foregroundStyle(filterIsActive ? SoulColor.accent : SoulColor.fgMuted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Filter chats")
                }
                .padding(.top, 4)
                .padding(.bottom, 4)
                .padding(.horizontal, 16)

                projectsScroll
                    .frame(maxHeight: .infinity)
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
        .background(SoulColor.bgElevated)
        // Clip BEFORE shadow so the rounded mask cuts every child view
        // (scroll content, rows, hover backgrounds) — otherwise children
        // paint into the corner area beyond the rounded background shape
        // and leak as "corner artifacts." Shadow sits outside the clip so
        // the lift still reads as soft beyond the rounded edge.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SoulColor.border, lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            repairToastBanner
                .animation(.easeInOut(duration: 0.15), value: repairToast)
        }
        .sheet(item: $ambiguousRepair) { ctx in
            ambiguousRepairSheet(ctx)
        }
        .task { await reload() }
        .onChange(of: activeProjectId) { _, newId in
            // Keep the parent of the active session expanded and primed so
            // the highlighted ChatRow is actually on-screen. Loads its
            // session list lazily if not already cached.
            guard let id = newId else { return }
            if !isExpanded(id) { setExpanded(id, true) }
            Task { await loadProject(id) }
        }
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
    /// Combined per-project chat list: every live session + every finalized
    /// session for the project, deduped by id, sorted by timestamp desc.
    /// Live rows additionally filter by transcript loadability (unless the
    /// user toggled "Show unreadable sessions") — finalized rows always
    /// show because they carry summary/intent + a hooks ledger that
    /// Replay can render even without a provider transcript.
    @ViewBuilder
    private var projectsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(projects) { project in
                    projectRow(project)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func projectRow(_ project: SoulProject) -> some View {
        ProjectSidebarRow(
            project: project,
            isSelected: activeProjectId == project.id
                || (selectedProject == project.id
                    && activeSessionId == nil
                    && activeReplaySessionId == nil),
            isExpanded: expansionBinding(for: project.id),
            chatCount: sessionCounts[project.id] ?? 0,
            onSelect: { selectedProject = project.id },
            onNewChat: {
                onNewChat(project.id)
            }
        )
        if isExpanded(project.id) {
            ForEach(mergedChatList(for: project)) { session in
                chatRow(session)
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ session: SoulSession) -> some View {
        ChatRow(
            session: session,
            isSelected: session.id == activeSessionId,
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
            if repairableProvider(for: session) != nil {
                Divider()
                Button("Repair session link") {
                    repairSessionLink(session)
                }
            }
        }
    }

    fileprivate func mergedChatList(for project: SoulProject) -> [SoulSession] {
        var lives = (liveSessions[project.id] ?? []).filter { live in
            showUnreadable || loadableIDs.contains(live.id)
        }
        if let draft = draftSession, draft.project == project.id {
            lives.insert(draft, at: 0)
        }
        let finalized = (finalizedByProject[project.id] ?? []).filter { s in
            if let f = chatSourceFilter, (s.source ?? "") != f { return false }
            if hideUntitled {
                let title = (s.intent ?? s.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { return false }
            }
            return true
        }
        var dedup: [String: SoulSession] = [:]
        for s in (lives + finalized) {
            // Finalized wins on tie (it has richer metadata: summary, source)
            if let existing = dedup[s.id], existing.summary != nil || existing.intent != nil {
                continue
            }
            dedup[s.id] = s
        }
        return dedup.values.sorted { $0.timestamp > $1.timestamp }
    }

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
        // Only load the project list at startup — per-project session scans
        // happen lazily when the user expands a folder. For accounts with
        // many projects × hundreds of finalized JSONs (soul, job-hunt) this
        // turns a multi-second startup stall into a single PROJECTS.json read.
        let projs = SoulRegistry.activeProjects()
        // Cheap session-count pass (no JSON parsing) so collapsed projects
        // still get an accurate badge without paying the lazy-load cost.
        let counts: [String: Int] = await Task.detached(priority: .userInitiated) {
            var c: [String: Int] = [:]
            for p in projs {
                let n = SoulRegistry.sessionCount(forProject: p.id)
                if n > 0 { c[p.id] = n }
            }
            return c
        }.value
        await MainActor.run {
            self.projects = projs
            self.sessionCounts = counts
            Self.writeSessionCountsCache(counts)
            if selectedProject == nil || projs.first(where: { $0.id == selectedProject }) == nil {
                selectedProject = projs.first?.id
            }
        }
        // Prime any project the user already had expanded from a prior launch
        // so badges + rows are present on first paint.
        for p in projs where isExpanded(p.id) {
            await loadProject(p.id)
        }
        // Also expand + prime the active session's project on first mount so
        // the highlighted ChatRow is immediately visible.
        if let active = activeProjectId, projs.contains(where: { $0.id == active }) {
            if !isExpanded(active) { setExpanded(active, true) }
            await loadProject(active)
        }
        await reloadSessions()
    }

    /// Off-main per-project scan: finalized + live + loadability. Idempotent —
    /// safe to call again on expand-toggle to refresh a stale folder.
    fileprivate func loadProject(_ projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId })
            ?? SoulRegistry.activeProjects().first(where: { $0.id == projectId })
        else { return }
        let providerRaw = currentProvider.rawValue
        struct Result {
            var live: [SoulSession] = []
            var finalized: [SoulSession] = []
            var loadable: Set<String> = []
        }
        let result: Result = await Task.detached(priority: .userInitiated) {
            var r = Result()
            r.live = SoulRegistry.liveSessions(forProject: project.id, projectPath: project.path, currentProvider: providerRaw)
            r.finalized = SoulRegistry.sessions(forProject: project.id, limit: 20, projectPath: project.path)
            let ids = Set(r.live.map { $0.id } + r.finalized.map { $0.id })
            for sid in ids where SessionLoadability.canLoadFromDisk(sessionId: sid, project: project) {
                r.loadable.insert(sid)
            }
            return r
        }.value
        await MainActor.run {
            if result.live.isEmpty {
                self.liveSessions.removeValue(forKey: projectId)
            } else {
                self.liveSessions[projectId] = result.live
            }
            if result.finalized.isEmpty {
                self.finalizedByProject.removeValue(forKey: projectId)
            } else {
                self.finalizedByProject[projectId] = result.finalized
            }
            self.loadableIDs.formUnion(result.loadable)
        }
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

    /// Maps a row's recorded source to the provider key
    /// `SoulRegistry.backfillNativeSessionID` understands. Returns nil for
    /// pi-native (out of scope per -022) and for rows where neither the
    /// session source nor the active harness can give us a content-match
    /// target.
    private func repairableProvider(for session: SoulSession) -> String? {
        switch session.source {
        case "gemini": return "geminiCLI"
        case "claude": return "claude"
        case "pi-native": return nil
        default: break
        }
        switch currentProvider {
        case .geminiCLI: return "geminiCLI"
        case .claude:    return "claude"
        case .pi:        return nil
        case .codex:     return nil
        }
    }

    private func repairSessionLink(_ session: SoulSession) {
        guard let provider = repairableProvider(for: session),
              let path = projects.first(where: { $0.id == session.project })?.path
        else { return }
        let projectKey = session.project
        let sessionId = session.id
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SoulRegistry.backfillNativeSessionID(
                    projectKey: projectKey,
                    sessionId: sessionId,
                    provider: provider,
                    cwd: path
                )
            }.value
            await reloadSessions()
            switch result {
            case .hit(let uuid):
                showRepairToast("Linked to \(uuid.prefix(8))…")
            case .alreadyMapped(let uuid):
                showRepairToast("Already linked to \(uuid.prefix(8))…")
            case .miss:
                showRepairToast("No matching agent transcript found")
            case .ambiguous(let candidates):
                ambiguousRepair = AmbiguousRepairContext(
                    projectKey: projectKey,
                    sessionId: sessionId,
                    provider: provider,
                    cwd: path,
                    candidates: candidates
                )
            case .unsupported:
                showRepairToast("Provider not supported for repair")
            }
        }
    }

    /// SOUL-SOUL_DESKTOP-036: read the per-project expand flag. Default is
    /// always false (collapsed). The previous fallback to
    /// `projectId == selectedProject` caused un-animated opens on the first
    /// click of any project: onSelect() flipped selectedProject before
    /// withAnimation ran, the fallback then read true, and the body
    /// re-rendered expanded without an animation transaction. With a flat
    /// false default, the only path to true is the toggle inside
    /// withAnimation — every open is animated.
    private func isExpanded(_ projectId: String) -> Bool {
        if let local = projectExpanded[projectId] { return local }
        let key = "soul.sidebar.expanded.\(projectId)"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return false
    }

    private func setExpanded(_ projectId: String, _ value: Bool) {
        projectExpanded[projectId] = value
        UserDefaults.standard.set(value, forKey: "soul.sidebar.expanded.\(projectId)")
        if value {
            Task { await loadProject(projectId) }
        }
    }

    private func expansionBinding(for projectId: String) -> Binding<Bool> {
        Binding(
            get: { isExpanded(projectId) },
            set: { setExpanded(projectId, $0) }
        )
    }

    private func showRepairToast(_ text: String) {
        repairToast = text
        // Cancel any prior auto-dismiss before scheduling the new one — a
        // rapid second click would otherwise clear the new toast early.
        let taskId = UUID()
        repairToastTaskId = taskId
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if repairToastTaskId == taskId {
                repairToast = nil
            }
        }
    }

    @ViewBuilder
    private var repairToastBanner: some View {
        if let toast = repairToast {
            Text(toast)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func ambiguousRepairSheet(_ ctx: AmbiguousRepairContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Multiple matching transcripts")
                .font(SoulFont.ui(14)).bold()
            Text("Two or more agent transcripts have the same first prompt as this chat. Pick the one to link.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
            ForEach(ctx.candidates, id: \.self) { uuid in
                Button {
                    SoulRegistry.writeNativeSessionID(
                        projectKey: ctx.projectKey,
                        sessionId: ctx.sessionId,
                        nativeId: uuid,
                        provider: ctx.provider,
                        cwd: ctx.cwd
                    )
                    ambiguousRepair = nil
                    Task {
                        await reloadSessions()
                        showRepairToast("Linked to \(uuid.prefix(8))…")
                    }
                } label: {
                    HStack {
                        Text(uuid).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("Use this").font(SoulFont.ui(11)).foregroundStyle(SoulColor.accent)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(SoulColor.sidebar, in: RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Spacer()
                Button("Cancel") { ambiguousRepair = nil }
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}
struct ChatRow: View {
    let session: SoulSession
    var isSelected: Bool = false
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
                    .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fgSubtle)
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
                    .font(SoulFont.ui(13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(relative(session.timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .layoutPriority(1)
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
        .background(
            (isSelected
                ? SoulColor.accent.opacity(0.22)
                : (hovering ? SoulColor.surface.opacity(0.6) : Color.clear)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(SoulColor.accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var sourceIcon: String {
        if session.origin == .terminal { return "terminal" }
        return ProviderIcon.symbol(forSessionSource: session.source)
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
///
/// SOUL-SOUL_DESKTOP-036: a leading chevron toggles per-project expand/collapse.
/// Expand state lives in the parent view (passed in as a Binding) so it can be
/// persisted to UserDefaults keyed by project id and survive relaunches.
private struct ProjectSidebarRow: View {
    let project: SoulProject
    let isSelected: Bool
    @Binding var isExpanded: Bool
    var chatCount: Int = 0
    let onSelect: () -> Void
    let onNewChat: () -> Void

    @State private var hovering = false
    @State private var buttonHover = false

    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: isExpanded ? "folder.fill" : "folder", color: SoulColor.fgMuted)
            Text(project.name)
                .font(SoulFont.ui(15))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            if chatCount > 0 {
                Text("\(chatCount)")
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SoulColor.surface, in: Capsule())
            }
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
            hovering
                ? AnyShapeStyle(SoulColor.fg.opacity(0.06))
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-click toggles expand/collapse. `onSelect` still fires so
            // the rest of the app (composer footer chip, new-chat target)
            // tracks the most recently clicked project, but the row itself
            // shows no "selected" styling — hover + expanded chevron carry
            // all the visual feedback the user wanted.
            onSelect()
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
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
        case "claude":    return "circle.hexagongrid"
        case "gemini":    return "sparkles"
        case "pi-native": return "wand.and.rays"
        default:          return "circle.dotted"
        }
    }

    static func symbol(forLiveProvider liveProvider: String?) -> String {
        switch liveProvider {
        case "claude":    return "circle.hexagongrid"
        case "geminiCLI": return "sparkles"
        case "pi":        return "wand.and.rays"
        default:          return "circle.dotted"
        }
    }
}
