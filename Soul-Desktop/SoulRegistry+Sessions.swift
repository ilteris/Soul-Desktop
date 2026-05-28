import Foundation
import SoulLedger

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
typealias SessionListPayload = LedgerSessionListPayload
typealias SessionListRecord = LedgerSessionListRecord

extension SoulRegistry {

    /// Single shell-out to `soul session list -p <key> --json`. Returns nil
    /// on CLI failure (executable missing, non-zero exit, decode error) —
    /// callers degrade to empty. SOUL-SOUL_DESKTOP-263.
    static func loadSessionListPayload(projectKey: String) -> SessionListPayload? {
        let trace = UserDefaults.standard.bool(forKey: "soul.sidebar.trace")
        guard let data = SoulCLI.runSync(["session", "list", "-p", projectKey, "--json"]) else {
            if trace { NSLog("[sidebar-load] FAIL project=\(projectKey) reason=cli-returned-nil") }
            return nil
        }
        do {
            return try decodeLedgerSessionListPayload(from: data)
        } catch {
            // Decode failures here are how SOUL-093-class shape drifts surface:
            // a single schema mismatch nukes the whole project's payload, so
            // we keep the diagnostic available (gated on soul.sidebar.trace)
            // rather than swallowing it entirely. FinalizeFixedShapeTests
            // covers the known regression — any future drift will land here.
            if trace {
                let head = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                NSLog("[sidebar-load] FAIL project=\(projectKey) bytes=\(data.count) reason=decode-failed err=\(error) head=\(head)")
            }
            return nil
        }
    }

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


    private static func countNeedle(_ needle: Data, in data: Data) -> Int {
        var n = 0
        var range = 0..<data.count
        while let r = data.range(of: needle, in: range) {
            n += 1
            range = r.upperBound..<data.count
        }
        return n
    }

    // Visibility policy retired from this file — see SidebarVisibilityPolicy.swift
    // for the single decision site. The historical `isUserVisibleSidebarSession`
    // and `isSidebarControlTitle` were duplicated across allSessions /
    // mergedChatList / filteredChatCount; consolidated into one type.

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

    /// Returns every session row for the project, sorted newest-first by
    /// `timestamp` (== `firstEventTimestamp` from the kernel ledger).
    ///
    /// The `limit` parameter is honored only when explicitly passed — Stage 1
    /// loading in `SidebarView+Loading` uses `limit = sessionPageSize (20)`
    /// for a fast first paint. Stage 2 and all badge/full-list consumers
    /// pass no argument so the full list is returned.
    ///
    /// Default was previously `100`, which silently truncated older genuine
    /// chats out of `sessionsByProject` once a project accumulated >100
    /// candidate sessions (Soul OS hit ~210 because every chat spawns a
    /// title-generation machine session, plus delegate/preamble/finalize
    /// kernel sessions). The render layer already paginates via
    /// `sessionPageSize`, so a load-time limit just hid rows from the badge
    /// and "Show N more" expander.
    static func allSessions(forProject key: String, limit: Int = .max, projectPath: String? = nil) -> [SoulSession] {
        // Single source of truth: `soul session list -p <key> --json` (kernel
        // CLI). The directory walk + hooks.jsonl needle scan + finalize JSON
        // read are now done server-side in soul_session_view.py. Soul-Desktop
        // only handles what the kernel doesn't own:
        //   - Provider transcript probes (loadable, transcriptTurns,
        //     liveProvider) — those touch ~/.claude/, ~/.gemini/, ~/.pi/
        //     which are provider artifacts, not kernel state.
        //   - The is-dirty / is-stale / sort-key derivation that depends
        //     on session-row UI semantics rather than ledger truth.
        // SOUL-SOUL_DESKTOP-263.
        guard let payload = loadSessionListPayload(projectKey: key) else { return [] }
        if UserDefaults.standard.bool(forKey: "soul.sidebar.trace") {
            let ids = payload.sessions.map { "\($0.session_id.prefix(8))(pc=\($0.prompt_count ?? -1))" }.joined(separator: ",")
            SidebarRowResolver.traceWrite("CLI project=\(key) count=\(payload.sessions.count) ids=[\(ids)]")
        }

        struct Shape {
            var finalizePath: String?
            var hooksPath: String?
            var jsonMtime: Date?
            var hooksMtime: Date?
            var sessionDir: String?
        }
        struct Ranked {
            var id: String
            var shape: Shape
            var record: SessionListRecord
            var recency: Date
        }

        let ranked: [Ranked] = payload.sessions.map { rec in
            var shape = Shape()
            shape.finalizePath = rec.finalize_path
            shape.hooksPath = rec.hooks_path
            shape.jsonMtime = rec.finalize_mtime.map { Date(timeIntervalSince1970: $0) }
            shape.hooksMtime = rec.hooks_mtime.map { Date(timeIntervalSince1970: $0) }
            shape.sessionDir = rec.session_dir
            let recency = max(
                shape.jsonMtime ?? .distantPast,
                shape.hooksMtime ?? .distantPast
            )
            return Ranked(id: rec.session_id, shape: shape, record: rec, recency: recency)
        }.sorted { $0.recency > $1.recency }

        if ranked.isEmpty { return [] }

        let dirCache = GeminiDirCache()
        var out: [SoulSession] = []
        for cand in ranked {
            let id = cand.id
            let shape = cand.shape
            let rec = cand.record
            let hasFinalize = rec.has_finalize ?? (shape.finalizePath != nil)
            var s = SoulSession(id: id, project: key, timestamp: cand.recency)
            // For finalized rows, file activity is not necessarily chat
            // activity: opening a row can regenerate preamble/cache files
            // inside the session dir. Start from the finalize mtime
            // and only move lastActivityAt forward with parsed event
            // timestamps below. Live rows still use the freshest file mtime
            // as a cheap activity fallback.
            s.lastActivityAt = hasFinalize ? shape.jsonMtime : cand.recency

            // Finalize metadata — kernel-supplied so we don't open the
            // JSON ourselves. The kernel may source this from a ledger
            // Finalize event or from legacy JSON. SOUL-SOUL_DESKTOP-263.
            if let finalize = rec.finalize {
                if let ts = parseTimestamp(finalize.timestamp) {
                    s.lastActivityAt = max(s.lastActivityAt ?? .distantPast, ts)
                    s.timestamp = ts
                }
                s.intent = finalize.intent
                s.summary = finalize.summary
                s.source = finalize.source
                s.status = finalize.status
                s.worktreePath = finalize.worktree_path
            }

            // Ledger metadata — kernel-derived via `soul session list --json`.
            // The in-process binary-needle scanner (readHooksMetadata) that
            // used to compute these fields was deleted in SOUL-277 — the
            // kernel CLI is the sole source of truth and stays in sync with
            // soul_session_view.py's own scanner semantics.
            s.eventCount = rec.event_count ?? 0
            s.promptCount = rec.prompt_count ?? 0
            s.assistantTurnCount = rec.assistant_turn_count ?? 0
            s.toolCallCount = rec.tool_call_count ?? 0
            s.visibleTurnCount = rec.visible_turn_count ?? 0
            s.hasConversation = rec.has_conversation
            s.rawTitle = rec.raw_title
            s.titleSource = rec.title_source
            s.titleStatus = rec.title_status
            s.provider = normalizedProviderName(rec.provider)
            s.origin = rec.origin
            s.resumeStrategy = rec.resume_strategy
            s.resumeTarget = rec.resume_target
            s.loadabilityReason = rec.loadability_reason
            s.health = rec.health
            s.healthReasons = rec.health_reasons ?? []
            s.lifecycle = rec.lifecycle
            s.trashedAt = parseTimestamp(rec.trashed_at)
            s.slashSemantics = (rec.slash_semantics ?? [:]).mapValues { sem in
                SoulSlashCommandSemantics(
                    localOnly: sem.local_only,
                    conversationWorthy: sem.conversation_worthy,
                    taskAffecting: sem.task_affecting,
                    titleWorthy: sem.title_worthy,
                    expansionStrategy: sem.expansion_strategy
                )
            }
            s.taskId = rec.task_id
            s.taskStatus = rec.task_status
            s.taskSubject = rec.task_subject
            let sessionStartPpid: Int? = rec.session_start_ppid
            let nativeSessionIDs: [String: String] = rec.native_session_ids ?? [:]
            let sessionVisibility: String? = rec.session_visibility
            let sessionKind: String? = rec.session_kind
            let visibilityReason: String? = rec.visibility_reason
            let delegationEventCount: Int = rec.delegation_event_count ?? 0
            let partialCapture: Bool = rec.partial_capture ?? false
            if s.worktreePath == nil { s.worktreePath = rec.worktree_path }
            s.title = rec.title?.isEmpty == false ? rec.title : nil
            if s.summary == nil { s.summary = s.title ?? s.intent }
            s.writer = sessionWriter(from: rec.writer, hasDesktopSignature: rec.has_desktop_signature, hooksPath: shape.hooksPath)
            s.startedAt = parseTimestamp(rec.first_event_ts)
            if let last = parseTimestamp(rec.last_event_ts) {
                s.lastActivityAt = max(s.lastActivityAt ?? .distantPast, last)
            }
            // Sort key = actual session start (first ledger event), not
            // finalize-time / file-mtime. Without this, regenerating a
            // preamble or re-saving finalize JSON on an old session
            // bumps it above newer rows in the sidebar.
            if let started = s.startedAt {
                s.timestamp = started
            }

            s.isLive = !hasFinalize
            // Stale: live session with no activity in 1 hour. Computed from
            // lastActivityAt (not the pinned sort timestamp below) so it tracks real
            // activity even though we freeze the sort key.
            if s.isLive {
                let lastActive = s.lastActivityAt ?? cand.recency
                s.isStale = Date().timeIntervalSince(lastActive) > 3600
            }
            // Sidebar rows should be stable: once a session exists, appending
            // prompts, assistant chunks, titles, summaries, or finalize rows
            // must not move it around. Live rows use ledger creation/start time;
            // finalized rows keep the summary timestamp, because opening old
            // summaries can mint a new hooks.jsonl and that must not re-sort them.
            if s.isLive {
                if let started = s.startedAt {
                    s.timestamp = started
                } else if let dir = shape.sessionDir, let created = creationTime(dir) {
                    s.timestamp = created
                } else if let hooks = shape.hooksPath, let created = creationTime(hooks) {
                    s.timestamp = created
                }
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
               hasFinalize, h.timeIntervalSince(j) < 60 {
                s.isDirty = false
            }
            s.replayable = rec.replayable ?? (shape.hooksPath != nil)
            if let provider = s.provider, provider != "unknown" {
                s.source = provider
                s.liveProvider = provider
            }
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

            let providerTranscriptLoadable = projectPath.map {
                canLoadCached(sessionId: id, projectKey: key, projectPath: $0, cache: dirCache, nativeSessionIDs: nativeSessionIDs)
            } ?? false
            if let loadable = rec.loadable {
                s.loadable = loadable || providerTranscriptLoadable
            } else {
                s.loadable = providerTranscriptLoadable
            }

            let providerTranscriptTurns = countTranscriptTurns(
                sessionId: id,
                projectKey: key,
                projectPath: projectPath,
                sessionDir: shape.sessionDir ?? sessionDir(projectKey: key, sessionId: id),
                cache: dirCache,
                nativeSessionIDs: nativeSessionIDs
            )
            if let visible = rec.visible_turn_count {
                s.transcriptTurns = max(visible, providerTranscriptTurns)
            } else {
                s.transcriptTurns = providerTranscriptTurns
            }

            if s.promptCount == 0, rec.title_status == nil, rec.title_source == nil {
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

            // Persist the inputs SidebarRowResolver.shouldShow reads. Single
            // source of truth for the visibility decision lives in the
            // resolver — no `substantive` gets pre-computed and stored on
            // disk.
            // SOUL-SOUL-092 Phase E: prefer the kernel-CLI's `has_finalize`
            // field, which is true when EITHER a legacy <ts>_<sid>.json
            // file exists OR a Finalize event lives in hooks.jsonl. Post-
            // Phase-D, new finalizes only land in the ledger — the legacy
            // file path is nil, so the old `finalizePath != nil` check
            // would mis-classify recent finalizes as unfinalized.
            s.hasFinalize = hasFinalize
            s.sessionVisibility = sessionVisibility
            s.sessionKind = sessionKind
            s.visibilityReason = visibilityReason
            let desktopMetadataOnly = rec.has_desktop_signature == true
                || rec.origin == "desktop"
                || rec.writer == "soul-desktop"
            if s.promptCount == 0,
               s.transcriptTurns > 0,
               sessionVisibility == "machine",
               sessionKind == "metadata_only",
               !desktopMetadataOnly {
                let transcriptPrompt = findFirstTranscriptPrompt(
                    sessionId: id,
                    projectKey: key,
                    projectPath: projectPath,
                    cache: dirCache,
                    nativeSessionIDs: nativeSessionIDs
                )
                if transcriptPrompt.map(isLocalOnlySlashPrompt) != true {
                    s.sessionVisibility = "human"
                    s.sessionKind = "conversation"
                    s.visibilityReason = "provider_transcript_conversation"
                    s.replayable = true
                }
            }
            s.delegationEventCount = delegationEventCount
            s.sessionStartPpid = sessionStartPpid
            s.partialCapture = partialCapture
            // SOUL-SOUL_DESKTOP-268: model fired AfterAgent envelopes but
            // every one carried empty content AND no provider transcript
            // rescues the session. Kernel exposes after_agent_content_count
            // (non-empty count). Compared to partialCapture (no envelope at
            // all), this catches the writer-drop class where envelopes did
            // fire but content was lost.
            let afterAgentContent = rec.after_agent_content_count ?? -1
            if rec.health_reasons?.contains("agent_reply_missing") == true
                || rec.health_reasons?.contains("empty_after_agent") == true {
                s.agentReplyMissing = true
            }
            if afterAgentContent >= 0,
               s.promptCount > 0,
               afterAgentContent == 0,
               s.transcriptTurns == 0 {
                s.agentReplyMissing = true
            }

            out.append(s)
        }

        return out
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizedProviderName(_ raw: String?) -> String? {
        switch raw {
        case "gemini", "gemini-cli", "geminiCLI": return Provider.geminiCLI.rawValue
        case "claude": return Provider.claude.rawValue
        case "pi", "pi-native": return Provider.pi.rawValue
        case "codex": return Provider.codex.rawValue
        case .some(let value) where !value.isEmpty: return value
        default: return nil
        }
    }

    private static func sessionWriter(from raw: String?, hasDesktopSignature: Bool?, hooksPath: String?) -> SessionWriter {
        switch raw {
        case "soulDesktop", "desktop": return .soulDesktop
        case "external", "terminal", "daemon", "subagent": return .external
        case "unknown": return .unknown
        default:
            if hasDesktopSignature == true { return .soulDesktop }
            if hooksPath != nil { return .external }
            return .unknown
        }
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

    private static func isLocalOnlySlashPrompt(_ raw: String) -> Bool {
        let stripped = stripCommandTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard stripped.hasPrefix("/") else { return false }
        let command = stripped.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? stripped
        return [
            "/clear",
            "/compact",
            "/finalize",
            "/help",
            "/init",
            "/login",
            "/logout",
            "/pulse",
            "/quit",
            "/reset",
        ].contains(command)
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

    /// Counts both JSON formatting styles for a key/value pair: the
    /// tight form `"key":"value"` (line-delimited JSONL emitted by stream
    /// writers) and the spaced form `"key": "value"` (pretty-printed JSON
    /// emitted by snapshots / migrations). Sum is safe — a file uses one
    /// form consistently. Without both, pretty-printed transcripts return
    /// zero matches and the row falls through to the no-conversation gate
    /// or shows "no reply" despite having a rescuable transcript on disk
    /// (SOUL-SOUL_DESKTOP-268 root cause for ~half of the 95 affected rows).
    private static func countJSONField(_ key: String, _ value: String, inFileAt path: String) -> Int {
        let tight = countNeedle(Data("\"\(key)\":\"\(value)\"".utf8), inFileAt: path)
        let spaced = countNeedle(Data("\"\(key)\": \"\(value)\"".utf8), inFileAt: path)
        return tight + spaced
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
                    // the prior tool_use block. Subtract tool_use_id
                    // occurrences as a fast heuristic — matches what
                    // ClaudeTranscriptReader produces post-click.
                    let userRecords = countJSONField("type", "user", inFileAt: claudePath)
                    // The key substring `"tool_use_id"` is identical in
                    // tight and spaced JSON forms — countNeedle once.
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
                    // SOUL-265 sibling: gemini chat records use `"type":"user"`,
                    // not `"role":"user"`. Pretty-printed `.json` snapshots
                    // emit the spaced form `"type": "user"`; streaming
                    // `.jsonl` emits the tight form. countJSONField covers
                    // both.
                    //
                    // SOUL-222 parallel for Gemini: every tool roundtrip is
                    // persisted as a synthetic `{type:"user"}` record whose
                    // content text is `{"functionResponse":{...}}`. Without
                    // subtracting these, a 7-real-turn chat with 59 tool
                    // calls shows as "66 turns" in the sidebar. Same shape
                    // as the Claude tool_use_id subtraction above.
                    let userRecords = countJSONField("type", "user", inFileAt: path)
                    let toolResults = countNeedle(Data("\"functionResponse\"".utf8), inFileAt: path)
                    let n = max(0, userRecords - toolResults)
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
                let byType = countJSONField("type", "user", inFileAt: codexPath)
                if byType > 0 {
                    recordTranscriptCount(byType, forPath: codexPath)
                    return byType
                }
                let byRole = countJSONField("role", "user", inFileAt: codexPath)
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
