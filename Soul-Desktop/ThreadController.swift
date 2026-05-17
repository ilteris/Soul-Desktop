import Foundation
import SwiftUI

struct PlanEntry: Hashable {
    let content: String
    let priority: String?
    let status: String?
}

struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String?
    let inputHint: String?
    var id: String { name }
}

/// Optional structured payload attached to a tool call. Today this carries
/// the before/after content for Edit/Write operations so the card can show
/// an inline diff on expand. Other tools (Read, Bash, Grep) leave this nil.
struct ToolCallDetails: Hashable {
    enum Kind: Hashable {
        case edit(oldString: String, newString: String)
        case write(content: String)
        case output(text: String)
        /// SOUL-SOUL_DESKTOP-111: structured payload for delegate_to_specialist
        /// tool calls so ThreadView can render a SubagentCard instead of the
        /// generic ToolCallRow. `subagentId` keys into the live.log tailer;
        /// `colorHex` is the kernel-resolved badge color (nil → palette fallback);
        /// `findingPath` is set when the agent script writes its final JSON.
        case subagent(specialist: String, objective: String, subagentId: String, colorHex: UInt32?, findingPath: String?)

        var isOutput: Bool {
            if case .output = self { return true }
            return false
        }
    }
    var kind: Kind
    /// First line of the edit in the source file when known (from ACP's
    /// `locations[0].line`). Used to label diff lines with their real
    /// in-file line numbers instead of starting at 1.
    var startLine: Int? = nil
    /// For `.write` only: line count of the file at the moment the tool
    /// call was first observed, captured before disk gets overwritten.
    /// Lets the row render `+N -M` instead of additions-only. nil when the
    /// path is unknown or the file didn't exist (fresh write).
    var previousLineCount: Int? = nil
}

indirect enum ThreadItem: Identifiable, Hashable {
    case userMessage(id: UUID, text: String, timestamp: Date)
    case agentMessage(id: UUID, text: String, complete: Bool, timestamp: Date)
    /// Streaming reasoning text from `agent_thought_chunk` ACP notifications.
    /// Rendered as a muted, italic, collapsible block — so the user sees
    /// what the agent is thinking through during long turns instead of
    /// staring at a "Thinking…" spinner.
    case agentThought(id: UUID, text: String, complete: Bool, timestamp: Date)
    case toolCall(id: UUID, kind: String, title: String, status: String, locationHint: String?, details: ToolCallDetails?)
    case plan(id: UUID, entries: [PlanEntry])
    case status(id: UUID, text: String)
    case error(id: UUID, text: String)
    /// Structured finalize summary rendered from the registry's
    /// `<ts>_<sid>.json` Quad. Surfaces what a session actually accomplished
    /// (Intent/Summary/Rationale/Fixed/Next) without the user having to
    /// `cat` the JSON. Injected once per hydrate when a finalize record
    /// exists for the session.
    case finalize(id: UUID, intent: String?, summary: String?, rationale: String?, fixed: String?, nextStep: String?, timestamp: Date)
    case toolCallGroup(id: UUID, kind: String, title: String, locationHint: String?, items: [ThreadItem])

    var id: UUID {
        switch self {
        case .userMessage(let id, _, _): return id
        case .agentMessage(let id, _, _, _): return id
        case .agentThought(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _): return id
        case .plan(let id, _): return id
        case .status(let id, _): return id
        case .error(let id, _): return id
        case .toolCallGroup(let id, _, _, _, _): return id
        case .finalize(let id, _, _, _, _, _, _): return id
        }
    }
}

/// Owns the live state of a single chat thread: the ordered ThreadItem list,
/// streaming agent message coalescing, tool-call lifecycle, and the bridge to
/// ACPClient for send/cancel/load. One instance per active thread.
@MainActor
@Observable
final class ThreadController {
    let id: String = UUID().uuidString.lowercased()
    let provider: Provider
    let project: SoulProject
    /// Best-effort wall-clock moment the underlying *session* started. For a
    /// fresh thread this is the instantiation time; AppShell overwrites it on
    /// session-load with the first hooks.jsonl event timestamp so the
    /// session-length chip reflects total session age, not "ms since this view
    /// opened."
    var startedAt: Date = Date()

    var items: [ThreadItem] = [] {
        didSet {
            itemsVersion &+= 1
        }
    }
    var historicalIDs: Set<UUID> = []
    /// Per-thread composer draft text. Lives on the controller (not on
    /// AppShell) so keystrokes don't invalidate the whole app's view tree —
    /// only ThreadView's body re-evaluates. Survives thread-switch without
    /// requiring a top-level dictionary.
    var composerDraft: String = ""
    var isWorking: Bool = false
    var lastError: String?
    var availableCommands: [SlashCommand] = []
    var customTitle: String? = nil
    /// Bumped (any change) when the toolbar's pencil/⋯ "Rename" is clicked.
    /// `ThreadView` observes this and opens its rename alert. Using a counter
    /// instead of a Bool so back-to-back rename clicks work without an
    /// explicit reset round-trip.
    var renameRequestNonce: Int = 0
    /// Per-thread permission policy. Default mirrors the previous behavior so
    /// existing flows don't regress; user can dial down via the composer chip.
    var permissionMode: PermissionMode = .fullAccess {
        didSet {
            let mode = permissionMode
            let c = client
            Task { await c?.setPermissionMode(mode) }
        }
    }
    /// Rolling capture of the agent's stderr + protocol-level errors. Bounded
    /// so a chatty agent can't bloat memory. Surfaced via the inactivity
    /// popover so the user has somewhere to look when the agent stalls.
    @ObservationIgnored var agentLog: [String] = []
    var agentLogCount: Int = 0
    @ObservationIgnored private var lastAgentLogCountPublishAt: Date = .distantPast
    /// Hot-path trace lines from `soul.acp.trace`. Off the observation graph
    /// so per-frame appends during a streaming turn don't invalidate the
    /// toolbar chip on every chunk (which spun the main thread).
    @ObservationIgnored var traceLog: [String] = []

    /// SOUL-SOUL_DESKTOP-063 diagnostic: per-kind cost of `apply(_:)` lives
    /// in ApplyTimingProbe.swift. Off the observation graph so the
    /// accounting itself can't invalidate any view.
    @ObservationIgnored var applyTiming = ApplyTimingProbe()
    /// Seed value for `lastActivityAt` read before any ACPSession has been
    /// allocated. Without it, a controller hydrated from disk that has not
    /// spawned yet would either need to allocate an ACPSession just to
    /// answer reads (wasteful for historical-only threads) or lie with a
    /// fresh `Date()` (inflates stall budgets, breaks sidebar duration).
    /// Once `ensureSession()` runs, this value is passed through to the
    /// session's `initialLastActivityAt` and reads route there.
    @ObservationIgnored private var _seedLastActivityAt: Date = Date()

    /// Sends issued while a turn is already running get parked here and
    /// drained in order once the current `client.prompt` resolves. Each
    /// entry carries both halves of the two-channel send so slash-expanded
    /// agent text and the bare-`/cmd` display bubble stay paired.
    struct QueuedPrompt: Hashable {
        let itemId: UUID
        let display: String
        let agent: String
    }
    var queuedPrompts: [QueuedPrompt] = []

    /// The set of `userMessage` item IDs that have been appended to `items`
    /// but not yet dispatched. ThreadView styles these bubbles with a
    /// "pending" look so the user can tell which prompts are queued vs. the
    /// one the agent is actively chewing on.
var queuedItemIDs: Set<UUID> { Set(queuedPrompts.map(\.itemId)) }

    /// Groups tool calls for compact rendering. 
    /// 1. File-changing tools (edit/write) for the same file are merged into 
    ///    a single cumulative group even if non-consecutive.
    /// 2. Verification tools (read, execute, search) are carouselled by kind,
    ///    but are HIDDEN if they occur after a file change in the same turn.
    /// 3. All grouping is turn-scoped (resets on user/agent messages).
    var groupedItems: [ThreadItem] {
        if let cache = groupedItemsCache, cache.version == itemsVersion {
            return cache.value
        }

        var result: [ThreadItem] = []
        /// Maps file paths to their index in `result`.
        var fileGroupMap: [String: Int] = [:]
        /// Maps tool kinds to their index in `result` (for non-file tools).
        var kindGroupMap: [String: Int] = [:]
        /// Track if we've seen any file changes in the current tool sequence.
        var turnHasFileChanges = false

        for item in items {
            guard case .toolCall(let id, let kind, let title, _, let loc, _) = item else {
                result.append(item)
                // SOUL-SOUL_DESKTOP-104b: only userMessage resets the grouping
                // context. Pi (and Claude Code on long turns) interleaves
                // agentMessage chunks between consecutive tool calls — the
                // agent narrating "I'll try X now" between two greps — and
                // the original "reset on any non-toolCall" rule turned every
                // execute into its own group. The carousel never engaged
                // because each group ended up with count == 1 and got
                // unwrapped. Now only a real turn boundary (a new user
                // message) resets the maps.
                if case .userMessage = item {
                    fileGroupMap.removeAll()
                    kindGroupMap.removeAll()
                    turnHasFileChanges = false
                }
                continue
            }

            let isFileChange = (kind == "edit" || kind == "write")
            let isVerification = (kind == "read" || kind == "execute" || kind == "search")
            let fileKey = loc ?? title

            if isFileChange {
                turnHasFileChanges = true
                if let idx = fileGroupMap[fileKey] {
                    if case .toolCallGroup(let gId, let gKind, let gTitle, let gLoc, var gItems) = result[idx] {
                        gItems.append(item)
                        result[idx] = .toolCallGroup(id: gId, kind: gKind, title: gTitle, locationHint: gLoc, items: gItems)
                    }
                } else {
                    fileGroupMap[fileKey] = result.count
                    result.append(.toolCallGroup(id: id, kind: kind, title: title, locationHint: loc, items: [item]))
                }
            } else if isVerification && turnHasFileChanges {
                // Noise! Skip rendering verification tools that happen during 
                // or after a file-change sequence in the same turn.
                continue
            } else {
                if let idx = kindGroupMap[kind] {
                    if case .toolCallGroup(let gId, let gKind, let gTitle, let gLoc, var gItems) = result[idx] {
                        gItems.append(item)
                        result[idx] = .toolCallGroup(id: gId, kind: gKind, title: gTitle, locationHint: gLoc, items: gItems)
                    }
                } else {
                    kindGroupMap[kind] = result.count
                    result.append(.toolCallGroup(id: id, kind: kind, title: title, locationHint: loc, items: [item]))
                }
            }
        }

        // Unwrap groups containing only one item.
        result = result.map { entry in
            if case .toolCallGroup(_, _, _, _, let inner) = entry, inner.count == 1 {
                return inner[0]
            }
            return entry
        }
        groupedItemsCache = (itemsVersion, result)
        return result
    }

    /// Per-thread scroll anchor. ThreadView records the top-most visible item
    /// as the user scrolls and restores it on re-appear so switching threads
    /// (multiplexer) doesn't snap each view back to the top.
    var scrollAnchorItemId: UUID? = nil
    /// True iff the anchor is the synthetic "__bottom__" sentinel. We store a
    /// separate bool because the sentinel isn't a UUID.
    var scrollAnchorAtBottom: Bool = true

    /// True while a `session/load` is in flight. The agent replays the prior
    /// transcript through `user_message_chunk` / `agent_message_chunk`
    /// notifications during the load — we still paint them, but flag the
    /// items as historical so they don't accidentally trigger one-shot
    /// behaviors like first-turn title generation.
    var isReplayingLoad: Bool = false

    /// Set when a gemini-CLI `session/load` fails on a corrupted chat file
    /// (force-quit mid-write etc.). AppShell observes this and surfaces a
    /// recovery sheet with one-click actions: Replay the kernel ledger,
    /// reveal the `.bak` snapshot in Finder, or start a fresh chat carrying
    /// this row's title. Set back to nil when the sheet dismisses.
    var pendingRecovery: RecoveryContext? = nil

    /// One-shot recovery info handed from `loadSession` to AppShell when a
    /// corrupted gemini chat file blocks resume.
    struct RecoveryContext: Identifiable {
        let id = UUID()
        let sessionId: String     // kernel UUID of the row being loaded
        let backupPath: String    // `.bak-<epoch>` snapshot of the broken file
        let quarantinedPath: String?  // where the live file got moved aside
        let rpcMessage: String    // the parser error from gemini-cli
        let title: String?        // row title, carried through if user picks "start fresh"
    }

    /// SOUL-SOUL_DESKTOP-043 (read-first session open). When true, this
    /// ThreadController was hydrated from on-disk transcript without spawning
    /// the agent. The next user `send()` triggers a lazy spawn-and-resume in
    /// `ensureSession()` — until then `client == nil` and `hasInitialized ==
    /// false`. Reset to false the moment we begin spawning so a second send
    /// during the spawn window doesn't re-enter the resume path.
    private var pendingResumeOnFirstSend: Bool = false

    /// While true, drop content events (`user_message_chunk` /
    /// `agent_message_chunk` / tool calls / plans) coming through `apply` —
    /// they're the agent's recap of a session we already rendered from disk
    /// via `hydrateFromDisk`. Without suppression we'd duplicate every
    /// historical item. `availableCommandsUpdate` is allowed through because
    /// it isn't content — we need it to populate the slash-command picker.
    var suppressLoadReplay: Bool = false

    /// When non-nil, the next agent reply stream is captured into this buffer
    /// instead of being rendered in the canvas. Used for out-of-band prompts
    /// like title generation — same ACP session, same agent, no second model
    /// spawn, but the user never sees the round-trip. Tool calls during a
    /// silent prompt are also suppressed; title prompts shouldn't need tools,
    /// and if the agent calls one anyway, surfacing it would be more confusing
    /// than helpful.
    var silentCapture: String? = nil

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }

        let firstUser: String? = items.lazy.compactMap {
            if case .userMessage(_, let t, _) = $0 { return t } else { return nil }
        }.first

        if let user = firstUser, !isBareSlashCommand(user) {
            return truncateForTitle(user)
        }

        let firstAgent: String? = items.lazy.compactMap {
            if case .agentMessage(_, let t, _, _) = $0 { return t } else { return nil }
        }.first

        if let agent = firstAgent, let line = firstMeaningfulLine(agent) {
            return truncateForTitle(line)
        }

        if let user = firstUser {
            return truncateForTitle(user)
        }
        return "New chat"
    }

    /// Most recent agent reply text in `items`, walking from the end.
    /// Used by `send()` to capture the just-completed turn for the kernel
    /// hooks ledger so Replay is durable against provider-side data loss.
    /// Returns nil if there's no agent message after the most recent user
    /// message (i.e. the agent didn't actually reply).
    private func mostRecentAgentReplyText() -> String? {
        for item in items.reversed() {
            switch item {
            case .agentMessage(_, let text, _, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .userMessage:
                // Reached the prompt that opened this turn without finding
                // an agent reply — nothing to persist.
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private func isBareSlashCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let body = trimmed.dropFirst()
        return !body.contains(" ") && !body.contains("\n") && !body.isEmpty
    }

    private func truncateForTitle(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }

    private func firstMeaningfulLine(_ text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Strip leading markdown markers
            while line.hasPrefix("#") || line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            // Strip simple inline markdown
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return line }
        }
        return nil
    }

    /// Bump the rename nonce so any observing view opens its rename alert.
    /// Called by the toolbar's pencil + ⋯ menu.
    func requestRename() {
        renameRequestNonce &+= 1
    }

    /// Copy this thread's session id (kernel uuid) to the pasteboard.
    func copySessionIdToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionId ?? id, forType: .string)
    }

    /// Copy the full conversation transcript as Markdown to the pasteboard.
    func copyMarkdownToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdownTranscript(), forType: .string)
    }

    func markdownTranscript() -> String {
        var out = "# \(displayTitle)\n\n"
        for item in items {
            switch item {
            case .userMessage(_, let text, _):
                out += "**You:** \(text)\n\n"
            case .agentMessage(_, let text, _, _):
                out += "**\(provider.label):** \(text)\n\n"
            case .agentThought(_, let text, _, _):
                // Thoughts go into the markdown export as a quoted block so
                // a copy-paste preserves the reasoning context the user saw.
                out += "> 💭 \(text)\n\n"
            case .toolCall(_, let kind, let title, let status, let loc, _):
                out += "_\(kind): \(title)_ — \(status)\(loc.map { " (\($0))" } ?? "")\n\n"
            case .toolCallGroup(_, let kind, let title, let loc, let inner):
                out += "_\(kind): \(title)_ — \(inner.count) edits\(loc.map { " (\($0))" } ?? "")\n\n"
            case .plan(_, let entries):
                out += "**Plan:**\n"
                for e in entries {
                    let mark = e.status == "completed" ? "x" : " "
                    out += "- [\(mark)] \(e.content)\n"
                }
                out += "\n"
            case .finalize(_, let intent, let summary, let rationale, let fixed, let nextStep, _):
                out += "---\n### Finalize\n"
                if let intent { out += "**Intent:** \(intent)\n\n" }
                if let summary { out += "**Summary:** \(summary)\n\n" }
                if let rationale { out += "**Rationale:** \(rationale)\n\n" }
                if let fixed { out += "**Fixed:** \(fixed)\n\n" }
                if let nextStep { out += "**Next:** \(nextStep)\n\n" }
                out += "---\n\n"
            case .status, .error:
                continue
            }
        }
        return out
    }

    var client: ACPClient?
    /// Codex app-server client. Spawned alongside `client` when provider ==
    /// .codex; the two clients never coexist on the same thread. Codex
    /// speaks its own JSON-RPC dialect (thread/start, turn/start, item/* and
    /// turn/* notifications) so its event loop and turn semantics live on a
    /// parallel path from ACPClient's session/prompt flow.
    var codexClient: CodexClient?
    /// Set while a codex turn is in flight. The codex event loop resumes
    /// this continuation when it observes `turn/completed`, letting `send`
    /// stay awaitable on a single turn boundary.
    var codexTurnContinuation: CheckedContinuation<Void, Error>?
    /// Maps codex-side `item.id` strings to the ThreadItem UUID we minted
    /// for that item. Lets `item/agentMessage/delta` + `item/completed`
    /// notifications find the right canvas row to update.
    var codexItemMap: [String: UUID] = [:]
    /// Active codex turn id, captured at `turn/start` and used to filter
    /// `turn/completed` notifications belonging to this turn.
    var codexActiveTurnId: String?
    /// Per-thread ACP session state, constructed lazily on first need.
    /// Owns codex token counters (and, in later refactor steps, the agent
    /// client handles + event stream). Historical-only threads loaded from
    /// disk never allocate one. See ACPSession.swift.
    @ObservationIgnored private var _session: ACPSession?
    private func ensureSession() -> ACPSession {
        if let s = _session { return s }
        let s = ACPSession(provider: provider,
                           project: project,
                           initialLastActivityAt: _seedLastActivityAt)
        _session = s
        return s
    }

    /// Forwarders so external callers (AppShell toolbar etc.) keep their
    /// existing read paths while storage lives on `ACPSession`. Note: the
    /// previous `fileprivate(set)` on `sessionId` and `private(set)` on
    /// `nativeSessionId` are not preserved here — the access narrowing was
    /// light protection against accidental external mutation, and no
    /// external call site writes either field. Will tighten back via a
    /// dedicated mutation method if a regression motivates it.
    var sessionId: String? {
        get { _session?.sessionId }
        set { ensureSession().sessionId = newValue }
    }
    var nativeSessionId: String? {
        get { _session?.nativeSessionId }
        set { ensureSession().nativeSessionId = newValue }
    }
    /// Read returns the session's value when allocated, else the seed.
    /// Write always allocates (creating the session at the seed's value
    /// before overwriting), so a pre-spawn write — e.g. AppShell setting
    /// `controller.lastActivityAt = session.timestamp` during resume
    /// hydration — survives into the eventual session.
    var lastActivityAt: Date {
        get { _session?.lastActivityAt ?? _seedLastActivityAt }
        set { ensureSession().lastActivityAt = newValue }
    }
    var codexTokensUsed: Int? {
        get { _session?.codexTokensUsed }
        set { ensureSession().codexTokensUsed = newValue }
    }
    var codexContextWindow: Int? {
        get { _session?.codexContextWindow }
        set { ensureSession().codexContextWindow = newValue }
    }
    // `sessionId`, `nativeSessionId`, `acpSessionId` now live on ACPSession
    // (forwarded by computed properties above).

    /// Synchronously stake out the kernel session id before any async load
    /// kicks in. AppShell calls this right after wiring the controller into
    /// `threads[]` so the sidebar's synthetic row uses the real session.id
    /// from frame zero — without it, the sidebar paints one tick with
    /// `id = "thread-<uuid>"`, fails to dedup against the finalized row,
    /// and shows two visually-identical entries until hydrateFromDisk's
    /// first MainActor block lands.
    func assignSessionId(_ sid: String) {
        sessionId = sid
        startFinalizeWatcher()
    }

    /// SOUL-SOUL_DESKTOP-075 (b1): watch the project's sessions dir for new
    /// finalize JSON files so an agent self-invoking `/finalize` (typical
    /// Gemini-CLI behavior) surfaces a real FinalizeCard instead of just a
    /// bold "Finalization complete" line of stdout from the tool call.
    @ObservationIgnored private var finalizeWatcher: FinalizeWatcher?

    private func startFinalizeWatcher() {
        finalizeWatcher?.stop()
        let dir = "\(SoulRegistry.registryPath)/sessions/\(project.id)"
        let watcher = FinalizeWatcher(directoryPath: dir) { [weak self] in
            guard let self, let sid = self.sessionId else { return }
            self.injectFinalizeSummaryIfFresh(sessionId: sid)
        }
        finalizeWatcher = watcher
        watcher.start()
    }
    /// Convenience: native id when known, else the kernel id. Use this at
    /// every ACPClient call site so we never accidentally ask the agent to
    /// resume a UUID it didn't mint. Forwards to ACPSession when allocated.
    private var acpSessionId: String? { _session?.acpSessionId }
    var hasInitialized = false
    private var supportsLoadSession = false
    var openAgentMessageId: UUID?
    var openAgentThoughtId: UUID? = nil
    var seenToolCallIds: [String: UUID] = [:]
    var eventTask: Task<Void, Never>?

    /// SOUL-SOUL_DESKTOP-024: per-turn stall watchdog. While `isWorking` is
    /// true, this task polls `lastActivityAt` and fires once at the provider's
    /// stall budget (StallDetected hook + UI capsule wakes up via TimelineView)
    /// and again at the hard auto-cancel ceiling (force-recovers the turn).
    /// One task per `send()` invocation; cleared on completion or cancel.
    private var stallWatchdog: Task<Void, Never>?
    /// Single-fire guard so the StallDetected hook lands once per stall
    /// episode even though the watchdog ticks every second.
    private var stallHookEmittedAt: Date?
    /// Most recent in_progress tool kind we observed when the stall fired,
    /// captured for the hook payload so post-mortems can pattern-match
    /// `swarm-status.py --oneshot` style hangs across sessions.
    private var lastInProgressToolKind: String?
    /// SOUL-SOUL_DESKTOP-033: per-toolCallId in_progress start timestamps.
    /// Each in-flight tool call gets its own deadline; the watchdog tick
    /// fires a ToolCallTimeout + turn cancel when any entry exceeds the
    /// configured threshold. Removed when the call hits a terminal status.
    var toolCallStartedAt: [String: Date] = [:]
    /// SOUL-SOUL_DESKTOP-079: activity-based timeout map. See commit 951d65d.
    var toolCallLastActivityAt: [String: Date] = [:]
    /// IDs we've already fired a timeout for so the watchdog doesn't keep
    /// hammering cancel + writing duplicate hooks every tick after expiry.
    var toolCallTimedOut: Set<String> = []
    /// SOUL-SOUL_DESKTOP-110: IDs we've already emitted a "still working"
    /// signpost for, so the watchdog tick doesn't keep spamming the canvas
    /// with the same warning. Cleared at end-of-turn alongside the other
    /// per-tool tracking sets.
    private var toolCallSignposted: Set<String> = []
    /// For Write tool calls: line count of the target file the first time
    /// we saw the toolCallId, captured before the agent's actual disk write
    /// lands. Lets the diff chip show `+N -M` for Writes against existing
    /// files. Keyed by toolCallId. Sentinel `0` means "file did not exist."
    var toolCallPreviousLineCount: [String: Int] = [:]
    @ObservationIgnored private var itemsVersion: Int = 0
    @ObservationIgnored private var groupedItemsCache: (version: Int, value: [ThreadItem])?
    /// Set when Stop / Recover intentionally tears down the provider child to
    /// force an in-flight prompt continuation to unwind. The resulting
    /// childTerminated error is expected and should not render as a red row.
    private var suppressNextInterruptedTurnError = false

    init(provider: Provider, project: SoulProject) {
        self.provider = provider
        self.project = project
    }

    func send(_ text: String) async {
        await send(display: text, agent: text)
    }

    /// Two-channel send: `display` is what the user sees in their own bubble;
    /// `agent` is what we actually ship over ACP. They diverge when a slash
    /// command expands client-side — the bubble keeps the bare `/cmd` chip
    /// while the agent receives the skill's full instructions + any args.
    ///
    /// While a turn is already in flight, additional sends queue rather than
    /// step on the live prompt. They paint as user bubbles immediately so the
    /// canvas reads chronologically, and dispatch to the agent in order once
    /// the current turn resolves. The behavior switch (queue vs steer-via-
    /// cancel) is the future home for a user setting; the queue side is the
    /// safe default.
    func send(display: String, agent: String) async {
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else { return }

        let messageId = UUID()
        items.append(.userMessage(id: messageId, text: trimmedDisplay, timestamp: Date()))
        openAgentMessageId = nil
        lastActivityAt = Date()
        // User just sent — they want to follow the response. Reset the scroll
        // anchor to "stick to bottom" so ThreadView's items.count auto-scroll
        // pins to the latest content regardless of where the view was before.
        scrollAnchorAtBottom = true
        scrollAnchorItemId = nil

        if isWorking {
            // Already running a turn; stash this for the dispatch loop to
            // pick up. UserPrompt is logged here so the hooks ledger
            // reflects the order the user sent things, not the order the
            // agent processed them.
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
                "event": "UserPrompt",
                "text": trimmedDisplay,
            ])
            queuedPrompts.append(QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent))
            return
        }

        isWorking = true
        startStallWatchdog()
        defer {
            isWorking = false
            stopStallWatchdog()
            drainQueuedPromptAfterTurn()
            suppressNextInterruptedTurnError = false
            
            NotificationManager.shared.sendTurnCompletedNotification(
                threadTitle: displayTitle,
                project: project.name
            )
        }

        // First turn dispatches immediately; subsequent queued turns are
        // drained from `queuedPrompts` while we still hold `isWorking`.
        // `isFirstTurn` toggles after the initial iteration so popped turns
        // can take the queue-consumption path (relocate bubble, skip the
        // dispatch-time UserPrompt hook since it was already logged at
        // queue time at line ~471).
        var current: QueuedPrompt? = QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent)
        var isFirstTurn = true
        do {
            try await ensureSession()
            // Codex path: parallel client + event semantics, see sendCodex.
            if provider == .codex {
                guard let sid = sessionId else { return }
                while let turn = current {
                    if isFirstTurn {
                        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                            "event": "UserPrompt",
                            "text": turn.display,
                        ])
                    } else {
                        relocateQueuedBubbleToEnd(turn)
                    }
                    isFirstTurn = false
                    try await sendCodex(text: turn.agent)

                    // Persist the codex agent's final reply text to the
                    // kernel hooks ledger, same way the ACP branch does.
                    // Without this, a codex session's transcript only has
                    // prompts in the kernel ledger; replay/hydrate shows
                    // empty agent responses. With it, `hydrateFromDisk`
                    // (codex branch below) renders full conversations.
                    if let reply = mostRecentAgentReplyText() {
                        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                            "event": "AfterAgent",
                            "content": reply,
                            "provider": provider.rawValue,
                        ])
                        // SOUL-SOUL_DESKTOP-065: AfterAgent is now the canonical
                        // record; the per-chunk file can retire.
                        SoulRegistry.retireAgentChunks(projectKey: project.id, sessionId: sid)
                    }

                    // Same finalize-card live injection as the ACP branch.
                    injectFinalizeSummaryIfFresh(sessionId: sid)

                    current = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
                }
                return
            }
            guard let client, let sid = sessionId else { return }
            // ACP id used for prompt/cancel — may differ from kernel sid
            // when the session was resumed via backfill.
            let nid = nativeSessionId ?? sid

            while let turn = current {
                if isFirstTurn {
                    SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                        "event": "UserPrompt",
                        "text": turn.display,
                    ])
                } else {
                    relocateQueuedBubbleToEnd(turn)
                }
                isFirstTurn = false
                do {
                    _ = try await client.prompt(sessionId: nid, text: turn.agent)
                } catch ACPClientError.rpcError(let rpc) where Self.isInvalidSessionRPC(rpc) {
                    // SOUL-SOUL_DESKTOP-103: Gemini-CLI rotates / drops the
                    // session mid-conversation (observed: session loaded fine,
                    // ran tools, then a later session/prompt fails with
                    // "Invalid session identifier" on the same sid we just
                    // used). Same class as SOUL-SOUL_DESKTOP-060 / -022 but at
                    // the prompt boundary instead of the load boundary. Try a
                    // transparent recovery: re-issue session/load on the held
                    // sid (the agent re-registers it in its session map), then
                    // retry the prompt once. If that also fails we fall through
                    // to the outer catch and surface the original error.
                    items.append(.status(
                        id: UUID(),
                        text: "ℹ \(rpc.message) — re-registering session and retrying"
                    ))
                    suppressLoadReplay = true
                    isReplayingLoad = true
                    defer {
                        suppressLoadReplay = false
                        isReplayingLoad = false
                    }
                    try await client.loadSession(sessionId: nid, cwd: project.path)
                    _ = try await client.prompt(sessionId: nid, text: turn.agent)
                }

                // Persist the agent's full reply text to the kernel hooks
                // ledger. Without this, the conversation only lives in the
                // provider's chat file (gemini-cli's `~/.gemini/tmp/.../chats/`
                // or Claude's `~/.claude/projects/...`) — and if that file
                // gets corrupted, rotated, or force-quit-truncated, Replay
                // shows the prompts with empty bodies. With this row, every
                // Soul-Desktop session is replayable from our own ledger
                // alone, regardless of agent-side disk state.
                if let reply = mostRecentAgentReplyText() {
                    SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                        "event": "AfterAgent",
                        "content": reply,
                        "provider": provider.rawValue,
                    ])
                    // SOUL-SOUL_DESKTOP-065: AfterAgent now holds the canonical
                    // reply text; the per-chunk file can retire so it doesn't
                    // grow unbounded across a long session.
                    SoulRegistry.retireAgentChunks(projectKey: project.id, sessionId: sid)
                }

                // If this turn was a `/finalize` (the agent just wrote a
                // finalize JSON to the registry), inject the structured
                // FinalizeCard inline so the user sees the Quad rendered
                // without having to re-open the session from the sidebar.
                injectFinalizeSummaryIfFresh(sessionId: sid)

                // Post-turn title generation only on the very first user turn
                // of a fresh chat. Skip when draining queued prompts.
                let userPrompts = items.filter { if case .userMessage = $0 { return true } else { return false } }.count
                if userPrompts == 1 && customTitle == nil {
                    Task { await generateTitle() }
                }

                // Pop the next queued turn. Re-check on each iteration so
                // sends that arrived during this loop's await get drained
                // without needing a separate dispatcher.
                current = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
            }
        } catch {
            if suppressNextInterruptedTurnError {
                suppressNextInterruptedTurnError = false
            } else {
                let msg = Self.humanReadable(error)
                items.append(.error(id: UUID(), text: msg))
                lastError = msg
            }
        }

        // Queue draining happens in the defer above, after `isWorking` has
        // flipped false. Draining while this send still owns the active turn
        // can re-enter `send()` and re-queue the same prompt, or worse, open
        // a second provider prompt on the same child process after recovery.
    }

    private func drainQueuedPromptAfterTurn() {
        guard !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        Task { [weak self] in
            await self?.send(display: next.display, agent: next.agent)
        }
    }

    private func markInFlightToolCallsStopped() {
        items = items.map { item in
            if case .toolCall(let id, let kind, let title, let status, let loc, let details) = item,
               status == "in_progress" || status == "pending" {
                return .toolCall(id: id, kind: kind, title: title, status: "stopped", locationHint: loc, details: details)
            }
            return item
        }
    }

    private func resetProviderProcessAfterInterruptedTurn() async {
        logLifecycle("resetProviderProcessAfterInterruptedTurn", note: "tearing down client; nativeSessionId preserved")
        suppressNextInterruptedTurnError = true
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.stop()
            self.client = nil
        }
        if let codexClient {
            await codexClient.stop()
            self.codexClient = nil
        }
        if let cont = codexTurnContinuation {
            codexTurnContinuation = nil
            cont.resume(throwing: NSError(
                domain: "Codex",
                code: 98,
                userInfo: [NSLocalizedDescriptionKey: "turn interrupted by recovery"]
            ))
        }
        hasInitialized = false
        supportsLoadSession = false
        codexActiveTurnId = nil
        openAgentMessageId = nil
        openAgentThoughtId = nil
        seenToolCallIds.removeAll(keepingCapacity: true)
        codexItemMap.removeAll(keepingCapacity: true)
    }

    private func cancelActiveProviderTurn() async {
        if provider == .codex {
            if let codex = codexClient,
               let tid = nativeSessionId ?? sessionId,
               let turnId = codexActiveTurnId {
                try? await codex.turnInterrupt(threadId: tid, turnId: turnId)
            }
            return
        }

        if let client, let sid = sessionId {
            let nid = nativeSessionId ?? sid
            try? await client.cancel(sessionId: nid)
        }
    }

    private func appendCancelStatusIfNeeded() {
        if case .status(_, let last)? = items.last, last == "■ cancel sent" {
            return
        }
        items.append(.status(id: UUID(), text: "■ cancel sent"))
    }

    /// Move a queued user bubble out of its insertion position (mid-prior-turn
    /// in `items[]`, where it was appended at queue time) to the end of
    /// `items[]` with a fresh timestamp. Without this, the bubble re-renders
    /// wedged between the previous turn's agent chunks once it's popped from
    /// `queuedItemIDs` — the "vanished queue" rendering bug in
    /// SOUL-SOUL_DESKTOP-066. Keeps the original `itemId` so the QueuedPrompt
    /// → ThreadItem linkage stays intact.
    private func relocateQueuedBubbleToEnd(_ turn: QueuedPrompt) {
        if let oldIdx = items.firstIndex(where: { $0.id == turn.itemId }) {
            items.remove(at: oldIdx)
        }
        items.append(.userMessage(id: turn.itemId, text: turn.display, timestamp: Date()))
    }

    /// Cancel the in-flight ACP turn over the wire and let the outer send()'s
    /// while-loop pop the queue and dispatch the next prompt on the *same*
    /// provider process. Shares `cancelActiveProviderTurn()` with Stop
    /// (`cancel()`) — the difference is Stop drops the queue and tears down
    /// the child, while Steer keeps both. Wired to the Steer button on the
    /// composer's queue chip.
    ///
    /// Why no `resetProviderProcessAfterInterruptedTurn` here: ACP's
    /// `session/cancel` resolves the in-flight `client.prompt` with
    /// stopReason=cancelled, leaving the session alive. Killing the child
    /// (as Stop and recoverStalledTurn do) would force the next queued
    /// prompt's send() to spawn a new process and call `session/load` —
    /// which fails with "invalid session identifier" on a fresh session
    /// whose session file the agent hasn't had time to persist yet.
    /// The teardown is appropriate for Stop (user wants out) and for
    /// recoverStalledTurn (agent is unresponsive). Steer is neither.
    func steerToNextQueued() async {
        guard isWorking, !queuedPrompts.isEmpty else { return }
        suppressNextInterruptedTurnError = true
        await cancelActiveProviderTurn()
        markInFlightToolCallsStopped()
        items.append(.status(id: UUID(), text: "↪ steered to next prompt"))
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
            "event": "TurnSteered",
            "provider": provider.rawValue,
            "queued_count": queuedPrompts.count,
        ])
    }

    /// Drop any queued-but-not-yet-sent prompts. Wired into `cancel()` and
    /// surfaced via a clear-X on the queue chip in the composer.
    func clearQueue() {
        queuedPrompts.removeAll()
    }

    func cancel() async {
        // Drop any queued prompts — cancelling means "stop, don't keep going."
        queuedPrompts.removeAll()
        await cancelActiveProviderTurn()
        // Flip any still-running tool calls to a terminal "stopped" status so
        // the row stops claiming work is happening. Without this the orange
        // "in_progress" pill lingers indefinitely after the agent acks cancel.
        markInFlightToolCallsStopped()
        // Guard against duplicate "cancel sent" rows when the user mashes the
        // cancel button.
        appendCancelStatusIfNeeded()
        await resetProviderProcessAfterInterruptedTurn()
        isWorking = false
    }

    /// Cancel the current stalled turn. If the queue has more prompts, dispatch
    /// the next one ("skip ahead"); otherwise just unblock the thread so the
    /// user can type. Wired to the WorkingIndicator's "Recover" capsule and
    /// also invoked by the watchdog when the hard auto-cancel ceiling is hit.
    ///
    /// SOUL-SOUL_DESKTOP-024: this used to require a non-empty queue. That
    /// gate meant five-hour `swarm-status.py --oneshot` hangs had no in-UI
    /// recovery affordance unless the user happened to type a follow-up first.
    /// Now the only precondition is an active session.
    func recoverStalledTurn(source: String = "manual") async {
        guard let sid = sessionId else { return }
        await cancelActiveProviderTurn()
        let stalledSeconds = Int(Date().timeIntervalSince(lastActivityAt))
        markInFlightToolCallsStopped()
        let label = source == "auto" ? "⏱ auto-recovered stalled turn (\(stalledSeconds)s)"
                                     : "⏭ recovered stalled turn (\(stalledSeconds)s)"
        items.append(.status(id: UUID(), text: label))
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "StallRecovered",
            "provider": provider.rawValue,
            "tool_kind": lastInProgressToolKind ?? "",
            "stalled_seconds": stalledSeconds,
            "recovery_source": source,
        ])
        // Tear the provider process down so the awaiting prompt/turn
        // continuation resolves. The original send() defer will then flip
        // `isWorking` off and drain exactly one queued prompt. Dispatching
        // here would overlap a new prompt with the still-awaiting old turn.
        await resetProviderProcessAfterInterruptedTurn()
        stopStallWatchdog()
    }

    /// Compat shim — older call sites still reference the previous name. The
    /// behavior matches the legacy method (requires a queued prompt) so any
    /// external caller keeps working; new UI uses `recoverStalledTurn`.
    func skipStalledTurn() async {
        guard !queuedPrompts.isEmpty else { return }
        await recoverStalledTurn(source: "manual")
    }

    /// Start a per-turn watchdog. Polls `lastActivityAt` every second while
    /// `isWorking` holds; fires a single StallDetected hook when quiet exceeds
    /// the provider's stall budget, and auto-recovers when quiet exceeds the
    /// hard ceiling. Cheap: one Task, one timer, no observers.
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        stallHookEmittedAt = nil
        lastInProgressToolKind = nil
        let budget = provider.stallBudgetSeconds
        let ceiling = StallPolicy.autoCancelCeilingSeconds
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.tickStallWatchdog(budget: budget, ceiling: ceiling)
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        stallHookEmittedAt = nil
        lastInProgressToolKind = nil
        // Drop per-tool-call deadlines at end-of-turn so a stray entry from
        // a never-resolved tool call doesn't leak across turns.
        toolCallStartedAt.removeAll()
        toolCallLastActivityAt.removeAll()
        toolCallTimedOut.removeAll()
        toolCallSignposted.removeAll()
        toolCallPreviousLineCount.removeAll()
    }

    /// One watchdog tick. Runs on @MainActor so it can read `items` /
    /// `isWorking` safely without locks.
    private func tickStallWatchdog(budget: Int, ceiling: Int) async {
        guard isWorking else { return }
        let quiet = Int(Date().timeIntervalSince(lastActivityAt))

        // Snapshot the most recent in_progress tool kind for the hook payload.
        // Walking items.reversed() short-circuits on the first match.
        if lastInProgressToolKind == nil {
            for item in items.reversed() {
                if case .toolCall(_, let kind, _, let status, _, _) = item,
                   status == "in_progress" || status == "pending" {
                    lastInProgressToolKind = kind
                    break
                }
            }
        }

        if quiet >= budget && stallHookEmittedAt == nil {
            stallHookEmittedAt = Date()
            SoulRegistry.appendHook(
                projectKey: project.id,
                sessionId: sessionId ?? id,
                event: [
                    "event": "StallDetected",
                    "provider": provider.rawValue,
                    "tool_kind": lastInProgressToolKind ?? "",
                    "stalled_seconds": quiet,
                    "threshold": budget,
                ]
            )
        }

        if quiet >= ceiling {
            await recoverStalledTurn(source: "auto")
            return
        }

        // SOUL-SOUL_DESKTOP-033: per-tool-call timeout sweep. Independent
        // from the turn-level quiet check — catches the `tail -f` case
        // where a single tool call sits in_progress forever while still
        // emitting enough output to keep `lastActivityAt` fresh.
        let toolTimeout = StallPolicy.toolCallTimeoutSeconds
        let signpostThreshold = Int(Double(toolTimeout) * StallPolicy.toolCallSignpostFraction)
        let now = Date()
        var expired: [String] = []
        var toSignpost: [(toolId: String, quietFor: Int)] = []
        // SOUL-SOUL_DESKTOP-079: drive expiry off lastActivityAt, not startedAt.
        for (toolId, lastSeen) in toolCallLastActivityAt where !toolCallTimedOut.contains(toolId) {
            let quietFor = Int(now.timeIntervalSince(lastSeen))
            if quietFor >= toolTimeout {
                expired.append(toolId)
                continue
            }
            // SOUL-SOUL_DESKTOP-110: midway signpost — surface that the tool
            // is still working and how far from cancellation we are. Once per
            // tool per turn; toolCallSignposted dedupes.
            if signpostThreshold > 0,
               quietFor >= signpostThreshold,
               !toolCallSignposted.contains(toolId) {
                toSignpost.append((toolId, quietFor))
            }
        }
        for entry in toSignpost {
            emitToolCallSignpost(toolId: entry.toolId, quietFor: entry.quietFor, threshold: toolTimeout)
        }
        for toolId in expired {
            await fireToolCallTimeout(toolId: toolId, threshold: toolTimeout)
        }
    }

    /// SOUL-SOUL_DESKTOP-110: emit a one-time "tool still working" status row
    /// when an in_progress tool call has been quiet for half the timeout
    /// budget. Lets the user see the tool is alive and how close it is to
    /// auto-cancel before we yank the turn. Idempotent per (toolId, turn)
    /// via toolCallSignposted; cleared at end-of-turn.
    private func emitToolCallSignpost(toolId: String, quietFor: Int, threshold: Int) {
        toolCallSignposted.insert(toolId)
        var label = "tool call"
        if let uuid = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == uuid }),
           case .toolCall(_, let k, let t, _, _, _) = items[idx] {
            let kindPart = k.isEmpty ? "tool" : k
            let titlePart = t.isEmpty ? "" : " \(t)"
            label = "\(kindPart)\(titlePart)"
        }
        let remaining = max(0, threshold - quietFor)
        items.append(.status(
            id: UUID(),
            text: "⏳ \(label) quiet for \(quietFor)s — will auto-cancel in \(remaining)s if no activity"
        ))
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: [
                "event": "ToolCallSignpost",
                "provider": provider.rawValue,
                "tool_call_id": toolId,
                "quiet_seconds": quietFor,
                "threshold": threshold,
            ]
        )
    }

    /// Mark a stuck tool call timed out, flip its row to stopped, write the
    /// telemetry hook, and cancel the turn so the agent unblocks. ACP today
    /// has no per-toolCallId cancel surface; the turn-level cancel is the
    /// only tool we have to free the awaiting `client.prompt`. Idempotent
    /// via `toolCallTimedOut`.
    private func fireToolCallTimeout(toolId: String, threshold: Int) async {
        guard !toolCallTimedOut.contains(toolId) else { return }
        toolCallTimedOut.insert(toolId)
        let startedAt = toolCallStartedAt[toolId] ?? Date()
        let elapsed = Int(Date().timeIntervalSince(startedAt))

        // Snapshot the row's kind/title for the hook and flip its visible
        // status to stopped so the spinner clears.
        var kindForHook = ""
        var titleForHook = ""
        if let uuid = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == uuid }),
           case .toolCall(let id, let k, let t, _, let loc, let details) = items[idx] {
            kindForHook = k
            titleForHook = t
            items[idx] = .toolCall(
                id: id,
                kind: k,
                title: t,
                status: "stopped",
                locationHint: loc,
                details: details
            )
        }

        // SOUL-SOUL_DESKTOP-078: classify the hang at firing time. If the
        // kernel ledger already has an AfterTool for this toolCallId, it's
        // class B (ACP item/completed never delivered). If not, it's class
        // A (still working — bump helps) or C (app-server stall). Cheap
        // tail scan; we read at most 256KB off the end of hooks.jsonl.
        let afterToolInLedger = SoulRegistry.ledgerContainsAfterTool(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            toolId: toolId
        )

        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sessionId ?? id,
            event: [
                "event": "ToolCallTimeout",
                "provider": provider.rawValue,
                "tool_call_id": toolId,
                "tool_kind": kindForHook,
                "tool_title": titleForHook,
                "elapsed_seconds": elapsed,
                "threshold": threshold,
                "afterTool_in_ledger": afterToolInLedger,
            ]
        )

        items.append(.status(
            id: UUID(),
            text: "⚠ tool call timed out after \(elapsed)s (limit \(threshold)s) — cancelling turn"
        ))

        // Best-effort turn cancel, then tear down the provider process so the
        // awaiting prompt continuation definitely resolves. Tool timeouts are
        // the same class of failure as a quiet stall: continuing on the same
        // child risks overlapping the next prompt with a stuck old turn.
        await cancelActiveProviderTurn()
        await resetProviderProcessAfterInterruptedTurn()
    }

    func loadSession(id sid: String) async {
        guard !hasInitialized else { return }
        let loadSessionInterval = SoulSignposts.beginInterval("ThreadController.loadSession", id: sid)
        isWorking = true
        defer {
            isWorking = false
            SoulSignposts.endInterval("ThreadController.loadSession", state: loadSessionInterval)
        }
        guard Self.looksLikeUUID(sid) else {
            items.append(.error(id: UUID(), text: "session id is not a UUID; cannot resume"))
            return
        }
        // Establish kernel identity before any ACP work. Every appendHook
        // from here on persists under the original kernel UUID, even if the
        // agent's native UUID diverges and gets stored in nativeSessionId.
        sessionId = sid

        // Off-main: metadata fetches scan hooks.jsonl.
        let proj = project
        let prov = provider.rawValue
        struct LoadMetadata {
            var nativeId: String?
            var title: String?
            var slashPrompts: [(text: String, timestamp: Date)] = []
        }
        let meta: LoadMetadata = await Task.detached(priority: .userInitiated) {
            LoadMetadata(
                nativeId: SoulRegistry.findNativeSessionID(projectKey: proj.id, sessionId: sid, provider: prov),
                title: SoulRegistry.findTitle(projectKey: proj.id, sessionId: sid),
                slashPrompts: SoulRegistry.slashCommandPrompts(projectKey: proj.id, sessionId: sid)
            )
        }.value

        if let t = meta.title, !t.isEmpty {
            customTitle = t
        }
        let nativeId = meta.nativeId

        do {
            switch provider {
            case .claude, .geminiCLI, .pi:
                try await spawnAndInitialize(skipNewSession: true)
                guard let client else { return }
                let resumeId = nativeId ?? sid

                let backupPath = Self.backupAgentChatIfPresent(
                    provider: provider,
                    sessionId: resumeId,
                    cwd: project.path
                )
                do {
                    isReplayingLoad = true
                    try await client.loadSession(sessionId: resumeId, cwd: project.path)
                    isReplayingLoad = false
                    nativeSessionId = resumeId
                    hasInitialized = true
                    injectSlashCommandPrompts(meta.slashPrompts)
                } catch ACPClientError.rpcError(let rpc) {
                    isReplayingLoad = false
                    let lowerMsg = rpc.message.lowercased()
                    let isInvalidSession = rpc.code == -32602
                        || rpc.code == -32002
                        || lowerMsg.contains("invalid session")
                        || lowerMsg.contains("session id")
                        || lowerMsg.contains("resource not found")
                    
                    if isInvalidSession {
                        let result = SoulRegistry.backfillNativeSessionID(
                            projectKey: project.id,
                            sessionId: sid,
                            provider: provider.rawValue,
                            cwd: project.path
                        )
                        if let backfilled = result.uuid, backfilled != resumeId {
                            items.append(.status(
                                id: UUID(),
                                text: "↻ backfilled native session id \(backfilled.prefix(8))… — retrying"
                            ))
                            do {
                                isReplayingLoad = true
                                try await client.loadSession(sessionId: backfilled, cwd: project.path)
                                isReplayingLoad = false
                                nativeSessionId = backfilled
                                hasInitialized = true
                                injectSlashCommandPrompts(meta.slashPrompts)
                                return
                            } catch {
                                isReplayingLoad = false
                            }
                        }
                    }

                    let dataStr = Self.describeJSONValue(rpc.data)
                    let suffix = dataStr.isEmpty ? "" : " · data: \(dataStr)"
                    let recoverable = isInvalidSession && provider == .claude
                    if recoverable {
                        items.append(.status(
                            id: UUID(),
                            text: "ℹ \(rpc.message) — session not on agent, recovering"
                        ))
                    } else if provider != .geminiCLI {
                        items.append(.error(
                            id: UUID(),
                            text: "session/load rpcError code=\(rpc.code) message=\(rpc.message)\(suffix)"
                        ))
                    }

                    if provider == .geminiCLI {
                        let quarantinedPath: String? = {
                            guard isInvalidSession, backupPath != nil else { return nil }
                            return Self.quarantineCorruptGeminiChat(
                                sessionId: resumeId,
                                cwd: project.path
                            )
                        }()
                        if let backupPath {
                            pendingRecovery = RecoveryContext(
                                sessionId: sid,
                                backupPath: backupPath,
                                quarantinedPath: quarantinedPath,
                                rpcMessage: rpc.message,
                                title: customTitle
                            )
                        }
                        return
                    }

                    renderHistoryIfAvailable(sid: sid)
                    items.append(.status(id: UUID(), text: "ℹ session could not be resumed — starting fresh"))
                    let newSid = try await client.newSession(cwd: project.path)
                    sessionId = newSid
                    nativeSessionId = newSid
                    hasInitialized = true
                }
            case .codex:
                try await spawnAndInitializeCodex()
            }
        } catch {
            isReplayingLoad = false
            items.append(.error(id: UUID(), text: "load failed: \(error)"))
        }
    }

    /// SOUL-SOUL_DESKTOP-043: render an archived session straight from the
    /// on-disk Claude transcript without spawning an agent. The agent process
    /// is started lazily by `ensureSession()` on the user's first `send()`,
    /// which is when they're already expecting a beat anyway. Versus the
    /// existing `loadSession` path this skips: process spawn (~1–3s),
    /// ACP initialize handshake, and the agent's `session/load` recap stream.
    ///
    /// Claude-only for now; other providers fall through to `loadSession`.
    /// If the on-disk transcript is missing/empty we also fall through so
    /// the user is never stuck staring at an empty canvas.
    func hydrateFromDisk(id sid: String) async {
        guard !hasInitialized else { return }
        let hydrateInterval = SoulSignposts.beginInterval("ThreadController.hydrateFromDisk", id: sid)
        defer { SoulSignposts.endInterval("ThreadController.hydrateFromDisk", state: hydrateInterval) }
        // Hydrate handles Claude, Gemini-CLI, AND Codex. Pi still falls
        // through to loadSession (no hydrate reader yet). The earlier
        // guard explicitly skipped codex which bounced every codex click
        // straight back to loadSession's fresh-thread fallback — the
        // canvas-came-empty bug.
        guard provider == .claude || provider == .geminiCLI || provider == .codex else {
            await loadSession(id: sid)
            return
        }
        guard Self.looksLikeUUID(sid) else {
            items.append(.error(id: UUID(), text: "session id is not a UUID; cannot resume"))
            return
        }
        // Establish kernel identity immediately so subsequent appendHooks
        // (e.g. a fast send() before hydrate finishes) write under the right
        // directory.
        sessionId = sid

        // Off-main: a 33h Claude transcript is multi-MB of JSONL. Parsing on
        // the main actor would beach-ball the sidebar click; mirror the
        // ReplayController pattern and hand the file work to a detached task.
        let proj = project
        let prov = provider
        struct HydrateResult {
            var history: [ThreadItem]?
            var title: String?
            var nativeId: String?
            var slashPrompts: [(text: String, timestamp: Date)] = []
        }
        let result: HydrateResult = await Task.detached(priority: .userInitiated) {
            var r = HydrateResult()
            // Native UUID lookup happens *before* the transcript read because
            // terminal-origin Gemini sessions are filed under a gemini-side
            // UUID that differs from the kernel UUID. Claude's identity-
            // mapped sessions use sid for both — passing sid through still
            // works when nativeId is nil.
            r.nativeId = SoulRegistry.findNativeSessionID(projectKey: proj.id, sessionId: sid, provider: prov.rawValue)
            let lookupId = r.nativeId ?? sid
            switch prov {
            case .claude:
                r.history = ClaudeTranscriptReader.transcript(forSession: lookupId, cwd: proj.path)
            case .geminiCLI:
                r.history = GeminiTranscriptReader.transcript(forSession: lookupId, projectKey: proj.id)
            case .pi:
                r.history = nil
            case .codex:
                // Codex has no off-disk transcript file we can read (no
                // rollout reader yet), but the kernel hooks ledger carries
                // every UserPrompt (always) and every AfterAgent reply
                // (for sessions created/used after the codex AfterAgent
                // capture landed). Render those so a click on a codex row
                // shows prior content instead of a blank fresh thread.
                let events = HooksReader.events(forSession: sid, project: proj)
                r.history = events.map { $0.item }
            }
            r.title = SoulRegistry.findTitle(projectKey: proj.id, sessionId: sid)
            r.slashPrompts = SoulRegistry.slashCommandPrompts(projectKey: proj.id, sessionId: sid)
            return r
        }.value

        // No on-disk transcript and no native-id mapping → this session
        // can't be resumed from disk. For Claude we can still try the agent
        // path (it owns the transcript at a different file). For Gemini,
        // that path would just rpcError with "Invalid session identifier" —
        // show a clean status row instead and let the user type to start
        // fresh. Codex shows the same clean status (we have no off-disk
        // reader and codex's session/load doesn't exist).
        if result.history == nil || result.history?.isEmpty == true {
            if provider == .claude || provider == .geminiCLI {
                await loadSession(id: sid)
                return
            }
            if let t = result.title, !t.isEmpty { customTitle = t }
            nativeSessionId = result.nativeId
            items.append(.status(id: UUID(), text: "ℹ this session has no offline transcript on this machine — type to start a fresh chat"))
            return
        }
        let history = result.history!

        // Preserve a caller-seeded title (AppShell sets customTitle from the
        // session row before this Task starts). Only overwrite if the
        // registry returned a non-empty title — a nil/empty value here used
        // to stomp the seed and leave the synthetic sidebar row reading
        // "New chat".
        if let t = result.title, !t.isEmpty { customTitle = t }
        nativeSessionId = result.nativeId
        // SOUL-SOUL_DESKTOP-097: bulk-update; see commit 88aead0.
        historicalIDs.formUnion(history.lazy.map(\.id))
        items.append(contentsOf: history)
        // Slash-command UserPrompt hooks (captured by the kernel before the
        // model API ever saw them) don't appear in the Claude transcript —
        // merge them in by timestamp so chip rendering stays consistent.
        injectSlashCommandPrompts(result.slashPrompts)
        // Surface the Quad from any finalize JSON for this session. The
        // structured summary (Intent / Summary / Rationale / Fixed / Next)
        // lives in `~/soul_registry/sessions/<project>/<ts>_<sid>.json` —
        // recorded by `/finalize` but otherwise never rendered to the user.
        // Injecting it at the tail of the loaded transcript means clicking
        // a finalized row immediately answers "what did we accomplish here?"
        // without anyone needing to `cat` the JSON.
        injectFinalizeSummary(sessionId: sid)
        pendingResumeOnFirstSend = true
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Render a JSONValue payload as a compact string for the error row.
    /// We don't try to be cute about it — JSON-encode and truncate so any
    /// shape lands as a single readable line the user can copy back.
    private static func describeJSONValue(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) {
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        }
        return ""
    }

    /// SOUL-SOUL_DESKTOP-103: matches the "agent doesn't know this sid"
    /// rpcError surface across providers. Gemini-CLI raises -32602 / -32603
    /// with messages mentioning "invalid session" or "session id"; Claude
    /// raises -32002 with "resource not found." Used by both the session/load
    /// recovery path (SOUL-SOUL_DESKTOP-022) and the mid-conversation
    /// session/prompt recovery path (SOUL-SOUL_DESKTOP-103).
    private static func isInvalidSessionRPC(_ rpc: JSONRPCError) -> Bool {
        let lowerMsg = rpc.message.lowercased()
        return rpc.code == -32602
            || rpc.code == -32002
            || lowerMsg.contains("invalid session")
            || lowerMsg.contains("session id")
            || lowerMsg.contains("resource not found")
    }

    /// Best-effort snapshot of the agent's chat file before a resume attempt.
    /// Copies `<chatsDir>/session-…-<first8>.json{,l}` → `<file>.bak-<epoch>`.
    /// Returns the backup path if a copy was made, nil otherwise. Failures
    /// are silent — this is belt-and-suspenders, not a correctness gate.
    private static func backupAgentChatIfPresent(provider: Provider, sessionId: String, cwd: String) -> String? {
        guard provider == .geminiCLI else { return nil }
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }
        let needle = String(sessionId.prefix(8))
        let candidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl"))
        }
        // Pick the largest matching file — that's the one with real history,
        // not a previous-attempt stub.
        let resolved = candidates.max(by: { a, b in
            let aSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(a)")[.size] as? Int) ?? 0
            let bSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(b)")[.size] as? Int) ?? 0
            return aSize < bSize
        })
        guard let match = resolved else { return nil }
        let src = "\(chatsDir)/\(match)"
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = "\(src).bak-\(stamp)"
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// Move a broken gemini-cli chat file out of the way so future click-to-
    /// resume attempts don't keep failing on the same parse error. The
    /// matching file (selected the same way as `backupAgentChatIfPresent`)
    /// is renamed to `.corrupt-<epoch>` alongside the `.bak` snapshot. After
    /// this, `SessionLoadability.canLoadFromDisk` returns false for the row,
    /// so the loadability gate in `AppShell.loadSession` routes the next
    /// click to the Replay sheet instead of another fruitless `session/load`.
    /// Returns the quarantined path on success.
    ///
    /// Called only after a `session/load` rpcError with a `.bak` already
    /// produced — never on a healthy file.
    private static func quarantineCorruptGeminiChat(sessionId: String, cwd: String) -> String? {
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }
        let needle = String(sessionId.prefix(8))
        let candidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl"))
        }
        let resolved = candidates.max(by: { a, b in
            let aSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(a)")[.size] as? Int) ?? 0
            let bSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(b)")[.size] as? Int) ?? 0
            return aSize < bSize
        })
        guard let match = resolved else { return nil }
        let src = "\(chatsDir)/\(match)"
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = "\(src).corrupt-\(stamp)"
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// When ACP resume isn't possible, hydrate the canvas from the harness's own
    /// transcript file so the user at least sees the conversation they clicked on.
    /// New turns will go through session/new — no replay into the agent.
    private func renderHistoryIfAvailable(sid: String) {
        guard provider == .claude,
              let history = ClaudeTranscriptReader.transcript(forSession: sid, cwd: project.path),
              !history.isEmpty
        else { return }

        // SOUL-SOUL_DESKTOP-097: bulk-update; see commit 88aead0.
        historicalIDs.formUnion(history.lazy.map(\.id))
        items.append(contentsOf: history)
        items.append(.status(id: UUID(), text: "─ history above (read-only) ─"))
    }

    /// Last finalize timestamp the live-injection helper has surfaced
    /// during THIS controller's lifetime. Prevents re-injecting the same
    /// finalize card after every subsequent turn — we only push a new
    /// card when a fresh finalize JSON (newer timestamp) appears on disk.
    private var lastFinalizeInjectedAt: Date? = nil

    /// Live-canvas variant: after a turn completes, peek at the registry's
    /// finalize JSON for this session and append a FinalizeCard IFF a
    /// newer finalize was recorded than the last one we injected. Works
    /// for any provider — the finalize JSON is written by the kernel's
    /// `/finalize` flow (whatever agent ran it), and Soul-Desktop just
    /// reads it and renders the Quad as a structured card. Without this,
    /// the user would only ever see the card on session reopen (via
    /// `hydrateFromDisk`); same session where /finalize ran would never
    /// surface the structured summary.
    private func injectFinalizeSummaryIfFresh(sessionId sid: String) {
        // SOUL-SOUL_DESKTOP-100: trace each branch.
        let provLabel = "\(provider.rawValue):\(String(sid.prefix(8)))"
        guard let rec = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) else {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.miss", "\(provLabel)")
            return
        }
        let hasContent = (rec.intent?.isEmpty == false)
            || (rec.summary?.isEmpty == false)
            || (rec.rationale?.isEmpty == false)
            || (rec.fixed?.isEmpty == false)
            || (rec.nextStep?.isEmpty == false)
        guard hasContent else {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.empty", "\(provLabel)")
            return
        }
        // Dedup: only inject if this is a NEWER finalize than what we
        // already rendered. First inject after spawn / hydrate always
        // counts (lastFinalizeInjectedAt nil → unconditional first push).
        if let ts = rec.timestamp,
           let prev = lastFinalizeInjectedAt,
           ts <= prev {
            SoulSignposts.event("injectFinalizeSummaryIfFresh.stale", "\(provLabel)")
            return
        }
        lastFinalizeInjectedAt = rec.timestamp ?? Date()
        items.append(.finalize(
            id: UUID(),
            intent: rec.intent,
            summary: rec.summary,
            rationale: rec.rationale,
            fixed: rec.fixed,
            nextStep: rec.nextStep,
            timestamp: rec.timestamp ?? Date()
        ))
        SoulSignposts.event("injectFinalizeSummaryIfFresh.appended", "\(provLabel)")
    }

    /// Append a `.finalize` card to the canvas if a finalize JSON exists for
    /// `sid` in this project's registry. No-op when no finalize has been
    /// recorded. Marked historical so it gets the muted/read-only styling
    /// alongside the rest of the loaded transcript.
    private func injectFinalizeSummary(sessionId sid: String) {
        // SOUL-SOUL_DESKTOP-100: trace each branch.
        let provLabel = "\(provider.rawValue):\(String(sid.prefix(8)))"
        guard let rec = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) else {
            SoulSignposts.event("injectFinalizeSummary.miss", "\(provLabel)")
            return
        }
        let hasContent = (rec.intent?.isEmpty == false)
            || (rec.summary?.isEmpty == false)
            || (rec.rationale?.isEmpty == false)
            || (rec.fixed?.isEmpty == false)
            || (rec.nextStep?.isEmpty == false)
        guard hasContent else {
            SoulSignposts.event("injectFinalizeSummary.empty", "\(provLabel)")
            return
        }
        let id = UUID()
        historicalIDs.insert(id)
        items.append(.finalize(
            id: id,
            intent: rec.intent,
            summary: rec.summary,
            rationale: rec.rationale,
            fixed: rec.fixed,
            nextStep: rec.nextStep,
            timestamp: rec.timestamp ?? Date()
        ))
        // Remember this finalize so the post-turn live-injection helper
        // doesn't push a duplicate card after the next turn completes.
        lastFinalizeInjectedAt = rec.timestamp ?? Date()
        SoulSignposts.event("injectFinalizeSummary.appended", "\(provLabel)")
    }

    /// SOUL-SOUL_DESKTOP-038: merge slash-command UserPrompt hooks back into
    /// the canvas after a Claude session/load. Terminal Claude Code expands
    /// `/decision` etc. client-side before the model API sees them, so the
    /// ACP transcript Claude streams back has no record of the literal
    /// invocation. The Soul harness captures them into hooks.jsonl; we
    /// re-inject so the chip rendering in UserMessageRow stays consistent
    /// across surfaces.
    private func injectSlashCommandPrompts(_ prompts: [(text: String, timestamp: Date)]) {
        guard !prompts.isEmpty else { return }

        for prompt in prompts {
            // Skip if an existing userMessage already carries the same
            // literal text near the same time — protects against double
            // injection on a retry or a re-load.
            let dedupWindow: TimeInterval = 2
            let alreadyPresent = items.contains { item in
                if case .userMessage(_, let text, let ts) = item,
                   text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.text,
                   abs(ts.timeIntervalSince(prompt.timestamp)) <= dedupWindow {
                    return true
                }
                return false
            }
            if alreadyPresent { continue }

            // Find the first user/agent message in items whose timestamp is
            // strictly after the hook's. Insert before it so narrative order
            // is preserved. If none later, append at the end of the
            // historical block (right before the load-complete status row).
            let id = UUID()
            let inserted: ThreadItem = .userMessage(id: id, text: prompt.text, timestamp: prompt.timestamp)
            historicalIDs.insert(id)

            var insertAt: Int? = nil
            for (i, item) in items.enumerated() {
                let ts: Date? = {
                    if case .userMessage(_, _, let t) = item { return t }
                    if case .agentMessage(_, _, _, let t) = item { return t }
                    return nil
                }()
                if let ts, ts > prompt.timestamp {
                    insertAt = i
                    break
                }
            }
            if let i = insertAt {
                items.insert(inserted, at: i)
            } else {
                items.append(inserted)
            }
        }
    }

    func teardown() async {
        logLifecycle("teardown", note: "controller torn down (e.g. row deselected)")
        finalizeWatcher?.stop()
        finalizeWatcher = nil
        eventTask?.cancel()
        await client?.stop()
        client = nil
        await codexClient?.stop()
        codexClient = nil
        if let cont = codexTurnContinuation {
            codexTurnContinuation = nil
            cont.resume(throwing: NSError(domain: "Codex", code: 99,
                                          userInfo: [NSLocalizedDescriptionKey: "thread torn down"]))
        }
    }

    // MARK: - private

    private func ensureSession() async throws {
        logLifecycle("ensureSession enter",
                     note: "hasInitialized=\(hasInitialized) client=\(client != nil) codexClient=\(codexClient != nil) sessionId=\(sessionId ?? "nil") nativeSessionId=\(nativeSessionId ?? "nil") pendingResumeOnFirstSend=\(pendingResumeOnFirstSend)")
        if provider == .codex {
            if hasInitialized, codexClient != nil, sessionId != nil { return }
            try await spawnAndInitializeCodex()
            return
        }
        if hasInitialized, client != nil, sessionId != nil { return }

        // A manual stop / stall recovery tears down the child process to
        // resolve the in-flight prompt continuation. Keep the logical kernel
        // session, then resume the provider-native session on the next send
        // instead of minting a new kernel row.
        if let sid = sessionId, nativeSessionId != nil {
            try await spawnAndInitialize(skipNewSession: true)
            guard let client else { return }
            let resumeId = nativeSessionId ?? sid
            suppressLoadReplay = true
            isReplayingLoad = true
            defer {
                suppressLoadReplay = false
                isReplayingLoad = false
            }
            try await client.loadSession(sessionId: resumeId, cwd: project.path)
            nativeSessionId = resumeId
            hasInitialized = true
            return
        }

        // SOUL-SOUL_DESKTOP-043: hydrated from disk, no agent yet. Spawn now,
        // ask the agent to load this session, and suppress its replay stream
        // so the disk-rendered items don't get duplicated. The user is
        // already in the "send" path — they expect a beat — so the spawn
        // cost pays for itself by making the *open* instant.
        if pendingResumeOnFirstSend, let sid = sessionId {
            pendingResumeOnFirstSend = false
            try await spawnAndInitialize(skipNewSession: true)
            guard let client else { return }
            let resumeId = nativeSessionId ?? sid
            // Backup mirror — gemini-cli's session/new fallback can rewrite
            // the agent's chat file. Claude doesn't, but the backup is cheap
            // and makes the failure mode survivable across providers.
            _ = Self.backupAgentChatIfPresent(
                provider: provider,
                sessionId: resumeId,
                cwd: project.path
            )
            suppressLoadReplay = true
            isReplayingLoad = true
            defer {
                suppressLoadReplay = false
                isReplayingLoad = false
            }
            try await client.loadSession(sessionId: resumeId, cwd: project.path)
            nativeSessionId = resumeId
            hasInitialized = true
            return
        }

        logLifecycle("ensureSession.newSession",
                     note: "no live client, no native id — minting fresh session via client.newSession")
        try await spawnAndInitialize(skipNewSession: false)
        guard let client else { return }
        let sid = try await client.newSession(cwd: project.path)
        // Fresh session: kernel and native ids coincide. The explicit
        // NativeSessionID hook below records the mapping so a later
        // findNativeSessionID never has to fall back to the bare sid.
        sessionId = sid
        nativeSessionId = sid
        hasInitialized = true

        // SOUL-FINALIZE-PARITY-001: write the freshly-minted sid to
        // /tmp/soul_last_session_id so a `soul finalize` call from the spawned
        // agent (which didn't have SOUL_SESSION_ID at spawn time) hits the
        // kernel's existing fallback path (soul_finalize.sh line ~104) and
        // tags its JSON with the desktop's sid. Best-effort write — the
        // worst case is the script falls back to mint_session_uuid() and the
        // FinalizeCard fails to match, which is the pre-fix status quo.
        try? sid.write(toFile: "/tmp/soul_last_session_id", atomically: true, encoding: .utf8)

        // Persist the provider's native sessionId alongside the kernel ledger
        // for this session. Identity-mapping for Soul-Desktop spawns (kernel
        // dir == gemini's sessionId), but keeping the explicit record means
        // findNativeSessionID always answers without falling back to `sid`.
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "NativeSessionID",
            "provider": provider.rawValue,
            "nativeId": sid,
            "cwd": project.path,
        ])
    }

    private func spawnAndInitialize(skipNewSession: Bool, resumeSessionId: String? = nil) async throws {
        if provider == .codex {
            try await spawnAndInitializeCodex()
            return
        }
        if client != nil { return }

        guard var spawn = ACPProviderSpawn.resolve(provider, resumeSessionId: resumeSessionId) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no spawn config for \(provider.label)"])
        }

        // Spawn-time bookkeeping (hydration log, initialize handshake,
        // session/new ack) used to write status rows here. They were chatty
        // and told the user nothing actionable when the path was healthy;
        // failures surface as thrown errors or the agent-stderr popover.
        // Keep the work, drop the rows.
        let hydration = await SoulHydration.prepare(
            provider: provider,
            projectKey: project.id,
            projectPath: project.path,
            sessionId: id
        )

        var env = spawn.environment ?? [:]
        for (k, v) in hydration.env { env[k] = v }
        // SOUL_PROJECT contract: declare the desktop-selected project key
        // explicitly so kernel hooks (middleware_runner, soul_trace_commit,
        // pi soul-orchestrator) don't re-derive a different key from cwd
        // and split the ledger across two ~/soul_registry/sessions/<key>/
        // buckets for the same session UUID. See SOUL-PROJECT-KEY-CONTRACT-001.
        env["SOUL_PROJECT"] = project.id
        // SOUL-FINALIZE-PARITY-001: forward the desktop-resolved kernel sid so
        // `soul finalize` (and any other kernel CLI the agent shells out to)
        // writes under the same sid the desktop holds. Without this, the
        // agent's env has GEMINI_SESSION_ID / SOUL_THREAD_ID unset and
        // mint_session_uuid() returns a fresh uuid that latestFinalize()
        // never matches → FinalizeCard never renders.
        //
        // For resumed sessions `sessionId` is set by assignSessionId() before
        // spawn. For fresh sessions the kernel sid is whatever the ACP agent
        // mints in newSession(), which happens after spawn — so we can't pre-
        // populate. The composer-side /finalize expansion picks up the sid
        // at type-time as the fallback for that case.
        if let sid = sessionId {
            env["SOUL_SESSION_ID"] = sid
        }
        spawn.environment = env
        spawn.cwd = project.path

        let client = try ACPClient(spawn: spawn)
        self.client = client
        await client.setAutoAllow(true)
        await client.setPermissionMode(permissionMode)
        try await client.start()

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }

        let initResp = try await client.initialize()
        supportsLoadSession = initResp.agentCapabilities?.loadSession ?? false
    }

    /// Phase 2 codex spawn: parallel to the ACP path, but talks codex
    /// app-server's JSON-RPC dialect. Creates a `CodexClient`, runs the
    /// initialize/initialized handshake, calls `thread/start` to mint a
    /// codex-side thread id, sets up the event-drain task that translates
    /// codex notifications into ThreadItem rows. AGENTS.md harness +
    /// session resume are out of scope for Phase 2.
    /// Silent ACP round-trip: send `text` over the same session, capture the
    /// agent's reply chunks into a buffer instead of rendering them, return
    /// the accumulated string once the prompt resolves. Streaming routing is
    /// gated by `silentCapture` over in `apply(_:)`.
    private func sendSilent(_ text: String) async -> String? {
        guard let client, let sid = sessionId else { return nil }
        let nid = nativeSessionId ?? sid
        silentCapture = ""
        defer { silentCapture = nil }
        do {
            _ = try await client.prompt(sessionId: nid, text: text)
        } catch {
            print("[silent-prompt] failed: \(error)")
            return nil
        }
        let captured = silentCapture?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured, !captured.isEmpty else { return nil }
        return captured
    }

    private func generateTitle() async {
        guard let sid = sessionId else { return }

        // Snapshot the first user + first agent turn from items. Reading
        // @MainActor state from inside an actor-isolated method is free; the
        // detached subprocess work below uses only the captured strings.
        var firstUser: String?
        var firstAgent: String?
        for item in items {
            switch item {
            case .userMessage(_, let text, _) where firstUser == nil:
                firstUser = text
            case .agentMessage(_, let text, _, _) where firstAgent == nil:
                firstAgent = text
            default: break
            }
            if firstUser != nil && firstAgent != nil { break }
        }
        guard let user = firstUser, !user.isEmpty else { return }

        let raw: String?
        if let claude = which("claude") {
            raw = await Self.runClaudePrint(executable: claude, user: user, agent: firstAgent)
        } else {
            // Fallback: no `claude` on PATH. Use the active ACP session so the
            // feature still works, at the cost of polluting context with one
            // meta-turn. Same prompt shape as the subprocess path.
            raw = await sendSilent(
                "Summarize our conversation so far into a concise 3-5 word title. Respond with ONLY the title, no quotes, no prefix, no trailing punctuation."
            )
        }

        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        // Strip the quotes / trailing punctuation the agent sometimes adds
        // despite the instruction. Cap length so the sidebar row doesn't
        // truncate mid-word.
        let strip = CharacterSet(charactersIn: "\"'`.")
        title = title.trimmingCharacters(in: strip)
        if title.count > 60 { title = String(title.prefix(60)) }
        await MainActor.run { self.customTitle = title }
        // Persist so the disk-driven sidebar surfaces it on the next scan,
        // and so finalize/replay anchor on the same title the canvas shows.
        // `source: "llm"` so a future user-rename path can win on precedence.
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "Title",
            "text": title,
            "source": "llm",
        ])
    }

    /// Run `claude -p` with a title-generation prompt that embeds the first
    /// user turn (and, when present, the first agent reply) as context.
    /// Returns trimmed stdout on success, nil on spawn/exit failure.
    private static func runClaudePrint(executable: String, user: String, agent: String?) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            var prompt = "Produce a concise 3-5 word title for the following chat. Respond with ONLY the title — no quotes, no prefix, no trailing punctuation.\n\nUser: \(user)"
            if let agent, !agent.isEmpty {
                prompt += "\n\nAssistant: \(agent)"
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-p", prompt]
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                return nil
            }
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    private func handle(_ event: ACPClient.Event) {
        // Don't bump activity during the agent's replay-transcript stream.
        // session/load streams every historical user/agent chunk back to us;
        // counting those as "activity" makes the sidebar row jump to the top
        // with an "in 0 sec." timestamp even though the user only clicked to
        // open. Real user activity (send, fresh assistant turn) bumps via
        // send() and the post-replay handler.
        if !isReplayingLoad {
            lastActivityAt = Date()
        }
        // Activity arrived — clear the stall flag so the next stall episode
        // gets its own StallDetected hook instead of being silently suppressed
        // by the prior turn's debounce.
        stallHookEmittedAt = nil
        switch event {
        case .sessionUpdate(let note):
            apply(note.update)
        case .stderr(let line):
            appendAgentLog(line)
        case .request(let id, let method, let params):
            Task { [weak self] in
                await self?.handleACPRequest(id: id, method: method, params: params)
            }
        case .unknownNotification(let method, let params):
            // Diagnostic: any JSON-RPC notification whose method we don't
            // recognize. pi-acp may stream progress via custom methods that
            // bypass session/update entirely. Log so we can see them in the
            // agent log instead of silently dropping.
            let preview = params.map { String(describing: $0).prefix(240) } ?? "<nil>"
            appendAgentLog("[unknown notif] method=\(method) params=\(preview)")
        case .terminated(let cause):
            // Child agent went away. Surface a status row so the user
            // notices instead of staring at a working spinner that will
            // never resolve. Pending continuations are already drained by
            // ACPClient; the rpcError / writeFailed / childTerminated
            // throws land in whichever send path was awaiting.
            appendAgentLog("[child terminated] \(cause)")
            if isWorking {
                isWorking = false
            }
            items.append(.status(id: UUID(), text: "■ agent process ended: \(cause)"))
        }
    }

    /// SOUL-SOUL_DESKTOP-063 diagnostic: every mutation of the live session
    /// triad (client / hasInitialized / nativeSessionId / sessionId) writes a
    /// line to both the in-memory agent log and ~/Library/Logs/Soul-Desktop/
    /// acp-protocol.jsonl (method="lifecycle") so post-mortems can correlate
    /// teardown order against the ACP wire trace.
    private func logLifecycle(_ event: String, note: String = "") {
        let line = "[lifecycle] \(event) provider=\(provider.rawValue)" + (note.isEmpty ? "" : " — \(note)")
        appendAgentLog(line)
        ACPProtocolLog.record(
            direction: "internal",
            method: "lifecycle",
            params: .object([
                "event": .string(event),
                "provider": .string(provider.rawValue),
                "sessionId": sessionId.map(JSONValue.string) ?? .null,
                "nativeSessionId": nativeSessionId.map(JSONValue.string) ?? .null,
                "hasInitialized": .bool(hasInitialized),
                "isWorking": .bool(isWorking),
                "note": .string(note),
            ])
        )
    }

    /// Format a thrown error into something a user can read, instead of the
    /// Swift-debug enum dump (`rpcError(JSONRPCError(code: -32603, …,
    /// data: Optional(JSONValue.object(["details": JSONValue.string(…)]))))`)
    /// that the default `"\(error)"` produces. Surfaces the upstream RPC
    /// message + the `details` string if the server attached one.
    static func humanReadable(_ error: Error) -> String {
        if let acp = error as? ACPClientError {
            switch acp {
            case .notInitialized:
                return "agent not initialized"
            case .spawnFailed(let s):
                return "spawn failed: \(s)"
            case .decodeFailed(let s):
                return "decode failed: \(s)"
            case .childTerminated(let cause):
                return "agent process ended: \(cause)"
            case .writeFailed(let s):
                return "write to agent failed: \(s)"
            case .rpcError(let rpc):
                var out = rpc.message
                let detail = extractDetailString(from: rpc.data)
                if !detail.isEmpty { out += " — \(detail)" }
                return out
            }
        }
        return error.localizedDescription
    }

    /// Pull a single user-readable string out of an RPC `data` payload.
    /// Servers commonly stash a `details` (or `detail` / `reason` / `message`)
    /// string alongside the generic JSON-RPC message. Returns empty when the
    /// payload doesn't carry one — caller appends nothing in that case.
    private static func extractDetailString(from value: JSONValue?) -> String {
        guard let value else { return "" }
        for key in ["details", "detail", "reason", "message", "error"] {
            if let s = value[key]?.stringValue, !s.isEmpty {
                return s
            }
        }
        if case .string(let s) = value { return s }
        return ""
    }

    func appendAgentLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agentLog.append(trimmed)
        // Cap at 400 lines so a hot-streaming agent can't balloon memory.
        if agentLog.count > 400 {
            agentLog.removeFirst(agentLog.count - 400)
        }
        publishAgentLogCountIfNeeded()
    }

    func refreshAgentLogCount() {
        agentLogCount = agentLog.count
    }

    private func publishAgentLogCountIfNeeded() {
        let now = Date()
        guard agentLogCount == 0 || now.timeIntervalSince(lastAgentLogCountPublishAt) >= 1.0 else { return }
        agentLogCount = agentLog.count
        lastAgentLogCountPublishAt = now
    }

    func appendTraceLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        traceLog.append(trimmed)
        if traceLog.count > 800 {
            traceLog.removeFirst(traceLog.count - 800)
        }
    }

    /// Short stable name for the trace log — picks the `sessionUpdate` kind
    /// off `SessionUpdate` without dumping the payload.
    static func kindLabel(_ u: SessionUpdate) -> String {
        switch u {
        case .agentMessageChunk:       return "agent_message_chunk"
        case .agentThoughtChunk:       return "agent_thought_chunk"
        case .userMessageChunk:        return "user_message_chunk"
        case .toolCall:                return "tool_call"
        case .toolCallUpdate:          return "tool_call_update"
        case .plan:                    return "plan"
        case .availableCommandsUpdate: return "available_commands_update"
        case .currentModeUpdate:       return "current_mode_update"
        case .unknown(let kind, _):    return "unknown(\(kind))"
        }
    }

    /// Tiny size hint — number of chars in the chunk's text payload for
    /// message/thought chunks; empty string for non-text updates so the
    /// trace line stays one column wide.
    static func sizeHint(_ u: SessionUpdate) -> String {
        switch u {
        case .agentMessageChunk(let b), .agentThoughtChunk(let b), .userMessageChunk(let b):
            if case .text(let s) = b { return "(\(s.count)c)" }
            return ""
        default:
            return ""
        }
    }

}

/// Shared classifier for Claude Code's `<local-command-*>` scaffolding. Used
/// by both the live ACP stream (`ThreadController.apply(_:.userMessageChunk)`)
/// and the read-first hydrate path (`ClaudeTranscriptReader`) so the two
/// surfaces never disagree on whether a caveat block should render as a user
/// bubble or as a compact status row.
enum LocalCommandClassifier {
    enum Shape {
        case skip                  // caveat-only / pure scaffolding → drop
        case status(String)        // command stdout/stderr → small status line
        case message(String)       // real user text (possibly with caveat stripped)
    }

    static func classify(_ raw: String) -> Shape {
        var stripped = raw.replacingOccurrences(
            of: "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if let regex = try? NSRegularExpression(pattern: "<task-notification>([\\s\\S]*?)</task-notification>") {
            let ns = stripped as NSString
            let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                guard m.numberOfRanges >= 2 else { continue }
                let inner = ns.substring(with: m.range(at: 1))
                let summaryRegex = try? NSRegularExpression(pattern: "<summary>([\\s\\S]*?)</summary>")
                let innerNS = inner as NSString
                let smatch = summaryRegex?.firstMatch(in: inner, range: NSRange(location: 0, length: innerNS.length))
                let summary = smatch.flatMap { sm -> String? in
                    guard sm.numberOfRanges >= 2 else { return nil }
                    return innerNS.substring(with: sm.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
                let replacement = summary.isEmpty ? "" : "[task] \(summary)"
                stripped = (stripped as NSString).replacingCharacters(in: m.range, with: replacement)
            }
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let streamPattern = "<local-command-(stdout|stderr)>([\\s\\S]*?)</local-command-\\1>"
        if let regex = try? NSRegularExpression(pattern: streamPattern) {
            let ns = stripped as NSString
            let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let parts = matches.compactMap { m -> String? in
                    guard m.numberOfRanges >= 3 else { return nil }
                    return ns.substring(with: m.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return joined.isEmpty ? .skip : .status(joined)
            }
        }

        if stripped.isEmpty { return .skip }
        if stripped.split(separator: "\n").allSatisfy({ $0.hasPrefix("[task] ") }) {
            return .status(stripped)
        }
        return .message(stripped)
    }
}
