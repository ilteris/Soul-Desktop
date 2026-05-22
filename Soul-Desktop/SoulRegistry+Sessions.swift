import Foundation

/// Session enumeration + agent-loadability discovery lifted out of
/// SoulRegistry. This is the heart of the "what does a chat row look
/// like for a session id?" pipeline: counts on disk, hooks.jsonl
/// metadata parsing, the big `allSessions(forProject:)` reducer that
/// merges live ledger rows with finalized JSON summaries, and the
/// agent-match helpers that decide which provider can resume each row
/// (and whether the on-disk transcript is loadable at all).
///
/// Pure file shuffle, no behavior change. Refactor 16/N — agent
/// ergonomics: shrink SoulRegistry.swift below the threshold where
/// a coding agent can hold it in context.
extension SoulRegistry {

    // MARK: - Sessions

    /// Count of distinct session UUIDs on disk for a project. A finalize
    /// JSON (`<uuid>.json` or `<ts>_<uuid>.json`) and a live dir (`<uuid>/`)
    /// for the same UUID count once. No parsing, no size filters — just the
    /// authoritative on-disk session set. Cheap enough to call for every
    /// project at startup, so sidebar badges paint instantly without
    /// triggering the heavier `sessions(forProject:)` parse pass.
    static func sessionCount(forProject key: String) -> Int {
        var ids: Set<String> = []
        for dir in projectSessionDirs(key) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
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
        /// True iff `NativeSessionID` or `Title` event present — i.e. a
        /// Soul-Desktop `ThreadController` wrote this ledger. `UserPrompt`
        /// alone does NOT count: terminal Claude / Pi fire UserPrompt hooks
        /// into the kernel ledger from outside Soul-Desktop.
        var hasDesktopSignature: Bool = false
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
                if event == "Title" {
                    meta.titleHook = (obj["text"] as? String) ?? (obj["title"] as? String)
                    meta.hasDesktopSignature = true
                }
                if (event == "UserPrompt" || event == "UserMessage") && meta.firstUserPrompt == nil {
                    let text = (obj["text"] as? String) ?? (obj["content"] as? String) ?? (obj["prompt"] as? String)
                    if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        meta.firstUserPrompt = String(stripCommandTags(t).prefix(120))
                    }
                }
                if event == "NativeSessionID" {
                    if let prov = obj["provider"] as? String,
                       let nid = obj["native_session_id"] as? String {
                        meta.nativeSessionIDs[prov] = nid
                    }
                    meta.hasDesktopSignature = true
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

        // 4. Tail metadata: parse last 8KB for the most recent timestamp and latest title.
        let maxTail = min(data.count, 8 * 1024)
        let tail = data.suffix(maxTail)
        if let tailStr = String(data: tail, encoding: .utf8) {
            let lines = tailStr.split(separator: "\n", omittingEmptySubsequences: true)
            var tailTitle: String? = nil
            for line in lines.reversed() {
                guard let ldata = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any]
                else { continue }

                if let ts = parseTimestamp(obj["timestamp"] as? String) {
                    if meta.lastEventTimestamp == nil {
                        meta.lastEventTimestamp = ts
                    }
                }

                let event = (obj["event"] as? String) ?? ""
                if event == "Title" && tailTitle == nil {
                    tailTitle = (obj["text"] as? String) ?? (obj["title"] as? String)
                }
            }
            if let tailTitle {
                meta.titleHook = tailTitle
                meta.hasDesktopSignature = true
            }
        }

        // 5. Deep presence fallback: scan whole file only if signals not in head.
        if !meta.hasDesktopSignature {
            let nsidNeedle = Data("\"event\":\"NativeSessionID\"".utf8)
            let titleNeedle = Data("\"event\":\"Title\"".utf8)
            if data.range(of: nsidNeedle) != nil || data.range(of: titleNeedle) != nil {
                meta.hasDesktopSignature = true
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
        let fm = FileManager.default

        struct Shape {
            var finalizeName: String?
            var finalizePath: String?
            var sessionDir: String?
            var hooksPath: String?
            var jsonMtime: Date?
            var hooksMtime: Date?
        }
        var shapes: [String: Shape] = [:]
        for dir in projectSessionDirs(key) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
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
                    if s.hooksMtime.map({ m > $0 }) ?? true {
                        s.sessionDir = "\(dir)/\(name)"
                        s.hooksPath = hooks
                        s.hooksMtime = m
                    }
                    shapes[name] = s
                }
            }
        }
        if shapes.isEmpty { return [] }

        let ranked = shapes.map { (id, shape) -> (id: String, shape: Shape, recency: Date) in
            let m = max(shape.jsonMtime ?? .distantPast, shape.hooksMtime ?? .distantPast)
            return (id, shape, m)
        }
        .sorted { $0.recency > $1.recency }

        let dirCache = GeminiDirCache()
        var out: [SoulSession] = []
        for cand in ranked {
            let id = cand.id
            let shape = cand.shape
            var s = SoulSession(id: id, project: key, timestamp: cand.recency)
            s.lastActivityAt = cand.recency

            if let path = shape.finalizePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ts = parseTimestamp(obj["timestamp"] as? String) {
                    s.lastActivityAt = max(s.lastActivityAt ?? .distantPast, ts)
                    s.timestamp = ts
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
                if meta.hasDesktopSignature {
                    s.writer = .soulDesktop
                } else if meta.hasTerminalSignal {
                    s.writer = .external
                } else {
                    s.writer = .unknown
                }
                s.startedAt = meta.firstEventTimestamp
                if let last = meta.lastEventTimestamp {
                    s.lastActivityAt = max(s.lastActivityAt ?? .distantPast, last)
                }
            }

            s.isLive = (shape.finalizePath == nil)
            // Stale: live session with no activity in 1 hour. Computed from
            // lastActivityAt (not the pinned sort timestamp below) so it tracks real
            // activity even though we freeze the sort key.
            if s.isLive {
                let lastActive = s.lastActivityAt ?? cand.recency
                s.isStale = Date().timeIntervalSince(lastActive) > 3600
            }
            // Sidebar rows should be stable: once a session exists, appending
            // prompts, assistant chunks, titles, summaries, or finalize rows
            // must not move it around. Use creation/start time for every row
            // that has a ledger, and keep last activity in `lastActivityAt`
            // for stale/dirty/display state.
            if let started = s.startedAt {
                s.timestamp = started
            } else if let dir = shape.sessionDir, let created = creationTime(dir) {
                s.timestamp = created
            } else if let hooks = shape.hooksPath, let created = creationTime(hooks) {
                s.timestamp = created
            }
            if let h = shape.hooksMtime, let j = shape.jsonMtime, h.timeIntervalSince(j) > 5 {
                s.isDirty = true
            }
            // SOUL-IDENTITY-SPLIT: the finalize transaction itself appends
            // a SESSION_SUMMARY event to hooks.jsonl AFTER writing the
            // finalize JSON — sometimes seconds, sometimes tens of
            // seconds later depending on writer flush timing. The
            // mtime-delta check above can't tell that apart from "user
            // kept working post-finalize." Treat any hooks-after-json
            // gap within 60s as part of the same finalize transaction
            // and clear the badge. Real post-finalize activity (a new
            // prompt + reply) takes far longer than 60s to land, so the
            // legitimate "unread since finalize" signal still works.
            if s.isDirty, let h = shape.hooksMtime, let j = shape.jsonMtime,
               shape.finalizePath != nil, h.timeIntervalSince(j) < 60 {
                s.isDirty = false
            }
            s.replayable = (shape.hooksPath != nil)
            if s.source == nil {
                if let live = agentMatchCached(sessionId: id, projectPath: projectPath, cache: dirCache, nativeSessionIDs: nativeSessionIDs) {
                    s.liveProvider = live
                } else {
                    let transcriptPath = "\(shape.sessionDir ?? sessionDir(projectKey: key, sessionId: id))/transcript.jsonl"
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

            // Always compute the provider-transcript turn count. Previously
            // gated on `promptCount == 0` as a perf optimization, but the
            // kernel hooks ledger frequently under-counts (terminal-origin
            // sessions, SOUL-247 payload-drop, hooks-disabled providers) —
            // a partial promptCount of 5 would freeze the sidebar at
            // "5 turns" forever on a session that actually had 90+ turns
            // in the provider transcript. metaLine picks max(promptCount,
            // transcriptTurns), which is robust to either source being
            // partial. Per-project scan is gated through cachedSessions
            // (projectStamp mtime), so this cost is paid once per project
            // dir change, not per sidebar body render.
            s.transcriptTurns = countTranscriptTurns(
                sessionId: id,
                projectKey: key,
                projectPath: projectPath,
                sessionDir: shape.sessionDir ?? sessionDir(projectKey: key, sessionId: id),
                cache: dirCache,
                nativeSessionIDs: nativeSessionIDs
            )

            if s.promptCount == 0 {
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

    /// Process-lifetime memoization of `countTranscriptTurns` results,
    /// keyed by transcript file path. Each entry stores the file mtime at
    /// scan time; lookups stat() the file (microseconds) and return the
    /// cached count if mtime is unchanged, bypassing the mmap + byte-scan
    /// (milliseconds) entirely. The big payoff is during streaming, when
    /// the project's `projectStamp` advances on every hook write and forces
    /// `sessions(forProject:)` to re-run for the whole project — but only
    /// the actively-streaming session's transcript file actually changed,
    /// so every other session's count is a stat() hit.
    private struct TranscriptCountCache {
        var mtime: Date
        var count: Int
    }
    nonisolated(unsafe) private static var transcriptCountCache: [String: TranscriptCountCache] = [:]
    private static let transcriptCountCacheLock = NSLock()

    /// Returns the cached count for `path` iff the file's mtime matches the
    /// cache entry. Stats the file once; cheap.
    private static func cachedTranscriptCount(forPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mt = attrs[.modificationDate] as? Date else {
            return nil
        }
        transcriptCountCacheLock.lock()
        defer { transcriptCountCacheLock.unlock() }
        guard let hit = transcriptCountCache[path], hit.mtime == mt else { return nil }
        return hit.count
    }

    private static func recordTranscriptCount(_ count: Int, forPath path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mt = attrs[.modificationDate] as? Date else {
            return
        }
        transcriptCountCacheLock.lock()
        transcriptCountCache[path] = TranscriptCountCache(mtime: mt, count: count)
        transcriptCountCacheLock.unlock()
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
                if let hit = cachedTranscriptCount(forPath: claudePath) {
                    if hit > 0 { return hit }
                } else {
                    // SOUL-222: Claude logs every tool roundtrip as
                    // {"type":"user", ...} with a "tool_use_id" pointing at
                    // the prior tool_use block. A raw "type":"user" count
                    // therefore inflates turn count by every tool the agent
                    // ran. Subtract tool_use_id occurrences as a fast
                    // heuristic — matches what ClaudeTranscriptReader
                    // produces post-click, so the sidebar count stays stable
                    // before and after the user opens the session.
                    let userRecords = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: claudePath)
                    let toolResults = countNeedle(Data("\"tool_use_id\"".utf8), inFileAt: claudePath)
                    let n = max(0, userRecords - toolResults)
                    recordTranscriptCount(n, forPath: claudePath)
                    if n > 0 { return n }
                }
            }

            let geminiId = nativeSessionIDs["geminiCLI"] ?? sid
            let shortId = String(geminiId.prefix(8))
            if let hit = cache.firstEightIndex[shortId] {
                let path = "\(hit.chatsDir)/\(hit.fileName)"
                if let cached = cachedTranscriptCount(forPath: path) {
                    if cached > 0 { return cached }
                } else {
                    let n = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: path)
                    recordTranscriptCount(n, forPath: path)
                    if n > 0 { return n }
                }
            }
        }

        let codexPath = "\(sessionDir)/transcript.jsonl"
        if fm.fileExists(atPath: codexPath) {
            if let cached = cachedTranscriptCount(forPath: codexPath) {
                if cached > 0 { return cached }
            } else {
                let byType = countNeedle(Data("\"type\":\"user\"".utf8), inFileAt: codexPath)
                if byType > 0 {
                    recordTranscriptCount(byType, forPath: codexPath)
                    return byType
                }
                let byRole = countNeedle(Data("\"role\":\"user\"".utf8), inFileAt: codexPath)
                if byRole > 0 {
                    recordTranscriptCount(byRole, forPath: codexPath)
                    return byRole
                }
                recordTranscriptCount(0, forPath: codexPath)
            }
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

    /// Strip Claude's system-tag noise from a user-prompt body so it
    /// doesn't leak into sidebar/toolbar titles. Terminal `claude` wraps
    /// slash-command stubs and various execution metadata in XML-ish tags
    /// inside the first UserPrompt payload:
    ///
    ///   - `<command-message>…</command-message>` / `<command-name>…</command-name>`
    ///     / `<command-args>…</command-args>` — slash command stub
    ///   - `<local-command-stdout>…</local-command-stdout>` /
    ///     `<local-command-stderr>` / `<local-command-caveat>` —
    ///     captured shell-execution context Claude pastes in
    ///
    /// Strip every tag pair whose name starts with one of the recognized
    /// noise prefixes. Keep the human-readable remainder; if nothing's
    /// left, surface the slash command name itself (`/pulse`) as a
    /// usable fallback.
    static func stripCommandTags(_ raw: String) -> String {
        let prefixes = ["<command-", "<local-command-"]
        guard prefixes.contains(where: { raw.contains($0) }) else { return raw }
        var fallbackCmd: String? = nil
        var s = raw
        while let opener = nextNoiseTagOpen(in: s, prefixes: prefixes) {
            let openRange = opener.openRange
            let closeOpen = opener.closeOpenRange
            let tagName = opener.tagName  // e.g. "command-name", "local-command-stdout"
            let endTag = "</\(tagName)>"
            guard let endRange = s.range(of: endTag, range: closeOpen.upperBound..<s.endIndex) else {
                // Unclosed tag — drop the opening token and continue so we
                // don't loop on a malformed payload.
                s.removeSubrange(openRange.lowerBound..<closeOpen.upperBound)
                continue
            }
            if tagName == "command-name" {
                fallbackCmd = String(s[closeOpen.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            s.removeSubrange(openRange.lowerBound..<endRange.upperBound)
        }
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        if let cmd = fallbackCmd { return cmd }
        // Used to `return raw` here — that defeated the entire strip pass for
        // sessions whose user prompt was nothing but `<local-command-caveat>
        // …</local-command-caveat>` (and no <command-name> inside). Title
        // display would then show the literal tag in the toolbar + sidebar.
        // Returning empty lets the caller substitute their own fallback
        // ("untitled" in the sidebar, "New chat" in the toolbar) instead of
        // leaking the raw envelope.
        return ""
    }

    private struct NoiseTagOpen {
        let openRange: Range<String.Index>
        let closeOpenRange: Range<String.Index>
        let tagName: String  // full tag name without `<` / `>` (e.g. "command-name")
    }

    private static func nextNoiseTagOpen(in s: String, prefixes: [String]) -> NoiseTagOpen? {
        var best: NoiseTagOpen? = nil
        for prefix in prefixes {
            guard let openRange = s.range(of: prefix),
                  let closeOpen = s.range(of: ">", range: openRange.upperBound..<s.endIndex)
            else { continue }
            let nameStart = s.index(openRange.lowerBound, offsetBy: 1)  // skip the `<`
            let tagName = String(s[nameStart..<closeOpen.lowerBound])
            let hit = NoiseTagOpen(openRange: openRange, closeOpenRange: closeOpen, tagName: tagName)
            if best == nil || openRange.lowerBound < best!.openRange.lowerBound {
                best = hit
            }
        }
        return best
    }

    private static func worktreePathFromHooks(path: String) -> String? {
        // SOUL-SOUL_DESKTOP-164: only first line needed.
        guard let lines = headLines(path: path, maxLines: 1), let line = lines.first,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["event"] as? String) == "SESSION_START"
        else { return nil }
        return obj["worktree_path"] as? String
    }

    static func firstHookTimestamp(projectKey: String, sessionId: String) -> Date? {
        let path = hooksPath(projectKey: projectKey, sessionId: sessionId)
        // SOUL-SOUL_DESKTOP-164: only first line needed.
        guard let lines = headLines(path: path, maxLines: 1), let line = lines.first,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseTimestamp(obj["timestamp"] as? String)
    }

    private static func normalizeCwd(_ p: String) -> String {
        var s = p
        if s.hasSuffix("/") { s.removeLast() }
        return (s as NSString).standardizingPath
    }

    /// SOUL-SOUL_DESKTOP-164: read up to `maxLines` complete newline-terminated
    /// lines from `path` via FileHandle. Returns nil if the file can't be
    /// opened. Replaces `String(contentsOfFile:encoding:.utf8).split("\n")`
    /// for callers that only need a small prefix — the old pattern read the
    /// entire file (often multi-MB for Gemini chats) and `split` then walked
    /// every grapheme. Sample (2026-05-20 sample 4) had 2482 / 2518
    /// background-queue samples (98.5%) in that grapheme walk on
    /// isResumableGeminiChatFile alone.
    ///
    /// `byteCap` is a defensive backstop in case a single line is pathologically
    /// long (it's a "give up after this many bytes" rather than a hard
    /// line-boundary cap). 1 MB is generous for 50 JSON lines.
    private static func headLines(path: String, maxLines: Int, byteCap: Int = 1_048_576) -> [String]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var lines: [String] = []
        var carry = Data()
        let chunkSize = 64 * 1024
        var totalRead = 0
        outer: while lines.count < maxLines, totalRead < byteCap {
            let chunk: Data
            do { chunk = try fh.read(upToCount: chunkSize) ?? Data() }
            catch { break }
            if chunk.isEmpty { break }
            totalRead += chunk.count
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 0x0A) {
                let lineData = carry[carry.startIndex..<nl]
                carry.removeSubrange(carry.startIndex...nl)
                if let s = String(data: lineData, encoding: .utf8) {
                    lines.append(s)
                    if lines.count >= maxLines { break outer }
                }
            }
        }
        return lines
    }

    private static func isResumableGeminiChatFile(_ path: String) -> Bool {
        // SOUL-SOUL_DESKTOP-164: only the first 50 lines are inspected; no
        // reason to read & grapheme-walk megabytes of transcript.
        guard let lines = headLines(path: path, maxLines: 50) else { return true }
        if lines.count <= 1 { return false }
        for line in lines {
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
        // SOUL-SOUL_DESKTOP-164: only the first 40 lines are inspected.
        guard let lines = headLines(path: path, maxLines: 40) else { return nil }
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

}
