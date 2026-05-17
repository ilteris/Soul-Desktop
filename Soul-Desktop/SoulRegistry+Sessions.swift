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
                if event == "Title", meta.titleHook == nil {
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
                if meta.hasDesktopSignature {
                    s.writer = .soulDesktop
                } else if meta.hasTerminalSignal {
                    s.writer = .external
                } else {
                    s.writer = .unknown
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

    /// Strip Claude's slash-command stub from a user-prompt body. Terminal
    /// `claude` wraps slash commands in `<command-message>…</command-message>`
    /// + `<command-name>/…</command-name>` tags inside the first UserPrompt
    /// payload, which leaks straight into sidebar titles. Drop the tags and
    /// keep the human-readable remainder; if nothing's left, surface the
    /// command name itself ("/pulse") as a usable fallback.
    static func stripCommandTags(_ raw: String) -> String {
        guard raw.contains("<command-") else { return raw }
        var fallbackCmd: String? = nil
        var s = raw
        while let openRange = s.range(of: "<command-"),
              let closeOpen = s.range(of: ">", range: openRange.upperBound..<s.endIndex) {
            let tagName = String(s[openRange.upperBound..<closeOpen.lowerBound])
            let endTag = "</command-\(tagName)>"
            guard let endRange = s.range(of: endTag, range: closeOpen.upperBound..<s.endIndex) else {
                s.removeSubrange(openRange.lowerBound..<closeOpen.upperBound)
                continue
            }
            if tagName == "name" {
                fallbackCmd = String(s[closeOpen.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            s.removeSubrange(openRange.lowerBound..<endRange.upperBound)
        }
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        return fallbackCmd ?? raw
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

}
