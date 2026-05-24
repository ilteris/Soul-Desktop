import SwiftUI
import AppKit

extension SidebarView {
    func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.ui(13))
            .foregroundStyle(SoulColor.fgSubtle)
    }

    /// Sentinel label for sessions without a recorded `worktree_path` (i.e.
    /// started in the main checkout). Kept as a constant so the header
    /// suppression check stays explicit.
    var mainWorktreeLabel: String { "(main)" }

    /// Bucket live sessions by their `worktreePath`. Order: main first (so
    /// the common case sits where it always has been), then each worktree
    /// sorted by basename for stable layout. Returned as an array because
    /// SwiftUI ForEach needs deterministic iteration order.
    /// Combined per-project chat list: every live session + every finalized
    /// session for the project, deduped by id, sorted by creation timestamp desc.
    /// Live rows additionally filter by transcript loadability (unless the
    /// user toggled "Show unreadable sessions") — finalized rows always
    /// show because they carry summary/intent + a hooks ledger that
    /// Replay can render even without a provider transcript.
    @ViewBuilder
    var projectsScroll: some View {
        // SOUL-SOUL_DESKTOP-234: wrap in ScrollViewReader so every
        // session-selection change (sidebar click, ⌘[ / ⌘] history nav,
        // restore-on-launch, external open) can pull the active row into
        // view. Without this, ⌘[ across projects would correctly switch
        // the canvas but leave the sidebar scrolled to wherever it was.
        ScrollViewReader { proxy in
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
            .onScrollPhaseChange { _, newPhase, _ in
                // Sidebar scroll-phase gate. We only animate the
                // scroll-to-active-row when the sidebar is at rest;
                // stacking an animation on top of momentum (.decelerating)
                // triggered the SwiftUI MoveTransition.MoveLayout recursion
                // documented in scrollToActiveSession's comment.
                sidebarScrollIdle = (newPhase == .idle)
            }
            .onChange(of: activeSessionId) { _, newId in
                scrollToActiveSession(proxy: proxy, sessionId: newId)
            }
            .onAppear {
                // First render after launch: if we already have an active
                // session (e.g. restored from prior run), pull it into view.
                scrollToActiveSession(proxy: proxy, sessionId: activeSessionId)
            }
        }
    }

    /// SOUL-SOUL_DESKTOP-234: ensure the row for `sessionId` is in view.
    /// Expands the owning project if it's collapsed (rows wouldn't render
    /// otherwise), then schedules a scroll on the next runloop so the
    /// freshly-expanded row exists for `scrollTo` to find.
    func scrollToActiveSession(proxy: ScrollViewProxy, sessionId: String?) {
        guard let sid = sessionId else { return }
        // SOUL-SOUL_DESKTOP-234: was calling mergedChatList per project just
        // to test membership — building a sorted dict-merged list to answer
        // a `contains` question. Direct scan over the underlying disk rows
        // and active threads is O(M) per project with zero allocations.
        //
        // SOUL-SOUL_DESKTOP-246 follow-up: prefer activeProjectId when set
        // (same pattern as navigateSession). Without this, a stale cache
        // entry for the same sid under a different project — or any future
        // dup state before SOUL-SOUL_DESKTOP-246's kernel write-time
        // prevention lands — would cause first(where:) to return the wrong
        // project, expand it, and scroll the sidebar to a row that isn't
        // the one the user just clicked.
        let owner: SoulProject? = {
            if let pid = activeProjectId,
               let p = projects.first(where: { $0.id == pid }) {
                return p
            }
            return projects.first(where: { p in
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
            })
        }()
        if let owner, !isExpanded(owner.id) {
            setExpanded(owner.id, true)
        }
        // Animate the scroll-to-row when the sidebar is at rest. The prior
        // unconditional `withAnimation` stacked on top of in-flight
        // momentum (.decelerating) and triggered a SwiftUI
        // MoveTransition.MoveLayout + nested-VStack recursion 100+ frames
        // deep — full beachball. `sidebarScrollIdle` is fed from
        // .onScrollPhaseChange on the parent ScrollView; when false we
        // snap (which mid-momentum is what the user perceived as natural
        // anyway, since they're actively scrolling). The 50ms delay stays
        // — expanding the owning project (above) needs a runloop tick for
        // the freshly-revealed row to materialize before scrollTo can find
        // it.
        let animate = sidebarScrollIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animate {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(sid, anchor: .center)
                }
            } else {
                proxy.scrollTo(sid, anchor: .center)
            }
        }
    }

    @ViewBuilder
    func projectRow(_ project: SoulProject) -> some View {
        // SOUL-SOUL_DESKTOP-270: one resolve() pass owns both the badge
        // count and the rendered list. They cannot disagree anymore.
        // resolved is nil when the project's sessions haven't been loaded
        // yet — badge falls back to the raw disk count.
        let resolved = resolvedRows(for: project)
        ProjectSidebarRow(
            project: project,
            isSelected: activeProjectId == project.id
                || (selectedProject == project.id
                    && activeSessionId == nil
                    && activeReplaySessionId == nil),
            isExpanded: expansionBinding(for: project.id),
            chatCount: resolved?.activeCount ?? (sessionCounts[project.id] ?? 0),
            onSelect: { selectedProject = project.id },
            onNewChat: {
                onNewChat(project.id)
            },
            onEdit: {
                pendingProjectEdit = ProjectEditRequest(project: project)
            },
            onDelete: {
                pendingProjectDelete = ProjectDeleteRequest(project: project)
            }
        )
        if isExpanded(project.id), let rows = resolved {
            let active = rows.active
            let archived = rows.archived
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
            // Always render the disclosure when archived rows exist so the
            // user has a visible signal that something is hidden — otherwise
            // archiving a row makes it vanish with zero UI trace.
            if !archived.isEmpty {
                archivedDisclosure(for: project, archived: archived)
            }
        }
    }

    @ViewBuilder
    func showMoreButton(for project: SoulProject, hiddenCount: Int) -> some View {
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
    func showLessButton(for project: SoulProject) -> some View {
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
    func archivedDisclosure(for project: SoulProject, archived: [SoulSession]) -> some View {
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
    func chatRow(_ session: SoulSession) -> some View {
        // Selection compares on (project, sid) — not sid alone. The kernel
        // permits the same Claude session UUID to appear under multiple
        // project dirs (e.g. when the user opens the same session while
        // cwd is different projects). Without the project check, every
        // sibling row across projects highlights for the active sid.
        let selected = session.id == activeSessionId
                    && session.project == activeProjectId
        ChatRow(
            session: session,
            isSelected: selected,
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
                    onArchive(session)
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
    ///   - kernel ledger:  <SOUL_HOME>/sessions/<proj>/<sid>/, plus legacy registry copies
    ///   - finalize JSON:  <SOUL_HOME>/sessions/<proj>/*<sid>.json, plus legacy registry copies
    ///   - Claude file:    ~/.claude/projects/<encoded-cwd>/<sid>.jsonl
    ///   - Gemini chat:    ~/.gemini/tmp/<basename>(-N)/chats/*<first8>*
    ///   - Codex transcript sibling lives inside the ledger dir, swept above
    /// then remove the row from the archive set + invalidate the cache so
    /// the sidebar repaints without it. Returns the count of trashed paths.
    @discardableResult
    func deleteSessionToTrash(_ session: SoulSession) -> Int {
        let fm = FileManager.default
        var paths: [String] = []

        // Kernel ledger dir.
        for root in SoulRegistry.sessionRoots() {
            let kernelDir = "\(root)/\(session.project)/\(session.id)"
            if fm.fileExists(atPath: kernelDir) { paths.append(kernelDir) }
        }

        // Finalize JSON siblings (timestamp-prefixed and bare).
        for projDir in SoulRegistry.projectSessionDirs(session.project) {
            guard let entries = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
            for name in entries where name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if stem == session.id || stem.hasSuffix("_\(session.id)") {
                    paths.append("\(projDir)/\(name)")
                }
            }
        }

        // Provider files. Resolve the project's cwd from PROJECTS.
        if let project = registryStore.projects().first(where: { $0.id == session.project }) {
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
        registryStore.invalidateCache(forProject: session.project)
        // Reload sessions so the sidebar repaints without the row.
        Task { await loadProject(session.project) }
        return urls.count
    }

    /// Build the visibility-policy `Context` once per render from the
    /// sidebar's current UI state. All callers (badge count + merged list)
    /// run through the same policy so the two can't disagree.
    private func visibilityContext(for project: SoulProject) -> SidebarRowResolver.VisibilityContext {
        SidebarRowResolver.VisibilityContext(
            archivedIds: archiveStore.archivedIDs(forProject: project.id),
            showUnreadable: showUnreadable,
            chatSourceFilter: chatSourceFilter,
            hideUntitled: hideUntitled
        )
    }

    /// Single resolve() pass. Both badge count and rendered list draw from
    /// this Output, so they can no longer disagree (SOUL-267 bug class).
    /// Returns nil when the project hasn't been loaded yet — caller falls
    /// back to the raw disk-count badge. SOUL-SOUL_DESKTOP-270.
    func resolvedRows(for project: SoulProject) -> SidebarRowResolver.Output? {
        if UserDefaults.standard.bool(forKey: "soul.sidebar.trace") {
            let n = sessionsByProject[project.id]?.count
            SidebarRowResolver.traceWrite("resolvedRows project=\(project.id) sessionsByProject.count=\(n.map(String.init) ?? "nil")")
        }
        guard let onDisk = sessionsByProject[project.id] else { return nil }
        let inputs = SidebarRowResolver.Inputs(
            projectKey: project.id,
            diskSessions: onDisk,
            activeControllers: activeThreads.filter { $0.project.id == project.id },
            draft: (draftSession?.project == project.id) ? draftSession : nil,
            archivedIds: archiveStore.archivedIDs(forProject: project.id),
            starredIds: starStore.starredIDs(forProject: project.id),
            visibilityContext: visibilityContext(for: project)
        )
        return SidebarRowResolver.resolve(inputs)
    }

    func worktreeGroups(for lives: [SoulSession]) -> [(label: String, sessions: [SoulSession])] {
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

}
