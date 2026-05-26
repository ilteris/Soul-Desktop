import SwiftUI

extension SidebarView {
    func reload() async {
        // Only load the project list at startup — per-project session scans
        // happen lazily when the user expands a folder. For accounts with
        // many projects × hundreds of finalized JSONs (soul, job-hunt) this
        // turns a multi-second startup stall into a single PROJECTS.json read.
        //
        // SOUL-SOUL_DESKTOP-161: the sidebar is one of the explicit
        // refresh trigger points. Hit disk here (so the user sees fresh
        // data on reload), then read the now-warmed cache. Other body
        // re-reads of registryStore.activeProjects() get the cached
        // copy without re-scanning.
        if let live = registryStore as? LiveSoulRegistryStore {
            live.refresh()
        }
        let projs = registryStore.activeProjects()
        // Cheap session-count pass (no JSON parsing) so collapsed projects
        // still get an accurate badge without paying the lazy-load cost.
        let counts: [String: Int] = await Task.detached(priority: .userInitiated) {
            var c: [String: Int] = [:]
            for p in projs {
                let n = registryStore.sessionCount(forProject: p.id)
                if n > 0 { c[p.id] = n }
            }
            return c
        }.value
        await MainActor.run {
            self.projects = projs
            // Merge, don't replace. `sessionCounts` is seeded from the
            // persisted filtered-count cache (see SidebarView.swift:104).
            // Replacing it with the raw on-disk count clobbers the cached
            // value and produces the 230→9 flicker on cold launch — raw
            // count shows first, then Stage 2 filtering drops it back to
            // the truth. Only adopt the raw count for projects we don't
            // have any prior count for; otherwise keep the cached value
            // until Stage 2's `recomputePersistedSessionCounts()` lands
            // the authoritative filtered number.
            var merged = self.sessionCounts
            for (key, rawCount) in counts where merged[key] == nil {
                merged[key] = rawCount
            }
            self.sessionCounts = merged
            Self.writeSessionCountsCache(merged)
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
                if let cached = registryStore.cachedSessions(forProject: p.id), !cached.isEmpty {
                    out.append((p.id, cached))
                }
            }
            return out
        }.value
        await MainActor.run {
            for (key, rows) in primed where sessionsByProject[key] == nil {
                sessionsByProject[key] = rows
            }
            // Recompute sessionCounts using the same filter pipeline the
            // list uses. Without this the persisted badge stays at the raw
            // on-disk count (which can include 40+ crash-residue dirs) and
            // every cold launch shows the inflated number until the user
            // expands the project — at which point filteredChatCount kicks
            // in and the badge collapses. Persisting the filtered count
            // means the next launch shows the right number immediately.
            rebuildResolvedRows()
        }
        // Refresh expanded projects AND prime any unprimed project so the
        // collapsed badge shows the visibility-filtered count instead of
        // the raw on-disk number. Without the unprimed pass, brand-new
        // projects (or ones whose cache was invalidated by mtime) display
        // the inflated raw count until the user expands them — at which
        // point the badge collapses to the truthful number (SOUL-270
        // badge-on-expand bug). Each loadProject is a single `soul session
        // list --json` shell-out (~500-700ms); fire them in parallel so the
        // batch finishes in max(times) not sum(times). Detached so cold
        // launch isn't blocked. RegistryWatcher catches in-flight changes.
        let needLoad = projs.filter { isExpanded($0.id) || sessionsByProject[$0.id] == nil }
        if !needLoad.isEmpty {
            Task { [needLoad] in
                await withTaskGroup(of: Void.self) { group in
                    for p in needLoad {
                        group.addTask { await self.loadProject(p.id) }
                    }
                }
            }
        }
        await reloadSessions()
    }

    /// Off-main per-project scan via `SoulRegistry.allSessions`. Idempotent —
    /// safe to call again on expand-toggle to refresh a stale folder. Result
    /// already carries `substantive`/`loadable`/`replayable` flags so the
    /// sidebar doesn't have to re-check disk.
    ///
    /// Single-pass project scan. The kernel CLI `soul session list --json`
    /// (called from `SoulRegistry.allSessions`) finishes a couple-hundred-
    /// session project in low-millisecond range, so the old "Stage 1: 20
    /// rows, Stage 2: full list" split (-145 / -229) is no longer needed.
    /// One scan → one assignment → one badge recompute.
    ///
    /// SOUL-SOUL_DESKTOP-234 lives on as the 5s TTL gate: browser-style
    /// project switching with ⌘[/⌘] could otherwise fire a full disk walk
    /// per visit. RegistryWatcher keeps the currently-selected project
    /// fresh; revisits within 5s skip the redundant scan.
    func loadProject(_ projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId })
            ?? registryStore.activeProjects().first(where: { $0.id == projectId })
        else { return }

        // INSTANT PAINT: always paint from the disk cache the moment we're
        // asked to load a project. We accept stale data here — a busy
        // project's dir mtime ticks on every hook write, so the strict
        // `cachedSessions` (mtime-validated) would miss often. Stale rows
        // are fine for the millisecond between click and CLI completion;
        // freshness is restored when the refresh below lands.
        if self.sessionsByProject[projectId] == nil,
           let stale = registryStore.cachedSessionsStaleOK(forProject: projectId),
           !stale.isEmpty {
            self.sessionsByProject[projectId] = stale
            rebuildResolvedRows(projectIds: Set([projectId]))
        }

        // Skip the CLI scan if the strict cache is fresh (in-memory or
        // disk-stamp-validated). RegistryWatcher invalidates this via
        // fsevents the moment the dir actually changes, so freshness
        // is preserved without paying for a CLI hop every click.
        if registryStore.cachedSessions(forProject: projectId) != nil {
            projectLastFullScanAt[projectId] = Date()
            if let rows = sessionsByProject[projectId] {
                onPrewarmSessions(Array(rows.prefix(sessionPageSize)))
            }
            return
        }

        if let last = projectLastFullScanAt[projectId],
           Date().timeIntervalSince(last) < 5 {
            return
        }
        projectLastFullScanAt[projectId] = Date()

        let rows: [SoulSession] = await Task.detached(priority: .userInitiated) {
            let r = registryStore.allSessions(forProject: project.id, projectPath: project.path)
            registryStore.warmCache(forProject: project.id, sessions: r)
            return r
        }.value
        await MainActor.run {
            // Defensive: a transient empty read shouldn't blank the cache.
            // A genuinely-empty project gets cleared elsewhere when the
            // row count is known to be zero.
            guard !rows.isEmpty else { return }
            self.sessionsByProject[projectId] = rows
            rebuildResolvedRows(projectIds: Set([projectId]))
            onPrewarmSessions(Array(rows.prefix(sessionPageSize)))
        }
    }

    func reloadSessions() async {
        guard let key = selectedProject else { return }
        let path = projects.first(where: { $0.id == key })?.path

        // 1. Paint cached data instantly so switching feels snappy.
        if let cached = registryStore.cachedSessions(forProject: key), !cached.isEmpty {
            await MainActor.run {
                self.sessionsByProject[key] = cached
            }
        }

        // 2. Fresh scan off the main actor — the file I/O is synchronous but
        //    we don't want any UI tick coupling to disk latency.
        let rows: [SoulSession] = await Task.detached(priority: .userInitiated) {
            let r = registryStore.allSessions(forProject: key, projectPath: path)
            registryStore.warmCache(forProject: key, sessions: r)
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
                if fresh.visibleTurnCount == 0 && old.visibleTurnCount > 0 {
                    out.visibleTurnCount = old.visibleTurnCount
                }
                return out
            }
            self.sessionsByProject[key] = merged
            rebuildResolvedRows(projectIds: Set([key]))
            onPrewarmSessions(Array(merged.prefix(sessionPageSize)))
        }
    }

    /// Re-derive `sessionCounts` from currently-loaded `sessionsByProject`
    /// using the same filter pipeline the rendered list applies, then
    /// persist to UserDefaults. The cold-launch badge then shows the
    /// filtered (== "what you actually see in the list") count instead of
    /// the raw on-disk count, fixing the "badge says 45, list shows 1"
    /// gap that recurred on every relaunch.
    ///
    /// Projects that don't have `sessionsByProject` populated yet keep
    /// their existing entry (either the raw initial-discovery count or the
    /// previously-persisted filtered count) so we never blank a badge.
    func recomputePersistedSessionCounts() {
        rebuildResolvedRows()
    }

}
