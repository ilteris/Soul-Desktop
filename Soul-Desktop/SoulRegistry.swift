import Foundation
import SoulCore
import SoulLedger

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
    var companionPaths: [String] = []
    var worktreePolicy: String? = nil
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
    /// Stable sidebar sort timestamp. For ledgers with hook events this is
    /// the session creation/start time, not the latest file activity.
    var timestamp: Date
    /// Canonical UI title. Generated once into the ledger's Title hook and
    /// decoded through the session-list model. `intent` remains the finalize
    /// intent; sidebar/header code should not derive display labels from it.
    var title: String?
    var firstUserPrompt: String? = nil
    var rawTitle: String? = nil
    var titleSource: String? = nil
    var titleStatus: String? = nil
    var intent: String?
    var summary: String?
    var source: String?            // "claude" | "gemini" | "pi-native"
    var provider: String? = nil
    var origin: String? = nil
    var status: String?
    var eventCount: Int = 0        // hooks.jsonl line count (kernel events)
    var promptCount: Int = 0       // Claude transcript "type":"user" count
    var assistantTurnCount: Int = 0
    var toolCallCount: Int = 0
    var visibleTurnCount: Int = 0
    var hasConversation: Bool? = nil
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
    /// Returns true if `worktreePath` is specified and the directory actually exists on disk.
    var isWorktreePresent: Bool {
        guard let path = worktreePath, !path.isEmpty else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded)
    }
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
    var resumeStrategy: String? = nil
    var resumeTarget: String? = nil
    var loadabilityReason: String? = nil
    var health: String? = nil
    var healthReasons: [String] = []
    var lifecycle: String? = nil
    var trashedAt: Date? = nil
    var slashSemantics: [String: SoulSlashCommandSemantics] = [:]
    var taskId: String? = nil
    var taskStatus: String? = nil
    var taskSubject: String? = nil
    /// True iff `<uuid>/hooks.jsonl` exists. The replay surface only needs
    /// the kernel ledger, so finalized rows whose provider transcript has
    /// rotated out are still replay-able.
    var replayable: Bool = true
    /// `"machine"` if the writer stamped this as a non-user session
    /// (title generation, subagent, finalize summary). Read by the sidebar
    /// visibility policy as the primary "hide from humans" signal.
    var sessionVisibility: String? = nil
    var sessionKind: String? = nil
    var visibilityReason: String? = nil
    /// Count of `Delegation{Started,Completed,Failed}` events. The visibility
    /// policy subtracts these from `eventCount` so delegation-only stub
    /// sessions don't look like real conversations.
    var delegationEventCount: Int = 0
    /// Parent PID stamped on SESSION_START. `1` (launchd) + no prompts =
    /// daemon residue, suppressed.
    var sessionStartPpid: Int? = nil
    /// True iff a `<uuid>.json` (or timestamp-prefixed equivalent) sits on
    /// disk for this id. Distinguishes finalized rows from live ledgers in
    /// the visibility policy.
    var hasFinalize: Bool = false
    /// True when the session has UserPrompt events but no AfterAgent events.
    /// Set by the partial-capture backfill (`SessionMeta { partial_capture:
    /// true }`) and by the live binary scan. Drives a muted "prompts only"
    /// subtitle in the sidebar so the user knows the row will load thin.
    var partialCapture: Bool = false
    /// SOUL-SOUL_DESKTOP-268: model fired AfterAgent envelopes but every one
    /// carried empty content (writer-drop class), AND no provider transcript
    /// rescues the session. Distinct from `partialCapture` which trips when
    /// no AfterAgent envelope landed at all. Rendered as a "no model reply"
    /// badge on the sidebar row; row stays visible so the user can decide to
    /// trash it.
    var agentReplyMissing: Bool = false
    /// Most recent observed activity. Kept separate from `timestamp` so
    /// sidebar rows can display freshness without reordering on every write.
    var lastActivityAt: Date? = nil
    /// First hook-event timestamp (the moment the session was started).
    /// Pairs with `lastActivityAt` to compute duration — e.g. "23m" /
    /// "1h 4m" / "2d 3h" — rendered under the row title.
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

struct SoulSlashCommandSemantics: Hashable, Codable {
    var localOnly: Bool?
    var conversationWorthy: Bool?
    var taskAffecting: Bool?
    var titleWorthy: Bool?
    var expansionStrategy: String?
}

enum SoulRegistry {
    /// Bump when the sidebar session list contract changes in a way that
    /// makes older persisted rows unsafe to paint before a fresh kernel scan.
    private static let diskCacheSchemaVersion = 2

    nonisolated(unsafe) static var homePath: String = NSHomeDirectory()
    nonisolated(unsafe) static var soulPath: String = homePath + "/dotfiles/soul"
    /// SOUL-265 (2026-05-23): SOUL_HOME default reverted from `~/.soul` to
    /// `~/soul_registry`. The kernel middleware (gemini-cli's Soul hooks
    /// bundle, version 8.6.27-fidelity) still writes exclusively to
    /// `~/soul_registry/sessions/...`; the half-finished migration split the
    /// two writers across two filesystem roots, causing every desktop hook
    /// (UserPrompt, NativeSessionID, Title, AfterAgent) to land in
    /// `~/.soul/sessions/...` where the sidebar's primary enumeration path
    /// never looked. Both writers now converge on `~/soul_registry/`. The
    /// SOUL_HOME env var still works for tests / overrides.
    nonisolated(unsafe) static var soulHomePath: String = ProcessInfo.processInfo.environment["SOUL_HOME"] ?? (homePath + "/soul_registry")
    /// Same path as `soulHomePath` now that the migration is reverted. Kept
    /// as a named alias so the legacy/primary distinction in sessionRoots()
    /// continues to work; sessionRoots() will collapse them to a single
    /// entry when they're equal.
    nonisolated(unsafe) static var registryPath: String = homePath + "/soul_registry"

    static var primarySessionsRoot: String { "\(soulHomePath)/sessions" }
    static var legacySessionsRoot: String { "\(registryPath)/sessions" }
    static var primaryCacheRoot: String { "\(soulHomePath)/cache" }

    static func sessionRoots() -> [String] {
        primarySessionsRoot == legacySessionsRoot
            ? [primarySessionsRoot]
            : [primarySessionsRoot, legacySessionsRoot]
    }

    static func projectSessionDirs(_ key: String) -> [String] {
        sessionRoots().map { "\($0)/\(key)" }
    }

    static func hooksPath(projectKey: String, sessionId: String) -> String {
        for root in sessionRoots() {
            let path = "\(root)/\(projectKey)/\(sessionId)/hooks.jsonl"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "\(primarySessionsRoot)/\(projectKey)/\(sessionId)/hooks.jsonl"
    }

    static func sessionDir(projectKey: String, sessionId: String) -> String {
        for root in sessionRoots() {
            let path = "\(root)/\(projectKey)/\(sessionId)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "\(primarySessionsRoot)/\(projectKey)/\(sessionId)"
    }

    static func writableSessionDir(projectKey: String, sessionId: String) -> String {
        "\(primarySessionsRoot)/\(projectKey)/\(sessionId)"
    }

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

    /// "Show me anything you have, even if stale." Used by the sidebar to
    /// paint the moment a project is clicked — we'd rather show 2-minute-old
    /// data instantly than make the user wait for a fresh CLI scan on a busy
    /// project whose dir mtime ticks on every hook write. The caller is
    /// expected to also kick off a refresh; this is just the "paint now"
    /// side of the contract.
    static func cachedSessionsStaleOK(forProject key: String) -> [SoulSession]? {
        // In-memory cache wins regardless of stamp — it's at most one scan
        // out of date and reflects what we last saw with our own eyes.
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit.sessions
        }
        cacheLock.unlock()
        // Fall through to disk cache, ignoring the stamp mismatch. We still
        // require the current schema version so rows written before kernel
        // visibility classification do not briefly reappear as stale UI.
        let path = diskCachePath(forProject: key)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(DiskCacheEnvelope.self, from: data) else { return nil }
        guard env.schemaVersion == diskCacheSchemaVersion else { return nil }
        // Warm in-memory so subsequent reads don't re-decode the file.
        // Use the on-disk stamp so a true fresh scan can still spot the
        // mismatch and overwrite us.
        cacheLock.lock()
        cache[key] = ProjectCache(dirMtime: Date(timeIntervalSince1970: env.stamp), sessions: env.sessions)
        cacheLock.unlock()
        return env.sessions
    }

    static func warmCache(forProject key: String, sessions: [SoulSession]) {
        // A transient empty scan (mid-write directory state, brief I/O hiccup,
        // CLI race during a sweep) must not poison the persisted cache. An
        // empty cache survives across launches and the strict-freshness check
        // in `cachedSessions` then short-circuits the fresh CLI scan at
        // SidebarView+Loading.swift:139, leaving the project visibly empty
        // even though disk has dozens of sessions. Skip both in-memory and
        // disk writes when sessions is empty — let the next non-empty scan
        // populate the cache.
        guard !sessions.isEmpty else { return }
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
    ///   ~/.soul/cache/sessions/<projectKey>.json
    ///   { "stamp": <unix-seconds>, "sessions": [SoulSession...] }
    /// The stamp is the same projectStamp(key:) we use for in-memory
    /// validation, so disk and memory share one freshness contract.
    private static func diskCachePath(forProject key: String) -> String {
        "\(primaryCacheRoot)/sessions/\(key).json"
    }

    private struct DiskCacheEnvelope: Codable {
        var schemaVersion: Int = diskCacheSchemaVersion
        let stamp: TimeInterval
        let sessions: [SoulSession]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case stamp
            case sessions
        }

        init(stamp: TimeInterval, sessions: [SoulSession]) {
            self.schemaVersion = SoulRegistry.diskCacheSchemaVersion
            self.stamp = stamp
            self.sessions = sessions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.stamp = try container.decode(TimeInterval.self, forKey: .stamp)
            self.sessions = try container.decode([SoulSession].self, forKey: .sessions)
        }
    }

    private static func readDiskCache(forProject key: String, expecting stamp: Date) -> [SoulSession]? {
        let path = diskCachePath(forProject: key)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(DiskCacheEnvelope.self, from: data) else { return nil }
        guard env.schemaVersion == diskCacheSchemaVersion else { return nil }
        // Mtime mismatch → cache is stale, ignore. Fresh scan will overwrite.
        guard abs(env.stamp - stamp.timeIntervalSince1970) < 0.001 else { return nil }
        return env.sessions
    }

    private static func writeDiskCache(forProject key: String, sessions: [SoulSession], stamp: Date) {
        let dir = "\(primaryCacheRoot)/sessions"
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
    /// touched). Scans every child directory because visibility/classifier
    /// migrations can affect old rows that are not among the newest names.
    private static func projectStamp(key: String) -> Date {
        var newest = Date.distantPast
        for dir in projectSessionDirs(key) {
            let dirMtime = mtime(dir)
            if dirMtime > newest { newest = dirMtime }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for entry in entries {
                guard UUID(uuidString: entry) != nil else { continue }
                let hooksPath = "\(dir)/\(entry)/hooks.jsonl"
                let m = mtime(hooksPath)
                if m > newest { newest = m }
            }
        }
        return newest
    }

    static func invalidateCache(forProject key: String? = nil) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let key { cache.removeValue(forKey: key) } else { cache.removeAll() }
    }

    // MARK: - Projects

    static func projects() -> [SoulProject] {
        // Source of truth: `soul project list` (kernel CLI). Direct read of
        // ~/dotfiles/soul/config/PROJECTS.json was retired in
        // SOUL-SOUL_DESKTOP-261 so the desktop and kernel can't drift on the
        // project-manifest schema. The CLI emits JSONL (one project per
        // line). On failure (CLI missing, non-zero exit) we return [] so
        // the sidebar shows empty rather than rendering stale state.
        guard let data = SoulCLI.runSync(["project", "list"]) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        let mapped: [SoulProject] = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let val = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let key = val["_key"] as? String
                else { return nil }
                return SoulProject(
                    id: key,
                    name: val["name"] as? String ?? key,
                    path: expand(val["path"] as? String ?? ""),
                    pillar: val["pillar"] as? String,
                    tier: val["tier"] as? Int,
                    status: val["status"] as? String,
                    primaryHost: val["primary_host"] as? String,
                    devCommand: val["dev_command"] as? String,
                    devURL: val["dev_url"] as? String,
                    companionPaths: (val["companion_paths"] as? [String] ?? []).map(expand),
                    worktreePolicy: val["worktree_policy"] as? String
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
        projectSessionDirs(p.id).map { mtime($0) }.max() ?? .distantPast
    }

    static func activeProjects() -> [SoulProject] {
        projects().filter { ($0.status ?? "active") == "active" }
    }


    private static let hookWriteQueue = DispatchQueue(label: "soul.registry.hook-write", qos: .utility)

    /// SOUL-SOUL_DESKTOP-246 (kernel-side prevention of split-ledger forks).
    /// Cache: provider sid → canonical project key. Resolved at first write
    /// for the sid, reused for the controller's lifetime. Accessed only
    /// from `hookWriteQueue` (serial), so no lock needed.
    private static var sidProjectCache: [String: String] = [:]

    /// Resolve which project dir a write for `sid` should land in. If the
    /// sid already lives under a project on disk, route there — even if
    /// `caller` is a different project. Prevents the split-ledger
    /// condition where opening the same session from different cwds
    /// forked the kernel ledger across `<projectA>/<sid>/` and
    /// `<projectB>/<sid>/`.
    ///
    /// Must be called from `hookWriteQueue`.
    private static func canonicalProjectForWrite(sid: String, caller: String) -> String {
        let sessionsRoot = primarySessionsRoot
        let fm = FileManager.default
        // Cache hit: still validate the dir exists (dedup script may have
        // moved it to ~/.Trash since we cached) — re-resolve on miss.
        if let cached = sidProjectCache[sid],
           fm.fileExists(atPath: "\(sessionsRoot)/\(cached)/\(sid)") {
            return cached
        }
        var existing: [String] = []
        for root in sessionRoots() {
            guard let projectDirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for proj in projectDirs {
                // The kernel uses `_backfill` / `_backfill_orphans` / `subagents`
                // as reserved subdirs at the same depth as session dirs. Skip
                // them so they can't be confused with a "project dir".
                if proj.hasPrefix("_") || proj == "subagents" { continue }
                if fm.fileExists(atPath: "\(root)/\(proj)/\(sid)") {
                    existing.append(proj)
                }
            }
        }
        if existing.isEmpty {
            // Bootstrap: sid doesn't exist anywhere. Caller's choice wins.
            sidProjectCache[sid] = caller
            return caller
        }
        if existing.count == 1 {
            let canonical = existing[0]
            if canonical != caller {
                // Mismatch logged at debug level only — happens routinely
                // when the same session is opened from a different cwd.
                // Not an error, just a routing decision.
                NSLog("[soul] redirect write for sid=\(sid): caller=\(caller) → canonical=\(canonical)")
            }
            sidProjectCache[sid] = canonical
            return canonical
        }
        // Legacy multi-project state: pick oldest first event. Matches
        // soul_dedupe_sessions.py's tiebreak so the resolution is stable
        // before vs after that script runs.
        let canonical = existing.min(by: { a, b in
            firstEventTimestamp(in: hooksPath(projectKey: a, sessionId: sid))
                < firstEventTimestamp(in: hooksPath(projectKey: b, sessionId: sid))
        }) ?? caller
        sidProjectCache[sid] = canonical
        return canonical
    }

    private static func firstEventTimestamp(in path: String) -> String {
        guard let blob = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["timestamp"] as? String, !ts.isEmpty
            else { continue }
            return ts
        }
        return ""
    }
    private static let hookTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
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

    /// Synchronously drain the async `hookWriteQueue` so every pending
    /// hook write has hit disk before this call returns. Cheap: enqueues
    /// a sync barrier the queue will hit only after every prior
    /// `appendHook(...)` block has run to completion.
    ///
    /// SOUL-WRITER-DRAIN: addresses a drain-on-terminate drop. Every
    /// `appendHook` enqueues onto a utility-QoS DispatchQueue; on process
    /// exit (force-quit, pkill, mac sleep then close, etc.) the queue
    /// can be torn down with pending writes never reaching disk. The
    /// signature was missing UserPrompt + AfterTool + AfterAgent events
    /// for `/finalize` turns while the bash subprocess's SESSION_SUMMARY
    /// (a synchronous external write) landed correctly. Call this at
    /// turn boundaries and on app termination to make sure nothing in
    /// flight gets lost.
    static func flushHooks() {
        hookWriteQueue.sync { /* barrier: returns only after all queued blocks completed */ }
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
            let resolved = canonicalProjectForWrite(sid: sessionId, caller: projectKey)
            let dir = writableSessionDir(projectKey: resolved, sessionId: sessionId)
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
            let resolved = canonicalProjectForWrite(sid: sessionId, caller: projectKey)
            let dir = writableSessionDir(projectKey: resolved, sessionId: sessionId)
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
            let path = "\(sessionDir(projectKey: projectKey, sessionId: sessionId))/agent_chunks.jsonl"
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func nativeSessionRecord(projectKey: String, sessionId: String) -> (provider: String?, cwd: String?)? {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
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

    enum BackfillResult: Equatable {
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
        let hooksPath = hooksPath(projectKey: projectKey, sessionId: sessionId)
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
            // Parity with readClaudeFirstUserPrompt — gemini-cli doesn't
            // currently emit `<command-*>` / `<local-command-*>` blocks
            // but stripCommandTags is a no-op when none are present, so
            // applying it costs nothing and closes the parity gap.
            let raw = obj["text"] as? String
            return (sid, raw.map { stripCommandTags($0) })
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
            // Strip Claude's `<command-*>` / `<local-command-*>` noise tags
            // before returning so sidebar titles + cache entries don't leak
            // the raw `<local-command-caveat>` blocks that terminal Claude
            // wraps into the first message body. SOUL-SOUL_DESKTOP-150.
            return stripCommandTags(content)
        }
        return nil
    }

    static func findProvider(projectKey: String, sessionId: String) -> String? {
        let hooksPath = hooksPath(projectKey: projectKey, sessionId: sessionId)
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

    /// SOUL-SOUL_DESKTOP-237: per-provider event count for a session, derived
    /// from the on-disk hooks.jsonl. Used to compute the "dominant provider"
    /// of a session that received writes from multiple providers, defending
    /// against the SOUL-SOUL-030 finalize-source bug where a finalize JSON's
    /// `source` field can disagree with who actually authored the session.
    struct ProviderTally {
        /// Provider → count of `provider:<name>` events in the ledger.
        let counts: [String: Int]
        /// Provider of the very first `NativeSessionID` event. The
        /// authoritative "who created this session id" signal.
        let firstAuthor: String?
        /// Provider with the highest event count. Tie-break: most-recent
        /// provider wins.
        let dominant: String?
        /// Convenience: did more than one provider write to this session?
        var isMixed: Bool { counts.count > 1 }
    }

    static func providerTally(projectKey: String, sessionId: String) -> ProviderTally {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return ProviderTally(counts: [:], firstAuthor: nil, dominant: nil)
        }
        var counts: [String: Int] = [:]
        var firstAuthor: String? = nil
        var mostRecent: String? = nil
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prov = obj["provider"] as? String
            else { continue }
            counts[prov, default: 0] += 1
            if firstAuthor == nil, (obj["event"] as? String) == "NativeSessionID" {
                firstAuthor = prov
            }
            mostRecent = prov
        }
        // Pick the provider with the highest count; if tied, pick most-recent.
        let dominant: String? = {
            guard !counts.isEmpty else { return nil }
            let maxCount = counts.values.max() ?? 0
            let winners = counts.filter { $0.value == maxCount }.map { $0.key }
            if winners.count == 1 { return winners[0] }
            return mostRecent ?? winners.first
        }()
        return ProviderTally(counts: counts, firstAuthor: firstAuthor, dominant: dominant)
    }

    /// SOUL-SOUL_DESKTOP-237: heal a session whose finalize JSON `source`
    /// field disagrees with the dominant provider in the hooks ledger.
    /// Rewrites the JSON in place (atomic, .bak backup taken before write).
    /// Returns the corrected source string on success, nil if there was no
    /// finalize JSON or no drift to repair.
    @discardableResult
    static func repairFinalizeSource(projectKey: String, sessionId: String) -> String? {
        var targetPath: String? = nil
        for dir in projectSessionDirs(projectKey) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if stem == sessionId || stem.hasSuffix("_\(sessionId)") {
                    targetPath = "\(dir)/\(name)"
                    break
                }
            }
            if targetPath != nil { break }
        }
        guard let path = targetPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tally = providerTally(projectKey: projectKey, sessionId: sessionId)
        // Prefer firstAuthor (the original creator of the kernel sid) over
        // dominant count, on the principle that the session's identity is
        // anchored to who minted it — later guest writes shouldn't relabel
        // the session.
        let canonical = tally.firstAuthor ?? tally.dominant
        guard let target = canonical else { return nil }
        let currentSource = obj["source"] as? String
        // Map provider raw values to the source-field convention used in
        // finalize JSONs (claude, gemini, pi-native).
        let canonicalSource: String = {
            switch target {
            case "claude": return "claude"
            case "geminiCLI": return "gemini"
            case "pi": return "pi-native"
            case "codex": return "codex"
            default: return target
            }
        }()
        if currentSource == canonicalSource { return nil }
        obj["source"] = canonicalSource
        // Stamp the prior value into history so future tooling can audit
        // the heal.
        var history = obj["source_history"] as? [String] ?? []
        if let cur = currentSource { history.append(cur) }
        obj["source_history"] = history
        // .bak before write
        let bak = path + ".bak-\(Int(Date().timeIntervalSince1970))"
        _ = try? FileManager.default.copyItem(atPath: path, toPath: bak)
        guard let newData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              (try? newData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
        else { return nil }
        invalidateCache(forProject: projectKey)
        return canonicalSource
    }

    /// Latest `ProviderTranscriptID` event for a session, if any. Written
    /// by `ProviderTranscriptWatcher` when it detects Claude rotating its
    /// on-disk transcript filename on `/compact`. Returns the most
    /// recent value matching `provider` (or any provider if omitted).
    ///
    /// SOUL-IDENTITY-SPLIT: this lookup has priority over `NativeSessionID`
    /// because rotations happen mid-conversation — the native id from
    /// session/new is no longer the right filename to read.
    static func findProviderTranscriptID(projectKey: String, sessionId: String, provider: String? = nil) -> String? {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "ProviderTranscriptID",
                  provider == nil || (obj["provider"] as? String) == provider
            else { continue }
            return obj["transcript_id"] as? String
        }
        return nil
    }

    struct HooksMetadata: Sendable {
        var providerTranscriptId: String?
        var nativeSessionId: String?
        var title: String?
        var slashPrompts: [(text: String, timestamp: Date)] = []
        var latestFinalize: FinalizeRecord?
    }

    struct TranscriptIdentity: Sendable {
        var providerTranscriptId: String?
        var nativeSessionId: String?
    }

    /// Narrow reader for call sites that only need the provider/native
    /// transcript identity. This stays separate from `hooksMetadata(...)`
    /// so lightweight UI refreshes, like the context usage chip, don't
    /// parse title/finalize/slash-command metadata on every selected-thread
    /// change.
    static func transcriptIdentity(projectKey: String, sessionId: String, provider: String? = nil) -> TranscriptIdentity {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        var identity = TranscriptIdentity()
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return identity }

        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"ProviderTranscriptID\"") || line.contains("\"NativeSessionID\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String,
                  provider == nil || (obj["provider"] as? String) == provider
            else { continue }

            switch event {
            case "ProviderTranscriptID" where identity.providerTranscriptId == nil:
                identity.providerTranscriptId = obj["transcript_id"] as? String
            case "NativeSessionID" where identity.nativeSessionId == nil:
                identity.nativeSessionId = (obj["nativeId"] as? String) ?? (obj["native_session_id"] as? String)
            default:
                break
            }

            if identity.providerTranscriptId != nil && identity.nativeSessionId != nil {
                break
            }
        }

        return identity
    }

    /// One-pass metadata reader for hydrate/cache paths. Those paths need
    /// several independent facts from the same hooks.jsonl; calling the
    /// point lookups separately repeatedly reads and parses the full file.
    static func hooksMetadata(projectKey: String, sessionId: String, provider: String? = nil, includeFinalize: Bool = true) -> HooksMetadata {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        var metadata = HooksMetadata()
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            if includeFinalize {
                metadata.latestFinalize = latestLegacyFinalize(projectKey: projectKey, sessionId: sessionId)
            }
            return metadata
        }

        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"ProviderTranscriptID\"")
                    || line.contains("\"NativeSessionID\"")
                    || line.contains("\"Title\"")
                    || line.contains("\"UserPrompt\"")
                    || line.contains("\"UserMessage\"")
                    || (includeFinalize && line.contains("\"Finalize\"")),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String
            else { continue }

            switch event {
            case "ProviderTranscriptID":
                guard provider == nil || (obj["provider"] as? String) == provider else { continue }
                metadata.providerTranscriptId = obj["transcript_id"] as? String
            case "NativeSessionID":
                guard provider == nil || (obj["provider"] as? String) == provider else { continue }
                metadata.nativeSessionId = (obj["nativeId"] as? String) ?? (obj["native_session_id"] as? String)
            case "Title":
                metadata.title = (obj["text"] as? String) ?? (obj["title"] as? String)
            case "UserPrompt", "UserMessage":
                let raw = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("/"),
                      let ts = parseTimestamp(obj["timestamp"] as? String)
                else { continue }
                metadata.slashPrompts.append((trimmed, ts))
            case "Finalize" where includeFinalize:
                metadata.latestFinalize = finalizeRecord(from: obj, sessionId: sessionId, handoffPath: path)
            default:
                continue
            }
        }

        if includeFinalize && metadata.latestFinalize == nil {
            metadata.latestFinalize = latestLegacyFinalize(projectKey: projectKey, sessionId: sessionId)
        }
        return metadata
    }

    /// SOUL-SOUL_DESKTOP-263: thin wrapper over `soul session show <sid> --json`.
    /// One CLI hop replaces three separate hooks.jsonl walks (findTitle /
    /// findNativeSessionID / latestFinalize). Returns nil on CLI failure
    /// (executable missing, non-zero exit, decode error) — callers degrade
    /// individually rather than treating CLI failure as "session has no
    /// title", which would mis-render the canvas.
    static func sessionShow(projectKey: String, sessionId: String) -> SessionListRecord? {
        guard let data = SoulCLI.runSync(["session", "show", sessionId, "-p", projectKey, "--json"]) else {
            return nil
        }
        return try? decodeLedgerSessionListRecord(from: data)
    }

    static func findNativeSessionID(projectKey: String, sessionId: String, provider: String? = nil) -> String? {
        // HOT PATH — called from AppShell.body via ContextUsage.compute on
        // every body re-eval. Stays direct-disk because shelling out to the
        // CLI here would (a) block the main actor for ~100ms per body
        // tick and (b) trigger SwiftUI's "may not be accessed during view
        // updates" crash on downstream ScrollViewProxy access. SOUL-SOUL_DESKTOP-263
        // keeps `soul session show` as the canonical CLI surface; this
        // helper consumes the same on-disk JSONL via a tight binary scan.
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
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
            if let nid = obj["nativeId"] as? String { return nid }
            return obj["native_session_id"] as? String
        }
        return nil
    }

    struct FinalizeRecord: Sendable {
        let sessionId: String
        let summary: String?
        let intent: String?
        let rationale: String?
        let fixed: String?
        let nextStep: String?
        let timestamp: Date?
        // SOUL-SOUL_DESKTOP-236: operational metadata the FinalizeCard
        // surfaces alongside the Quad. Project key + on-disk JSON path
        // give the card a "what" and "where"; decisionsCount surfaces
        // how many DECISION ops were synthesized; parentId links to a
        // source session when the user branched into this one.
        let handoffPath: String?
        let fixedIssues: [String]
        let decisionsCount: Int?
        let parentId: String?
    }

    static func latestFinalize(projectKey: String, sessionId: String) -> FinalizeRecord? {
        // HOT PATH — see findNativeSessionID. Direct disk scan.
        let sidLabel = "\(projectKey):\(String(sessionId.prefix(8)))"
        if let rec = latestLedgerFinalize(projectKey: projectKey, sessionId: sessionId) {
            SoulSignposts.event("latestFinalize.ledger_hit", "\(sidLabel)")
            return rec
        }
        return latestLegacyFinalize(projectKey: projectKey, sessionId: sessionId)
    }

    private static func latestLedgerFinalize(projectKey: String, sessionId: String) -> FinalizeRecord? {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        var latest: [String: Any]? = nil
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"Finalize\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["event"] as? String == "Finalize"
            else { continue }
            latest = obj
        }
        guard let obj = latest else { return nil }
        return finalizeRecord(from: obj, sessionId: sessionId, handoffPath: path)
    }

    private static func latestLegacyFinalize(projectKey: String, sessionId: String) -> FinalizeRecord? {
        let sidLabel = "\(projectKey):\(String(sessionId.prefix(8)))"
        let dirs = projectSessionDirs(projectKey)
        let fm = FileManager.default
        var candidates: [(dir: String, name: String)] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if stem == sessionId || stem.hasSuffix("_\(sessionId)") {
                    candidates.append((dir, name))
                }
            }
        }
        candidates.sort { $0.name > $1.name }
        guard let pick = candidates.first else {
            SoulSignposts.event("latestFinalize.no_dir", "\(sidLabel)")
            return nil
        }
        let dir = pick.dir
        let name = pick.name
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            SoulSignposts.event("latestFinalize.parse_fail", "\(sidLabel) file=\(name)")
            return nil
        }
        SoulSignposts.event("latestFinalize.hit", "\(sidLabel) file=\(name)")
        return finalizeRecord(from: obj, sessionId: sessionId, handoffPath: "\(dir)/\(name)")
    }

    private static func finalizeRecord(from obj: [String: Any], sessionId: String, handoffPath: String?) -> FinalizeRecord {
        let fixedArray = finalizeFixedIssues(from: obj)
        let fixedStr: String? = fixedArray.isEmpty ? nil : fixedArray.joined(separator: ", ")
        let decisions = obj["decisions_events"] as? [Any]
        return FinalizeRecord(
            sessionId: sessionId,
            summary: obj["summary"] as? String,
            intent: obj["intent"] as? String,
            rationale: obj["rationale"] as? String,
            fixed: fixedStr,
            nextStep: obj["next_step"] as? String,
            timestamp: parseTimestamp(obj["timestamp"] as? String),
            handoffPath: handoffPath,
            fixedIssues: fixedArray,
            decisionsCount: decisions?.count,
            parentId: obj["parent_id"] as? String
        )
    }

    private static func finalizeFixedIssues(from obj: [String: Any]) -> [String] {
        if let arr = obj["fixed_issues"] as? [String] { return arr }
        if let arr = obj["fixed"] as? [String] { return arr }
        if let str = obj["fixed_issues"] as? String, !str.isEmpty { return [str] }
        if let str = obj["fixed"] as? String, !str.isEmpty { return [str] }
        return []
    }

    static func findTitle(projectKey: String, sessionId: String) -> String? {
        // HOT PATH — see findNativeSessionID. Direct disk scan.
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: path),
              let blob = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var latest: String? = nil
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["event"] as? String) == "Title",
                  let t = (obj["text"] as? String) ?? (obj["title"] as? String)
            else { continue }
            latest = t
        }
        return latest
    }

    static func slashCommandPrompts(projectKey: String, sessionId: String) -> [(text: String, timestamp: Date)] {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
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
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
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

    // SOUL-SOUL_DESKTOP-165: cache the three formatters as static-let
    // singletons. The previous parseTimestamp() instantiated all three on
    // every call — sample 5 (2026-05-20) showed 82+ samples in
    // parseTimestamp/ISO8601DateFormatter init across one short window
    // because session scans call it per JSON line. ISO8601DateFormatter
    // and DateFormatter are documented thread-safe for parsing.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let kernelMicrosFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let kernelSecondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso8601Fractional.date(from: s) { return d }
        if let d = iso8601Plain.date(from: s) { return d }
        if let d = kernelMicrosFormatter.date(from: s) { return d }
        return kernelSecondsFormatter.date(from: s)
    }

    static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
    }

    static func creationTime(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date
    }

    static func stringOrNil(_ v: Any?) -> String? {
        guard let s = v as? String, s != "None", !s.isEmpty else { return nil }
        return s
    }
}
