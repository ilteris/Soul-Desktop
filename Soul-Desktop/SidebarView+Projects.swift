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
        // Bring the active row into view when the sidebar is at rest. The prior
        // unconditional `withAnimation` stacked on top of in-flight
        // momentum (.decelerating) and triggered a SwiftUI
        // MoveTransition.MoveLayout + nested-VStack recursion 100+ frames
        // deep — full beachball. `sidebarScrollIdle` is fed from
        // .onScrollPhaseChange on the parent ScrollView; when false we
        // snap (which mid-momentum is what the user perceived as natural
        // anyway, since they're actively scrolling). Do not force `.center`:
        // direct row clicks near the viewport edge should not recenter the
        // whole list. Let ScrollViewProxy apply its minimal "make visible"
        // behavior instead. The 50ms delay stays
        // — expanding the owning project (above) needs a runloop tick for
        // the freshly-revealed row to materialize before scrollTo can find
        // it.
        let animate = sidebarScrollIdle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animate {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(sid)
                }
            } else {
                proxy.scrollTo(sid)
            }
        }
    }

    @ViewBuilder
    func projectRow(_ project: SoulProject) -> some View {
        // SOUL-SOUL_DESKTOP-270: one resolve() pass owns both the badge
        // count and the rendered list. They cannot disagree anymore.
        // resolved is nil when the project's sessions haven't been loaded
        // yet — badge falls back to the raw disk count.
        let resolved = sidebarRowsProjection.rowsByProject[project.id]
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
            // Trashed rows are hidden from the normal project list by
            // default. The filter menu can reveal this disclosure when the
            // user needs restore/permanent-delete actions.
            if showArchived, !archived.isEmpty {
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
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text("Recently Trashed")
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
                    rebuildResolvedRows(projectIds: Set([session.project]))
                }
            } else {
                Button("Star (pin to top)") {
                    starStore.star(session.id, project: session.project)
                    rebuildResolvedRows(projectIds: Set([session.project]))
                }
            }
            Divider()
            if session.lifecycle == "trashed" {
                Button("Restore") {
                    restoreSessionFromKernelTrash(session)
                }
                Divider()
                Button("Delete permanently…", role: .destructive) {
                    pendingDelete = DeleteConfirmation(session: session, permanently: true)
                }
            } else if session.lifecycle == "archived" {
                Button("Restore") {
                    restoreSessionFromKernelTrash(session)
                }
            } else if session.lifecycle == nil && archiveStore.isArchived(session.id, project: session.project) {
                Button("Restore legacy archive") {
                    archiveStore.unarchive(session.id, project: session.project)
                    rebuildResolvedRows(projectIds: Set([session.project]))
                }
            } else {
                Button("Move to Trash…", role: .destructive) {
                    pendingDelete = DeleteConfirmation(session: session, permanently: false)
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

    func moveSessionToKernelTrash(_ session: SoulSession) {
        optimisticallyApplyLifecycle("trashed", to: session)
        archivedExpanded[session.project] = false
        onArchive(session)
        runKernelLifecycleCommand("trash", session: session) {
        }
    }

    func restoreSessionFromKernelTrash(_ session: SoulSession) {
        optimisticallyApplyLifecycle(nil, to: session)
        runKernelLifecycleCommand("restore", session: session)
    }

    func deleteSessionPermanently(_ session: SoulSession) {
        optimisticallyRemoveSession(session)
        runKernelLifecycleCommand("delete", session: session)
    }

    private func optimisticallyApplyLifecycle(_ lifecycle: String?, to session: SoulSession) {
        guard var rows = sessionsByProject[session.project],
              let index = rows.firstIndex(where: { $0.id == session.id })
        else { return }
        rows[index].lifecycle = lifecycle
        rows[index].trashedAt = lifecycle == "trashed" ? Date() : nil
        sessionsByProject[session.project] = rows
        rebuildResolvedRows(projectIds: Set([session.project]))
    }

    private func optimisticallyRemoveSession(_ session: SoulSession) {
        guard var rows = sessionsByProject[session.project] else { return }
        rows.removeAll { $0.id == session.id }
        sessionsByProject[session.project] = rows
        rebuildResolvedRows(projectIds: Set([session.project]))
    }

    private func runKernelLifecycleCommand(
        _ command: String,
        session: SoulSession,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        Task {
            do {
                try await SoulCLI.runMutation(["session", command, session.id, "-p", session.project])
                archiveStore.unarchive(session.id, project: session.project)
                registryStore.invalidateCache(forProject: session.project)
                rebuildResolvedRows(projectIds: Set([session.project]))
                onSuccess()
                await loadProject(session.project)
            } catch {
                NSLog("[sidebar] soul session \(command) failed for \(session.project)/\(session.id): \(error)")
                registryStore.invalidateCache(forProject: session.project)
                await loadProject(session.project)
            }
        }
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
        if UserDefaults.standard.bool(forKey: "soul.sidebar.trace.verbose") {
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

    var sidebarProjectionInputSignature: SidebarProjectionInputSignature {
        SidebarProjectionInputSignature(
            projectIds: projects.map(\.id),
            activeThreads: activeThreads.map { thread in
                SidebarProjectionInputSignature.Thread(
                    id: thread.id,
                    sessionId: thread.sessionId,
                    projectId: thread.project.id,
                    provider: thread.provider.rawValue,
                    displayTitle: thread.displayTitle,
                    itemCount: thread.items.count,
                    queuedCount: thread.queuedPrompts.count,
                    isWorking: thread.isWorking,
                    lastActivityAt: thread.lastActivityAt
                )
            },
            draftId: draftSession?.id,
            draftProject: draftSession?.project,
            archivedIdsByProject: Dictionary(uniqueKeysWithValues: projects.map { project in
                (project.id, archiveStore.archivedIDs(forProject: project.id).sorted())
            }),
            starredIdsByProject: Dictionary(uniqueKeysWithValues: projects.map { project in
                (project.id, starStore.starredIDs(forProject: project.id).sorted())
            })
        )
    }

    func rebuildResolvedRows(projectIds: Set<String>? = nil) {
        var projection = sidebarRowsProjection
        let updatedCounts = projection.rebuild(
            projects: projects,
            projectIds: projectIds,
            currentCounts: sessionCounts,
            outputForProject: resolvedRows(for:)
        )
        sidebarRowsProjection = projection
        if updatedCounts != sessionCounts {
            sessionCounts = updatedCounts
            Self.writeSessionCountsCache(updatedCounts)
        }
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

struct SidebarProjectionInputSignature: Hashable {
    struct Thread: Hashable {
        var id: String
        var sessionId: String?
        var projectId: String
        var provider: String
        var displayTitle: String
        var itemCount: Int
        var queuedCount: Int
        var isWorking: Bool
        var lastActivityAt: Date
    }

    var projectIds: [String]
    var activeThreads: [Thread]
    var draftId: String?
    var draftProject: String?
    var archivedIdsByProject: [String: [String]]
    var starredIdsByProject: [String: [String]]
}

struct SidebarRowsProjection {
    private(set) var rowsByProject: [String: SidebarRowResolver.Output] = [:]

    mutating func rebuild(
        projects: [SoulProject],
        projectIds: Set<String>?,
        currentCounts: [String: Int],
        outputForProject: (SoulProject) -> SidebarRowResolver.Output?
    ) -> [String: Int] {
        let allProjectIds = Set(projects.map(\.id))
        let targets = projectIds ?? allProjectIds
        var updatedCounts = currentCounts

        if projectIds == nil {
            rowsByProject = rowsByProject.filter { allProjectIds.contains($0.key) }
        }

        for project in projects where targets.contains(project.id) {
            guard let output = outputForProject(project) else {
                rowsByProject.removeValue(forKey: project.id)
                continue
            }
            rowsByProject[project.id] = output
            updatedCounts[project.id] = output.activeCount
        }

        return updatedCounts
    }
}
