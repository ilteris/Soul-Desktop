import SwiftUI

struct SidebarView: View {
    var registryStore: SoulRegistryStore = LiveSoulRegistryStore.shared
    @Binding var selectedProject: String?
    var onSelectSession: (SoulSession) -> Void = { _ in }
    var onReplaySession: (SoulSession) -> Void = { _ in }
    var onNewChat: (_ targetProjectID: String?) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    /// Fires after archiveStore.archive completes. AppShell uses this to
    /// tear down the active thread when the user archives the session
    /// currently open in the canvas — otherwise the row disappears from
    /// the sidebar but the chat stays painted in the center pane.
    var onArchive: (SoulSession) -> Void = { _ in }
    /// Cross-provider branch: AppShell looks up the active ThreadController
    /// for the session (or hydrates from kernel ledger), then composes a
    /// branch-seed via background LLM and pre-fills the composer.
    var onBranch: (SoulSession, Provider) -> Void = { _, _ in }
    var onPrewarmSessions: ([SoulSession]) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
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
    /// Live ThreadControllers from AppShell. Surfaced as synthetic sidebar
    /// rows so a session is visible the instant it exists, without waiting
    /// for the kernel to write hooks.jsonl + the registry watcher to fire.
    /// Each controller becomes one row keyed by its sessionId (preferred)
    /// or controller.id (pre-spawn).
    var activeThreads: [ThreadController] = []
    /// SOUL-SOUL_DESKTOP-138: bumped by AppShell every time the user
    /// initiates a new chat (composer send into empty hero, sidebar "+ New
    /// chat" button). Distinguishes user-initiated chats from launch
    /// state restore.
    var newChatNonce: Int = 0
    /// Bumped by AppShell after known project-list mutations, like creating a
    /// project in NewProjectWizard. This keeps the sidebar explicit-refresh
    /// based instead of watching PROJECTS.json continuously.
    var projectListRefreshNonce: Int = 0
    // Seed projects synchronously from PROJECTS.json so the first render
    // already has data instead of flashing an empty "Projects" + "No chats"
    // header for the ~250ms until the async reload finishes.
    @State var projects: [SoulProject] = LiveSoulRegistryStore.shared.activeProjects()
    /// Unified per-project session list, populated by `SoulRegistry.allSessions`.
    /// Each entry carries derived `isLive` / `isDirty` / `loadable` /
    /// `replayable` / `substantive` flags so the sidebar doesn't have to
    /// reach back into the registry for filtering decisions.
    @State var sessionsByProject: [String: [SoulSession]] = [:]
    @State var chatSourceFilter: String? = nil   // nil = all
    @State var hideUntitled: Bool = false
    /// When false (default), the sidebar hides session rows whose provider
    /// transcript file is missing and whose hooks ledger is also empty —
    /// i.e. orphan kernel UUIDs that would dead-end on click. Rows that are
    /// replay-only (transcript gone, hooks intact) still appear by default
    /// because Replay can render them. Toggle this on to also see fully
    /// orphan rows for archaeological purposes.
    @AppStorage("soul.sidebar.showUnreadable") var showUnreadable: Bool = false
    /// SOUL-SOUL_DESKTOP-230: archived sessions hide from the sidebar by
    /// default (the always-visible "Archived (N)" disclosure was clutter
    /// per user feedback). Toggle on to reveal the disclosure when you
    /// need to unarchive or trash an archived row.
    @AppStorage("soul.sidebar.showArchived") var showArchived: Bool = false
    @State var archiveStore = ArchiveStore.shared
    @State var starStore = StarStore.shared
    @State var archivedExpanded: [String: Bool] = [:]
    /// Per-project "show all sessions" toggle. Default-collapsed: only the
    /// most-recent `sessionPageSize` chats render until the user clicks
    /// "Show N more" on a project with a deeper history.
    @State var sessionListExpanded: Set<String> = []
    let sessionPageSize: Int = 5
    /// True when the sidebar's ScrollView is at rest. `scrollToActiveSession`
    /// reads this to decide whether to animate the scroll-to-row (clean,
    /// idle case) or snap (mid-momentum case where stacking an animation
    /// on top of an in-flight scroll caused a SwiftUI layout-recursion
    /// beachball — see comment in SidebarView+Projects).
    @State var sidebarScrollIdle: Bool = true
    @State var pendingDelete: DeleteConfirmation? = nil
    @State var pendingProjectEdit: ProjectEditRequest? = nil
    @State var pendingProjectDelete: ProjectDeleteRequest? = nil

    /// One-shot confirmation context for the destructive delete action.
    /// Identifiable so SwiftUI's `.alert(item:)` modifier can drive it.
    struct DeleteConfirmation: Identifiable {
        let id = UUID()
        let session: SoulSession
        let permanently: Bool
    }
    /// Per-project session count for the sidebar badge. Persisted to
    /// UserDefaults so subsequent launches paint instantly; the fresh scan
    /// then runs in the background and overwrites stale entries.
    @State var sessionCounts: [String: Int] = Self.cachedSessionCounts()
    /// Cached sidebar projection. Views read this prepared model; loading,
    /// filtering, and live-thread changes rebuild it outside SwiftUI body
    /// evaluation so layout/resize invalidations don't redo merge/filter/sort work.
    @State var sidebarRowsProjection = SidebarRowsProjection()

    private static let sessionCountsCacheKey = "soul.sidebar.sessionCounts.v1"
    private static func cachedSessionCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: sessionCountsCacheKey) as? [String: Int]) ?? [:]
    }
    static func writeSessionCountsCache(_ counts: [String: Int]) {
        UserDefaults.standard.set(counts, forKey: sessionCountsCacheKey)
    }
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0
    @State private var watcher: RegistryWatcher? = nil
    /// SOUL-SOUL_DESKTOP-234: per-project timestamp of last full disk scan.
    /// Cross-project browser-history nav (⌘[ / ⌘]) was thrashing
    /// `loadProject` and burning ~200% CPU on `allSessions` because every
    /// project switch re-scanned. RegistryWatcher keeps the currently
    /// selected project fresh; other projects get a short TTL (5s) so
    /// rapid back-and-forth coalesces to a single scan.
    @State var projectLastFullScanAt: [String: Date] = [:]
    /// SOUL-SOUL_DESKTOP-036: per-project expand/collapse state, persisted
    /// to UserDefaults keyed by project id. Default = expanded for the
    /// selected project, collapsed for others. Mirrored into local state so
    /// SwiftUI animates the toggle and the chevron stays in sync.
    @State private var projectExpanded: [String: Bool] = [:]
    /// Toast text is owned by AppShell so the banner can render at the top
    /// center of the full window instead of inside the sidebar's 320pt
    /// column where it gets clipped / hidden. SidebarView writes via this
    /// binding when a repair succeeds / fails / finds ambiguous matches.
    @Binding var repairToast: String?
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
                        .font(SoulFont.ui(11, weight: .regular))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SoulColor.surface, in: Capsule())
                }
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.soulHover)
                .help("Refresh projects")
                Button {
                    if let project = selectedProjectForMutation {
                        pendingProjectEdit = ProjectEditRequest(project: project)
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedProjectForMutation == nil ? SoulColor.fgSubtle.opacity(0.35) : SoulColor.fgMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.soulHover)
                .disabled(selectedProjectForMutation == nil)
                .help("Edit selected project")
                Button {
                    if let project = selectedProjectForMutation {
                        pendingProjectDelete = ProjectDeleteRequest(project: project)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedProjectForMutation == nil ? SoulColor.fgSubtle.opacity(0.35) : SoulColor.fgMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.soulHover)
                .disabled(selectedProjectForMutation == nil)
                .help("Remove selected project")
                Button(action: onNewProject) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.soulHover)
                .help("Add project")
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
                        Toggle("Show Recently Trashed", isOn: $showArchived)
                    } label: {
                        Image(systemName: filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                            .font(.system(size: 13))
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

            HStack(alignment: .center) {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        SoulIcon(name: "gear", color: SoulColor.fgMuted)
                        Text("Settings").font(SoulFont.ui(14)).foregroundStyle(SoulColor.fg)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soulHover)

                Spacer()

                Button {
                    UserDefaults.standard.set("controlPanel", forKey: "soul.appVersion")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "command")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SoulColor.fgMuted)
                        Text("Control")
                            .font(SoulFont.ui(14))
                            .foregroundStyle(SoulColor.fg)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soulHover)
                .help("Open Control Panel")

                Spacer()

                buildBadge
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // SOUL-208: NavigationSplitView's sidebar column already paints
        // the system `.sidebar` vibrancy material. Drop our custom cream
        // bg + rounded inset so the content reads directly on the system
        // surface (Mail/Notes style). No clip, no inner stroke.
        // Repair toast was previously overlaid here; lifted to AppShell so
        // the banner sits at the top-center of the whole window rather than
        // being clipped inside the sidebar's narrow column.
        .sheet(item: $ambiguousRepair) { ctx in
            ambiguousRepairSheet(ctx)
        }
        .sheet(item: $pendingProjectEdit) { ctx in
            ProjectEditSheet(
                project: ctx.project,
                onCancel: { pendingProjectEdit = nil },
                onSaved: {
                    pendingProjectEdit = nil
                    Task { await reload() }
                }
            )
        }
        .sheet(item: $pendingProjectDelete) { ctx in
            ProjectDeleteSheet(
                project: ctx.project,
                onCancel: { pendingProjectDelete = nil },
                onDeleted: {
                    pendingProjectDelete = nil
                    if selectedProject == ctx.project.id {
                        selectedProject = nil
                    }
                    Task { await reload() }
                }
            )
        }
        .alert(item: $pendingDelete) { ctx in
            let name = sessionDisplayName(ctx.session)
            return Alert(
                title: Text(ctx.permanently ? "Delete “\(name)” permanently?" : "Move “\(name)” to Trash?"),
                message: Text(ctx.permanently
                    ? "Permanently deletes the kernel session and its indexed artifacts. This cannot be undone."
                    : "Moves the session into the kernel trash lifecycle state so it can be restored."),
                primaryButton: .destructive(Text(ctx.permanently ? "Delete Permanently" : "Move to Trash")) {
                    if ctx.permanently {
                        deleteSessionPermanently(ctx.session)
                    } else {
                        moveSessionToKernelTrash(ctx.session)
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .task { await reload() }
        .onChange(of: activeProjectId) { _, newId in
            // Prime the session cache when active project changes.
            guard let id = newId else { return }
            Task { await loadProject(id) }
        }
        .onChange(of: newChatNonce) { _, _ in
            // SOUL-SOUL_DESKTOP-138: AppShell bumps this every time the user
            // initiates a new chat (composer-send into the empty hero state,
            // or the sidebar "+ New chat" button). Auto-expand the parent
            // project so the freshly-active live row is visible without an
            // extra click. Restored-at-launch sessions don't bump the nonce,
            // so the launch UX stays "all projects collapsed."
            guard let pid = activeProjectId else { return }
            setExpanded(pid, true)
        }
        .onChange(of: currentProvider) { _, _ in
            // Harness change → re-filter live rows. A row that's valid under
            // Claude isn't valid under Gemini-CLI (and vice-versa).
            Task { await reload() }
        }
        .onChange(of: projectListRefreshNonce) { _, _ in
            Task { await reload() }
        }
        .onChange(of: sidebarProjectionInputSignature) { _, _ in
            rebuildResolvedRows()
        }
        .onChange(of: chatSourceFilter) { _, _ in
            rebuildResolvedRows()
        }
        .onChange(of: hideUntitled) { _, _ in
            rebuildResolvedRows()
        }
        .onChange(of: showUnreadable) { _, _ in
            rebuildResolvedRows()
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
        // SOUL-SOUL_DESKTOP-234: ⌘⇧O = jump to the session row above the
        // currently-active one in the sidebar. Defined in SoulShortcuts.swift;
        // menu bar entry under Navigate → "Previous Session".
        .onReceive(NotificationCenter.default.publisher(for: .soulPreviousSession)) { _ in
            navigateSession(delta: -1)
        }
        // ⌘[ / ⌘] (back/forward through view history) are NOT handled here —
        // AppShell owns the cross-project view history stack.
    }

    /// SOUL-SOUL_DESKTOP-234: walk `delta` rows in the sidebar's creation-sorted
    /// list (delta < 0 = newer, delta > 0 = older). Falls back to the most
    /// recent visible session if nothing is active. Respects the same filter
    /// pipeline the rendered list uses (substantive, loadable/replayable,
    /// source filter, hideUntitled, archived).
    private func navigateSession(delta: Int) {
        // Find which project owns the active session. Prefer activeProjectId
        // when set; otherwise scan projects for the one containing the
        // currently-active session id.
        let projectId: String? = activeProjectId
            ?? projects.first(where: { p in
                // SOUL-SOUL_DESKTOP-234: cheap membership check — no
                // dict-merge + sort just to answer `contains`.
                guard let sid = activeSessionId else { return false }
                if let rows = sessionsByProject[p.id], rows.contains(where: { $0.id == sid }) {
                    return true
                }
                if activeThreads.contains(where: {
                    $0.project.id == p.id && ($0.sessionId == sid || "thread-\($0.id)" == sid)
                }) {
                    return true
                }
                if let draft = draftSession, draft.project == p.id, draft.id == sid {
                    return true
                }
                return false
            })?.id
        guard let pid = projectId,
              projects.first(where: { $0.id == pid }) != nil
        else { return }

        // SOUL-SOUL_DESKTOP-270: same resolve() the sidebar uses, so the
        // keyboard nav order matches the rendered list exactly.
        guard let visible = sidebarRowsProjection.rowsByProject[pid]?.active, !visible.isEmpty else { return }

        if let currentIdx = visible.firstIndex(where: { $0.id == activeSessionId }) {
            let targetIdx = currentIdx + delta
            guard targetIdx >= 0, targetIdx < visible.count else { return }   // no-op at list edge
            onSelectSession(visible[targetIdx])
        } else {
            // No active session in this project's list (or activeSessionId is
            // nil) — jump to the most-recent visible row as the natural
            // landing target regardless of delta direction.
            onSelectSession(visible[0])
        }
    }

    private var selectedProjectForMutation: SoulProject? {
        guard let selectedProject else { return nil }
        return projects.first { $0.id == selectedProject }
    }

    private var buildBadge: some View {
        HStack(spacing: 4) {
            let isDev: Bool = {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }()
            Text(isDev ? "DEV" : "RELEASE")
                .font(SoulFont.ui(9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isDev ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 4))
            
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
        }
    }

    /// Maps a row's recorded source to the provider key
    /// `SoulRegistry.backfillNativeSessionID` understands. Returns nil for
    /// pi-native (out of scope per -022) and for rows where neither the
    /// session source nor the active harness can give us a content-match
    /// target.
    func repairableProvider(for session: SoulSession) -> String? {
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

    func repairSessionLink(_ session: SoulSession) {
        guard let provider = repairableProvider(for: session),
              let path = projects.first(where: { $0.id == session.project })?.path
        else { return }
        let projectKey = session.project
        let sessionId = session.id
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                registryStore.backfillNativeSessionID(
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
    func isExpanded(_ projectId: String) -> Bool {
        // Every launch starts with every project collapsed (outlined folder
        // icon). The user explicitly opens a project to expand it; that
        // state lives in-memory only and resets on app restart. We used to
        // honor a persisted `soul.sidebar.expanded.<id>` pref but it made
        // the prior session's "Soul OS" pop open at launch — clutter the
        // user explicitly didn't want.
        return projectExpanded[projectId] ?? false
    }

    func setExpanded(_ projectId: String, _ value: Bool) {
        projectExpanded[projectId] = value
        UserDefaults.standard.set(value, forKey: "soul.sidebar.expanded.\(projectId)")
        if value {
            Task { await loadProject(projectId) }
        }
    }

    func expansionBinding(for projectId: String) -> Binding<Bool> {
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
                .font(SoulFont.ui(13))
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
                .font(SoulFont.ui(15)).bold()
            Text("Two or more agent transcripts have the same first prompt as this chat. Pick the one to link.")
                .font(SoulFont.ui(13))
                .foregroundStyle(SoulColor.fgMuted)
            ForEach(ctx.candidates, id: \.self) { uuid in
                Button {
                    registryStore.writeNativeSessionID(
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
                        Text("Use this").font(SoulFont.ui(12)).foregroundStyle(SoulColor.accent)
                    }
                }
                .buttonStyle(.soulHover)
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

    /// Human-readable label for the trash/delete confirmation alert. Mirrors
    /// the sidebar row fallback chain so users see the same name they clicked.
    func sessionDisplayName(_ session: SoulSession) -> String {
        let raw = (session.title ?? session.intent ?? session.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = SoulRegistry.stripCommandTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var s = stripped
        let noise = CharacterSet(charactersIn: "#[]-*> ")
        while let first = s.unicodeScalars.first, noise.contains(first) {
            s.removeFirst()
        }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        if s.isEmpty { return "untitled · \(session.id.prefix(8))…" }
        if s.count > 80 { return String(s.prefix(80)) + "…" }
        return s
    }
}
