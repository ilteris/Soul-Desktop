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
    /// True when the kernel wrote a `<uuid>/hooks.jsonl` ledger but no sibling
    /// `<uuid>.json` finalize summary exists yet. These rows stay visible
    /// under their project until /finalize promotes them to Chats.
    var isLive: Bool = false
    /// Finalized but has activity since: hooks.jsonl mtime > json mtime. The
    /// summary in the Chats row is stale; user should /finalize again to refresh.
    var isDirty: Bool = false
    /// Where this live session was started from. Only meaningful for live
    /// rows; finalized sessions leave this at `.unknown`.
    var origin: SessionOrigin = .unknown
    /// Absolute path of the git worktree the session was started in, when
    /// the kernel detected one. Null for main-tree sessions and pre-007
    /// sessions. Read from hooks.jsonl `SESSION_START` (live) or the
    /// finalized session JSON top-level field. Drives sidebar sub-grouping.
    var worktreePath: String? = nil
    /// Which agent has a persistence file for this UUID. Set only for live
    /// rows by `liveSessions` (derived from agentHasSession). Used by
    /// `AppShell.loadSession` to pick the right harness on click — without
    /// this, a Claude session clicked while the harness is Gemini would
    /// spawn gemini and fail `session/load`.
    var liveProvider: String? = nil
}

enum SoulRegistry {
    nonisolated(unsafe) static var homePath: String = NSHomeDirectory()
    nonisolated(unsafe) static var soulPath: String = homePath + "/dotfiles/soul"
    nonisolated(unsafe) static var registryPath: String = homePath + "/soul_registry"

    /// Per-project cache for the heavy scan (sessions + live). Keyed by
    /// project id; refresh when the sessions/<key> directory mtime advances.
    /// Lives at class-level so it survives view rebuilds.
    private struct ProjectCache {
        var dirMtime: Date
        var sessions: [SoulSession]
        var live: [SoulSession]
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ProjectCache] = [:]

    /// Read cached scan results if the registry directory hasn't changed.
    /// Returns nil on miss / stale. Callers should fall back to a fresh scan.
    static func cachedSessions(forProject key: String) -> (sessions: [SoulSession], live: [SoulSession])? {
        let now = projectStamp(key: key)
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let hit = cache[key], hit.dirMtime == now else { return nil }
        return (hit.sessions, hit.live)
    }

    static func warmCache(forProject key: String, sessions: [SoulSession], live: [SoulSession]) {
        let m = projectStamp(key: key)
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key] = ProjectCache(dirMtime: m, sessions: sessions, live: live)
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

        // Sort by recent activity: mtime of the sessions dir wins, then project path mtime.
        // Falls back alphabetic when both are missing (fresh project, no sessions yet).
        return mapped.sorted { lhs, rhs in
            let la = lastActivity(for: lhs)
            let ra = lastActivity(for: rhs)
            if la != ra { return la > ra }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func lastActivity(for p: SoulProject) -> Date {
        let sessionsDir = "\(registryPath)/sessions/\(p.id)"
        if let m = (try? FileManager.default.attributesOfItem(atPath: sessionsDir)[.modificationDate]) as? Date {
            return m
        }
        if !p.path.isEmpty,
           let m = (try? FileManager.default.attributesOfItem(atPath: p.path)[.modificationDate]) as? Date {
            return m
        }
        return Date.distantPast
    }

    static func activeProjects() -> [SoulProject] {
        projects().filter { ($0.status ?? "active") == "active" }
    }

    // MARK: - Sessions

    static func sessions(forProject key: String, limit: Int = 50, projectPath: String? = nil) -> [SoulSession] {
        let dir = "\(registryPath)/sessions/\(key)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        // Fast path: sort filenames by file mtime first, parse only the top N.
        // For projects with hundreds of finalized sessions this turns an O(n)
        // parse+sort into ~5 parses regardless of total session count.
        let candidates = entries
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (name: String, id: String, mtime: Date)? in
                // Finalize files come in two shapes:
                //   <uuid>.json
                //   <timestamp>_<uuid>.json    (kernel-prefixed, the common case)
                // Extract whichever UUID-looking trailing component we can find.
                let stem = name.replacingOccurrences(of: ".json", with: "")
                let id: String? = {
                    if UUID(uuidString: stem) != nil { return stem }
                    if let tail = stem.split(separator: "_").last, UUID(uuidString: String(tail)) != nil {
                        return String(tail)
                    }
                    return nil
                }()
                guard let id else { return nil }
                let path = "\(dir)/\(name)"
                return (name, id, mtime(path))
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(limit * 2)   // tiny overshoot so dedupe doesn't underfill

        let parsed: [SoulSession] = candidates.compactMap { entry in
            let path = "\(dir)/\(entry.name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let id = obj["session_id"] as? String ?? entry.id
            let ts = parseTimestamp(obj["timestamp"] as? String) ?? entry.mtime
            return SoulSession(
                id: id,
                project: key,
                timestamp: ts,
                intent: stringOrNil(obj["intent"]),
                summary: stringOrNil(obj["summary"]),
                source: obj["source"] as? String,
                status: obj["status"] as? String,
                worktreePath: stringOrNil(obj["worktree_path"])
            )
        }

        var deduped: [String: SoulSession] = [:]
        for s in parsed {
            if let existing = deduped[s.id], existing.timestamp >= s.timestamp { continue }
            deduped[s.id] = s
        }
        let sorted = deduped.values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }

        // Enrich each row with event count (cheap line count on small files).
        // Prompt count is deliberately skipped here — it requires reading the
        // entire Claude transcript (often megabytes) and was the dominant cost
        // when switching projects. The sidebar chip falls back to eventCount.
        _ = projectPath   // kept for API compat; reintroduce if we async-load promptCount later
        return sorted.map { session in
            var s = session
            s.eventCount = hooksLineCount(projectKey: key, sessionId: s.id)
            // Staleness: hooks ledger advanced past the last finalize. The
            // displayed summary in the row is no longer authoritative — user
            // resumed and added turns without re-running /finalize.
            let hooksPath = "\(registryPath)/sessions/\(key)/\(s.id)/hooks.jsonl"
            let jsonPath = "\(registryPath)/sessions/\(key)/\(s.id).json"
            if FileManager.default.fileExists(atPath: hooksPath) {
                let h = mtime(hooksPath)
                let j = mtime(jsonPath)
                // 5s grace: finalize writes both files in succession; tiny
                // mtime jitter shouldn't flag the row.
                if h.timeIntervalSince(j) > 5 { s.isDirty = true }
            }
            return s
        }
    }

    /// Live, un-finalized sessions for a project. Detection rule (matches the
    /// kernel layout): a directory `<uuid>/` containing `hooks.jsonl` with no
    /// sibling `<uuid>.json` file. Returned newest-first by hooks.jsonl mtime.
    ///
    /// Filters to keep the row count sane:
    ///   - Drop dirs where hooks.jsonl has fewer than `minEvents` lines (those
    ///     are usually crashes / spawned-then-cancelled spawns the kernel
    ///     leaves behind, not real conversations).
    ///   - Drop anything older than `maxAge` (default: 24h) — anything that
    ///     old should have been finalized; treating it as "live" lies.
    ///   - Optionally cap the return at `limit` (default 5) so a chatty
    ///     project doesn't flood the sidebar.
    static func liveSessions(
        forProject key: String,
        minEvents: Int = 4,
        maxAge: TimeInterval = 24 * 60 * 60,
        limit: Int = 5,
        projectPath: String? = nil,
        currentProvider: String? = nil
    ) -> [SoulSession] {
        let dir = "\(registryPath)/sessions/\(key)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let jsonNames = Set(entries.filter { $0.hasSuffix(".json") }
                                    .map { $0.replacingOccurrences(of: ".json", with: "") })
        let now = Date()

        // Phase 1: cheap pre-sort by hooks.jsonl mtime, no file reads yet.
        let candidates: [(id: String, mtime: Date, path: String)] = entries
            .compactMap { entry in
                guard UUID(uuidString: entry) != nil else { return nil }
                if jsonNames.contains(entry) { return nil }
                let hooks = "\(dir)/\(entry)/hooks.jsonl"
                guard fm.fileExists(atPath: hooks) else { return nil }
                let ts = mtime(hooks)
                if now.timeIntervalSince(ts) > maxAge { return nil }
                return (entry, ts, hooks)
            }
            .sorted { $0.mtime > $1.mtime }

        // Phase 2: only read & parse the top candidates. We over-fetch a bit
        // so the filter doesn't underfill the limit. Two qualifying shapes:
        //   - kernel-rich ledgers (≥ `minEvents` lines) — real terminal/kernel
        //     sessions that wrote SESSION_START + a few tool/agent rows
        //   - Soul-Desktop-thin ledgers — sessions Soul-Desktop spawned where
        //     the kernel hooks bridge didn't fire (no SOUL_SESSION_ID env),
        //     so the ledger only has a UserPrompt + maybe a Title +
        //     NativeSessionID. The presence of a UserPrompt is the actual
        //     signal that this is a real conversation, not a crash residue.
        var out: [SoulSession] = []
        for c in candidates.prefix(limit * 2) {
            let events = hooksLineCount(projectKey: key, sessionId: c.id)
            let firstPrompt = firstUserPromptFromHooks(path: c.path)
            if events < minEvents && firstPrompt == nil { continue }
            let origin = detectOrigin(path: c.path, projectPath: projectPath, sessionId: c.id)
            // Hide un-hydratable rows. Without an agent-side chat file the
            // row can't `session/load`, so surfacing it as "live" misleads —
            // clicking it dead-ends. We still keep these on disk for the
            // legacy correlate-and-remap path (SOUL-SOUL_DESKTOP-020).
            if origin != .desktop { continue }
            // No further provider/cwd filtering: hiding rows was producing
            // "where did my session go?" without a clear upside. The
            // `agentHasSession` check above already gates to rows whose
            // chat file lives in this project's cwd-basename gemini dir,
            // and `loadSession` will auto-switch the harness on click.
            // If load eventually fails for a same-basename cwd collision,
            // the user sees the error and can act — better than silent drop.
            out.append(SoulSession(
                id: c.id,
                project: key,
                timestamp: c.mtime,
                intent: firstPrompt,
                summary: firstPrompt,
                source: nil,
                status: "live",
                eventCount: events,
                promptCount: 0,
                isLive: true,
                origin: origin,
                worktreePath: worktreePathFromHooks(path: c.path),
                liveProvider: agentMatch(sessionId: c.id, projectPath: projectPath)
            ))
            if out.count >= limit { break }
        }
        return out
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
    static func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
        let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let path = "\(dir)/hooks.jsonl"

        var fullEvent = event
        if fullEvent["timestamp"] == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            fullEvent["timestamp"] = f.string(from: Date())
        }
        if fullEvent["session_id"] == nil {
            fullEvent["session_id"] = sessionId
        }

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

    /// Content-match backfill of a missing `kernel_uuid → agent_uuid` mapping.
    /// SOUL-SOUL_DESKTOP-022: when `session/load` fails with `Invalid session
    /// identifier`, the kernel UUID we handed the agent is one it never minted.
    /// Scan the agent's native transcript directory, find a file whose first
    /// user prompt content-matches our hooks ledger's first prompt, and append
    /// a `NativeSessionID` event with `source: "backfill"`. After this the
    /// existing `findNativeSessionID` reader resolves cleanly on retry.
    ///
    /// Returns the discovered native UUID on a unique match. Returns nil on
    /// no-match, on ambiguity (writes a `BackfillAmbiguous` diagnostic hook
    /// listing the candidates so the user can disambiguate manually), and on
    /// unsupported providers (Pi already has a direct mapping via
    /// `~/.pi/pi-acp/session-map.json`).
    ///
    /// Safety: only appends to hooks.jsonl. Never writes to agent transcript
    /// directories, never overwrites an existing non-identity NativeSessionID.
    /// Bounded: ≤ 500 candidates × 64 KB read per candidate.
    static func backfillNativeSessionID(
        projectKey: String,
        sessionId: String,
        provider: String,
        cwd: String
    ) -> String? {
        // Short-circuit: if a non-identity mapping is already on file, return
        // it. Identity mapping (existing == sessionId) is what we wrote at
        // spawn; if session/load failed anyway the agent must have minted a
        // different UUID, so we proceed with the scan.
        if let existing = findNativeSessionID(projectKey: projectKey, sessionId: sessionId),
           existing != sessionId {
            return existing
        }

        let hooksPath = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let ourPrompt = firstUserPromptFullFromHooks(path: hooksPath) else { return nil }
        let needle = normalizeForMatch(ourPrompt)
        // Trivial first prompts ("hi", "ok", "/finalize") are too common to
        // disambiguate sessions. A 20-char floor avoids false-positive
        // backfills against unrelated chats that happen to start the same way.
        guard needle.count >= 20 else { return nil }

        let candidates: [(nativeId: String, firstPrompt: String?)]
        switch provider {
        case "geminiCLI": candidates = scanGeminiCandidates(cwd: cwd)
        case "claude":    candidates = scanClaudeCandidates(cwd: cwd)
        default: return nil
        }

        let hits = candidates.compactMap { c -> String? in
            guard let p = c.firstPrompt else { return nil }
            return normalizeForMatch(p) == needle ? c.nativeId : nil
        }

        switch hits.count {
        case 0:
            return nil
        case 1:
            let nativeId = hits[0]
            appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "NativeSessionID",
                "provider": provider,
                "nativeId": nativeId,
                "cwd": cwd,
                "source": "backfill",
            ])
            return nativeId
        default:
            appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "BackfillAmbiguous",
                "provider": provider,
                "cwd": cwd,
                "candidates": hits,
            ])
            return nil
        }
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
            if event == "UserPrompt" || event == "UserMessage" || event == "session/prompt" {
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
    static func findNativeSessionID(projectKey: String, sessionId: String) -> String? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        // Scan backwards: if there are multiple, the most recent one is the
        // current native session we should resume.
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "NativeSessionID",
                  let nativeId = obj["nativeId"] as? String
            else { continue }
            return nativeId
        }
        return nil
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
