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

/// Who authored this session's hooks.jsonl ledger. Pure provenance — does
/// NOT gate resumability on its own. The resume decision is `canSafelyResume`,
/// which combines writer + isLive + isStale.
///
/// The discriminating signal is `NativeSessionID` / `Title` — only
/// `ThreadController` writes those events. Terminal-started Claude / Pi
/// sessions DO fire `UserPrompt` hooks into the kernel ledger (because
/// kernel hooks are installed globally in `~/.claude/settings.json` etc.),
/// so `UserPrompt` alone is not a desktop-authorship signal.
enum SessionWriter: String, Hashable, Codable {
    case soulDesktop   // ledger has NativeSessionID or Title (only ThreadController writes these)
    case external      // ledger has SESSION_START / AfterTool / AfterAgent but no desktop signature
    case unknown       // no signals either way (crashed before first hook, or empty file)
}

struct SoulSession: Identifiable, Hashable, Codable {
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
    /// Who wrote this session's hooks ledger. See `SessionWriter` doc.
    var writer: SessionWriter = .unknown
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

    /// Single resume gate, applies to every provider:
    ///   - finalized → safe (no live writer)
    ///   - desktop-authored live → safe (we own the writer in-process)
    ///   - externally-authored live, idle ≥1h → safe (terminal almost certainly closed)
    ///   - externally-authored live, recently active → unsafe (dual-writer risk)
    var canSafelyResume: Bool {
        !isLive || isStale || writer == .soulDesktop
    }
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
    /// Returns nil on miss / stale. Falls through to disk on in-memory miss
    /// so a cold-start launch (process restarted) still gets instant sidebar
    /// without re-parsing every project's hooks ledgers — see SOUL-149.
    /// Callers should fall back to a fresh scan on nil.
    static func cachedSessions(forProject key: String) -> [SoulSession]? {
        let now = projectStamp(key: key)
        cacheLock.lock()
        if let hit = cache[key], hit.dirMtime == now {
            cacheLock.unlock()
            return hit.sessions
        }
        cacheLock.unlock()
        // Cold-start disk fallback. Validated against the same projectStamp
        // so a project whose ledger changed since the cache was written
        // returns nil and forces a re-scan.
        if let disk = readDiskCache(forProject: key, expecting: now) {
            cacheLock.lock()
            cache[key] = ProjectCache(dirMtime: now, sessions: disk)
            cacheLock.unlock()
            return disk
        }
        return nil
    }

    static func warmCache(forProject key: String, sessions: [SoulSession]) {
        let m = projectStamp(key: key)
        cacheLock.lock()
        cache[key] = ProjectCache(dirMtime: m, sessions: sessions)
        cacheLock.unlock()
        // Persist to disk best-effort. Off the cache lock; failures are
        // silent (next launch just falls back to a fresh scan).
        Task.detached(priority: .background) {
            writeDiskCache(forProject: key, sessions: sessions, stamp: m)
        }
    }

    /// On-disk cache layout:
    ///   ~/soul_registry/cache/sessions/<projectKey>.json
    ///   { "stamp": <unix-seconds>, "sessions": [SoulSession...] }
    /// The stamp is the same projectStamp(key:) we use for in-memory
    /// validation, so disk and memory share one freshness contract.
    private static func diskCachePath(forProject key: String) -> String {
        "\(registryPath)/cache/sessions/\(key).json"
    }

    private struct DiskCacheEnvelope: Codable {
        let stamp: TimeInterval
        let sessions: [SoulSession]
    }

    private static func readDiskCache(forProject key: String, expecting stamp: Date) -> [SoulSession]? {
        let path = diskCachePath(forProject: key)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(DiskCacheEnvelope.self, from: data) else { return nil }
        // Mtime mismatch → cache is stale, ignore. Fresh scan will overwrite.
        guard abs(env.stamp - stamp.timeIntervalSince1970) < 0.001 else { return nil }
        return env.sessions
    }

    private static func writeDiskCache(forProject key: String, sessions: [SoulSession], stamp: Date) {
        let dir = "\(registryPath)/cache/sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let env = DiskCacheEnvelope(stamp: stamp.timeIntervalSince1970, sessions: sessions)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(env) else { return }
        let path = diskCachePath(forProject: key)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

        // Sort by recency: most-recently-active project first. Activity is
        // measured at the sessions/<project>/ directory mtime — APFS bumps
        // it whenever a session dir is added or removed (new chat, finalize,
        // archive). One stat per project keeps `projects()` cheap enough to
        // call from the sidebar body without blocking the main thread.
        return mapped.sorted { lhs, rhs in
            let la = lastModifiedAt(for: lhs)
            let ra = lastModifiedAt(for: rhs)
            if la != ra { return la > ra }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func lastModifiedAt(for p: SoulProject) -> Date {
        // Use the sessions/<project>/ dir mtime as the recency signal. The
        // prior shape that iterated every session UUID and called mtime() on
        // each was O(N*sessions) per call — with ~430 sessions across 18
        // projects, that was 430+ stats per `projects()` call. Since
        // `projects()` is called from the sidebar body, that landed on the
        // main thread on every paint and beachballed the Dev build. Dir
        // mtime is one stat per project, ~24× cheaper, same ordering for
        // the cases this sort actually surfaces (new chat, finalize).
        mtime("\(registryPath)/sessions/\(p.id)")
    }

    static func activeProjects() -> [SoulProject] {
        projects().filter { ($0.status ?? "active") == "active" }
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

    static func readGeminiChatHeader(path: String) -> (sid: String, firstPrompt: String?)? {
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

    static func readClaudeFirstUserPrompt(path: String) -> String? {
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

    static func parseTimestamp(_ s: String?) -> Date? {
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

    static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    static func stringOrNil(_ v: Any?) -> String? {
        guard let s = v as? String, s != "None", !s.isEmpty else { return nil }
        return s
    }
}
