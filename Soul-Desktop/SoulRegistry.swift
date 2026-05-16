import Foundation

struct SoulProject: Identifiable, Hashable {
    var id: String                 // project key, e.g. "soul", "bifrost"
    var name: String
    var path: String               // expanded absolute path
    var pillar: String?
    var tier: Int?
    var status: String?
    var primaryHost: String?
    var devCommand: String?        // optional shell command, e.g. "npm run dev"
    var devURL: String?            // optional URL to open after dev server starts, e.g. "http://localhost:3002"
}

/// Where a live session was started from. Derived from the shape of events
/// in its hooks.jsonl. Drives sidebar styling: terminal-origin rows get a
/// muted look + different icon + tooltip, because Soul-Desktop can't resume
/// them (the kernel and the agent are in separate UUID namespaces) until
/// SOUL-SOUL-004 lands. Desktop-spawned rows resume cleanly via ACP
/// session/load.
enum SessionOrigin: String, Hashable {
    case desktop   // ledger has UserPrompt / NativeSessionID / Title written by Soul-Desktop
    case terminal  // ledger has only kernel events (SESSION_START / AfterTool / AfterAgent)
    case unknown   // empty or ambiguous
}

struct SoulSession: Identifiable, Hashable {
    var id: String                 // session_id
    var project: String
    var timestamp: Date
    var intent: String?
    var summary: String?
    var source: String?            // "claude" | "gemini" | "pi-native"
    var status: String?
    var eventCount: Int = 0        // hooks.jsonl line count (kernel events)
    var promptCount: Int = 0       // Claude transcript "type":"user" count
    /// Fallback turn count derived from the provider's transcript when the
    /// kernel ledger has no UserPrompt events. Rendered with a `~` prefix
    /// in the sidebar so users can still gauge session length on rows the
    /// kernel didn't instrument (terminal-origin Codex, ledger-less Gemini).
    var transcriptTurns: Int = 0
    /// True when the kernel wrote a `<uuid>/hooks.jsonl` ledger but no sibling
    /// `<uuid>.json` finalize summary exists yet. These rows stay visible
    /// under their project until /finalize promotes them to Chats.
    var isLive: Bool = false
    /// Finalized but has activity since: hooks.jsonl mtime > json mtime. The
    /// summary in the Chats row is stale; user should /finalize again to refresh.
    var isDirty: Bool = false
    /// Where this session was started from. Drives `AppShell.loadSession`
    /// routing — terminal-origin live rows go to Replay because the kernel
    /// and the agent occupy different UUID namespaces.
    var origin: SessionOrigin = .unknown
    /// Absolute path of the git worktree the session was started in, when
    /// the kernel detected one. Null for main-tree sessions and pre-007
    /// sessions. Read from hooks.jsonl `SESSION_START` (live) or the
    /// finalized session JSON top-level field. Drives sidebar sub-grouping.
    var worktreePath: String? = nil
    /// Which agent owns this session's persistence file. Set by `allSessions`
    /// via `agentMatch`. Used by `AppShell.loadSession` to pick the right
    /// harness on click so a Claude session clicked while the harness is
    /// Gemini auto-switches instead of dead-ending in `session/load`.
    var liveProvider: String? = nil
    /// True iff a provider transcript file (Claude `.jsonl` under
    /// `~/.claude/projects/...` or a content-bearing gemini chat file under
    /// `~/.gemini/tmp/.../chats/`) resolves for this id. Drives the default
    /// "is this row resumable?" filter — non-loadable rows can still appear
    /// when `replayable`, just with a Replay-only affordance.
    var loadable: Bool = true
    /// True iff `<uuid>/hooks.jsonl` exists. The replay surface only needs
    /// the kernel ledger, so finalized rows whose provider transcript has
    /// rotated out are still replay-able.
    var replayable: Bool = true
    /// True iff this row reflects a real conversation (finalized with
    /// summary, or live with ≥ 4 hook events or a UserPrompt). Used to drop
    /// crash residue without an age heuristic.
    var substantive: Bool = true
    /// First hook-event timestamp (the moment the session was started).
    /// Pairs with `timestamp` (most-recent activity) to compute duration —
    /// e.g. "23m" / "1h 4m" / "2d 3h" — rendered under the row title.
    var startedAt: Date? = nil
}

enum SoulRegistry {
    nonisolated(unsafe) static var homePath: String = NSHomeDirectory()
    nonisolated(unsafe) static var soulPath: String = homePath + "/dotfiles/soul"
    nonisolated(unsafe) static var registryPath: String = homePath + "/soul_registry"

    /// Per-project cache for the unified `allSessions` scan. Keyed by project
    /// id; refresh when the sessions/<key> directory mtime advances. Lives at
    /// class-level so it survives view rebuilds.
    private struct ProjectCache {
        var dirMtime: Date
        var sessions: [SoulSession]
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ProjectCache] = [:]

    /// Read cached scan results if the registry directory hasn't changed.
    /// Returns nil on miss / stale. Callers should fall back to a fresh scan.
    static func cachedSessions(forProject key: String) -> [SoulSession]? {
        let now = projectStamp(key: key)
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let hit = cache[key], hit.dirMtime == now else { return nil }
        return hit.sessions
    }

    static func warmCache(forProject key: String, sessions: [SoulSession]) {
        let m = projectStamp(key: key)
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key] = ProjectCache(dirMtime: m, sessions: sessions)
    }

    /// Cache-validity stamp for a project's sessions tree. Combines the
    /// parent directory's mtime (catches add/remove of session dirs) with
    /// the newest child hooks.jsonl mtime (catches in-place appends — which
    /// don't bump the parent dir mtime and were previously serving stale
    /// rows after a session crossed the visibility threshold or was newly
    /// touched). Bounded to the first 64 entries to keep this O(1)-ish on
    /// projects with hundreds of sessions; the dir-mtime fallback still
    /// catches the case where a fresh session dir is created.
    private static func projectStamp(key: String) -> Date {
        let dir = "\(registryPath)/sessions/\(key)"
        var newest = mtime(dir)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return newest
        }
        for entry in entries.prefix(64) {
            guard UUID(uuidString: entry) != nil else { continue }
            let hooksPath = "\(dir)/\(entry)/hooks.jsonl"
            let m = mtime(hooksPath)
            if m > newest { newest = m }
        }
        return newest
    }

    static func invalidateCache(forProject key: String? = nil) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let key { cache.removeValue(forKey: key) } else { cache.removeAll() }
    }

    // MARK: - Projects

    static func projects() -> [SoulProject] {
        let url = URL(fileURLWithPath: "\(soulPath)/config/PROJECTS.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["projects"] as? [String: [String: Any]]
        else { return [] }

        let mapped = dict.map { (key, val) in
            SoulProject(
                id: key,
                name: val["name"] as? String ?? key,
                path: expand(val["path"] as? String ?? ""),
                pillar: val["pillar"] as? String,
                tier: val["tier"] as? Int,
                status: val["status"] as? String,
                primaryHost: val["primary_host"] as? String,
                devCommand: val["dev_command"] as? String,
                devURL: val["dev_url"] as? String
            )
        }

        // Sort by project creation time (oldest first) so the sidebar order
        // is STABLE — doesn't reshuffle as you send prompts or files get
        // touched. Creation time = the birth date of the project's
        // sessions/ directory, falling back to the project's source path,
        // then alphabetical for projects without either timestamp yet.
        return mapped.sorted { lhs, rhs in
            let la = createdAt(for: lhs)
            let ra = createdAt(for: rhs)
            if la != ra { return la < ra }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func createdAt(for p: SoulProject) -> Date {
        let sessionsDir = "\(registryPath)/sessions/\(p.id)"
        if let m = (try? FileManager.default.attributesOfItem(atPath: sessionsDir)[.creationDate]) as? Date {
            return m
        }
        if !p.path.isEmpty,
           let m = (try? FileManager.default.attributesOfItem(atPath: p.path)[.creationDate]) as? Date {
            return m
        }
        return Date.distantPast
    }

    static func activeProjects() -> [SoulProject] {
        projects().filter { ($0.status ?? "active") == "active" }
    }

    // MARK: - Sessions

    /// Count of distinct session UUIDs on disk for a project. A finalize
    /// JSON (`<uuid>.json` or `<ts>_<uuid>.json`) and a live dir (`<uuid>/`)
    /// for the same UUID count once. No parsing, no size filters — just the
    /// authoritative on-disk session set. Cheap enough to call for every
    /// project at startup, so sidebar badges paint instantly without
    /// triggering the heavier `sessions(forProject:)` parse pass.
    static func sessionCount(forProject key: String) -> Int {
        let dir = "\(registryPath)/sessions/\(key)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        var ids: Set<String> = []
        for name in entries {
            if name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if UUID(uuidString: stem) != nil {
                    ids.insert(stem)
                } else if let tail = stem.split(separator: "_").last, UUID(uuidString: String(tail)) != nil {
                    ids.insert(String(tail))
                }
            } else if UUID(uuidString: name) != nil {
                ids.insert(name)
            }
        }
        return ids.count
    }

    /// Unified producer: every `<uuid>` for a project, finalized and live
    /// alike, in one pass. Each row carries derived flags (`isLive`,
    /// `isDirty`, `loadable`, `replayable`, `substantive`, `origin`) so
    /// callers can filter on intent ("show resumable", "show replayable",
    /// "hide crash residue") without reaching back into the registry.
    ///
    /// Replaces the prior `sessions(forProject:)` + `liveSessions(forProject:)`
    /// split, which conflated lifecycle state (finalized vs live) with
    /// visibility heuristics (24h maxAge, origin-must-be-desktop, separate
    /// limits) and required downstream dedup. Lifecycle becomes a field, not
    /// a code path. The age cap is gone — staleness was always a proxy for
    /// "probably unresumable," and `loadable`/`replayable` now answer that
    /// directly.
    ///
    /// Cheap mtime pre-sort, parse top `limit * 2` for full enrichment, return
    /// top `limit` by activity. Loadability uses `SessionLoadability` so
    /// gemini sessions are matched via chat-file content rather than UUID
    /// prefix alone.
    /// Single-pass metadata pulled from one read of a session's hooks.jsonl.
    /// Replaces five separate file reads (`hooksLineCount` +
    /// `worktreePathFromHooks` + `firstUserPromptFromHooks` + `findTitle` +
    /// `detectOrigin`) per session — the dominant cost when expanding a
    /// project with dozens of finalized sessions.
    private struct HooksMetadata {
        var eventCount: Int = 0
        var promptCount: Int = 0
        var worktreePath: String? = nil
        var firstUserPrompt: String? = nil
        var titleHook: String? = nil
        var hasNativeOrUserPrompt: Bool = false
        var hasTerminalSignal: Bool = false
        var firstEventTimestamp: Date? = nil
        var lastEventTimestamp: Date? = nil
        /// SOUL-SOUL_DESKTOP-061: parent PID stamped on SESSION_START. When
        /// it equals 1 (launchd) and no UserPrompt ever lands, this row is
        /// residue from the `com.soul.app-server` daemon making single-shot
        /// LLM calls for housekeeping — not a human conversation. The
        /// sidebar uses this to flip `substantive = false` so daemon
        /// sessions stop crowding project rows.
        var sessionStartPpid: Int? = nil
    }

    private static func readHooksMetadata(path: String) -> HooksMetadata {
        var meta = HooksMetadata()
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return meta }
        // Full scan: every line gets parsed so promptCount + last-event
        // timestamp + terminal signal flags are accurate even on long
        // sessions. The early-exit-after-80-lines optimization broke prompt
        // counting (it stopped counting after the first 80 events, so a
        // 200-turn session reported as 6 turns).
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        meta.eventCount = lines.count

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = (obj["event"] as? String) ?? ""

            if event == "SESSION_START", meta.worktreePath == nil {
                meta.worktreePath = obj["worktree_path"] as? String
            }
            if event == "SESSION_START", meta.sessionStartPpid == nil {
                if let p = obj["ppid"] as? Int { meta.sessionStartPpid = p }
            }
            if event == "Title", meta.titleHook == nil {
                meta.titleHook = (obj["text"] as? String) ?? (obj["title"] as? String)
            }
            if event == "UserPrompt" || event == "UserMessage" {
                meta.promptCount += 1
                if meta.firstUserPrompt == nil {
                    let text = (obj["text"] as? String)
                        ?? (obj["content"] as? String)
                        ?? (obj["prompt"] as? String)
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let t = trimmed, !t.isEmpty {
                        meta.firstUserPrompt = String(t.prefix(120))
                    }
                }
            }
            if event == "NativeSessionID" || event == "UserPrompt" {
                meta.hasNativeOrUserPrompt = true
            }
            if event == "SESSION_START" || event == "AfterTool" || event == "AfterAgent" || event == "AfterModel" {
                meta.hasTerminalSignal = true
            }

            // Capture first/last event timestamps to compute session
            // duration. First-event is always seen in the first loop tick
            // (lines are in disk order); last-event keeps updating until
            // the loop ends. We cap the scan at `maxLinesScanned`, so for
            // sessions with >80 events the last-event timestamp is the
            // 80th hook rather than the very last — acceptable for a
            // sidebar duration chip, doesn't pretend to be authoritative.
            if let ts = parseTimestamp(obj["timestamp"] as? String) {
                if meta.firstEventTimestamp == nil {
                    meta.firstEventTimestamp = ts
                }
                meta.lastEventTimestamp = ts
            }
        }
        return meta
    }

    /// Per-scan cache of gemini chat-dir listings + a first-8-char reverse
    /// index that maps `<first8>` → `(chatsDir, filename, isResumable)`.
    /// Building the index once per scan turns N×M per-session matching
    /// (`for each session, iterate every chat file looking for suffix`)
    /// into N O(1) lookups. With ~100 sessions in a project × ~50 chat
    /// files in a sibling `<project>-N/chats/` dir, that's ~5000 fewer
    /// suffix checks per project expand.
    /// Also caches the `isResumableGeminiChatFile` content check so we
    /// don't open the same file twice.
    private final class GeminiDirCache {
        var listings: [String: [String]] = [:]    // chatsDir path → filenames
        /// Reverse index: `<first8>` → `(chatsDirPath, fileName)`. First
        /// hit per first8 wins (largest-file disambiguation isn't needed
        /// at index-build time — the per-session loadability check still
        /// validates first-line sessionId for ambiguity).
        var firstEightIndex: [String: (chatsDir: String, fileName: String)] = [:]
        /// Memoized resumable-file check by absolute path.
        var resumableCache: [String: Bool] = [:]
        /// Per-scan set of session UUIDs found under
        /// `~/.pi/agent/sessions/<encoded-cwd>/`. Populated lazily on the
        /// first Pi probe per project so subsequent rows hit a set lookup
        /// instead of re-listing the directory.
        var piSessionsByDir: [String: Set<String>] = [:]
        private var built: Set<String> = []

        func entries(at dir: String, fm: FileManager) -> [String] {
            if let hit = listings[dir] { return hit }
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            listings[dir] = entries
            indexFirstEights(chatsDir: dir, entries: entries)
            return entries
        }

        private func indexFirstEights(chatsDir: String, entries: [String]) {
            guard !built.contains(chatsDir) else { return }
            built.insert(chatsDir)
            // Filenames look like `session-<ts>-<first8>.jsonl(.bak-<n>|.corrupt-<n>)?`.
            // Extract `<first8>` from each and remember the first match.
            for name in entries {
                guard name.hasSuffix(".jsonl") || name.hasSuffix(".json")
                      || name.contains(".jsonl.bak-") || name.contains(".jsonl.corrupt-")
                else { continue }
                // Find the 8-hex segment before the extension. The kernel
                // filename shape is stable enough that "last 8 hex chars
                // before .jsonl" finds it; we also accept the
                // "-<first8>." pattern that gemini-cli emits.
                let stem = (name as NSString).deletingPathExtension
                let parts = stem.split(separator: "-")
                if let candidate = parts.last, candidate.count == 8,
                   candidate.allSatisfy({ $0.isHexDigit }) {
                    if firstEightIndex[String(candidate)] == nil {
                        firstEightIndex[String(candidate)] = (chatsDir, name)
                    }
                }
            }
        }
    }

    static func allSessions(forProject key: String, limit: Int = 100, projectPath: String? = nil) -> [SoulSession] {
        let dir = "\(registryPath)/sessions/\(key)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        // Pass 1: collect every distinct UUID and its on-disk shape. A UUID
        // can appear as a finalize JSON, a live dir, or both (finalized then
        // resumed without re-finalizing).
        struct Shape {
            var finalizeName: String?    // filename under sessions/<key>/ (may be timestamp-prefixed)
            var finalizePath: String?
            var hooksPath: String?       // sessions/<key>/<uuid>/hooks.jsonl
            var jsonMtime: Date?
            var hooksMtime: Date?
        }
        var shapes: [String: Shape] = [:]
        for name in entries {
            if name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                let id: String? = {
                    if UUID(uuidString: stem) != nil { return stem }
                    if let tail = stem.split(separator: "_").last, UUID(uuidString: String(tail)) != nil {
                        return String(tail)
                    }
                    return nil
                }()
                guard let id else { continue }
                let path = "\(dir)/\(name)"
                let m = mtime(path)
                var s = shapes[id] ?? Shape()
                // Prefer the most recent finalize JSON when two siblings exist
                // (rare, but the kernel occasionally writes both shapes).
                if s.jsonMtime.map({ m > $0 }) ?? true {
                    s.finalizeName = name
                    s.finalizePath = path
                    s.jsonMtime = m
                }
                shapes[id] = s
            } else if UUID(uuidString: name) != nil {
                let hooks = "\(dir)/\(name)/hooks.jsonl"
                guard fm.fileExists(atPath: hooks) else { continue }
                let m = mtime(hooks)
                var s = shapes[name] ?? Shape()
                s.hooksPath = hooks
                s.hooksMtime = m
                shapes[name] = s
            }
        }
        if shapes.isEmpty { return [] }

        // Pass 2: rank candidates by most-recent activity (max of json/hooks
        // mtimes). Only the top `limit * 2` get full parse + loadability;
        // this keeps the scan O(constant) for projects with hundreds of dirs.
        let ranked = shapes.map { (id, shape) -> (id: String, shape: Shape, recency: Date) in
            let m = max(shape.jsonMtime ?? .distantPast, shape.hooksMtime ?? .distantPast)
            return (id, shape, m)
        }
        .sorted { $0.recency > $1.recency }
        .prefix(limit * 2)

        // Pass 3: enrich + classify. Single-pass hooks read per session +
        // shared gemini dir cache so re-listing the chats dir 91 times
        // (one per candidate) collapses to once per sibling. This is the
        // dominant performance win for projects with many sessions —
        // dropped expand time from ~5s to under 200ms on a 91-row project.
        let dirCache = GeminiDirCache()
        var out: [SoulSession] = []
        for cand in ranked {
            let id = cand.id
            let shape = cand.shape
            var s = SoulSession(id: id, project: key, timestamp: cand.recency)

            // Finalize side: source of truth for intent/summary/source/status
            // when present.
            if let path = shape.finalizePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ts = parseTimestamp(obj["timestamp"] as? String) {
                    s.timestamp = max(s.timestamp, ts)
                }
                s.intent = stringOrNil(obj["intent"])
                s.summary = stringOrNil(obj["summary"])
                s.source = obj["source"] as? String
                s.status = obj["status"] as? String
                s.worktreePath = stringOrNil(obj["worktree_path"])
            }

            // Single hooks.jsonl read for ALL live-side metadata (event
            // count, worktree path, first prompt, title hook, origin signals).
            // Title precedence: Title hook → finalize intent → firstUserPrompt.
            var sessionStartPpid: Int? = nil
            if let hooks = shape.hooksPath {
                let meta = readHooksMetadata(path: hooks)
                s.eventCount = meta.eventCount
                s.promptCount = meta.promptCount
                sessionStartPpid = meta.sessionStartPpid
                if s.worktreePath == nil { s.worktreePath = meta.worktreePath }
                if let t = meta.titleHook, !t.isEmpty {
                    s.intent = t
                } else if s.intent == nil {
                    s.intent = meta.firstUserPrompt
                }
                if s.summary == nil { s.summary = s.intent }
                // Origin derived from the same single-read signals.
                if meta.hasNativeOrUserPrompt {
                    s.origin = .desktop
                } else if meta.hasTerminalSignal {
                    s.origin = .terminal
                } else {
                    s.origin = .unknown
                }
                s.startedAt = meta.firstEventTimestamp
            }

            s.isLive = (shape.finalizePath == nil)
            // Staleness: hooks advanced past the finalize JSON. 5s grace
            // covers the finalize's own paired-write tick.
            if let h = shape.hooksMtime, let j = shape.jsonMtime, h.timeIntervalSince(j) > 5 {
                s.isDirty = true
            }
            s.replayable = (shape.hooksPath != nil)
            // Provider mapping: prefer the recorded `source` from a finalize;
            // fall back to whichever agent owns the chat file on disk. Uses
            // the per-scan directory cache so we don't `contentsOfDirectory`
            // the same gemini chats dir 91 times. Codex fallback: a sibling
            // `transcript.jsonl` in the session's registry dir is the
            // codex marker (codex writes its own per-session transcript
            // there). Without this, codex rows without a NativeSessionID
            // hook show the dotted-circle "unknown" glyph even though the
            // dropdown identifies them correctly via `Provider.icon`.
            if s.source == nil {
                if let live = agentMatchCached(sessionId: id, projectPath: projectPath, cache: dirCache) {
                    s.liveProvider = live
                } else {
                    let transcriptPath = "\(dir)/\(id)/transcript.jsonl"
                    if FileManager.default.fileExists(atPath: transcriptPath) {
                        s.liveProvider = Provider.codex.rawValue
                    }
                }
            }

            // Substantive: finalize record (always counts) OR a real
            // conversation in the live ledger (≥ 4 hook events or a recorded
            // UserPrompt). This is the gate that filters crash residue —
            // empty <uuid>/hooks.jsonl dirs the kernel leaves behind when a
            // spawn is cancelled before the first turn.
            let hasFinalize = (shape.finalizePath != nil)
            let hasPrompt = (s.intent?.isEmpty == false)
            s.substantive = hasFinalize || s.eventCount >= 4 || hasPrompt

            // SOUL-SOUL_DESKTOP-061: headless app-server daemon spawns.
            // `com.soul.app-server` (a LaunchAgent) makes single-shot LLM
            // calls for housekeeping — pattern distillation, /pulse,
            // scheduled audits. They fire AfterModel/AfterAgent hooks
            // (passing the eventCount >= 4 substantive gate) but never
            // capture a UserPrompt because no human typed anything. Detect
            // by the launchd signature: SESSION_START.ppid == 1 plus zero
            // UserPrompts. Flip substantive=false so the sidebar hides
            // them as the noise they are. Finalize records are exempted —
            // if a daemon-spawned session was later finalized by hand,
            // keep it visible.
            if !hasFinalize, sessionStartPpid == 1, s.promptCount == 0 {
                s.substantive = false
            }

            // Loadable: does a provider transcript exist that
            // `hydrateFromDisk` can actually render? Uses the same cache as
            // agentMatchCached so the gemini sibling walk happens at most
            // once per scan.
            if let path = projectPath {
                s.loadable = canLoadCached(sessionId: id, projectKey: key, projectPath: path, cache: dirCache)
            } else {
                s.loadable = false
            }

            // Transcript-turn fallback: only run when the kernel ledger had
            // no UserPrompt events. Reads the provider's own transcript file
            // (Claude jsonl / Gemini chats json / Codex sibling jsonl) and
            // counts user-role entries. Cheap because most rows skip it —
            // anything Soul-Desktop spawned has promptCount > 0 already.
            if s.promptCount == 0 {
                s.transcriptTurns = countTranscriptTurns(
                    sessionId: id,
                    projectKey: key,
                    projectPath: projectPath,
                    sessionDir: "\(dir)/\(id)",
                    cache: dirCache
                )
            }

            out.append(s)
        }

        return out
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    /// Cached variant of `agentMatch`: walks every `~/.gemini/tmp/<basename>(-N)`
    /// sibling using the shared `GeminiDirCache`. Equivalent semantics — same
    /// "biggest content-bearing file wins" rule — just without re-listing.
    private static func agentMatchCached(sessionId: String, projectPath: String?, cache: GeminiDirCache) -> String? {
        let first8 = String(sessionId.prefix(8))
        let fm = FileManager.default

        if let projectPath {
            // O(1) gemini lookup via the per-scan first-8 index. The first
            // call to `cache.entries(at:)` for each sibling dir populates
            // the index automatically; subsequent sessions skip the scan.
            // Warm the index by listing all sibling chats dirs once.
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let base = (trimmed as NSString).lastPathComponent
            let geminiBase = "\(homePath)/.gemini/tmp"
            if let projects = try? fm.contentsOfDirectory(atPath: geminiBase) {
                for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
                    _ = cache.entries(at: "\(geminiBase)/\(proj)/chats", fm: fm)
                }
            }
            if let hit = cache.firstEightIndex[first8] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                let resumable: Bool = {
                    if let cached = cache.resumableCache[path] { return cached }
                    let r = isResumableGeminiChatFile(path)
                    cache.resumableCache[path] = r
                    return r
                }()
                if resumable { return "geminiCLI" }
            }

            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudePath = "\(homePath)/.claude/projects/\(encoded)/\(sessionId).jsonl"
            if fm.fileExists(atPath: claudePath) {
                return "claude"
            }

            // Pi: ~/.pi/agent/sessions/<encoded>/<timestamp>_<sid>.jsonl.
            // Encoding shape from pi-acp's session-map.json is `--<a-b-c>--`
            // (leading + trailing double-dash around the dash-joined parts).
            // List the dir once per project (cached in piSessionsByDir) and
            // extract the trailing UUID from every filename so subsequent
            // rows hit an O(1) set lookup.
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            let piEncoded = "--" + parts.joined(separator: "-") + "--"
            let piDir = "\(homePath)/.pi/agent/sessions/\(piEncoded)"
            let piSet: Set<String> = {
                if let hit = cache.piSessionsByDir[piDir] { return hit }
                var ids = Set<String>()
                if let entries = try? fm.contentsOfDirectory(atPath: piDir) {
                    for name in entries where name.hasSuffix(".jsonl") {
                        // Filename: <iso-ts>_<sid>.jsonl  →  parse last segment.
                        let stem = (name as NSString).deletingPathExtension
                        if let underscore = stem.lastIndex(of: "_") {
                            let sid = String(stem[stem.index(after: underscore)...])
                            if !sid.isEmpty { ids.insert(sid) }
                        }
                    }
                }
                cache.piSessionsByDir[piDir] = ids
                return ids
            }()
            if piSet.contains(sessionId) { return "pi" }
        }
        return nil
    }

    /// Cached variant of `SessionLoadability.canLoadFromDisk` for the
    /// `allSessions` hot loop. Same provider-aware NSID lookup, but the
    /// gemini chats dir listing is shared with `agentMatchCached`.
    private static func canLoadCached(sessionId sid: String, projectKey: String, projectPath: String, cache: GeminiDirCache) -> Bool {
        let fm = FileManager.default
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")

        // Claude path probe with provider-filtered NSID lookup.
        let claudeId = findNativeSessionID(projectKey: projectKey, sessionId: sid, provider: "claude") ?? sid
        if fm.fileExists(atPath: "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl") {
            return true
        }

        // Gemini probe via the cached first-8 index — O(1) per session.
        // `agentMatchCached` already warmed the index for every sibling
        // chats dir at this point in the scan.
        let geminiId = findNativeSessionID(projectKey: projectKey, sessionId: sid, provider: "geminiCLI") ?? sid
        let shortId = String(geminiId.prefix(8))
        if let hit = cache.firstEightIndex[shortId] {
            return Self.geminiChatHasContent(
                at: "\(hit.chatsDir)/\(hit.fileName)",
                expectedSessionId: geminiId
            )
        }
        return false
    }

    /// Count user-role entries in whichever provider transcript backs this
    /// session. Returns 0 when no transcript is reachable. Used to surface
    /// "~N turns" in the sidebar for rows whose kernel ledger never wrote
    /// `UserPrompt` events (terminal-origin sessions, ledger-less Gemini).
    /// Reads the file as `Data` (memory-mapped when possible) and counts
    /// needle byte ranges; avoids allocating a full Swift `String` for
    /// multi-MB Claude transcripts.
    private static func countTranscriptTurns(
        sessionId sid: String,
        projectKey key: String,
        projectPath: String?,
        sessionDir: String,
        cache: GeminiDirCache
    ) -> Int {
        let fm = FileManager.default

        // Claude: count `"type":"user"` occurrences in the transcript jsonl.
        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudeId = findNativeSessionID(projectKey: key, sessionId: sid, provider: "claude") ?? sid
            let claudePath = "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl"
            if fm.fileExists(atPath: claudePath) {
                let n = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: claudePath)
                if n > 0 { return n }
            }

            // Gemini: chat-file `"role":"user"` count. Path comes from the
            // first-8 reverse index the loadability check already populated.
            let geminiId = findNativeSessionID(projectKey: key, sessionId: sid, provider: "geminiCLI") ?? sid
            let shortId = String(geminiId.prefix(8))
            if let hit = cache.firstEightIndex[shortId] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                let n = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: path)
                if n > 0 { return n }
            }
        }

        // Codex: sibling transcript jsonl inside the kernel ledger dir.
        let codexPath = "\(sessionDir)/transcript.jsonl"
        if fm.fileExists(atPath: codexPath) {
            let byType = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: codexPath)
            if byType > 0 { return byType }
            let byRole = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: codexPath)
            if byRole > 0 { return byRole }
        }

        return 0
    }

    /// Count non-overlapping occurrences of `needle` in the file at `path`.
    /// Memory-maps when the OS allows, falls back to a regular read, and
    /// uses `Data.range(of:in:)` which is significantly faster than naive
    /// byte loops for the small (~13–14 byte) needles we pass here.
    private static func countNeedle(_ needle: Data, inFileAt path: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe, .uncached]) else {
            return 0
        }
        var n = 0
        var range = 0..<data.count
        while let r = data.range(of: needle, in: range) {
            n += 1
            range = r.upperBound..<data.count
        }
        return n
    }

    /// Lightweight first-line sessionId + content check shared with
    /// `canLoadCached`. Mirrors `SessionLoadability.hasContent` but inlined
    /// to keep all probes pointing at the same cache.
    private static func geminiChatHasContent(at path: String, expectedSessionId sid: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1024)
        guard let s = String(data: head, encoding: .utf8) else { return false }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        guard let data = String(lines[0]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let firstSid = obj["sessionId"] as? String,
              firstSid == sid
        else { return false }
        return true
    }

    /// Classify a live session by whether an agent-side persistence file
    /// exists for this UUID. Ledger-shape heuristics are unreliable here
    /// (a kernel-only ledger can still be resumable if the agent persisted
    /// the chat under the same UUID, and a ledger with leftover NativeSessionID
    /// stubs can be un-resumable). Only the agent's own storage answers
    /// truthfully whether `session/load` will succeed.
    ///
    /// Checks gemini-cli (`~/.gemini/tmp/<any-proj>/chats/session-*-<first8>.json`)
    /// and Claude (`~/.claude/projects/<encoded-cwd>/<sid>.jsonl`). If either
    /// matches, the row is `.desktop` (= resumable). Otherwise `.terminal`
    /// if the ledger looks real, else `.unknown`.
    private static func detectOrigin(path: String, projectPath: String?, sessionId: String) -> SessionOrigin {
        if agentHasSession(sessionId: sessionId, projectPath: projectPath) {
            return .desktop
        }
        // Read the ledger once and classify. Two desktop signals beat the
        // agentHasSession lookup when the agent's internal UUID has diverged
        // from our kernel UUID (the SOUL-SOUL_DESKTOP-022 namespace case):
        //   - `NativeSessionID` written by ThreadController — we minted this
        //   - `UserPrompt` written by ThreadController.send — we minted this
        // Either is proof the row is ours regardless of whether we can find
        // a matching chat file via first8 prefix scan. Without this, the
        // live in-canvas thread vanishes from the sidebar the moment the
        // agent's transcript filename's first8 no longer matches.
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return .unknown }
        var hasTerminalSignal = false
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = obj["event"] as? String ?? ""
            if event == "NativeSessionID" || event == "UserPrompt" {
                return .desktop
            }
            if event == "SESSION_START" || event == "AfterTool" || event == "AfterAgent" || event == "AfterModel" {
                hasTerminalSignal = true
            }
        }
        return hasTerminalSignal ? .terminal : .unknown
    }

    /// Read `worktree_path` from the first `SESSION_START` event in a
    /// hooks.jsonl. Kernel writes this on the first line for sessions
    /// started inside a git worktree (SOUL-SOUL-007). Returns nil for
    /// main-tree sessions and ledgers that pre-date the tagging change.
    private static func worktreePathFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // First non-empty line only — kernel always writes SESSION_START first
        // when the file is created.
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).prefix(1) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "SESSION_START"
            else { return nil }
            return obj["worktree_path"] as? String
        }
        return nil
    }

    /// Read the timestamp on the first hook event for a session. This is the
    /// real session start — the kernel writes SESSION_START as the first line
    /// when the directory is created. Returns nil if the file is missing,
    /// empty, or the first line lacks a parseable timestamp.
    static func firstHookTimestamp(projectKey: String, sessionId: String) -> Date? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).prefix(1) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return parseTimestamp(obj["timestamp"] as? String)
        }
        return nil
    }

    private static func normalizeCwd(_ p: String) -> String {
        var s = p
        if s.hasSuffix("/") { s.removeLast() }
        return (s as NSString).standardizingPath
    }

    private static func agentHasSession(sessionId: String, projectPath: String?) -> Bool {
        return agentMatch(sessionId: sessionId, projectPath: projectPath) != nil
    }

    /// Like `agentHasSession` but reports *which* agent has the persistence
    /// file. Returns `"geminiCLI"` / `"claude"` / nil. Used at row-build
    /// time so the click handler can switch the harness to match.
    private static func agentMatch(sessionId: String, projectPath: String?) -> String? {
        let first8 = String(sessionId.prefix(8))
        let fm = FileManager.default

        // Gemini-cli stores chats at ~/.gemini/tmp/<dir>/chats/ where <dir>
        // is `basename(cwd)` with an optional `-N` collision suffix. We MUST
        // scope the lookup to dirs that map to this projectPath — `session/load`
        // is cwd-scoped, so a prefix match in some other project's chats dir
        // is a false positive (agent says "yes I have it" but load fails when
        // gemini is spawned in this cwd).
        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let base = (trimmed as NSString).lastPathComponent
            let geminiBase = "\(homePath)/.gemini/tmp"
            if let projects = try? fm.contentsOfDirectory(atPath: geminiBase) {
                for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
                    let chatsDir = "\(geminiBase)/\(proj)/chats"
                    // Gemini-cli switched session-file extension from .json to
                    // .jsonl mid-stream; old sessions still use .json. Accept
                    // either so live rows recorded under both formats surface.
                    guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
                    let matches = files.filter {
                        $0.hasSuffix("-\(first8).json") || $0.hasSuffix("-\(first8).jsonl")
                    }
                    // Surface only files that gemini-cli will actually be
                    // able to resume. Its `listSessions` skips any file
                    // that has only system messages (no user/assistant
                    // turns) — we mirror that check here so dead stub files
                    // don't surface as "live" rows and dead-end on click.
                    if matches.contains(where: { isResumableGeminiChatFile("\(chatsDir)/\($0)") }) {
                        return "geminiCLI"
                    }
                }
            }
        }

        // Claude: ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let path = "\(homePath)/.claude/projects/\(encoded)/\(sessionId).jsonl"
            if fm.fileExists(atPath: path) {
                return "claude"
            }
        }

        return nil
    }

    /// True iff the gemini-cli chat file at `path` carries at least one
    /// user-or-assistant turn. Mirrors gemini-cli's own `getAllSessionFiles`
    /// filter (sessionUtils.ts: `hasUserOrAssistantMessage`) so we never
    /// classify a metadata-only stub as resumable — it would dead-end on
    /// click with `Invalid session identifier`. Cheap: we scan up to 50
    /// lines, which is plenty to find the first user turn for any non-stub
    /// chat. Returns true on read errors so we don't accidentally hide
    /// healthy sessions if the JSONL has an unexpected shape.
    private static func isResumableGeminiChatFile(_ path: String) -> Bool {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        // Hard-stub guard: a brand-new gemini session is exactly one
        // metadata line, no `type` field. Bail without parsing.
        if lines.count <= 1 { return false }
        for line in lines.prefix(50) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let type = obj["type"] as? String,
               type == "user" || type == "assistant" || type == "model" {
                return true
            }
        }
        return false
    }

    /// Scan the first few hooks for a user-prompt event to use as a row title.
    /// Falls back to nil — the row will render "live N min ago" via the row UI.
    private static func firstUserPromptFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        
        // Pass 1: Look for explicit "Title" event
        for line in lines.prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if (obj["event"] as? String) == "Title", let text = obj["text"] as? String {
                return truncateForTitle(text)
            }
        }

        // Pass 2: Heuristic search for first user prompt or agent thought
        for line in lines.prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = (obj["event"] as? String) ?? ""
            let content = (obj["content"] as? String) ?? (obj["text"] as? String) ?? (obj["prompt"] as? String)
            
            if event == "UserPrompt" || event == "UserMessage" || event == "session/prompt" || event == "BeforeAgent" {
                if let text = content {
                    return truncateForTitle(text)
                }
            }
        }
        return nil
    }

    private static func truncateForTitle(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.count > 60 ? String(one.prefix(60)) + "…" : one
    }

    /// Append a JSON event to a session's hooks.jsonl. Uses POSIX `O_APPEND`
    /// so concurrent writes from the Python kernel (which also opens in
    /// append mode) interleave atomically per line. `FileHandle.seekToEnd +
    /// write` is two syscalls — another writer can extend the file between
    /// them and the Swift write then clobbers the tail.
    ///
    /// Schema matches the kernel's rows: `timestamp` (POSIX microsecond ISO,
    /// UTC) and `session_id` are injected if the caller didn't set them, so
    /// the row flows through the same finalize / replay pipelines as
    /// kernel-emitted rows.
    /// Serial queue that owns every kernel-ledger write. Single queue (not
    /// concurrent) so appends preserve the order callers submit them in —
    /// important because Replay merges by timestamp + arrival order and a
    /// scrambled UserPrompt/AfterAgent pair would render out of sequence.
    /// SOUL-SOUL_DESKTOP-063: moved off the main actor to unblock the UI
    /// during heavy turns (every UserPrompt + AfterAgent used to do a
    /// synchronous open()/write()/close() on whatever actor called it).
    private static let hookWriteQueue = DispatchQueue(
        label: "soul.registry.hook-write",
        qos: .utility
    )

    /// Cached timestamp formatter — DateFormatter allocation is non-trivial
    /// and we hit appendHook on every prompt + reply + tool call.
    private static let hookTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// SOUL-SOUL_DESKTOP-078: scan the live hooks.jsonl for any AfterTool
    /// event whose tool_call_id (or "tool_use_id" — Claude shape) matches
    /// `toolId`. Used by `fireToolCallTimeout` to classify the hang:
    ///
    ///   - true  → tool actually completed; ACP just didn't surface
    ///             `item/completed` to the desktop (class B in -078).
    ///   - false → tool genuinely never finished, or the kernel writer
    ///             never landed AfterTool (class A or C).
    ///
    /// Reads only the tail of hooks.jsonl (last ~256KB) — enough to find
    /// any plausibly-recent AfterTool without scanning the full ledger.
    /// Cheap; safe to call from the stall watchdog tick.
    static func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        // Match either "AfterTool" + tool_call_id, or AfterTool + tool_use_id
        // (Claude). Cheap substring check — false-positive risk is essentially
        // zero because the toolId is a UUID-ish opaque string.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("AfterTool"),
               line.contains(toolId) {
                return true
            }
        }
        return false
    }

    static func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
        // Snapshot the wall-clock at call time. The dispatch below may run a
        // few ms later; we want the timestamp to reflect when the caller
        // logged the event, not when the file write actually landed.
        let capturedAt = Date()
        var fullEvent = event
        if fullEvent["timestamp"] == nil {
            fullEvent["timestamp"] = hookTimestampFormatter.string(from: capturedAt)
        }
        if fullEvent["session_id"] == nil {
            fullEvent["session_id"] = sessionId
        }

        hookWriteQueue.async {
            let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let path = "\(dir)/hooks.jsonl"

            guard let data = try? JSONSerialization.data(withJSONObject: fullEvent),
                  let line = String(data: data, encoding: .utf8),
                  let payload = (line + "\n").data(using: .utf8)
            else { return }

            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.write(contentsOf: payload)
            try? handle.close()
        }
    }

    /// SOUL-SOUL_DESKTOP-065: stream-time capture of agent reply chunks.
    /// Every `agent_message_chunk` notification appends one line here so
    /// that if the provider child dies before its checkpoint flush AND
    /// before Soul-Desktop's end-of-turn `AfterAgent` write, the reply
    /// text still survives on disk and Replay can stitch it.
    ///
    /// Schema: `{ "ts": ISO-UTC, "bubble_id": <UUID>, "chunk": "<text>" }`.
    /// One line per chunk; the reader coalesces by `bubble_id` order to
    /// reconstruct each agent reply. Bounded growth: `retireChunks` empties
    /// the file at end-of-turn once `AfterAgent` has landed authoritatively
    /// in hooks.jsonl.
    static func appendAgentChunk(projectKey: String, sessionId: String, bubbleId: UUID, chunk: String) {
        let capturedAt = Date()
        let entry: [String: Any] = [
            "ts": hookTimestampFormatter.string(from: capturedAt),
            "bubble_id": bubbleId.uuidString,
            "chunk": chunk,
        ]
        hookWriteQueue.async {
            let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let path = "\(dir)/agent_chunks.jsonl"
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: data, encoding: .utf8),
                  let payload = (line + "\n").data(using: .utf8)
            else { return }
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.write(contentsOf: payload)
            try? handle.close()
        }
    }

    /// Drop the per-session chunk file once the turn's `AfterAgent` row has
    /// been authoritatively written to hooks.jsonl. Called at end of every
    /// successful turn so the chunk file doesn't grow unbounded across a
    /// long session. Idempotent.
    static func retireAgentChunks(projectKey: String, sessionId: String) {
        hookWriteQueue.async {
            let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/agent_chunks.jsonl"
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Read the most-recent NativeSessionID event for a session and return
    /// (provider, cwd) if present. Used by `liveSessions` to filter out rows
    /// the current harness can't actually resume.
    static func nativeSessionRecord(projectKey: String, sessionId: String) -> (provider: String?, cwd: String?)? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "NativeSessionID"
            else { continue }
            return (obj["provider"] as? String, obj["cwd"] as? String)
        }
        return nil
    }

    /// Outcome of a backfill attempt. Callers that only need a UUID for retry
    /// can read `.uuid`; callers that surface state to the user (sidebar
    /// Repair menu) switch on the cases.
    enum BackfillResult: Equatable {
        case hit(String)                       // newly written mapping
        case alreadyMapped(String)             // existing NativeSessionID on file
        case miss                              // no needle or no matching candidate
        case ambiguous(candidates: [String])   // multiple candidates with identical first prompt
        case unsupported                       // provider not eligible (e.g. pi)

        var uuid: String? {
            switch self {
            case .hit(let u), .alreadyMapped(let u): return u
            default: return nil
            }
        }
    }

    /// Content-match backfill of a missing `kernel_uuid → agent_uuid` mapping.
    /// SOUL-SOUL_DESKTOP-022: when `session/load` fails with `Invalid session
    /// identifier`, the kernel UUID we handed the agent is one it never minted.
    /// Scan the agent's native transcript directory, find a file whose first
    /// user prompt content-matches our hooks ledger's first prompt, and append
    /// a `NativeSessionID` event with `source: "backfill"`. After this the
    /// existing `findNativeSessionID` reader resolves cleanly on retry.
    ///
    /// Returns a typed `BackfillResult` (SOUL-SOUL_DESKTOP-029) so callers can
    /// surface miss / ambiguous outcomes to the user instead of swallowing nil.
    ///
    /// Safety: only appends to hooks.jsonl. Never writes to agent transcript
    /// directories, never overwrites an existing NativeSessionID.
    /// Bounded: ≤ 500 candidates × 64 KB read per candidate.
    static func backfillNativeSessionID(
        projectKey: String,
        sessionId: String,
        provider: String,
        cwd: String
    ) -> BackfillResult {
        // Short-circuit: if any NativeSessionID hook is already on file,
        // return it. The on-disk mapping wins — backfill never overwrites or
        // duplicates an existing record. This applies equally to identity
        // mappings (existing == sessionId, written at spawn): when session/load
        // fails despite an identity record, the failure is something other
        // than UUID-namespace divergence (parse error, capability bug, cwd
        // mismatch) and a content-match rescan would just append an unrelated
        // second mapping. Forced re-scan, if it's ever needed, belongs behind
        // an explicit force/repair API surface — not this implicit fall-through.
        if let existing = findNativeSessionID(projectKey: projectKey, sessionId: sessionId) {
            return .alreadyMapped(existing)
        }

        let hooksPath = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let ourPrompt = firstUserPromptFullFromHooks(path: hooksPath) else { return .miss }
        let needle = normalizeForMatch(ourPrompt)
        // Trivial first prompts ("hi", "ok", "/finalize") are too common to
        // disambiguate sessions. A 20-char floor avoids false-positive
        // backfills against unrelated chats that happen to start the same way.
        guard needle.count >= 20 else { return .miss }

        let candidates: [(nativeId: String, firstPrompt: String?)]
        switch provider {
        case "geminiCLI": candidates = scanGeminiCandidates(cwd: cwd)
        case "claude":    candidates = scanClaudeCandidates(cwd: cwd)
        default: return .unsupported
        }

        let hits = candidates.compactMap { c -> String? in
            guard let p = c.firstPrompt else { return nil }
            return normalizeForMatch(p) == needle ? c.nativeId : nil
        }

        switch hits.count {
        case 0:
            return .miss
        case 1:
            let nativeId = hits[0]
            appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "NativeSessionID",
                "provider": provider,
                "nativeId": nativeId,
                "cwd": cwd,
                "source": "backfill",
            ])
            return .hit(nativeId)
        default:
            appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "BackfillAmbiguous",
                "provider": provider,
                "cwd": cwd,
                "candidates": hits,
            ])
            return .ambiguous(candidates: hits)
        }
    }

    /// Write a chosen NativeSessionID mapping. Used by the sidebar's
    /// ambiguous-result popover so the user can resolve a tie by picking
    /// one of the candidate UUIDs. No content matching, no append guard
    /// beyond the appendHook line-atomic write.
    static func writeNativeSessionID(
        projectKey: String,
        sessionId: String,
        nativeId: String,
        provider: String,
        cwd: String,
        source: String = "manual"
    ) {
        appendHook(projectKey: projectKey, sessionId: sessionId, event: [
            "event": "NativeSessionID",
            "provider": provider,
            "nativeId": nativeId,
            "cwd": cwd,
            "source": source,
        ])
    }

    /// Whitespace-normalize a string for first-prompt content matching. The
    /// raw text the user typed may have leading/trailing whitespace or CRLF
    /// where the agent's transcript has LF; normalize before comparing so
    /// cosmetic differences don't break the match.
    private static func normalizeForMatch(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\r\n", with: "\n")
                         .components(separatedBy: .whitespacesAndNewlines)
                         .filter { !$0.isEmpty }
                         .joined(separator: " ")
        return collapsed
    }

    /// Non-truncating variant of `firstUserPromptFromHooks`. Used by backfill
    /// where we need the full text to content-match against agent transcripts;
    /// the truncated version is for sidebar titles only.
    private static func firstUserPromptFullFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = (obj["event"] as? String) ?? ""
            if event == "UserPrompt" || event == "UserMessage" || event == "session/prompt" || event == "BeforeAgent" {
                let content = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String)
                if let text = content, !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// Scan `~/.gemini/tmp/<basename-of-cwd>[*]/chats/session-*.{json,jsonl}`
    /// for resumable chat files and return their self-reported sessionId +
    /// first user-role prompt text. Capped at 500 files; 64 KB read budget
    /// per file.
    private static func scanGeminiCandidates(cwd: String) -> [(nativeId: String, firstPrompt: String?)] {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let base = (trimmed as NSString).lastPathComponent
        let root = "\(homePath)/.gemini/tmp"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var out: [(nativeId: String, firstPrompt: String?)] = []
        for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
            let chatsDir = "\(root)/\(proj)/chats"
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
            for f in files where f.hasSuffix(".json") || f.hasSuffix(".jsonl") {
                if out.count >= 500 { return out }
                let path = "\(chatsDir)/\(f)"
                if let (sid, prompt) = readGeminiChatHeader(path: path) {
                    out.append((sid, prompt))
                }
            }
        }
        return out
    }

    /// Extract `(sessionId, firstUserPromptText)` from a gemini-cli chat file.
    /// Handles both formats:
    ///   - `.json`  — single object with `sessionId` and `messages: [{type, content: [{text}]}]`
    ///   - `.jsonl` — header line carries `sessionId`; subsequent lines are messages,
    ///                interleaved with `{"$set": {...}}` mutations we skip.
    /// Reads at most 64 KB from the file.
    private static func readGeminiChatHeader(path: String) -> (sid: String, firstPrompt: String?)? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        let slice = Data(bytes: buf, count: n)
        guard let text = String(data: slice, encoding: .utf8) else { return nil }

        if path.hasSuffix(".jsonl") {
            var sid: String? = nil
            var prompt: String? = nil
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if sid == nil, let s = obj["sessionId"] as? String { sid = s }
                if prompt == nil,
                   (obj["type"] as? String) == "user",
                   let content = obj["content"] as? [[String: Any]],
                   let first = content.first?["text"] as? String {
                    prompt = first
                }
                if sid != nil && prompt != nil { break }
            }
            guard let s = sid else { return nil }
            return (s, prompt)
        }

        // .json: try full parse first. Large transcripts (the truss-labs
        // 11 MB chat is a real example) exceed the 64 KB read cap and the
        // truncated JSON won't deserialize — fall back to a regex pull of
        // `sessionId` so the candidate still counts. Prompt is best-effort:
        // gemini writes it within the first ~1 KB so the head usually has
        // it, and we regex it out of the head in the same pass.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["sessionId"] as? String {
            var prompt: String? = nil
            if let msgs = obj["messages"] as? [[String: Any]] {
                for m in msgs {
                    if (m["type"] as? String) == "user",
                       let content = m["content"] as? [[String: Any]],
                       let first = content.first?["text"] as? String {
                        prompt = first
                        break
                    }
                }
            }
            return (s, prompt)
        }
        // Truncated-JSON fallback: regex sessionId out of the head.
        let sidPattern = #""sessionId"\s*:\s*"([0-9a-fA-F-]{36})""#
        guard let sidRe = try? NSRegularExpression(pattern: sidPattern),
              let m = sidRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let sidRange = Range(m.range(at: 1), in: text)
        else { return nil }
        let sid = String(text[sidRange])
        // Best-effort prompt salvage from the same head bytes. Match the
        // first `{"type":"user","content":[{"text":"…"}]}` shape; gemini
        // writes the first user message within ~1 KB of the messages array
        // start, so it's reliably inside our 64 KB window.
        var prompt: String? = nil
        let promptPattern = #""type"\s*:\s*"user"\s*,\s*"content"\s*:\s*\[\s*\{\s*"text"\s*:\s*"((?:[^"\\]|\\.)*)""#
        if let promptRe = try? NSRegularExpression(pattern: promptPattern),
           let pm = promptRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let pRange = Range(pm.range(at: 1), in: text) {
            let raw = String(text[pRange])
            prompt = raw
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (sid, prompt)
    }

    /// Scan `~/.claude/projects/<encoded-cwd>/*.jsonl` for transcripts and
    /// return `(sessionId, firstUserPromptText)`. The sessionId IS the
    /// filename stem for Claude — no in-file extraction needed.
    private static func scanClaudeCandidates(cwd: String) -> [(nativeId: String, firstPrompt: String?)] {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let dir = "\(homePath)/.claude/projects/\(encoded)"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var out: [(nativeId: String, firstPrompt: String?)] = []
        for f in files where f.hasSuffix(".jsonl") {
            if out.count >= 500 { return out }
            let stem = String(f.dropLast(".jsonl".count))
            guard UUID(uuidString: stem) != nil else { continue }
            let path = "\(dir)/\(f)"
            let prompt = readClaudeFirstUserPrompt(path: path)
            out.append((stem, prompt))
        }
        return out
    }

    /// Read the first real `type: "user"` prompt from a Claude transcript.
    /// Skips tool_result records (where `message.content` is a list) — those
    /// are bookkeeping, not user input. 64 KB read cap.
    private static func readClaudeFirstUserPrompt(path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        let slice = Data(bytes: buf, count: n)
        guard let text = String(data: slice, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "user" else { continue }
            let msg = obj["message"] as? [String: Any]
            if let s = msg?["content"] as? String, !s.isEmpty {
                return s
            }
            // List content = tool_result; keep scanning.
        }
        return nil
    }

    /// Search for a `NativeSessionID` event in the session's hooks.jsonl.
    /// Read the recorded provider for a session from its hooks ledger. Any
    /// kernel event line that carries a `provider` field counts; we take the
    /// first non-empty one we see. Returns the raw provider string ("claude",
    /// "geminiCLI", "pi", "codex") so the caller can map it to a Provider
    /// enum case. nil if the session has no ledger or no provider field was
    /// written.
    ///
    /// SOUL-SOUL_DESKTOP-043: AppShell.loadSession uses this to override the
    /// active harness when the user opens an archived row from a different
    /// provider than what's currently active. Without it, a Gemini session
    /// clicked while Claude is the active harness spawns the wrong agent and
    /// fails session/load against a UUID it never minted.
    static func findProvider(projectKey: String, sessionId: String) -> String? {
        let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"

        // Primary signal: NativeSessionID hook (any provider that
        // Soul-Desktop spawned writes one in `ensureSession`).
        let hooksPath = "\(dir)/hooks.jsonl"
        if FileManager.default.fileExists(atPath: hooksPath),
           let blob = try? String(contentsOfFile: hooksPath, encoding: .utf8) {
            for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let prov = obj["provider"] as? String,
                      !prov.isEmpty
                else { continue }
                return prov
            }
        }

        // Codex fallback: codex sessions are the only ones that get a
        // sibling `transcript.jsonl` file in the registry directory
        // (codex writes its own per-session transcript there). Before the
        // NativeSessionID hook landed for codex spawns, legacy codex
        // sessions had no marker — this fallback lets those rows still
        // route correctly. New codex sessions will hit the NSID branch
        // above first.
        if FileManager.default.fileExists(atPath: "\(dir)/transcript.jsonl") {
            return Provider.codex.rawValue
        }
        return nil
    }

    /// Resolve the agent-side UUID Soul-Desktop recorded for this session.
    ///
    /// When `provider` is supplied, only return NSIDs whose recorded provider
    /// matches. This matters when the same kernel UUID has been touched by
    /// more than one provider over its lifetime (e.g. Claude finalize + later
    /// Gemini resume): the most-recent NSID hook would otherwise misroute a
    /// Claude resume into Gemini's UUID namespace, and `session/load` falls
    /// through to a fresh-session spawn.
    ///
    /// `provider` is the canonical Soul-Desktop key — `"claude"` / `"geminiCLI"`
    /// / `"pi"` / `"codex"` — matching `Provider.rawValue` and the value the
    /// kernel writes into the hook record. Pass `nil` to keep the legacy
    /// "any provider, most recent wins" behavior (only callers that don't
    /// know the provider, e.g. read-only loadability checks pre-route, should
    /// do this).
    static func findNativeSessionID(projectKey: String, sessionId: String, provider: String? = nil) -> String? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        // Scan backwards: most recent matching NSID wins. Provider filter
        // applied per-record so a stale opposite-provider mapping at the
        // bottom of the ledger doesn't shadow the right one above it.
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "NativeSessionID",
                  let nativeId = obj["nativeId"] as? String
            else { continue }
            if let want = provider {
                guard (obj["provider"] as? String) == want else { continue }
            }
            return nativeId
        }
        return nil
    }

    /// Structured Quad pulled from the most-recent `<ts>_<sid>.json` finalize
    /// record for a session. Returns nil if no finalize file exists. Used by
    /// `ThreadController.hydrateFromDisk` to render a finalize summary card
    /// in the canvas so the user can see what a session accomplished without
    /// reading the JSON directly.
    struct FinalizeRecord: Hashable {
        var intent: String?
        var summary: String?
        var rationale: String?
        var fixed: String?
        var nextStep: String?
        var timestamp: Date?
    }

    static func latestFinalize(projectKey: String, sessionId: String) -> FinalizeRecord? {
        let dir = "\(registryPath)/sessions/\(projectKey)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        // Filename shapes the kernel writes:
        //   <uuid>.json
        //   <ts>_<uuid>.json   (the common case; multiple per session as the
        //                       user re-finalizes)
        let matches = entries.filter { name in
            guard name.hasSuffix(".json") else { return false }
            let stem = String(name.dropLast(5))
            if stem == sessionId { return true }
            if let tail = stem.split(separator: "_").last, String(tail) == sessionId { return true }
            return false
        }
        // Most recent finalize wins — `<ts>_<uuid>` filenames sort
        // lexicographically by timestamp prefix.
        guard let latest = matches.sorted().last else { return nil }
        let path = "\(dir)/\(latest)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return FinalizeRecord(
            intent: stringOrNil(obj["intent"]),
            summary: stringOrNil(obj["summary"]),
            rationale: stringOrNil(obj["rationale"]),
            fixed: stringOrNil(obj["fixed"]),
            nextStep: stringOrNil(obj["next_step"]) ?? stringOrNil(obj["next"]),
            timestamp: parseTimestamp(obj["timestamp"] as? String)
        )
    }

    /// Search for a `Title` event in the session's hooks.jsonl.
    static func findTitle(projectKey: String, sessionId: String) -> String? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "Title",
                  let text = obj["text"] as? String
            else { continue }
            return text
        }
        return nil
    }

    /// SOUL-SOUL_DESKTOP-038: read UserPrompt hooks whose text starts with a
    /// slash command (e.g. `/decision`, `/finalize`). Terminal Claude Code
    /// expands these client-side before the model API sees them, so a
    /// session/load via ACP never re-streams them. The Soul harness captures
    /// the raw text into hooks.jsonl, so we merge those back into the canvas
    /// on load to keep the slash-command chip rendering consistent across
    /// surfaces. Returns chronological order.
    static func slashCommandPrompts(projectKey: String, sessionId: String) -> [(text: String, timestamp: Date)] {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        // hooks.jsonl writes microsecond-precision UTC timestamps with a Z
        // suffix (post -027). Tolerate the legacy naive-local format too so
        // older files keep working.
        let withZ = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        let naive = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"

        var out: [(text: String, timestamp: Date)] = []
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = (obj["event"] as? String) ?? ""
            guard event == "UserPrompt" || event == "UserMessage" else { continue }
            let raw = (obj["text"] as? String)
                ?? (obj["content"] as? String)
                ?? (obj["prompt"] as? String)
                ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { continue }
            // Match the same /<kebab> shape UserMessageRow.parsed accepts so we
            // don't inject text that wouldn't render as a chip anyway.
            let body = trimmed.dropFirst()
            let name: Substring = {
                if let space = body.firstIndex(of: " ") { return body[..<space] }
                if let nl = body.firstIndex(of: "\n") { return body[..<nl] }
                return body
            }()
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { continue }
            let tsStr = (obj["timestamp"] as? String) ?? ""
            fmt.dateFormat = withZ
            let ts = fmt.date(from: tsStr)
                ?? { fmt.dateFormat = naive; return fmt.date(from: tsStr) }()
                ?? Date()
            out.append((text: trimmed, timestamp: ts))
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    private static func hooksLineCount(projectKey: String, sessionId: String) -> Int {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return 0 }
        return blob.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func transcriptUserCount(sessionId: String, cwd: String) -> Int {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let path = homePath + "/.claude/projects/\(encoded)/\(sessionId).jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return 0 }
        var n = 0
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            // Quick substring check beats JSON parse for 30+ sessions.
            // Claude writes tool_results as user-type records too, so a raw
            // "type":"user" count is wildly inflated. Real prompts carry a
            // string content field; tool_results carry a list with
            // "tool_use_id" / "tool_result" markers — exclude those.
            let isUserType = line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")
            guard isUserType else { continue }
            if line.contains("tool_use_id") || line.contains("\"tool_result\"") { continue }
            n += 1
        }
        return n
    }

    // MARK: - helpers

    private static func expand(_ p: String) -> String {
        guard p.hasPrefix("~") else { return p }
        return NSString(string: p).expandingTildeInPath
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        let f3 = DateFormatter()
        f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.timeZone = TimeZone(identifier: "UTC")
        return f3.date(from: s)
    }

    private static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    private static func stringOrNil(_ v: Any?) -> String? {
        guard let s = v as? String, s != "None", !s.isEmpty else { return nil }
        return s
    }
}
