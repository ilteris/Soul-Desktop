import SwiftUI

struct SidebarView: View {
    @Binding var selectedProject: String?
    var onSelectSession: (SoulSession) -> Void = { _ in }
    var onReplaySession: (SoulSession) -> Void = { _ in }
    var onNewChat: (_ targetProjectID: String?) -> Void = { _ in }
    /// Cross-provider branch: AppShell looks up the active ThreadController
    /// for the session (or hydrates from kernel ledger), then composes a
    /// branch-seed via background LLM and pre-fills the composer.
    var onBranch: (SoulSession, Provider) -> Void = { _, _ in }
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
    // Seed projects synchronously from PROJECTS.json so the first render
    // already has data instead of flashing an empty "Projects" + "No chats"
    // header for the ~250ms until the async reload finishes.
    @State private var projects: [SoulProject] = SoulRegistry.activeProjects()
    /// Unified per-project session list, populated by `SoulRegistry.allSessions`.
    /// Each entry carries derived `isLive` / `isDirty` / `loadable` /
    /// `replayable` / `substantive` flags so the sidebar doesn't have to
    /// reach back into the registry for filtering decisions.
    @State private var sessionsByProject: [String: [SoulSession]] = [:]
    @State private var chatSourceFilter: String? = nil   // nil = all
    @State private var hideUntitled: Bool = false
    /// When false (default), the sidebar hides session rows whose provider
    /// transcript file is missing and whose hooks ledger is also empty —
    /// i.e. orphan kernel UUIDs that would dead-end on click. Rows that are
    /// replay-only (transcript gone, hooks intact) still appear by default
    /// because Replay can render them. Toggle this on to also see fully
    /// orphan rows for archaeological purposes.
    @AppStorage("soul.sidebar.showUnreadable") private var showUnreadable: Bool = false
    @State private var archiveStore = ArchiveStore.shared
    @State private var starStore = StarStore.shared
    @State private var archivedExpanded: [String: Bool] = [:]
    /// Per-project "show all sessions" toggle. Default-collapsed: only the
    /// most-recent `sessionPageSize` chats render until the user clicks
    /// "Show N more" on a project with a deeper history.
    @State private var sessionListExpanded: Set<String> = []
    private let sessionPageSize: Int = 20
    @State private var pendingDelete: DeleteConfirmation? = nil

    /// One-shot confirmation context for the destructive delete action.
    /// Identifiable so SwiftUI's `.alert(item:)` modifier can drive it.
    struct DeleteConfirmation: Identifiable {
        let id = UUID()
        let session: SoulSession
    }
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

                buildBadge
            }
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
        // Repair toast was previously overlaid here; lifted to AppShell so
        // the banner sits at the top-center of the whole window rather than
        // being clipped inside the sidebar's narrow column.
        .sheet(item: $ambiguousRepair) { ctx in
            ambiguousRepairSheet(ctx)
        }
        .alert(item: $pendingDelete) { ctx in
            Alert(
                title: Text("Move chat to Trash?"),
                message: Text("Trashes the kernel ledger, finalize summary, and the provider's chat file. Files appear in ~/.Trash and can be restored from Finder."),
                primaryButton: .destructive(Text("Move to Trash")) {
                    deleteSessionToTrash(ctx.session)
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(13))
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
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(NSScrollViewConfigurator { sv in
            sv.verticalScrollElasticity = .none
            sv.horizontalScrollElasticity = .none
        })
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
            chatCount: filteredChatCount(for: project) ?? (sessionCounts[project.id] ?? 0),
            onSelect: { selectedProject = project.id },
            onNewChat: {
                onNewChat(project.id)
            }
        )
        if isExpanded(project.id) {
            let all = mergedChatList(for: project)
            let archivedSet = archiveStore.archivedIDs(forProject: project.id)
            let active = all.filter { !archivedSet.contains($0.id) }
            let archived = all.filter { archivedSet.contains($0.id) }
            let showAll = sessionListExpanded.contains(project.id)
            let visible = showAll ? active : Array(active.prefix(sessionPageSize))
            ForEach(visible) { session in
                chatRow(session)
            }
            if active.count > visible.count {
                showMoreButton(for: project, hiddenCount: active.count - visible.count)
            } else if showAll && active.count > sessionPageSize {
                showLessButton(for: project)
            }
            if !archived.isEmpty {
                archivedDisclosure(for: project, archived: archived)
            }
        }
    }

    @ViewBuilder
    private func showMoreButton(for project: SoulProject, hiddenCount: Int) -> some View {
        Button {
            sessionListExpanded.insert(project.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text("Show \(hiddenCount) more")
                    .font(SoulFont.ui(12, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
            }
            .padding(.leading, 18)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulHover)
    }

    @ViewBuilder
    private func showLessButton(for project: SoulProject) -> some View {
        Button {
            sessionListExpanded.remove(project.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text("Show less")
                    .font(SoulFont.ui(12, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
            }
            .padding(.leading, 18)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulHover)
    }

    @ViewBuilder
    private func archivedDisclosure(for project: SoulProject, archived: [SoulSession]) -> some View {
        let expanded = archivedExpanded[project.id] ?? false
        Button {
            archivedExpanded[project.id] = !expanded
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
                Image(systemName: "archivebox")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text("Archived")
                    .font(SoulFont.ui(12, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("\(archived.count)")
                    .font(SoulFont.code(12))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
            }
            .padding(.leading, 18)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulHover)
        if expanded {
            ForEach(archived) { session in
                chatRow(session)
                    .opacity(0.65)
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ session: SoulSession) -> some View {
        ChatRow(
            session: session,
            isSelected: session.id == activeSessionId,
            isStarred: starStore.isStarred(session.id, project: session.project),
            onReplay: { onReplaySession(session) },
            isActiveReplay: session.id == activeReplaySessionId,
            replayProgress: replayProgress,
            replayIndex: replayIndex,
            replayTotal: replayTotal,
            replayPrompts: replayPrompts,
            replayReplies: replayReplies
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Keep the sidebar's selectedProject in sync with the row's
            // parent project. AppShell.loadSession also coerces this, but
            // setting it here means everything else binding to
            // `selectedProject` (filter chips, expansion state, etc.)
            // updates atomically with the click instead of in a later
            // dispatch tick.
            if selectedProject != session.project {
                selectedProject = session.project
            }
            onSelectSession(session)
        }
        .contextMenu {
            Button("Open chat") { onSelectSession(session) }
            Button("Replay…") { onReplaySession(session) }
            Divider()
            if starStore.isStarred(session.id, project: session.project) {
                Button("Unstar") {
                    starStore.unstar(session.id, project: session.project)
                }
            } else {
                Button("Star (pin to top)") {
                    starStore.star(session.id, project: session.project)
                }
            }
            Divider()
            if archiveStore.isArchived(session.id, project: session.project) {
                Button("Unarchive") {
                    archiveStore.unarchive(session.id, project: session.project)
                }
                // Two-step delete: only available on archived rows so a
                // fat-finger on the main list can't trash a live session.
                // Files move to ~/.Trash (recoverable), not `rm`.
                Divider()
                Button("Delete (move to Trash)…", role: .destructive) {
                    pendingDelete = DeleteConfirmation(session: session)
                }
            } else {
                Button("Archive") {
                    archiveStore.archive(session.id, project: session.project)
                }
            }
            if repairableProvider(for: session) != nil {
                Divider()
                Button("Repair session link") {
                    repairSessionLink(session)
                }
            }
        }
    }

    /// Move every on-disk artifact for a session to ~/.Trash:
    ///   - kernel ledger:  ~/soul_registry/sessions/<proj>/<sid>/
    ///   - finalize JSON:  ~/soul_registry/sessions/<proj>/*<sid>.json
    ///   - Claude file:    ~/.claude/projects/<encoded-cwd>/<sid>.jsonl
    ///   - Gemini chat:    ~/.gemini/tmp/<basename>(-N)/chats/*<first8>*
    ///   - Codex transcript sibling lives inside the ledger dir, swept above
    /// then remove the row from the archive set + invalidate the cache so
    /// the sidebar repaints without it. Returns the count of trashed paths.
    @discardableResult
    fileprivate func deleteSessionToTrash(_ session: SoulSession) -> Int {
        let fm = FileManager.default
        var paths: [String] = []

        // Kernel ledger dir.
        let kernelDir = NSHomeDirectory() + "/soul_registry/sessions/\(session.project)/\(session.id)"
        if fm.fileExists(atPath: kernelDir) { paths.append(kernelDir) }

        // Finalize JSON siblings (timestamp-prefixed and bare).
        let projDir = NSHomeDirectory() + "/soul_registry/sessions/\(session.project)"
        if let entries = try? fm.contentsOfDirectory(atPath: projDir) {
            for name in entries where name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if stem == session.id || stem.hasSuffix("_\(session.id)") {
                    paths.append("\(projDir)/\(name)")
                }
            }
        }

        // Provider files. Resolve the project's cwd from PROJECTS.
        if let project = SoulRegistry.projects().first(where: { $0.id == session.project }) {
            let trimmed = project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
            // Claude
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudePath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(session.id).jsonl"
            if fm.fileExists(atPath: claudePath) { paths.append(claudePath) }
            // Gemini (walk basename + -N siblings)
            let base = (trimmed as NSString).lastPathComponent
            let geminiBase = NSHomeDirectory() + "/.gemini/tmp"
            let first8 = String(session.id.prefix(8))
            if let projects = try? fm.contentsOfDirectory(atPath: geminiBase) {
                for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
                    let chatsDir = "\(geminiBase)/\(proj)/chats"
                    guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
                    for name in files where name.contains(first8) {
                        paths.append("\(chatsDir)/\(name)")
                    }
                }
            }
        }

        // Move to Trash via NSWorkspace.recycle (uses Finder's recoverable
        // path — files appear in ~/.Trash and can be restored).
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            NSWorkspace.shared.recycle(urls) { _, _ in }
        }

        archiveStore.unarchive(session.id, project: session.project)
        SoulRegistry.invalidateCache(forProject: session.project)
        // Reload sessions so the sidebar repaints without the row.
        Task { await loadProject(session.project) }
        return urls.count
    }

    /// Per-project chat list for the sidebar. One disk-derived row per
    /// session UUID, optionally augmented with synthetic rows for in-memory
    /// ThreadControllers that haven't written hooks.jsonl yet.
    ///
    /// Filter pipeline (default-on, all overridable from the filter menu):
    ///   - `substantive`            → drop crash-residue dirs
    ///   - `loadable || replayable` → drop fully orphan rows (toggle: showUnreadable)
    ///   - `chatSourceFilter`       → optional provider scope
    ///   - `hideUntitled`           → optional drop of empty-titled rows
    /// SOUL-SOUL_DESKTOP-148: derive the badge count from the same filter
    /// the rendered list uses (substantive + loadable/replayable + provider
    /// filter + hideUntitled), minus archived. Returns nil if the project's
    /// sessions haven't been loaded yet — caller falls back to the raw
    /// disk-count badge in that case (which gets corrected on first expand
    /// when the Stage-1 scan populates sessionsByProject).
    fileprivate func filteredChatCount(for project: SoulProject) -> Int? {
        guard sessionsByProject[project.id] != nil else { return nil }
        let merged = mergedChatList(for: project)
        let archivedSet = archiveStore.archivedIDs(forProject: project.id)
        return merged.filter { !archivedSet.contains($0.id) }.count
    }

    fileprivate func mergedChatList(for project: SoulProject) -> [SoulSession] {
        let onDisk = (sessionsByProject[project.id] ?? []).filter { s in
            if !s.substantive { return false }
            if !showUnreadable, !(s.loadable || s.replayable) { return false }
            if let f = chatSourceFilter, (s.source ?? s.liveProvider ?? "") != f { return false }
            if hideUntitled {
                let title = (s.intent ?? s.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { return false }
            }
            return true
        }
        // Index by id so synthetic rows can merge titles cleanly instead of
        // duplicating. Live in-memory titles win — a freshly-renamed thread
        // shouldn't get stomped by the stale disk record.
        var byId: [String: SoulSession] = [:]
        for s in onDisk { byId[s.id] = s }

        for ctrl in activeThreads where ctrl.project.id == project.id {
            let sid = ctrl.sessionId ?? "thread-\(ctrl.id)"
            let synthetic = SoulSession(
                id: sid,
                project: project.id,
                // Stable: use the disk row's existing timestamp when merging
                // (line below), and `startedAt` only as a fallback when the
                // session has no disk row yet. Previously this was
                // `max(lastActivityAt, startedAt)`, which made the row pop to
                // the top of the sidebar every time the user typed — which
                // shuffled the list mid-conversation. Disabled per user
                // request: the sort should not reorder on activity.
                timestamp: ctrl.startedAt,
                intent: ctrl.displayTitle,
                source: ctrl.provider.rawValue,
                isLive: true,
                writer: .soulDesktop,
                liveProvider: ctrl.provider.rawValue,
                loadable: true,
                replayable: true,
                substantive: true,
                isWorking: ctrl.isWorking
            )
            if let existing = byId[sid] {
                // Take the disk row's metadata (source, worktree, status) and
                // overlay the live title + timestamp from the controller.
                var merged = existing
                let t = ctrl.displayTitle
                if !t.isEmpty { merged.intent = t }
                // Keep the disk row's original timestamp — don't bump it from
                // the live controller's startedAt / lastActivityAt. Live
                // activity should NOT reorder the sidebar.
                //
                // Intentionally preserve `existing.writer` and `existing.isLive`:
                // opening a row to view it doesn't make us its author or
                // revive a finalized session. Once the user sends, the
                // controller's appendHook writes NativeSessionID/Title to
                // the ledger and the next disk scan reflects writer=.soulDesktop
                // naturally. Same for isLive — true real state, not derived
                // from "is a controller pointed at this row."
                merged.liveProvider = ctrl.provider.rawValue
                merged.isWorking = ctrl.isWorking
                merged.promptCount = ctrl.items.filter { if case .userMessage = $0 { return true } else { return false } }.count
                byId[sid] = merged
            } else {
                byId[sid] = synthetic
            }
        }
        if let draft = draftSession, draft.project == project.id {
            byId[draft.id] = draft
        }
        // SOUL-SOUL_DESKTOP-198: starred sessions float to the top within
        // their project group; ties (both starred or both unstarred) keep
        // the existing recency sort.
        let starred = starStore.starredIDs(forProject: project.id)
        return byId.values.sorted { a, b in
            let aStar = starred.contains(a.id)
            let bStar = starred.contains(b.id)
            if aStar != bStar { return aStar }
            return a.timestamp > b.timestamp
        }
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
        // SOUL-SOUL_DESKTOP-149: prime sessionsByProject from the on-disk
        // session cache for EVERY project, not just the ones the user had
        // expanded last launch. Cold-start launches inherit the previous
        // session's parsed data so badges show filtered counts and first
        // expand renders instantly. Cache is mtime-validated — projects
        // whose ledgers changed since the last write get nil here and
        // hit Stage-1 on first expand.
        let primed: [(String, [SoulSession])] = await Task.detached(priority: .userInitiated) {
            var out: [(String, [SoulSession])] = []
            for p in projs {
                if let cached = SoulRegistry.cachedSessions(forProject: p.id), !cached.isEmpty {
                    out.append((p.id, cached))
                }
            }
            return out
        }.value
        await MainActor.run {
            for (key, rows) in primed where sessionsByProject[key] == nil {
                sessionsByProject[key] = rows
            }
        }
        // Refresh any project the user already had expanded from a prior
        // launch so freshly-changed sessions get re-rendered (cache may
        // have been invalidated above, in which case loadProject does the
        // full disk scan). No auto-expansion at startup — every project
        // starts collapsed unless the user has explicitly opened it.
        for p in projs where isExpanded(p.id) {
            await loadProject(p.id)
        }
        await reloadSessions()
    }

    /// Off-main per-project scan via `SoulRegistry.allSessions`. Idempotent —
    /// safe to call again on expand-toggle to refresh a stale folder. Result
    /// already carries `substantive`/`loadable`/`replayable` flags so the
    /// sidebar doesn't have to re-check disk.
    ///
    /// SOUL-SOUL_DESKTOP-145: two-stage to match the render-time pagination.
    /// Stage 1 scans the most-recent `sessionPageSize` (20) sessions for
    /// fast initial paint. Stage 2 runs the full 100-session scan in the
    /// background and replaces sessionsByProject when ready. For projects
    /// with hundreds of sessions (Soul OS at 111), users see rows in tens
    /// of ms instead of hundreds.
    fileprivate func loadProject(_ projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId })
            ?? SoulRegistry.activeProjects().first(where: { $0.id == projectId })
        else { return }

        // Stage 1: fast scan, bounded to the page size we'll actually render.
        let quickLimit = sessionPageSize
        let quickRows: [SoulSession] = await Task.detached(priority: .userInitiated) {
            SoulRegistry.allSessions(forProject: project.id, limit: quickLimit, projectPath: project.path)
        }.value
        await MainActor.run {
            if !quickRows.isEmpty {
                self.sessionsByProject[projectId] = quickRows
            }
        }

        // Stage 2: full scan in background. The default limit (100) covers
        // the "Show more" expanded case. Warm the cache so subsequent
        // reloadSessions paint-instant paths see the full list.
        let fullRows: [SoulSession] = await Task.detached(priority: .background) {
            let r = SoulRegistry.allSessions(forProject: project.id, projectPath: project.path)
            SoulRegistry.warmCache(forProject: project.id, sessions: r)
            return r
        }.value
        await MainActor.run {
            // Preserve previous rows on empty (defensive against transient
            // disk-read churn). A genuinely empty project gets cleared
            // elsewhere when its row count is known to be zero.
            if !fullRows.isEmpty {
                self.sessionsByProject[projectId] = fullRows
            }
        }
    }

    private func reloadSessions() async {
        guard let key = selectedProject else { return }
        let path = projects.first(where: { $0.id == key })?.path

        // 1. Paint cached data instantly so switching feels snappy.
        if let cached = SoulRegistry.cachedSessions(forProject: key), !cached.isEmpty {
            await MainActor.run {
                self.sessionsByProject[key] = cached
            }
        }

        // 2. Fresh scan off the main actor — the file I/O is synchronous but
        //    we don't want any UI tick coupling to disk latency.
        let rows: [SoulSession] = await Task.detached(priority: .userInitiated) {
            let r = SoulRegistry.allSessions(forProject: key, projectPath: path)
            SoulRegistry.warmCache(forProject: key, sessions: r)
            return r
        }.value

        await MainActor.run {
            // Preserve the previous list on an empty scan. Transient empty
            // results (mid-write directory state, brief I/O hiccup) used to
            // wipe `sessionsByProject[key]` and cause every row to vanish
            // for ~10s until the next refresh. Only overwrite when the
            // fresh scan actually produced rows.
            guard !rows.isEmpty else { return }
            // SOUL-SOUL_DESKTOP-193: non-regressing merge for turn counts.
            // Opening a session triggers a NativeSessionID hook write,
            // which fires RegistryWatcher → reloadSessions. The fresh scan
            // can race the partial write and return promptCount=0 for that
            // row, blanking "96 turns · 19m ago" to just "19m ago" until
            // the next scan. Carry forward the prior row's counts when
            // the fresh scan regressed them to zero.
            let prior = self.sessionsByProject[key] ?? []
            let priorById = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
            let merged: [SoulSession] = rows.map { fresh in
                guard let old = priorById[fresh.id] else { return fresh }
                var out = fresh
                if fresh.promptCount == 0 && old.promptCount > 0 {
                    out.promptCount = old.promptCount
                }
                if fresh.transcriptTurns == 0 && old.transcriptTurns > 0 {
                    out.transcriptTurns = old.transcriptTurns
                }
                return out
            }
            self.sessionsByProject[key] = merged
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
        // Every launch starts with every project collapsed (outlined folder
        // icon). The user explicitly opens a project to expand it; that
        // state lives in-memory only and resets on app restart. We used to
        // honor a persisted `soul.sidebar.expanded.<id>` pref but it made
        // the prior session's "Soul OS" pop open at launch — clutter the
        // user explicitly didn't want.
        return projectExpanded[projectId] ?? false
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
}
