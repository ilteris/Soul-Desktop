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
    /// session for the project, deduped by id, sorted by timestamp desc.
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
        // Beachball investigation: dropped the `withAnimation` wrap. Clicking
        // a session while mid-scroll was stacking the scroll-to-center
        // animation on top of the in-flight scroll-momentum transition,
        // showing up in layout traces as MoveTransition.MoveLayout +
        // nested-VStack recursion 100+ frames deep. The 50ms delay stays —
        // expanding the owning project (above) needs a runloop tick for the
        // freshly-revealed row to materialize before scrollTo can find it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(sid, anchor: .center)
        }
    }

    @ViewBuilder
    func projectRow(_ project: SoulProject) -> some View {
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
            },
            onEdit: {
                pendingProjectEdit = ProjectEditRequest(project: project)
            },
            onDelete: {
                pendingProjectDelete = ProjectDeleteRequest(project: project)
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
            // SOUL-SOUL_DESKTOP-230: gated on `showArchived` so the
            // disclosure only paints when the user has explicitly opted
            // in via the filter menu. Default is hidden — archived rows
            // are soft-deletes and shouldn't be in the user's daily view.
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
    func filteredChatCount(for project: SoulProject) -> Int? {
        // SOUL-SOUL_DESKTOP-234: avoid calling mergedChatList here. That
        // helper builds a [String: SoulSession] dict and sorts the result
        // — work the badge only needs counted, not ordered. Expand/collapse
        // re-renders every project row, so this path is hit N times per
        // body invocation. The dict+sort across ~100 sessions per project
        // for 10+ projects was producing a visible main-thread beachball.
        // O(M) scan with a Set for de-dup is enough.
        guard let onDisk = sessionsByProject[project.id] else { return nil }
        let archivedSet = archiveStore.archivedIDs(forProject: project.id)
        var seenIds = Set<String>()
        seenIds.reserveCapacity(onDisk.count)
        var count = 0
        for s in onDisk {
            if !s.substantive { continue }
            if !showUnreadable, !(s.loadable || s.replayable) { continue }
            if let f = chatSourceFilter, (s.source ?? s.liveProvider ?? "") != f { continue }
            if hideUntitled {
                let title = (s.intent ?? s.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { continue }
            }
            if archivedSet.contains(s.id) { continue }
            seenIds.insert(s.id)
            count += 1
        }
        for ctrl in activeThreads where ctrl.project.id == project.id {
            let sid = ctrl.sessionId ?? "thread-\(ctrl.id)"
            if archivedSet.contains(sid) { continue }
            if seenIds.insert(sid).inserted { count += 1 }
        }
        if let draft = draftSession,
           draft.project == project.id,
           !archivedSet.contains(draft.id),
           seenIds.insert(draft.id).inserted {
            count += 1
        }
        return count
    }

    func mergedChatList(for project: SoulProject) -> [SoulSession] {
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
                // SOUL-216 (revised): live ctrl.items userMessage count is
                // the canonical source — it matches the ThreadView toolbar
                // chip's chapterCount, so sidebar and toolbar can never
                // disagree. Disk's promptCount under-counts external
                // Gemini sessions (kernel only records UserPrompt when
                // Soul-Desktop is the writer); ctrl.items reflects the
                // full transcript.
                //
                // SOUL-219: hold the disk count while hydrate is streaming
                // items in. Without this, the row's turn-count text
                // climbs 0 → N visibly during the click-to-open animation,
                // producing a flicker the user can spot. Once
                // isReplayingLoad flips false, switch to the live ctrl
                // count (which is now stable for the rest of the session).
                //
                // SOUL-SOUL_DESKTOP-228: additionally require `!items.isEmpty`.
                // -219's gate covered the "during hydrate" window but missed
                // the *before hydrate starts* window — a fresh ctrl exists
                // with isReplayingLoad still false and zero items, so the
                // override dropped promptCount to 0 for one or two renders.
                // metaLine then returned just "ago", the turn count
                // disappeared, the timestamp slid left, then jumped back
                // right when the override re-engaged. Empty items mean
                // "the controller hasn't produced anything yet" (whether
                // because it hasn't loaded or because the session is
                // genuinely empty); in both cases the disk count is the
                // truthful value to display.
                let liveCount = ctrl.items.filter { if case .userMessage = $0 { return true } else { return false } }.count
                if !ctrl.isReplayingLoad && !ctrl.items.isEmpty {
                    merged.promptCount = liveCount
                }
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
