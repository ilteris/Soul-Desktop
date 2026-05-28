import Foundation

/// SOUL-SOUL_DESKTOP-270: single source of truth for "what rows does this
/// project's sidebar show right now, in what state."
///
/// Owns three previously-scattered concerns:
///   - Per-row visibility (the 7 hide rules formerly in SidebarVisibilityPolicy)
///   - Synthetic-thread injection + live-overlay (formerly in mergedChatList)
///   - Archive partitioning + sort + draft injection
///
/// Both the badge count and the rendered list derive from one resolve()
/// pass so they cannot disagree (the bug class chased in SOUL-267, where
/// filteredChatCount and mergedChatList read the same data through
/// different filter logic and produced different totals).
enum SidebarRowResolver {

    // MARK: - Inputs / Output

    struct VisibilityContext {
        /// Session ids the user has archived in this project. Used by the
        /// caller only — visibility policy ignores it (archived rows still
        /// pass; they're partitioned into the archived bucket downstream).
        let archivedIds: Set<String>
        /// When false (default), rows without an offline transcript or hooks
        /// ledger are hidden. The "Show unreadable" filter toggle flips this
        /// to true so the user can see crash-residue rows for diagnostics.
        let showUnreadable: Bool
        /// Provider chip filter — e.g. "claude" hides Gemini rows.
        let chatSourceFilter: String?
        /// When true, sessions whose resolved title is empty get hidden.
        let hideUntitled: Bool
    }

    struct Inputs {
        /// Project key — included so diagnostic traces can attribute each
        /// PASS/DROP line to the project it belongs to (without this, all
        /// projects' decisions interleave in one trace log with no key).
        var projectKey: String = ""
        /// Disk-scanned sessions for this project (sessionsByProject[id]).
        var diskSessions: [SoulSession]
        /// Live ThreadControllers attached to this project. Used to inject
        /// synthetic rows for new chats and overlay live state (working
        /// indicator, freshly-renamed title) on existing disk rows.
        var activeControllers: [ThreadController]
        /// In-flight draft session (user hit "New chat" but hasn't sent the
        /// first prompt yet — no disk row exists yet).
        var draft: SoulSession?
        /// Session ids the user has archived in this project.
        var archivedIds: Set<String>
        /// Session ids the user has starred. Starred rows float to the top
        /// within both the active and archived buckets.
        var starredIds: Set<String>
        /// Filter-toggle state the visibility policy reads.
        var visibilityContext: VisibilityContext
    }

    struct Output {
        /// Rows shown in the project's main list, sorted (starred first,
        /// then recency descending). Excludes archived. Includes any live
        /// synthetic thread rows and the draft.
        var active: [SoulSession]
        /// Rows shown in the "Archived (N)" disclosure. Passed visibility
        /// but are present in archivedIds. Same sort as active.
        var archived: [SoulSession]
        /// Count of active rows — for badge callers that don't need the
        /// full array.
        var activeCount: Int { active.count }
    }

    // MARK: - Public API

    @MainActor
    static func resolve(_ inputs: Inputs) -> Output {
        let ctx = inputs.visibilityContext

        // Stamp the per-resolve project key on a thread-local so trace lines
        // can be attributed back to the project they came from. Required:
        // sidebar repaints fire resolve() for every project per frame, so a
        // trace log without project keys interleaves all decisions into one
        // unattributable stream — and a single project's logs look like
        // sessions are missing when in fact they belong to a sibling.
        currentTraceProject = inputs.projectKey
        defer { currentTraceProject = "" }

        if verboseTraceEnabled {
            traceWrite("RESOLVE project=\(inputs.projectKey) diskSessions=\(inputs.diskSessions.count) active=\(inputs.activeControllers.count) draft=\(inputs.draft != nil)")
        }

        // 1. Collapse duplicate disk candidates before visibility. The
        // kernel CLI can surface more than one physical artifact for the
        // same logical session id (for example a live dir plus a finalized
        // summary, or primary+legacy roots during migrations). Filtering
        // first made traces contradict themselves for one sid: an empty
        // artifact logged DROP while the content-bearing artifact logged
        // PASS. Resolve one authoritative row, then make one visibility
        // decision.
        let diskSessions = mergedDiskSessions(inputs.diskSessions)

        // 2. Visibility filter (rules inlined below; see shouldShow).
        var byId: [String: SoulSession] = [:]
        byId.reserveCapacity(diskSessions.count)
        for s in diskSessions {
            guard shouldShow(s, in: ctx) else { continue }
            byId[s.id] = s
        }

        // 3. Overlay / inject live ThreadControllers. Contract preserved
        // from the old mergedChatList: don't surface a naked controller
        // shell — it must have a session id, items, or queued prompts.
        // Otherwise an empty new-chat shell would show up as a ghost row.
        for ctrl in inputs.activeControllers {
            guard ctrl.sessionId != nil || !ctrl.items.isEmpty || !ctrl.queuedPrompts.isEmpty else {
                continue
            }
            let sid = ctrl.sessionId ?? "thread-\(ctrl.id)"
            if let existing = byId[sid] {
                // Live overlay on the existing disk row. Preserve disk
                // metadata (writer, source, isLive) — opening a row to
                // view doesn't make us its author or revive a finalized
                // session. Only overwrite fields the live ctrl owns.
                var merged = existing
                let t = ctrl.displayTitle
                if !t.isEmpty { merged.title = t }
                merged.liveProvider = ctrl.provider.rawValue
                merged.lastActivityAt = max(
                    existing.lastActivityAt ?? existing.timestamp,
                    ctrl.lastActivityAt
                )
                merged.isWorking = ctrl.isWorking
                // SOUL-219 / SOUL-SOUL_DESKTOP-228: gate promptCount overlay
                // on `!isReplayingLoad && !items.isEmpty`. Empty items means
                // the controller hasn't hydrated yet — disk count is the
                // truthful value until items stream in.
                let liveCount = ctrl.items.filter {
                    if case .userMessage = $0 { return true } else { return false }
                }.count
                if !ctrl.isReplayingLoad && !ctrl.items.isEmpty {
                    merged.promptCount = liveCount
                }
                byId[sid] = merged
            } else {
                byId[sid] = SoulSession(
                    id: sid,
                    project: ctrl.project.id,
                    timestamp: ctrl.startedAt,
                    title: ctrl.displayTitle,
                    source: ctrl.provider.rawValue,
                    isLive: true,
                    writer: .soulDesktop,
                    liveProvider: ctrl.provider.rawValue,
                    loadable: true,
                    replayable: true,
                    lastActivityAt: ctrl.lastActivityAt,
                    isWorking: ctrl.isWorking
                )
            }
        }

        // 4. Draft (user hit "New chat", no first send yet). Always active.
        if let draft = inputs.draft {
            byId[draft.id] = draft
        }

        // 5. Partition active vs archived in one pass; sort each with the
        // same comparator (starred float, then recency descending).
        let starred = inputs.starredIds
        var active: [SoulSession] = []
        var archived: [SoulSession] = []
        active.reserveCapacity(byId.count)
        for s in byId.values {
            if s.lifecycle == "deleted" || s.lifecycle == "purged" {
                continue
            }

            let hasKernelLifecycle = !(s.lifecycle ?? "").isEmpty
            if s.lifecycle == "archived" || s.lifecycle == "trashed" {
                archived.append(s)
            } else if !hasKernelLifecycle && inputs.archivedIds.contains(s.id) {
                archived.append(s)
            } else {
                active.append(s)
            }
        }
        let sortFn: (SoulSession, SoulSession) -> Bool = { a, b in
            let aStar = starred.contains(a.id)
            let bStar = starred.contains(b.id)
            if aStar != bStar { return aStar }
            return a.timestamp > b.timestamp
        }
        return Output(
            active: active.sorted(by: sortFn),
            archived: archived.sorted(by: sortFn)
        )
    }

    private static func mergedDiskSessions(_ sessions: [SoulSession]) -> [SoulSession] {
        var byId: [String: SoulSession] = [:]
        byId.reserveCapacity(sessions.count)
        for session in sessions {
            if let existing = byId[session.id] {
                byId[session.id] = mergedDiskSession(existing, session)
            } else {
                byId[session.id] = session
            }
        }
        return Array(byId.values)
    }

    private static func mergedDiskSession(_ a: SoulSession, _ b: SoulSession) -> SoulSession {
        func score(_ s: SoulSession) -> Int {
            (s.promptCount > 0 ? 1_000_000 : 0)
            + (s.transcriptTurns > 0 ? 100_000 : 0)
            + (s.hasFinalize ? 10_000 : 0)
            + s.eventCount
        }

        var out = score(b) > score(a) ? b : a
        let other = out.id == a.id && out == a ? b : a

        out.promptCount = max(a.promptCount, b.promptCount)
        out.assistantTurnCount = max(a.assistantTurnCount, b.assistantTurnCount)
        out.toolCallCount = max(a.toolCallCount, b.toolCallCount)
        out.visibleTurnCount = max(a.visibleTurnCount, b.visibleTurnCount)
        out.transcriptTurns = max(a.transcriptTurns, b.transcriptTurns)
        out.eventCount = max(a.eventCount, b.eventCount)
        out.delegationEventCount = max(a.delegationEventCount, b.delegationEventCount)
        out.hasFinalize = a.hasFinalize || b.hasFinalize
        out.loadable = a.loadable || b.loadable
        out.replayable = a.replayable || b.replayable
        out.isLive = a.isLive || b.isLive
        out.isDirty = a.isDirty || b.isDirty
        out.isWorking = a.isWorking || b.isWorking
        out.isStale = a.isStale && b.isStale
        out.partialCapture = a.partialCapture && b.partialCapture
        out.agentReplyMissing = a.agentReplyMissing && b.agentReplyMissing
        out.lastActivityAt = max(a.lastActivityAt ?? .distantPast, b.lastActivityAt ?? .distantPast)
        out.startedAt = min(a.startedAt ?? .distantFuture, b.startedAt ?? .distantFuture)
        if out.lastActivityAt == .distantPast { out.lastActivityAt = other.lastActivityAt }
        if out.startedAt == .distantFuture { out.startedAt = other.startedAt }
        if out.title == nil || out.title?.isEmpty == true { out.title = other.title }
        if out.intent == nil || out.intent?.isEmpty == true { out.intent = other.intent }
        if out.summary == nil || out.summary?.isEmpty == true { out.summary = other.summary }
        if out.source == nil { out.source = other.source }
        if out.provider == nil { out.provider = other.provider }
        if out.origin == nil { out.origin = other.origin }
        if out.rawTitle == nil { out.rawTitle = other.rawTitle }
        if out.titleSource == nil { out.titleSource = other.titleSource }
        if out.titleStatus == nil { out.titleStatus = other.titleStatus }
        if out.liveProvider == nil { out.liveProvider = other.liveProvider }
        if out.worktreePath == nil { out.worktreePath = other.worktreePath }
        if out.sessionVisibility == nil { out.sessionVisibility = other.sessionVisibility }
        if out.sessionKind == nil { out.sessionKind = other.sessionKind }
        if out.visibilityReason == nil { out.visibilityReason = other.visibilityReason }
        if out.hasConversation == nil { out.hasConversation = other.hasConversation }
        if out.resumeStrategy == nil { out.resumeStrategy = other.resumeStrategy }
        if out.resumeTarget == nil { out.resumeTarget = other.resumeTarget }
        if out.loadabilityReason == nil { out.loadabilityReason = other.loadabilityReason }
        if out.health == nil { out.health = other.health }
        if out.healthReasons.isEmpty { out.healthReasons = other.healthReasons }
        if out.lifecycle == nil { out.lifecycle = other.lifecycle }
        if out.trashedAt == nil { out.trashedAt = other.trashedAt }
        if out.slashSemantics.isEmpty { out.slashSemantics = other.slashSemantics }
        if out.taskId == nil { out.taskId = other.taskId }
        if out.taskStatus == nil { out.taskStatus = other.taskStatus }
        if out.taskSubject == nil { out.taskSubject = other.taskSubject }
        if out.sessionStartPpid == nil { out.sessionStartPpid = other.sessionStartPpid }
        if out.writer == .unknown, other.writer != .unknown { out.writer = other.writer }
        return out
    }

    // MARK: - Visibility (formerly SidebarVisibilityPolicy)

    /// True when the row should appear in the project's list (either active
    /// or archived bucket). Archived ids are NOT excluded here — the
    /// resolver partitions on archivedIds separately so the disclosure can
    /// still show them.
    static func shouldShow(_ session: SoulSession, in ctx: VisibilityContext) -> Bool {
        // Kernel contract path. When the kernel has classified visibility,
        // Desktop consumes that field instead of re-interpreting ledger
        // semantics from counts/titles/provider artifacts.
        if let visibility = session.sessionVisibility {
            if visibility == "machine" || visibility == "hidden" {
                return traceDrop("1-kernel-visibility-\(visibility)", session.id)
            }

            if !ctx.showUnreadable, !(session.loadable || session.replayable) {
                return traceDrop("5-not-loadable-not-replayable", session.id)
            }

            if let filter = ctx.chatSourceFilter,
               (session.provider ?? session.source ?? session.liveProvider ?? "") != filter {
                return traceDrop("6-source-filter want=\(filter) got=\(session.source ?? session.provider ?? session.liveProvider ?? "nil")", session.id)
            }

            if ctx.hideUntitled {
                let title = (session.title ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { return traceDrop("7-hide-untitled", session.id) }
            }

            if verboseTraceEnabled {
                NSLog("[sidebar-trace] PASS proj=\(currentTraceProject) sid=\(session.id.prefix(8)) pc=\(session.promptCount) tt=\(session.transcriptTurns)")
                traceWrite("PASS proj=\(currentTraceProject) sid=\(session.id.prefix(8)) visibility=\(visibility) kind=\(session.sessionKind ?? "nil") reason=\(session.visibilityReason ?? "nil") writer=\(session.writer.rawValue) loadable=\(session.loadable) replayable=\(session.replayable)")
            }
            return true
        }

        // 1a. Partial-capture sessions. UserPrompt events landed but writer
        // never persisted AfterAgent — the row opens onto an empty canvas.
        if session.partialCapture { return traceDrop("1a-partial-capture", session.id) }

        // 2. Launchd-started rows with no prompts are daemon residue.
        if !session.hasFinalize, session.sessionStartPpid == 1, session.promptCount == 0 {
            return traceDrop("2-launchd-no-prompt-no-finalize", session.id)
        }

        // 3. Delegation-stub leak — kernel-minted session whose only events
        // are Delegation{Started,Completed,Failed} from a `soul delegate`
        // invocation when the parent crashed or never had a UserPrompt.
        let nonDelegationEvents = max(0, session.eventCount - session.delegationEventCount)
        if !session.hasFinalize,
           session.promptCount == 0,
           session.transcriptTurns == 0,
           session.delegationEventCount > 0,
           nonDelegationEvents < 2 {
            return traceDrop("3-delegation-stub", session.id)
        }

        // 4. Conversation gate. User content has to exist somewhere — the
        // kernel ledger OR the provider transcript (transcriptTurns rescues
        // the SOUL-247 payload-drop class).
        let hasConversation = session.promptCount > 0 || session.transcriptTurns > 0
        guard hasConversation else { return traceDrop("4-no-conversation pc=\(session.promptCount) tt=\(session.transcriptTurns)", session.id) }

        // 5. Loadability. Rows without a kernel ledger AND without an
        // off-disk provider transcript get hidden unless the user explicitly
        // toggles "Show unreadable".
        if !ctx.showUnreadable, !(session.loadable || session.replayable) {
            return traceDrop("5-not-loadable-not-replayable", session.id)
        }

        // 6. Provider chip filter.
        if let filter = ctx.chatSourceFilter,
           (session.source ?? session.liveProvider ?? "") != filter {
            return traceDrop("6-source-filter want=\(filter) got=\(session.source ?? session.liveProvider ?? "nil")", session.id)
        }

        // 7. Untitled toggle.
        if ctx.hideUntitled {
            let title = (session.title ?? session.intent ?? session.summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { return traceDrop("7-hide-untitled", session.id) }
        }

        if verboseTraceEnabled {
            NSLog("[sidebar-trace] PASS proj=\(currentTraceProject) sid=\(session.id.prefix(8)) pc=\(session.promptCount) tt=\(session.transcriptTurns)")
            traceWrite("PASS proj=\(currentTraceProject) sid=\(session.id.prefix(8)) pc=\(session.promptCount) tt=\(session.transcriptTurns) writer=\(session.writer.rawValue) loadable=\(session.loadable) replayable=\(session.replayable)")
        }
        return true
    }

    // Per-resolve thread-local project key for trace attribution. Set by
    // resolve() entry; cleared on exit. Read by traceDrop/PASS sites.
    nonisolated(unsafe) static var currentTraceProject: String = ""

    // MARK: - Diagnostic trace

    /// When `defaults write com.test.Soul-Desktop.dev soul.sidebar.trace
    /// -bool true` is set, every visibility decision is logged with rule +
    /// sid. File-based because NSLog routinely gets lost in log stream.
    private static func traceDrop(_ rule: String, _ sid: String) -> Bool {
        if verboseTraceEnabled {
            NSLog("[sidebar-trace] DROP proj=\(currentTraceProject) sid=\(sid.prefix(8)) rule=\(rule)")
            traceWrite("DROP proj=\(currentTraceProject) sid=\(sid.prefix(8)) rule=\(rule)")
        }
        return false
    }

    private static let tracePath = NSString(string: "~/tmp/soul-sidebar-trace.log").expandingTildeInPath
    private static let traceQueue = DispatchQueue(label: "soul.sidebar.trace.file")
    private static var traceEnabled: Bool {
        UserDefaults.standard.bool(forKey: "soul.sidebar.trace")
    }

    /// Per-row resolver traces are intentionally louder than scan traces and
    /// run from SwiftUI render paths. Keep them opt-in so resize/drag invalidations
    /// don't flood Console or the file trace during normal diagnostics.
    private static var verboseTraceEnabled: Bool {
        UserDefaults.standard.bool(forKey: "soul.sidebar.trace.verbose")
    }

    static func traceWrite(_ line: String) {
        guard traceEnabled else { return }
        traceQueue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let row = "\(ts) \(line)\n"
            let dir = (tracePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = row.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: tracePath)) {
                    defer { try? h.close() }
                    try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: URL(fileURLWithPath: tracePath))
                }
            }
        }
    }
}
