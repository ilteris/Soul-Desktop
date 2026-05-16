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
/// them (the kernel and the agent CLI mint UUIDs in separate namespaces) until
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
    /// True iff the agent is currently processing a turn in this session.
    /// Drives the "working" indicator in the sidebar.
    var isWorking: Bool = false
    /// True iff a live session has no activity in the last N minutes.
    /// Used to distinguish active terminal sessions from abandoned ones.
    var isStale: Bool = false
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

    /// Single-pass metadata pulled from one read of a session's hooks.jsonl.
    /// Replaces five separate file reads per session — the dominant cost
    /// when expanding a project with dozens of finalized sessions.
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
        /// Parent PID stamped on SESSION_START. When it equals 1 (launchd)
        /// and no UserPrompt ever lands, this row is daemon residue.
        var sessionStartPpid: Int? = nil
        /// Map of provider -> native UUID from NativeSessionID events.
        var nativeSessionIDs: [String: String] = [:]
    }

    private static func readHooksMetadata(path: String) -> HooksMetadata {
        var meta = HooksMetadata()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else { return meta }
        if data.isEmpty { return meta }

        // 1. eventCount: Count newlines in binary data.
        let newline = Data([0x0A])
        meta.eventCount = countNeedle(newline, in: data)
        // Adjust if the file doesn't end with a newline.
        if let last = data.last, last != 0x0A { meta.eventCount += 1 }
        else if meta.eventCount == 0 && !data.isEmpty { meta.eventCount = 1 }

        // 2. promptCount: Fast binary scan for event markers.
        let userPromptNeedle = Data("\"event\":\"UserPrompt\"".utf8)
        let userMessageNeedle = Data("\"event\":\"UserMessage\"".utf8)
        meta.promptCount = countNeedle(userPromptNeedle, in: data) + countNeedle(userMessageNeedle, in: data)

        // 3. Head metadata: parse first 64KB for title, worktree, start-ppid.
        let maxHead = min(data.count, 64 * 1024)
        let head = data.prefix(maxHead)
        if let headStr = String(data: head, encoding: .utf8) {
            let lines = headStr.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let ldata = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any]
                else { continue }
                let event = (obj["event"] as? String) ?? ""

                if event == "SESSION_START", meta.worktreePath == nil {
                    meta.worktreePath = obj["worktree_path"] as? String
                    if let p = obj["ppid"] as? Int { meta.sessionStartPpid = p }
                }
                if event == "Title", meta.titleHook == nil {
                    meta.titleHook = (obj["text"] as? String) ?? (obj["title"] as? String)
                }
                if (event == "UserPrompt" || event == "UserMessage") && meta.firstUserPrompt == nil {
                    let text = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String)
                    if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        meta.firstUserPrompt = String(t.prefix(120))
                    }
                }
                if event == "NativeSessionID" {
                    if let prov = obj["provider"] as? String,
                       let nid = obj["native_session_id"] as? String {
                        meta.nativeSessionIDs[prov] = nid
                    }
                    meta.hasNativeOrUserPrompt = true
                }
                if event == "UserPrompt" {
                    meta.hasNativeOrUserPrompt = true
                }
                if event == "SESSION_START" || event == "AfterTool" || event == "AfterAgent" || event == "AfterModel" {
                    meta.hasTerminalSignal = true
                }
                if let ts = parseTimestamp(obj["timestamp"] as? String) {
                    if meta.firstEventTimestamp == nil {
                        meta.firstEventTimestamp = ts
                    }
                }
            }
        }

        // 4. Tail metadata: parse last 8KB for the most recent timestamp.
        let maxTail = min(data.count, 8 * 1024)
        let tail = data.suffix(maxTail)
        if let tailStr = String(data: tail, encoding: .utf8) {
            let lines = tailStr.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let ldata = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any],
                      let ts = parseTimestamp(obj["timestamp"] as? String)
                else { continue }
                meta.lastEventTimestamp = ts
                break
            }
        }

        // 5. Deep presence fallback: scan whole file only if signals not in head.
        if !meta.hasNativeOrUserPrompt {
            let nsidNeedle = Data("\"event\":\"NativeSessionID\"".utf8)
            if data.range(of: nsidNeedle) != nil || data.range(of: userPromptNeedle) != nil {
                meta.hasNativeOrUserPrompt = true
            }
        }
        if !meta.hasTerminalSignal {
            let signals = ["SESSION_START", "AfterTool", "AfterAgent", "AfterModel"]
            for s in signals {
                if data.range(of: Data("\"event\":\"\(s)\"".utf8)) != nil {
                    meta.hasTerminalSignal = true
                    break
                }
            }
        }

        return meta
    }

    private static func countNeedle(_ needle: Data, in data: Data) -> Int {
        var n = 0
        var range = 0..<data.count
        while let r = data.range(of: needle, in: range) {
            n += 1
            range = r.upperBound..<data.count
        }
        return n
    }

    /// Per-scan cache of gemini chat-dir listings + a first-8-char reverse
    /// index that maps `<first8>` → `(chatsDir, filename, isResumable)`.
    private final class GeminiDirCache {
        var listings: [String: [String]] = [:]    // chatsDir path → filenames
        var firstEightIndex: [String: (chatsDir: String, fileName: String)] = [:]
        var resumableCache: [String: Bool] = [:]
        var piSessionsByDir: [String: Set<String>] = [:]
        private var built: Set<String> = []
        /// Cached list of Gemini project directories that match the current
        /// projectPath. Populated once per scan.
        var matchedGeminiChatsDirs: [String]? = nil

        func indexFirstEights(chatsDir: String, entries: [String]) {
            guard !built.contains(chatsDir) else { return }
            built.insert(chatsDir)
            for name in entries {
                guard name.hasSuffix(".jsonl") || name.hasSuffix(".json")
                      || name.contains(".jsonl.bak-") || name.contains(".jsonl.corrupt-")
                else { continue }
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

        struct Shape {
            var finalizeName: String?
            var finalizePath: String?
            var hooksPath: String?
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

        let ranked = shapes.map { (id, shape) -> (id: String, shape: Shape, recency: Date) in
            let m = max(shape.jsonMtime ?? .distantPast, shape.hooksMtime ?? .distantPast)
            return (id, shape, m)
        }
        .sorted { $0.recency > $1.recency }
        .prefix(limit * 2)

        let dirCache = GeminiDirCache()
        var out: [SoulSession] = []
        for cand in ranked {
            let id = cand.id
            let shape = cand.shape
            var s = SoulSession(id: id, project: key, timestamp: cand.recency)

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

            var sessionStartPpid: Int? = nil
            var nativeSessionIDs: [String: String] = [:]
            if let hooks = shape.hooksPath {
                let meta = readHooksMetadata(path: hooks)
                s.eventCount = meta.eventCount
                s.promptCount = meta.promptCount
                sessionStartPpid = meta.sessionStartPpid
                nativeSessionIDs = meta.nativeSessionIDs
                if s.worktreePath == nil { s.worktreePath = meta.worktreePath }
                if let t = meta.titleHook, !t.isEmpty {
                    s.intent = t
                } else if s.intent == nil {
                    s.intent = meta.firstUserPrompt
                }
                if s.summary == nil { s.summary = s.intent }
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
            // Stale: live session with no activity in 1 hour.
            if s.isLive {
                let lastActive = cand.recency
                s.isStale = Date().timeIntervalSince(lastActive) > 3600
            }
            if let h = shape.hooksMtime, let j = shape.jsonMtime, h.timeIntervalSince(j) > 5 {
                s.isDirty = true
            }
            s.replayable = (shape.hooksPath != nil)
            if s.source == nil {
                if let live = agentMatchCached(sessionId: id, projectPath: projectPath, cache: dirCache, nativeSessionIDs: nativeSessionIDs) {
                    s.liveProvider = live
                } else {
                    let transcriptPath = "\(dir)/\(id)/transcript.jsonl"
                    if FileManager.default.fileExists(atPath: transcriptPath) {
                        s.liveProvider = Provider.codex.rawValue
                    }
                }
            }

            let hasFinalize = (shape.finalizePath != nil)
            let hasPrompt = (s.intent?.isEmpty == false)
            s.substantive = hasFinalize || s.eventCount >= 4 || hasPrompt

            if !hasFinalize, sessionStartPpid == 1, s.promptCount == 0 {
                s.substantive = false
            }

            if let path = projectPath {
                s.loadable = canLoadCached(sessionId: id, projectKey: key, projectPath: path, cache: dirCache, nativeSessionIDs: nativeSessionIDs)
            } else {
                s.loadable = false
            }

            if s.promptCount == 0 {
                s.transcriptTurns = countTranscriptTurns(
                    sessionId: id,
                    projectKey: key,
                    projectPath: projectPath,
                    sessionDir: "\(dir)/\(id)",
                    cache: dirCache,
                    nativeSessionIDs: nativeSessionIDs
                )

                // Title fallback for terminal-origin sessions. If the kernel
                // ledger has no UserPrompt events, s.intent will be nil (no
                // Title hook). reach into the native transcript to sniff the
                // first prompt for the sidebar title.
                if s.intent == nil || s.intent!.isEmpty {
                    s.intent = findFirstTranscriptPrompt(
                        sessionId: id,
                        projectKey: key,
                        projectPath: projectPath,
                        cache: dirCache,
                        nativeSessionIDs: nativeSessionIDs
                    )
                    if s.summary == nil { s.summary = s.intent }
                }
            }

            out.append(s)
        }

        return out
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    private static func agentMatchCached(sessionId: String, projectPath: String?, cache: GeminiDirCache, nativeSessionIDs: [String: String]) -> String? {
        let fm = FileManager.default

        if let projectPath {
            if cache.matchedGeminiChatsDirs == nil {
                var matched: [String] = []
                let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
                let base = (trimmed as NSString).lastPathComponent
                let geminiBase = "\(homePath)/.gemini/tmp"
                let projectRealpath = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path
                let baseLC = base.lowercased()
                let prefixLC = "\(baseLC)-"

                if let projects = try? fm.contentsOfDirectory(atPath: geminiBase) {
                    for proj in projects {
                        let markerPath = "\(geminiBase)/\(proj)/.project_root"
                        let matchedByMarker: Bool? = {
                            guard let raw = try? String(contentsOfFile: markerPath, encoding: .utf8) else { return nil }
                            let resolved = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                                .resolvingSymlinksInPath().path
                            return resolved == projectRealpath
                        }()
                        let match: Bool = {
                            if let m = matchedByMarker { return m }
                            let projLC = proj.lowercased()
                            return projLC == baseLC || projLC.hasPrefix(prefixLC)
                        }()
                        if match {
                            let chatsDir = "\(geminiBase)/\(proj)/chats"
                            matched.append(chatsDir)
                            let entries = (try? fm.contentsOfDirectory(atPath: chatsDir)) ?? []
                            cache.listings[chatsDir] = entries
                            cache.indexFirstEights(chatsDir: chatsDir, entries: entries)
                        }
                    }
                }
                cache.matchedGeminiChatsDirs = matched
            }

            let geminiId = nativeSessionIDs["geminiCLI"] ?? sessionId
            let shortId = String(geminiId.prefix(8))
            if let hit = cache.firstEightIndex[shortId] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                let resumable: Bool = {
                    if let cached = cache.resumableCache[path] { return cached }
                    let r = isResumableGeminiChatFile(path)
                    cache.resumableCache[path] = r
                    return r
                }()
                if resumable { return "geminiCLI" }
            }

            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudeId = nativeSessionIDs["claude"] ?? sessionId
            let claudePath = "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl"
            if fm.fileExists(atPath: claudePath) {
                return "claude"
            }

            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            let piEncoded = "--" + parts.joined(separator: "-") + "--"
            let piDir = "\(homePath)/.pi/agent/sessions/\(piEncoded)"
            let piSet: Set<String> = {
                if let hit = cache.piSessionsByDir[piDir] { return hit }
                var ids = Set<String>()
                if let entries = try? fm.contentsOfDirectory(atPath: piDir) {
                    for name in entries where name.hasSuffix(".jsonl") {
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

    private static func canLoadCached(sessionId sid: String, projectKey: String, projectPath: String, cache: GeminiDirCache, nativeSessionIDs: [String: String]) -> Bool {
        let fm = FileManager.default
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")

        let claudeId = nativeSessionIDs["claude"] ?? sid
        if fm.fileExists(atPath: "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl") {
            return true
        }

        let geminiId = nativeSessionIDs["geminiCLI"] ?? sid
        let shortId = String(geminiId.prefix(8))
        if let hit = cache.firstEightIndex[shortId] {
            return geminiChatHasContent(at: "\(hit.chatsDir)/\(hit.fileName)", expectedSessionId: geminiId)
        }
        return false
    }

    private static func findFirstTranscriptPrompt(
        sessionId sid: String,
        projectKey key: String,
        projectPath: String?,
        cache: GeminiDirCache,
        nativeSessionIDs: [String: String]
    ) -> String? {
        let fm = FileManager.default
        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath

            // Claude
            let claudeId = nativeSessionIDs["claude"] ?? sid
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudePath = "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl"
            if fm.fileExists(atPath: claudePath), let p = readClaudeFirstUserPrompt(path: claudePath) {
                return p
            }

            // Gemini
            let geminiId = nativeSessionIDs["geminiCLI"] ?? sid
            let shortId = String(geminiId.prefix(8))
            if let hit = cache.firstEightIndex[shortId] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                if let header = readGeminiChatHeader(path: path) {
                    return header.firstPrompt
                }
            }
        }
        return nil
    }

    private static func countTranscriptTurns(
        sessionId sid: String,
        projectKey key: String,
        projectPath: String?,
        sessionDir: String,
        cache: GeminiDirCache,
        nativeSessionIDs: [String: String]
    ) -> Int {
        let fm = FileManager.default

        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
            let claudeId = nativeSessionIDs["claude"] ?? sid
            let claudePath = "\(homePath)/.claude/projects/\(encoded)/\(claudeId).jsonl"
            if fm.fileExists(atPath: claudePath) {
                let n = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: claudePath)
                if n > 0 { return n }
            }

            let geminiId = nativeSessionIDs["geminiCLI"] ?? sid
            let shortId = String(geminiId.prefix(8))
            if let hit = cache.firstEightIndex[shortId] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                let n = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: path)
                if n > 0 { return n }
            }
        }

        let codexPath = "\(sessionDir)/transcript.jsonl"
        if fm.fileExists(atPath: codexPath) {
            let byType = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: codexPath)
            if byType > 0 { return byType }
            let byRole = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: codexPath)
            if byRole > 0 { return byRole }
        }

        return 0
    }

    private static func countNeedle(_ needle: Data, inFileAt path: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe, .uncached]) else {
            return 0
        }
        return countNeedle(needle, in: data)
    }

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

    private static func detectOrigin(path: String, projectPath: String?, sessionId: String) -> SessionOrigin {
        if agentHasSession(sessionId: sessionId, projectPath: projectPath) {
            return .desktop
        }
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

    private static func worktreePathFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).prefix(1) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "SESSION_START"
            else { return nil }
            return obj["worktree_path"] as? String
        }
        return nil
    }

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

    private static func agentMatch(sessionId: String, projectPath: String?) -> String? {
        let first8 = String(sessionId.prefix(8))
        let fm = FileManager.default
        if let projectPath {
            let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
            let base = (trimmed as NSString).lastPathComponent
            let geminiBase = "\(homePath)/.gemini/tmp"
            if let projects = try? fm.contentsOfDirectory(atPath: geminiBase) {
                for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
                    let chatsDir = "\(geminiBase)/\(proj)/chats"
                    guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
                    let matches = files.filter {
                        $0.hasSuffix("-\(first8).json") || $0.hasSuffix("-\(first8).jsonl")
                    }
                    if matches.contains(where: { isResumableGeminiChatFile("\(chatsDir)/\($0)") }) {
                        return "geminiCLI"
                    }
                }
            }
        }
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

    private static func isResumableGeminiChatFile(_ path: String) -> Bool {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
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

    private static func firstUserPromptFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if (obj["event"] as? String) == "Title", let text = obj["text"] as? String {
                return truncateForTitle(text)
            }
        }
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

    private static let hookWriteQueue = DispatchQueue(label: "soul.registry.hook-write", qos: .utility)
    private static let hookTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let readLen = min(size, UInt64(256 * 1024))
        if size > readLen { try? fh.seek(toOffset: size - readLen) }
        let data = fh.readDataToEndOfFile()
        guard let blob = String(data: data, encoding: .utf8) else { return false }
        let needle = "\"event\":\"AfterTool\",\"tool_call_id\":\"\(toolId)\""
        return blob.contains(needle)
    }

    static func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
        let capturedAt = Date()
        var payload = event
        if payload["timestamp"] == nil {
            payload["timestamp"] = hookTimestampFormatter.string(from: capturedAt)
        }
        if payload["session_id"] == nil {
            payload["session_id"] = sessionId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        hookWriteQueue.async {
            let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let path = "\(dir)/hooks.jsonl"
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                _ = line.withUnsafeBytes { p in write(fd, p.baseAddress, p.count) }
                close(fd)
            }
        }
    }

    static func appendAgentChunk(projectKey: String, sessionId: String, bubbleId: UUID, chunk: String) {
        let capturedAt = Date()
        let entry: [String: Any] = [
            "timestamp": hookTimestampFormatter.string(from: capturedAt),
            "event": "AgentThoughtChunk",
            "bubble_id": bubbleId.uuidString,
            "chunk": chunk
        ]
        hookWriteQueue.async {
            let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let path = "\(dir)/agent_chunks.jsonl"
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                    var line = data
                    line.append(0x0A)
                    _ = line.withUnsafeBytes { p in write(fd, p.baseAddress, p.count) }
                }
                close(fd)
            }
        }
    }

    static func retireAgentChunks(projectKey: String, sessionId: String) {
        hookWriteQueue.async {
            let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/agent_chunks.jsonl"
            try? FileManager.default.removeItem(atPath: path)
        }
    }

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

    enum BackfillResult {
        case hit(String)
        case alreadyMapped(String)
        case miss
        case ambiguous([String])
        case unsupported

        var uuid: String? {
            switch self {
            case .hit(let u), .alreadyMapped(let u): return u
            default: return nil
            }
        }
    }

    static func backfillNativeSessionID(
        projectKey: String,
        sessionId: String,
        provider: String,
        cwd: String
    ) -> BackfillResult {
        if let existing = findNativeSessionID(projectKey: projectKey, sessionId: sessionId, provider: provider) {
            return .alreadyMapped(existing)
        }
        let hooksPath = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let ourPrompt = firstUserPromptFullFromHooks(path: hooksPath) else { return .miss }
        let needle = normalizeForMatch(ourPrompt)
        guard needle.count >= 20 else { return .miss }
        var candidates: [(nativeId: String, firstPrompt: String?)] = []
        if provider == "geminiCLI" {
            candidates = scanGeminiCandidates(cwd: cwd)
        } else if provider == "claude" {
            candidates = scanClaudeCandidates(cwd: cwd)
        } else {
            return .unsupported
        }
        let hits = candidates.filter { cand in
            guard let p = cand.firstPrompt else { return false }
            return normalizeForMatch(p) == needle
        }
        if hits.isEmpty { return .miss }
        if hits.count > 1 {
            let ids = hits.map { $0.nativeId }
            appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "BackfillAmbiguous",
                "provider": provider,
                "candidate_ids": ids,
                "first_prompt_preview": String(needle.prefix(100))
            ])
            return .ambiguous(ids)
        }
        let hit = hits[0].nativeId
        writeNativeSessionID(projectKey: projectKey, sessionId: sessionId, nativeId: hit, provider: provider, cwd: cwd)
        return .hit(hit)
    }

    static func writeNativeSessionID(
        projectKey: String,
        sessionId: String,
        nativeId: String,
        provider: String,
        cwd: String
    ) {
        appendHook(projectKey: projectKey, sessionId: sessionId, event: [
            "event": "NativeSessionID",
            "native_session_id": nativeId,
            "provider": provider,
            "cwd": cwd,
            "source": "backfill"
        ])
    }

    private static func normalizeForMatch(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\r\n", with: "\n")
                         .components(separatedBy: .whitespacesAndNewlines)
                         .filter { !$0.isEmpty }
                         .joined(separator: " ")
        return collapsed
    }

    private static func firstUserPromptFullFromHooks(path: String) -> String? {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "UserPrompt" || (obj["event"] as? String) == "UserMessage"
            else { continue }
            let text = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String)
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t = trimmed, !t.isEmpty { return t }
        }
        return nil
    }

    private static func scanGeminiCandidates(cwd: String) -> [(nativeId: String, firstPrompt: String?)] {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let base = (trimmed as NSString).lastPathComponent
        let root = "\(homePath)/.gemini/tmp"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [(String, String?)] = []
        for proj in projects where proj == base || proj.hasPrefix("\(base)-") {
            let chatsDir = "\(root)/\(proj)/chats"
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
            for name in files where name.hasSuffix(".json") || name.hasSuffix(".jsonl") {
                if let header = readGeminiChatHeader(path: "\(chatsDir)/\(name)") {
                    out.append((header.sid, header.firstPrompt))
                }
                if out.count >= 500 { break }
            }
            if out.count >= 500 { break }
        }
        return out
    }

    private static func readGeminiChatHeader(path: String) -> (sid: String, firstPrompt: String?)? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let blob = String(bytes: buf.prefix(n), encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first?.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              let sid = meta["sessionId"] as? String
        else { return nil }
        for line in lines.dropFirst() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user"
            else { continue }
            return (sid, obj["text"] as? String)
        }
        return (sid, nil)
    }

    private static func scanClaudeCandidates(cwd: String) -> [(nativeId: String, firstPrompt: String?)] {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let dir = "\(homePath)/.claude/projects/\(encoded)"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [(String, String?)] = []
        for name in files where name.hasSuffix(".jsonl") {
            let sid = (name as NSString).deletingPathExtension
            let prompt = readClaudeFirstUserPrompt(path: "\(dir)/\(name)")
            out.append((sid, prompt))
            if out.count >= 500 { break }
        }
        return out
    }

    private static func readClaudeFirstUserPrompt(path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let blob = String(bytes: buf.prefix(n), encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty
            else { continue }
            return content
        }
        return nil
    }

    static func findProvider(projectKey: String, sessionId: String) -> String? {
        let dir = "\(registryPath)/sessions/\(projectKey)/\(sessionId)"
        let hooksPath = "\(dir)/hooks.jsonl"
        if FileManager.default.fileExists(atPath: hooksPath),
           let blob = try? String(contentsOfFile: hooksPath, encoding: .utf8) {
            for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let prov = obj["provider"] as? String,
                      (obj["event"] as? String) == "NativeSessionID" || (obj["event"] as? String) == "AfterAgent"
                else { continue }
                return prov
            }
        }
        return nil
    }

    static func findNativeSessionID(projectKey: String, sessionId: String, provider: String? = nil) -> String? {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "NativeSessionID",
                  provider == nil || (obj["provider"] as? String) == provider
            else { continue }
            return obj["native_session_id"] as? String
        }
        return nil
    }

    struct FinalizeRecord {
        let sessionId: String
        let summary: String?
        let intent: String?
        let rationale: String?
        let fixed: String?
        let nextStep: String?
        let timestamp: Date?
    }

    static func latestFinalize(projectKey: String, sessionId: String) -> FinalizeRecord? {
        // SOUL-SOUL_DESKTOP-100: trace each step of the finalize lookup.
        let sidLabel = "\(projectKey):\(String(sessionId.prefix(8)))"
        let dir = "\(registryPath)/sessions/\(projectKey)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            SoulSignposts.event("latestFinalize.no_dir", "\(sidLabel)")
            return nil
        }
        for name in entries where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            if stem == sessionId || stem.hasSuffix("_\(sessionId)") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    SoulSignposts.event("latestFinalize.parse_fail", "\(sidLabel) file=\(name)")
                    continue
                }
                let fixedArray = obj["fixed_issues"] as? [String]
                let fixedStr = fixedArray?.joined(separator: ", ")
                SoulSignposts.event("latestFinalize.hit", "\(sidLabel) file=\(name)")
                return FinalizeRecord(
                    sessionId: sessionId,
                    summary: obj["summary"] as? String,
                    intent: obj["intent"] as? String,
                    rationale: obj["rationale"] as? String,
                    fixed: fixedStr,
                    nextStep: obj["next_step"] as? String,
                    timestamp: parseTimestamp(obj["timestamp"] as? String)
                )
            }
        }
        SoulSignposts.event("latestFinalize.no_match", "\(sidLabel)")
        return nil
    }

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
                  let t = (obj["text"] as? String) ?? (obj["title"] as? String)
            else { continue }
            return t
        }
        return nil
    }

    static func slashCommandPrompts(projectKey: String, sessionId: String) -> [(text: String, timestamp: Date)] {
        let path = "\(registryPath)/sessions/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        var out: [(text: String, timestamp: Date)] = []
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let event = (obj["event"] as? String) ?? ""
            guard event == "UserPrompt" || event == "UserMessage" else { continue }
            let raw = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { continue }
            if let ts = parseTimestamp(obj["timestamp"] as? String) {
                out.append((trimmed, ts))
            }
        }
        return out
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
