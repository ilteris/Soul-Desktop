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
    func loadProject(_ projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId })
            ?? registryStore.activeProjects().first(where: { $0.id == projectId })
        else { return }

        // Stage 1: fast scan, bounded to the page size we'll actually render.
        //
        // SOUL-SOUL_DESKTOP-229: stage 1 exists to give a brand-new project
        // a fast first paint. If `sessionsByProject[projectId]` is already
        // populated (e.g. -149 prime at launch loaded the on-disk cache,
        // or a previous loadProject finished), overwriting it with just
        // the 20-row quick scan visibly shrinks the project's header
        // chatCount badge until stage 2 restores it ~1-2s later. That's
        // what users were seeing on session click: clicking a session in
        // an already-warm project flips `activeProjectId` → fires this
        // function → stage 1 truncates the 67-row warm cache to 20. Gate
        // the stage-1 assignment to fresh projects only.
        let alreadyWarm = (sessionsByProject[projectId]?.isEmpty == false)
        if !alreadyWarm {
            let quickLimit = sessionPageSize
            let quickRows: [SoulSession] = await Task.detached(priority: .userInitiated) {
                registryStore.allSessions(forProject: project.id, limit: quickLimit, projectPath: project.path)
            }.value
            await MainActor.run {
                if !quickRows.isEmpty, (self.sessionsByProject[projectId]?.isEmpty ?? true) {
                    self.sessionsByProject[projectId] = quickRows
                }
            }
        }

        // Stage 2: full scan in background. The default limit (100) covers
        // the "Show more" expanded case. Warm the cache so subsequent
        // reloadSessions paint-instant paths see the full list.
        let fullRows: [SoulSession] = await Task.detached(priority: .background) {
            let r = registryStore.allSessions(forProject: project.id, projectPath: project.path)
            registryStore.warmCache(forProject: project.id, sessions: r)
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
                return out
            }
            self.sessionsByProject[key] = merged
        }
    }

}
