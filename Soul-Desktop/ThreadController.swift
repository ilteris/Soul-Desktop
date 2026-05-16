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

    /// SOUL-SOUL_DESKTOP-063 diagnostic: cumulative time spent inside `apply(_:)`
    /// bucketed by sessionUpdate kind. Off the observation graph so the
    /// accounting itself can't invalidate any view. Flushed to
    /// ~/Library/Logs/Soul-Desktop/acp-protocol.jsonl as method="apply_timing"
    /// every `applyTimingFlushEveryNUpdates` updates.
    @ObservationIgnored private var applyTimingNs: [String: UInt64] = [:]
    @ObservationIgnored private var applyTimingCount: [String: Int] = [:]
    @ObservationIgnored private var applyTimingSlowestNs: [String: UInt64] = [:]
    @ObservationIgnored private var applyTimingUpdatesSinceFlush: Int = 0
    private let applyTimingFlushEveryNUpdates = 100
    /// Last time we received any event from the agent. Used to compute
    /// "quiet for Ns" once `isWorking` is true and nothing's streaming.
    var lastActivityAt: Date = Date()

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
                if case .agentThought = item {
                    // Thoughts don't break the tool-grouping context.
                } else {
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
    private var isReplayingLoad: Bool = false

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
    private var suppressLoadReplay: Bool = false

    /// When non-nil, the next agent reply stream is captured into this buffer
    /// instead of being rendered in the canvas. Used for out-of-band prompts
    /// like title generation — same ACP session, same agent, no second model
    /// spawn, but the user never sees the round-trip. Tool calls during a
    /// silent prompt are also suppressed; title prompts shouldn't need tools,
    /// and if the agent calls one anyway, surfacing it would be more confusing
    /// than helpful.
    private var silentCapture: String? = nil

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

    private var client: ACPClient?
    /// Codex app-server client. Spawned alongside `client` when provider ==
    /// .codex; the two clients never coexist on the same thread. Codex
    /// speaks its own JSON-RPC dialect (thread/start, turn/start, item/* and
    /// turn/* notifications) so its event loop and turn semantics live on a
    /// parallel path from ACPClient's session/prompt flow.
    private var codexClient: CodexClient?
    /// Set while a codex turn is in flight. The codex event loop resumes
    /// this continuation when it observes `turn/completed`, letting `send`
    /// stay awaitable on a single turn boundary.
    private var codexTurnContinuation: CheckedContinuation<Void, Error>?
    /// Maps codex-side `item.id` strings to the ThreadItem UUID we minted
    /// for that item. Lets `item/agentMessage/delta` + `item/completed`
    /// notifications find the right canvas row to update.
    private var codexItemMap: [String: UUID] = [:]
    /// Active codex turn id, captured at `turn/start` and used to filter
    /// `turn/completed` notifications belonging to this turn.
    private var codexActiveTurnId: String?
    /// Latest token count reported by codex's `thread/tokenUsage/updated`
    /// notification (`last.totalTokens` from the payload). nil until the
    /// first usage event lands.
    var codexTokensUsed: Int?
    /// Model context-window budget reported by the same notification
    /// (`modelContextWindow`). Drives the toolbar chip's denominator.
    var codexContextWindow: Int?
    /// Kernel/registry session id. This is the UUID Soul writes hooks under
    /// (~/soul_registry/sessions/<project>/<sessionId>/hooks.jsonl) and the
    /// id AppShell / SidebarView use to identify the chat row. Stable for
    /// the entire thread lifetime — never overwritten by a successful
    /// session/load, even when the agent's native UUID differs.
    fileprivate(set) var sessionId: String?

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
    /// Agent-native session id used for ACP calls (session/prompt,
    /// session/cancel, session/load). For Soul-Desktop spawns this equals
    /// `sessionId` (identity mapping written at session/new). For divergent
    /// legacy sessions resumed via backfill, this is the agent's UUID while
    /// `sessionId` stays the kernel id. nil until the first ACP id is known.
    private(set) var nativeSessionId: String?
    /// Convenience: native id when known, else the kernel id. Use this at
    /// every ACPClient call site so we never accidentally ask the agent to
    /// resume a UUID it didn't mint.
    private var acpSessionId: String? { nativeSessionId ?? sessionId }
    private var hasInitialized = false
    private var supportsLoadSession = false
    private var openAgentMessageId: UUID?
    private var seenToolCallIds: [String: UUID] = [:]
    private var eventTask: Task<Void, Never>?

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
    private var toolCallStartedAt: [String: Date] = [:]
    /// SOUL-SOUL_DESKTOP-079: activity-based timeout map. See commit 951d65d.
    private var toolCallLastActivityAt: [String: Date] = [:]
    /// IDs we've already fired a timeout for so the watchdog doesn't keep
    /// hammering cancel + writing duplicate hooks every tick after expiry.
    private var toolCallTimedOut: Set<String> = []
    /// For Write tool calls: line count of the target file the first time
    /// we saw the toolCallId, captured before the agent's actual disk write
    /// lands. Lets the diff chip show `+N -M` for Writes against existing
    /// files. Keyed by toolCallId. Sentinel `0` means "file did not exist."
    private var toolCallPreviousLineCount: [String: Int] = [:]
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
        let now = Date()
        var expired: [String] = []
        // SOUL-SOUL_DESKTOP-079: drive expiry off lastActivityAt, not startedAt.
        for (toolId, lastSeen) in toolCallLastActivityAt where !toolCallTimedOut.contains(toolId) {
            if Int(now.timeIntervalSince(lastSeen)) >= toolTimeout {
                expired.append(toolId)
            }
        }
        for toolId in expired {
            await fireToolCallTimeout(toolId: toolId, threshold: toolTimeout)
        }
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
    private func spawnAndInitializeCodex() async throws {
        if codexClient != nil { return }
        guard let spawn = ACPProviderSpawn.resolve(.codex) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex binary not found on PATH"])
        }
        var enriched = spawn
        var codexEnv = enriched.environment ?? [:]
        // SOUL_PROJECT contract — see ACP spawn path above. Same rationale
        // for codex: kernel hooks should write to the desktop-selected
        // project bucket, not a cwd-derived one.
        codexEnv["SOUL_PROJECT"] = project.id
        // SOUL-FINALIZE-PARITY-001: same SOUL_SESSION_ID export as the ACP
        // path so `soul finalize` from a codex bash tool call writes a JSON
        // tagged with the desktop's session id. Codex resume isn't wired yet,
        // so `sessionId` is nil at spawn — the env stays out and the composer
        // expansion below carries the sid at /finalize time.
        if let sid = sessionId {
            codexEnv["SOUL_SESSION_ID"] = sid
        }
        enriched.environment = codexEnv
        enriched.cwd = project.path

        let client = try CodexClient(spawn: enriched)
        self.codexClient = client
        try await client.start()

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handleCodex(event)
            }
        }

        _ = try await client.initializeAndAck()

        let threadId = try await client.threadStart(cwd: project.path)
        // Preserve the kernel sessionId when this thread was hydrated from
        // disk (sessionId already set to the original kernel UUID by
        // `hydrateFromDisk`). Without this guard, the freshly-minted codex
        // threadId would clobber the kernel UUID and every subsequent
        // appendHook would write to a new directory, orphaning the
        // ledger the user just opened.
        if sessionId == nil {
            sessionId = threadId
        }
        nativeSessionId = threadId
        hasInitialized = true

        // Record a NativeSessionID hook so future reopens can identify this
        // session as codex via `SoulRegistry.findProvider`. Without it
        // codex sessions have no provider marker in the kernel ledger and
        // AppShell falls back to the active harness on click, mis-routing
        // codex rows when the harness is gemini/claude.
        if let sid = sessionId {
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "NativeSessionID",
                "provider": Provider.codex.rawValue,
                "nativeId": threadId,
                "cwd": project.path,
            ])
        }
    }

    /// Drive a single codex turn: send `text` via turn/start, then await
    /// the turn/completed notification (resumed by `handleCodex`). The
    /// streaming agent/tool events update `items` as they arrive.
    private func sendCodex(text: String) async throws {
        // Use `nativeSessionId` (the codex-minted thread id) for the actual
        // RPC. `sessionId` is the kernel UUID and is preserved as the hooks
        // directory key — see `spawnAndInitializeCodex`. Sending the kernel
        // UUID to codex produces "thread not found" because codex never
        // started a thread with that id.
        guard let client = codexClient, let tid = nativeSessionId ?? sessionId else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        codexItemMap.removeAll(keepingCapacity: true)
        let turnId = try await client.turnStart(threadId: tid, text: text)
        codexActiveTurnId = turnId
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            codexTurnContinuation = cont
        }
        codexActiveTurnId = nil
    }

    /// Translates codex notifications (item/started, item/agentMessage/delta,
    /// item/completed, turn/completed, etc.) into ThreadItem mutations. Kept
    /// intentionally narrow: handles agent text and turn lifecycle today;
    /// tool-call rendering is a follow-up.
    private func handleCodex(_ event: CodexClient.Event) {
        switch event {
        case .request(let id, let method, let params):
            CodexProtocolLog.record(method: method, params: params)
            lastActivityAt = Date()
            Task { [weak self] in
                await self?.handleCodexRequest(id: id, method: method, params: params)
            }
        case .notification(let method, let params):
            // Append-only protocol log so we can see EXACTLY what codex
            // sends on the wire. When extractors fail (empty Thought, bare
            // execute row), tail
            // `~/Library/Logs/Soul-Desktop/codex-protocol.jsonl` and the
            // mismatched shape is right there. No guessing.
            CodexProtocolLog.record(method: method, params: params)
            // Any notification = the agent is alive and emitting. Bump the
            // stall watchdog's clock so it doesn't trip on tool-call /
            // reasoning streams that we don't render yet but still indicate
            // forward motion.
            lastActivityAt = Date()
            switch method {
            case "item/started":
                guard case .object(let p)? = params,
                      case .object(let item)? = p["item"],
                      case .string(let itemType)? = item["type"],
                      case .string(let codexId)? = item["id"]
                else { return }
                appendCodexItem(itemType: itemType, codexId: codexId, item: item, terminal: false)
            case "item/agentMessage/delta":
                guard case .object(let p)? = params,
                      case .string(let itemId)? = p["itemId"],
                      case .string(let delta)? = p["delta"],
                      let uuid = codexItemMap[itemId]
                else { return }
                if let idx = items.firstIndex(where: { $0.id == uuid }),
                   case .agentMessage(let id, let prior, _, let ts) = items[idx] {
                    items[idx] = .agentMessage(id: id, text: prior + delta, complete: false, timestamp: ts)
                }
                lastActivityAt = Date()
            case "item/completed":
                guard case .object(let p)? = params,
                      case .object(let item)? = p["item"],
                      case .string(let itemType)? = item["type"],
                      case .string(let codexId)? = item["id"]
                else { return }
                completeCodexItem(itemType: itemType, codexId: codexId, item: item)
            case "turn/completed":
                guard case .object(let p)? = params,
                      case .object(let turn)? = p["turn"]
                else { return }
                let turnIdMatches: Bool = {
                    if case .string(let tid)? = turn["id"], let active = codexActiveTurnId {
                        return tid == active
                    }
                    return true
                }()
                guard turnIdMatches else { return }
                if let cont = codexTurnContinuation {
                    codexTurnContinuation = nil
                    if case .string(let status)? = turn["status"], status == "failed",
                       case .object(let err)? = turn["error"],
                       case .string(let msg)? = err["message"] {
                        cont.resume(throwing: NSError(domain: "Codex", code: 1,
                                                      userInfo: [NSLocalizedDescriptionKey: msg]))
                    } else {
                        cont.resume(returning: ())
                    }
                }
            case "item/reasoning/textDelta",
                 "item/reasoning/summaryTextDelta",
                 "item/reasoning/summaryPartAdded":
                // Codex's reasoning stream. Append each delta into the open
                // agent-thought bubble so the user sees what the agent is
                // reasoning through. Without this the `item/started` event
                // creates an empty `Thinking…` card and the deltas vanish.
                guard case .object(let p)? = params,
                      case .string(let itemId)? = p["itemId"],
                      let uuid = codexItemMap[itemId]
                else { return }
                // Codex reasoning streams come in three shapes:
                //   - summaryTextDelta / textDelta:  {"delta": "<string>"}
                //   - summaryPartAdded:              {"summaryPart": {"text": "<string>"}}
                //   - any: pick first nested string we find
                let delta: String = {
                    if case .string(let s)? = p["delta"] { return s }
                    if case .string(let s)? = p["text"] { return s }
                    if case .object(let part)? = p["summaryPart"] {
                        if case .string(let s)? = part["text"] { return s }
                    }
                    if case .object(let item)? = p["item"] {
                        if case .string(let s)? = item["text"] { return s }
                        if case .string(let s)? = item["content"] { return s }
                    }
                    return ""
                }()
                guard !delta.isEmpty else { return }
                if let idx = items.firstIndex(where: { $0.id == uuid }),
                   case .agentThought(let id, let prior, _, let ts) = items[idx] {
                    items[idx] = .agentThought(id: id, text: prior + delta, complete: false, timestamp: ts)
                }
            case "item/commandExecution/outputDelta",
                 "item/fileChange/outputDelta",
                 "item/plan/delta":
                // Stream-level deltas for other item types — keep
                // `lastActivityAt` fresh (already done above) and rely on
                // `item/completed` to render the final state. Wiring
                // per-row live streaming for these is a follow-up.
                break
            case "thread/tokenUsage/updated":
                guard case .object(let p)? = params,
                      case .object(let usage)? = p["tokenUsage"]
                else { return }
                if case .object(let last)? = usage["last"],
                   case .int(let total)? = last["totalTokens"] {
                    codexTokensUsed = total
                }
                if case .int(let window)? = usage["modelContextWindow"] {
                    codexContextWindow = window
                }
            default:
                break  // ignore lifecycle / mcp / remoteControl chatter
            }
        case .stderr(let line):
            print("[codex stderr] \(line)")
        case .terminated(let cause):
            items.append(.error(id: UUID(), text: "codex child terminated: \(cause)"))
            if let cont = codexTurnContinuation {
                codexTurnContinuation = nil
                cont.resume(throwing: NSError(domain: "Codex", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: cause]))
            }
        }
    }

    
    private func handleACPRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        // By the time this reaches handleACPRequest, ACPClient has already
        // checked its own built-ins (fs/*, session/request_permission).
        // Anything here is an unknown provider request.
        // Respond with an error so the provider doesn'''t stall, and log it.
        await client?.respondError(id: id, code: -32601, message: "method not implemented: \(method)")

        let text = "■ ACP request ignored: \(method)"
        items.append(.status(id: UUID(), text: text))

        // Log to kernel hooks for -056 auditing
        if let sid = sessionId {
            var hook: [String: Any] = [
                "event": "ACPRequestIgnored",
                "method": method,
                "provider": provider.rawValue
            ]
            if let params {
                hook["params"] = compactJSONString(params)
            }
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: hook)
        }
    }
    private func handleCodexRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        guard method == "item/commandExecution/requestApproval" else {
            try? await codexClient?.respond(id: id, result: .null)
            appendCodexRequestHook(
                method: method,
                params: params,
                decision: .string("ignored"),
                handled: false
            )
            items.append(.status(id: UUID(), text: "■ Codex request ignored: \(method)"))
            return
        }

        let result = CodexApprovalPolicy.responseResult(params: params, permissionMode: permissionMode)
        let decision: JSONValue = {
            if case .object(let obj) = result, let value = obj["decision"] { return value }
            return .null
        }()
        if case .object(let obj) = result,
           case .string("decline")? = obj["decision"] {
            try? await codexClient?.respond(id: id, result: result)
            appendCodexRequestHook(
                method: method,
                params: params,
                decision: decision,
                handled: true
            )
            items.append(.status(id: UUID(), text: "■ Codex command approval cancelled"))
            return
        }

        try? await codexClient?.respond(id: id, result: result)
        appendCodexRequestHook(
            method: method,
            params: params,
            decision: decision,
            handled: true
        )
        items.append(.status(id: UUID(), text: "✓ Codex command approval handled"))
    }

    private func appendCodexRequestHook(
        method: String,
        params: JSONValue?,
        decision: JSONValue,
        handled: Bool
    ) {
        guard let sid = sessionId else { return }
        let command = codexRequestCommand(from: params)
        let decisionText = compactJSONString(decision)
        let intent: String = {
            if !handled { return "Codex request ignored: \(method)" }
            if decisionText.contains("decline") || decisionText.contains("cancel") {
                return command.isEmpty
                    ? "Codex command approval cancelled"
                    : "Codex command approval cancelled: \(command)"
            }
            return command.isEmpty
                ? "Codex command approval handled"
                : "Codex command approval handled: \(command)"
        }()
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "CodexApproval",
            "op": handled ? "APPROVAL" : "REQUEST",
            "intent": intent,
            "provider": Provider.codex.rawValue,
            "method": method,
            "decision": decisionText,
            "command": command,
            "permission_mode": permissionMode.rawValue,
        ])
    }

    /// Phase 3: translate a codex `item/started` payload into a ThreadItem.
    /// Each branch handles one codex item type, choosing the closest
    /// existing ThreadItem shape so the canvas reads consistently across
    /// providers. Codex emits richer item types than ACP, so a few of them
    /// fall through to a `status` row (a one-liner with an emoji prefix)
    /// rather than a full toolCall card.
    private func appendCodexItem(itemType: String, codexId: String, item: [String: JSONValue], terminal: Bool) {
        let uuid = UUID()
        codexItemMap[codexId] = uuid
        let now = Date()
        switch itemType {
        case "agentMessage":
            let text = stringField(item, "text") ?? ""
            items.append(.agentMessage(id: uuid, text: text, complete: terminal, timestamp: now))
            openAgentMessageId = uuid
        case "commandExecution":
            // Build the title from command + argv so the row shows the FULL
            // command line, not just the bare executable. Codex sometimes
            // sends `command: "soul"` + `argv: ["soul", "task", "list"]`;
            // showing just `command` truncated rows to "execute soul" which
            // is useless for understanding what the agent ran.
            let cmd = codexCommandTitle(from: item) ?? "(command)"
            let cwd = stringField(item, "cwd")
            let status = stringField(item, "status") ?? "pending"
            items.append(.toolCall(
                id: uuid,
                kind: "execute",
                title: cmd,
                status: status,
                locationHint: cwd,
                details: nil
            ))
        case "fileChange":
            let details = codexFileChangeDetails(from: item)
            let title = codexFileChangeTitle(from: item)
            let status = stringField(item, "status") ?? "pending"
            let kindLabel: String = {
                if case .write = details?.kind { return "write" }
                return "edit"
            }()
            items.append(.toolCall(
                id: uuid,
                kind: kindLabel,
                title: title,
                status: status,
                locationHint: nil,
                details: details
            ))
        case "mcpToolCall":
            let server = stringField(item, "server") ?? "mcp"
            let tool = stringField(item, "tool") ?? "?"
            let status = stringField(item, "status") ?? "pending"
            items.append(.toolCall(
                id: uuid,
                kind: "mcp:\(server)",
                title: tool,
                status: status,
                locationHint: nil,
                details: nil
            ))
        case "webSearch":
            let query = stringField(item, "query") ?? ""
            items.append(.toolCall(
                id: uuid,
                kind: "search",
                title: query.isEmpty ? "(web search)" : query,
                status: "in_progress",
                locationHint: nil,
                details: nil
            ))
        case "imageView":
            let path = stringField(item, "path") ?? "(image)"
            items.append(.toolCall(
                id: uuid,
                kind: "view-image",
                title: (path as NSString).lastPathComponent,
                status: "completed",
                locationHint: path,
                details: nil
            ))
        case "reasoning":
            // Render reasoning as a proper agentThought bubble (muted
            // italic + collapsible). Pre-fill from any text on the
            // started event — `text`/`summary`/`content` as strings, or
            // a `summary` array of summary-part objects (the canonical
            // codex shape). Deltas streamed via
            // `item/reasoning/textDelta` etc. append to this bubble.
            let initial: String = {
                if let s = stringField(item, "text"), !s.isEmpty { return s }
                if let s = stringField(item, "summary"), !s.isEmpty { return s }
                if let s = stringField(item, "content"), !s.isEmpty { return s }
                if case .array(let parts)? = item["summary"] {
                    return parts.compactMap { p -> String? in
                        guard case .object(let o) = p,
                              case .string(let t)? = o["text"] else { return nil }
                        return t
                    }.joined(separator: "\n\n")
                }
                return ""
            }()
            // Only materialize the bubble when there's actually text on the
            // started event. Otherwise leave bubble creation to the first
            // non-empty delta (appendAgentThoughtChunk lazy-creates and
            // registers under openAgentThoughtId). Codex frequently emits
            // reasoning items that stay encrypted server-side and never
            // ship visible text — creating a bubble preemptively just to
            // delete it (or worse, leave a "reasoning hidden" placeholder)
            // is the wrong default.
            if !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.agentThought(id: uuid, text: initial, complete: false, timestamp: now))
                openAgentThoughtId = uuid
            } else {
                // Drop the mapping so item/completed doesn't try to fill a
                // bubble that was never created.
                codexItemMap.removeValue(forKey: codexId)
            }
        case "plan":
            let entries = codexPlanEntries(from: item)
            if entries.isEmpty {
                let text = stringField(item, "text") ?? ""
                items.append(.status(id: uuid, text: "📋 plan: \(text.prefix(120))"))
            } else {
                items.append(.plan(id: uuid, entries: entries))
            }
        case "enteredReviewMode":
            let review = stringField(item, "review") ?? "review"
            items.append(.status(id: uuid, text: "🔍 entered review: \(review)"))
        case "exitedReviewMode":
            items.append(.status(id: uuid, text: "✓ exited review"))
        case "contextCompaction":
            items.append(.status(id: uuid, text: "⤵ context compacted"))
        default:
            // Unknown codex item types used to render as `· <itemType>`
            // status rows, leaking implementation names like `· userMessage`
            // into the canvas. Specifically skip `userMessage` (the user's
            // prompt is already rendered by `send()` — we don't need codex
            // echoing it back as a status), and silently swallow every other
            // unknown type. New first-class types can be added to the switch
            // when we want them visible.
            if itemType == "userMessage" { return }
            // Other unknowns: capture in the codexItemMap for completion
            // tracking but don't render. If we discover one matters we can
            // promote it to a real case.
            return
        }
        lastActivityAt = now
    }

    /// Build a readable command line from a codex `commandExecution` item.
    /// Codex sends this under various keys depending on protocol version;
    /// we try each known shape and fall back to the bare executable.
    ///
    /// Tail `~/Library/Logs/Soul-Desktop/codex-protocol.jsonl` to see what
    /// actually arrives in your session — if a new key shape appears,
    /// add it to this matrix.
    private func codexCommandTitle(from item: [String: JSONValue]) -> String? {
        // 1. A `command` string that already looks like a full line wins.
        if let cmd = stringField(item, "command")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cmd.isEmpty,
           cmd.contains(" ") {
            return cmd
        }
        // 2. Try every known array-of-args key. Codex has shipped at least
        //    `argv`, `args`, `arguments`, `commandArgs` in different builds.
        for key in ["argv", "args", "arguments", "commandArgs"] {
            if case .array(let arr)? = item[key] {
                let parts = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
        }
        // 3. A `command` array (some codex versions send the bare executable
        //    in `command` AND the args as siblings; others bundle both into
        //    `command` as an array).
        if case .array(let arr)? = item["command"] {
            let parts = arr.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        // 4. Some payloads expose the full pre-formatted line.
        for key in ["commandLine", "fullCommand", "aggregatedCommand", "displayCommand"] {
            if let s = stringField(item, key), !s.isEmpty { return s }
        }
        // 5. Bare `command` string (single executable). Last resort.
        return stringField(item, "command")
    }

    /// Finalize the row that `appendCodexItem` opened for `codexId`. Updates
    /// status (terminal completed/failed/etc.) and fills in any fields that
    /// were only known at end-of-call (e.g. agent message final text, file
    /// change diff, command output).
    private func completeCodexItem(itemType: String, codexId: String, item: [String: JSONValue]) {
        guard let uuid = codexItemMap[codexId],
              let idx = items.firstIndex(where: { $0.id == uuid })
        else { return }
        switch items[idx] {
        case .agentMessage(let id, let prior, _, let ts):
            let final = stringField(item, "text") ?? prior
            items[idx] = .agentMessage(id: id, text: final, complete: true, timestamp: ts)
        case .toolCall(let id, let kind, let title, _, let loc, let priorDetails):
            let status = stringField(item, "status") ?? "completed"
            // For fileChange items the final diff arrives at completion —
            // rebuild details from the finalized payload so the diff card
            // renders something useful.
            let details: ToolCallDetails?
            if itemType == "fileChange" {
                details = codexFileChangeDetails(from: item) ?? priorDetails
            } else {
                details = priorDetails
            }
            let finalTitle: String
            if itemType == "fileChange" {
                finalTitle = codexFileChangeTitle(from: item)
            } else if itemType == "commandExecution" {
                // Use the full argv-joined title at completion too. The
                // bare `command` field often contains just the executable
                // name (`soul`), which would clobber the started-event's
                // richer title (`soul task list`).
                finalTitle = codexCommandTitle(from: item) ?? title
            } else {
                finalTitle = title
            }
            items[idx] = .toolCall(
                id: id,
                kind: kind,
                title: finalTitle,
                status: status,
                locationHint: loc,
                details: details
            )
            appendCodexToolHook(
                itemType: itemType,
                item: item,
                kind: kind,
                title: finalTitle,
                status: status,
                locationHint: loc,
                details: details
            )
        case .plan(let id, _):
            let entries = codexPlanEntries(from: item)
            if !entries.isEmpty { items[idx] = .plan(id: id, entries: entries) }
        case .agentThought(let id, let prior, _, let ts):
            // Codex's reasoning completion comes in a few shapes — flat
            // `text`/`summary`/`content`, or a `summary` array of
            // summary-part objects (`{"text": "...", "type": "..."}`).
            // We try each. If the model didn't produce a human-readable
            // summary (codex sends `summary: []` and stashes the actual
            // chain in `encrypted_content` which we can't decode), the
            // final text stays empty — in which case REMOVE the bubble
            // entirely rather than leaving a hollow "Thought" card on
            // the canvas. This is the root cause of the empty cards: the
            // bubble was created at `item/started` time, then nothing
            // visible ever arrived to fill it.
            let final: String = {
                if let flat = stringField(item, "text"), !flat.isEmpty { return flat }
                if let flat = stringField(item, "summary"), !flat.isEmpty { return flat }
                if let flat = stringField(item, "content"), !flat.isEmpty { return flat }
                if case .array(let parts)? = item["summary"] {
                    let joined = parts.compactMap { part -> String? in
                        guard case .object(let o) = part,
                              case .string(let s)? = o["text"] else { return nil }
                        return s
                    }.joined(separator: "\n\n")
                    if !joined.isEmpty { return joined }
                }
                if case .array(let parts)? = item["content"] {
                    let joined = parts.compactMap { part -> String? in
                        guard case .object(let o) = part,
                              case .string(let s)? = o["text"] else { return nil }
                        return s
                    }.joined(separator: "\n\n")
                    if !joined.isEmpty { return joined }
                }
                return ""
            }()
            // NEVER remove the bubble on completion. If streaming put text
            // into `prior`, we keep it — even if the completion payload's
            // `summary` is an empty array (codex routinely sends `summary:
            // []` while stashing the real chain in `encrypted_content`).
            // The old "drop hollow bubble" path was nuking bubbles that had
            // already rendered text to the user — visible as a flicker.
            let chosen = final.count > prior.count ? final : prior
            let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = trimmed.isEmpty ? "_(reasoning hidden by codex)_" : chosen
            items[idx] = .agentThought(id: id, text: finalText, complete: true, timestamp: ts)
            openAgentThoughtId = nil
        default:
            break  // status / error rows finalize themselves on append
        }
    }

    private func appendCodexToolHook(
        itemType: String,
        item: [String: JSONValue],
        kind: String,
        title: String,
        status: String,
        locationHint: String?,
        details: ToolCallDetails?
    ) {
        guard let sid = sessionId else { return }
        let tool: String
        let target: String
        switch itemType {
        case "commandExecution":
            tool = "Bash"
            target = codexCommandTitle(from: item) ?? title
        case "fileChange":
            if case .write = details?.kind {
                tool = "Write"
            } else {
                tool = "Edit"
            }
            target = codexFileChangePath(from: item) ?? title
        case "mcpToolCall":
            tool = "MCP"
            let server = stringField(item, "server") ?? "mcp"
            let call = stringField(item, "tool") ?? title
            target = "\(server).\(call)"
        case "webSearch":
            tool = "WebSearch"
            target = stringField(item, "query") ?? title
        case "imageView":
            tool = "Read"
            target = stringField(item, "path") ?? locationHint ?? title
        default:
            tool = kind
            target = title
        }
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "AfterTool",
            "tool": tool,
            "target": target,
            "rationale": title,
            "provider": Provider.codex.rawValue,
            "codex_item_type": itemType,
            "status": status,
            "cwd": locationHint ?? project.path,
        ])
    }

    /// Pull `field` out of a codex item object when it's a string.
    private func stringField(_ obj: [String: JSONValue], _ field: String) -> String? {
        if case .string(let s)? = obj[field] { return s }
        return nil
    }

    /// Build a ToolCallDetails from codex's fileChange shape. Codex packs
    /// changes into `changes: [{path, kind, diff}]`; we render the first
    /// entry so the diff card has something concrete. `kind` is `"add"` /
    /// `"modify"` / `"delete"` — we collapse to write (add) or edit (modify).
    private func codexFileChangeDetails(from item: [String: JSONValue]) -> ToolCallDetails? {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first
        else { return nil }
        let kind = stringField(change, "kind") ?? "modify"
        let diff = stringField(change, "diff") ?? ""
        if kind == "add" {
            return ToolCallDetails(kind: .write(content: diff))
        }
        // For modify/delete we expose the raw diff in newString and leave
        // oldString empty — the side-by-side diff card still renders
        // something the user can scan; a richer hunk parser is a follow-up.
        return ToolCallDetails(kind: .edit(oldString: "", newString: diff))
    }

    /// Title for a fileChange row — first path's basename, falls back to a
    /// generic label if `changes` is empty.
    private func codexFileChangeTitle(from item: [String: JSONValue]) -> String {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first,
              let path = stringField(change, "path")
        else { return "(file change)" }
        return (path as NSString).lastPathComponent
    }

    private func codexFileChangePath(from item: [String: JSONValue]) -> String? {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first
        else { return nil }
        return stringField(change, "path")
    }

    private func codexRequestCommand(from params: JSONValue?) -> String {
        guard case .object(let obj)? = params else { return "" }
        if let command = codexCommandTitle(from: obj) { return command }
        if case .object(let item)? = obj["item"],
           let command = codexCommandTitle(from: item) {
            return command
        }
        return ""
    }

    private func compactJSONString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }

    /// Parse codex's plan into our PlanEntry shape. Codex plan items are
    /// proposed-action text; without a structured shape we wrap each line.
    private func codexPlanEntries(from item: [String: JSONValue]) -> [PlanEntry] {
        let text = stringField(item, "text") ?? ""
        return text
            .split(separator: "\n")
            .map { line in
                PlanEntry(
                    content: String(line).trimmingCharacters(in: .whitespaces),
                    priority: nil,
                    status: nil
                )
            }
            .filter { !$0.content.isEmpty }
    }

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

    /// Accumulate one `apply(_:)` invocation into the per-kind counters. Flushes
    /// a snapshot to acp-protocol.jsonl every `applyTimingFlushEveryNUpdates`
    /// to keep disk pressure bounded.
    private func recordApplyTiming(kind: String, elapsedNs: UInt64) {
        applyTimingNs[kind, default: 0] &+= elapsedNs
        applyTimingCount[kind, default: 0] += 1
        if elapsedNs > applyTimingSlowestNs[kind, default: 0] {
            applyTimingSlowestNs[kind] = elapsedNs
        }
        applyTimingUpdatesSinceFlush += 1
        if applyTimingUpdatesSinceFlush >= applyTimingFlushEveryNUpdates {
            applyTimingUpdatesSinceFlush = 0
            flushApplyTiming()
        }
    }

    private func flushApplyTiming() {
        var perKind: [String: JSONValue] = [:]
        for (kind, totalNs) in applyTimingNs {
            let count = applyTimingCount[kind] ?? 0
            let slowestNs = applyTimingSlowestNs[kind] ?? 0
            perKind[kind] = .object([
                "count": .double(Double(count)),
                "total_ms": .double(Double(totalNs) / 1_000_000.0),
                "avg_ms": .double(count > 0 ? Double(totalNs) / Double(count) / 1_000_000.0 : 0),
                "max_ms": .double(Double(slowestNs) / 1_000_000.0),
                "items_at_snapshot": .double(Double(items.count)),
            ])
        }
        ACPProtocolLog.record(
            direction: "internal",
            method: "apply_timing",
            params: .object([
                "provider": .string(provider.rawValue),
                "sessionId": sessionId.map(JSONValue.string) ?? .null,
                "items_count": .double(Double(items.count)),
                "per_kind": .object(perKind),
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

    private func appendAgentLog(_ line: String) {
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

    private func appendTraceLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        traceLog.append(trimmed)
        if traceLog.count > 800 {
            traceLog.removeFirst(traceLog.count - 800)
        }
    }

    /// Short stable name for the trace log — picks the `sessionUpdate` kind
    /// off `SessionUpdate` without dumping the payload.
    private static func kindLabel(_ u: SessionUpdate) -> String {
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
    private static func sizeHint(_ u: SessionUpdate) -> String {
        switch u {
        case .agentMessageChunk(let b), .agentThoughtChunk(let b), .userMessageChunk(let b):
            if case .text(let s) = b { return "(\(s.count)c)" }
            return ""
        default:
            return ""
        }
    }

    private func apply(_ update: SessionUpdate) {
        let _applyStart = DispatchTime.now()
        let _applyKind = Self.kindLabel(update)
        defer {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- _applyStart.uptimeNanoseconds
            recordApplyTiming(kind: _applyKind, elapsedNs: elapsedNs)
        }
        // ACP trace: when the `soul.acp.trace` UserDefault is on, every
        // session/update lands as a one-line entry in the agent log
        // (kind name + a tiny size hint). Lets you see end-to-end whether
        // ACP frames are arriving during a turn — separate from the
        // unknown-kind logging which only fires on decoder gaps.
        if UserDefaults.standard.bool(forKey: "soul.acp.trace") {
            appendTraceLog("[acp ←] \(Self.kindLabel(update)) \(Self.sizeHint(update))")
        }
        // SOUL-SOUL_DESKTOP-043: during a session/load that follows a disk
        // hydrate, the agent streams every prior turn back through
        // user/agent_message_chunk + toolCall notifications. We already
        // rendered those items from the on-disk transcript, so re-applying
        // them here would double everything. Let only non-content updates
        // (availableCommandsUpdate populates the slash picker) through.
        if suppressLoadReplay {
            if case .availableCommandsUpdate(let payload) = update {
                updateCommands(payload)
            }
            return
        }
        switch update {
        case .agentMessageChunk(let block):
            if case .text(let chunk) = block {
                if silentCapture != nil {
                    silentCapture? += chunk
                } else {
                    appendAgentChunk(chunk)
                }
            }
        case .agentThoughtChunk(let block):
            // Render the agent's reasoning stream so the user sees what's
            // happening during long turns instead of staring at a spinner.
            // Same coalescing pattern as agentMessageChunk: append to the
            // open thought bubble, or open a new one. A subsequent
            // agentMessageChunk (or tool call) closes the bubble by
            // resetting `openAgentThoughtId`.
            if silentCapture != nil { break }
            if case .text(let text) = block,
               !text.isEmpty {
                appendAgentThoughtChunk(text)
            }
        case .toolCall(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: false)
        case .toolCallUpdate(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: true)
        case .plan(let payload):
            insertPlan(payload)
        case .availableCommandsUpdate(let payload):
            updateCommands(payload)
        case .userMessageChunk(let block):
            // The agent replays prior user turns through this stream during
            // `session/load`. Each chunk is the full text of one turn (not a
            // partial stream). Closing the open agent bubble ensures turn
            // boundaries paint cleanly when several turns replay in sequence.
            if case .text(let text) = block,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openAgentMessageId = nil
                // Claude Code wraps locally-executed slash command output in
                // `<local-command-*>` scaffolding tags before injecting them
                // back into the chat stream. Without filtering, those tags
                // would render verbatim as user bubbles. Strip / re-route.
                let classified = classifyLocalCommand(text)
                switch classified {
                case .skip:
                    break
                case .status(let inner):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    items.append(.status(id: id, text: inner))
                case .message(let cleaned):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    // Strip Gemini-CLI's `--- Content from referenced files ---`
                    // auto-expansion block (same as the off-disk path in
                    // GeminiTranscriptReader). Defensive for non-Gemini
                    // streams too — the marker is unique enough not to false
                    // positive on legitimate prose.
                    let stripped = GeminiTranscriptReader.stripGeminiReferencedFileBlock(cleaned)
                    items.append(.userMessage(id: id, text: stripped, timestamp: Date()))
                }
            }
        case .currentModeUpdate:
            break
        case .unknown(let kind, let payload):
            // pi-acp emits `session_info_update` as queue/running telemetry
            // on every turn (depth + running flag). Useful diagnostic data
            // but emitted at high frequency — silently drop so the agent
            // log doesn't fill up with one entry per pi event. When Pi says
            // it is idle, also drain any stale per-tool watchdog entries left
            // behind by replay/noisy status bursts so they cannot cancel the
            // next live turn.
            if kind == "session_info_update" {
                clearPiToolTimeoutsIfIdle(payload)
                break
            }
            let preview = String(describing: payload).prefix(240)
            appendAgentLog("[unknown sessionUpdate] kind=\(kind) payload=\(preview)")
        }
    }

    private func clearPiToolTimeoutsIfIdle(_ payload: JSONValue) {
        guard provider == .pi else { return }
        guard case .bool(false)? = payload["_meta"]?["piAcp"]?["running"] else { return }
        let queueDepth: Int
        if case .int(let depth)? = payload["_meta"]?["piAcp"]?["queueDepth"] {
            queueDepth = depth
        } else {
            queueDepth = 0
        }
        guard queueDepth == 0 else { return }
        toolCallStartedAt.removeAll()
        toolCallLastActivityAt.removeAll()
        toolCallTimedOut.removeAll()
        toolCallPreviousLineCount.removeAll()
    }

    private typealias LocalCommandShape = LocalCommandClassifier.Shape

    private func classifyLocalCommand(_ raw: String) -> LocalCommandShape {
        return LocalCommandClassifier.classify(raw)
    }

    private func appendAgentChunk(_ chunk: String) {
        // A new message bubble ends any open thought bubble. The thought
        // chunks always precede the visible reply in Claude's stream, so
        // closing here keeps narrative order: thought → message.
        openAgentThoughtId = nil
        let bubbleId: UUID
        if let openId = openAgentMessageId,
           let idx = items.firstIndex(where: { $0.id == openId }),
           case .agentMessage(let id, let existing, _, let ts) = items[idx] {
            items[idx] = .agentMessage(id: id, text: existing + chunk, complete: false, timestamp: ts)
            bubbleId = id
        } else {
            let id = UUID()
            openAgentMessageId = id
            items.append(.agentMessage(id: id, text: chunk, complete: false, timestamp: Date()))
            bubbleId = id
        }
        // SOUL-SOUL_DESKTOP-065: persist each chunk to disk so the reply
        // text survives an abrupt child teardown (manual quit / force-quit
        // / OS sleep) that would otherwise lose everything written between
        // the last completed turn and the next AfterAgent. Retired at
        // end-of-turn when AfterAgent has been written authoritatively.
        if let sid = sessionId {
            SoulRegistry.appendAgentChunk(
                projectKey: project.id,
                sessionId: sid,
                bubbleId: bubbleId,
                chunk: chunk
            )
        }
    }

    private var openAgentThoughtId: UUID? = nil

    /// Inject a paragraph break when a reasoning chunk begins with a bold
    /// span (`**Header**`) and the prior buffer ends in sentence-terminating
    /// punctuation. Gemini (and sometimes Pi/Codex) emit reasoning as one
    /// long run with no linebreaks between section headers, so the renderer's
    /// inline-only markdown parser ends up gluing headers onto the end of
    /// the previous sentence. Patching the buffer here is cheaper than
    /// rewriting the renderer (block-level markdown caused exponential
    /// SwiftUI layout recursion — see comment in AgentThoughtRow).
    private func normalizeThoughtJoin(prior: String, incoming: String) -> String {
        let trimmedIncoming = incoming.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmedIncoming.hasPrefix("**") else { return prior + incoming }
        let lastNonSpace = prior.reversed().drop(while: { $0 == " " || $0 == "\t" }).first
        guard let last = lastNonSpace, last == "." || last == "!" || last == "?" else {
            return prior + incoming
        }
        // Already separated by a newline? Don't double up.
        let tailNewlines = prior.reversed().prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if tailNewlines.contains("\n") { return prior + incoming }
        return prior + "\n\n" + incoming
    }

    private func appendAgentThoughtChunk(_ chunk: String) {
        if let openId = openAgentThoughtId,
           let idx = items.firstIndex(where: { $0.id == openId }),
           case .agentThought(let id, let existing, _, let ts) = items[idx] {
            let combined = normalizeThoughtJoin(prior: existing, incoming: chunk)
            items[idx] = .agentThought(id: id, text: combined, complete: false, timestamp: ts)
        } else {
            // Symmetric to appendAgentChunk: opening a thought bubble closes
            // any open message bubble. Without this, a stream of shape
            // message-chunk → thought-chunks → message-chunks (observed on
            // Pi) appends the second batch of message chunks back into the
            // first bubble — which sits ABOVE the thought bubble in items[],
            // so the reply text visually grows above the thinking card and
            // pushes it down. SOUL-SOUL_DESKTOP-070.
            openAgentMessageId = nil
            let id = UUID()
            openAgentThoughtId = id
            items.append(.agentThought(id: id, text: chunk, complete: false, timestamp: Date()))
        }
    }

    private func insertToolCall(_ payload: JSONValue, isUpdate: Bool) {
        let toolId: String = {
            if let tid = payload["toolCallId"]?.stringValue { return tid }
            // pi-acp legacy/load support: try to derive an ID from the payload
            // if toolCallId is missing, to avoid duplication during session/load.
            if let kind = payload["kind"]?.stringValue,
               let title = payload["title"]?.stringValue {
                return "legacy-\(kind)-\(title)"
            }
            return UUID().uuidString
        }()
        let rawKind = payload["kind"]?.stringValue ?? "tool"
        let rawTitle = payload["title"]?.stringValue ?? ""
        // Normalize provider kind quirks: Pi sends kind="other"+title="bash"
        // for shell invocations; the rest of the codebase (icon, kindForTool,
        // play-button affordance, carousel grouping) keys off "execute" for
        // shell tools. Remap so Pi bash renders identically to Claude/Gemini
        // bash instead of through the generic ⚙️ "other" path.
        let kind: String = {
            if rawKind == "other" {
                let t = rawTitle.lowercased()
                if t == "bash" || t == "shell" || t == "sh" || t == "command" {
                    return "execute"
                }
            }
            return rawKind
        }()
        let status = payload["status"]?.stringValue ?? "pending"

        // Claude (and most ACP agents) attach a human-readable description to
        // every tool call's rawInput — "Search for X", "List dotfiles". For
        // Bash calls especially, the title field is the raw command, which is
        // useless as a chip headline. Prefer description when present, and
        // surface the command underneath as location.
        let rawInput = payload["rawInput"]
        let description = rawInput?["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Provider variance: command can land in rawInput.command (Claude),
        // rawInput.cmd, or older Gemini-CLI variants stash it in
        // rawInput.shell_command / .args. Check all known spellings so the
        // chip never falls back to a generic "Shell" label with no command.
        let command: String = {
            for key in ["command", "cmd", "shell_command", "args"] {
                if let s = rawInput?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty {
                    return s
                }
            }
            return ""
        }()

        // Treat generic placeholder titles ("Shell", "Bash", "Execute") as
        // unset so the command takes over the headline. Gemini-CLI sometimes
        // ships these literal placeholders when the rawTitle should have
        // been the command itself.
        let genericTitles: Set<String> = ["Shell", "Bash", "Execute", "execute", "Run", "run"]
        let titleIsGeneric = genericTitles.contains(rawTitle)

        let title: String = {
            if !description.isEmpty { return description }
            if kind == "execute", !command.isEmpty, (rawTitle.isEmpty || titleIsGeneric) {
                return command
            }
            return rawTitle
        }()

        let location: String? = {
            // Surface the command underneath as location only when title
            // already holds something else (description). Otherwise we'd
            // duplicate the command on both lines.
            if kind == "execute", !command.isEmpty, title != command {
                return command
            }
            return firstLocation(payload)
        }()

        if status == "failed" {
            ToolFailureLog.dump(payload: payload, provider: provider, sessionId: sessionId)
        }

        // Try structured extraction from rawInput first. ACP `tool_call_update`
        // notifications often re-send the same toolCallId with only the
        // status/output changing, so rawInput is empty on later updates.
        // We must NOT overwrite a previously-captured structured payload
        // with the JSON fallback when an update arrives empty-handed.
        let startLine: Int? = {
            guard case .array(let locs)? = payload["locations"], let first = locs.first,
                  let line = first["line"], case .int(let l) = line else { return nil }
            return l
        }()
        let structuredDetails: ToolCallDetails? = {
            // SOUL-SOUL_DESKTOP-101: ACP DiffContent fallback. Gemini-CLI
            // write_file omits rawInput entirely; the diff lives in the
            // top-level content[] as { type:"diff", path, oldText, newText }.
            if case .array(let blocks)? = payload["content"] {
                for block in blocks {
                    guard block["type"]?.stringValue == "diff" else { continue }
                    let oldT = block["oldText"]?.stringValue ?? block["old_string"]?.stringValue
                    let newT = block["newText"]?.stringValue ?? block["new_string"]?.stringValue
                    guard let newT else { continue }
                    if let oldT, !oldT.isEmpty {
                        return ToolCallDetails(kind: .edit(oldString: oldT, newString: newT), startLine: startLine)
                    }
                    if toolCallPreviousLineCount[toolId] == nil,
                       let path = block["path"]?.stringValue {
                        let abs = path.hasPrefix("/") ? path : (project.path as NSString).appendingPathComponent(path)
                        toolCallPreviousLineCount[toolId] = previousLineCount(atPath: abs)
                    }
                    let prev = toolCallPreviousLineCount[toolId]
                    return ToolCallDetails(
                        kind: .write(content: newT),
                        startLine: startLine,
                        previousLineCount: (prev ?? 0) > 0 ? prev : nil
                    )
                }
            }
            if let rawInput {
                let oldS = rawInput["old_string"]?.stringValue ?? rawInput["oldString"]?.stringValue
                let newS = rawInput["new_string"]?.stringValue ?? rawInput["newString"]?.stringValue
                if let oldS, let newS {
                    return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS), startLine: startLine)
                }
                // SOUL-SOUL_DESKTOP-080: Pi's edit shape — `edits: [{oldText, newText}]`
                // wrapped in an array, camelCase keys. Without this branch every Pi
                // edit fell through to nil details → no +/- counts, no diff card.
                // For now we render the first edit; multi-edit grouping is a
                // follow-up (Pi sometimes batches several edits into one tool call).
                if case .array(let edits)? = rawInput["edits"],
                   let first = edits.first {
                    let oldT = first["oldText"]?.stringValue ?? first["old_string"]?.stringValue
                    let newT = first["newText"]?.stringValue ?? first["new_string"]?.stringValue
                    if let oldT, let newT {
                        return ToolCallDetails(kind: .edit(oldString: oldT, newString: newT), startLine: startLine)
                    }
                }
                // Write-body field name varies by provider: Claude uses `content`
                // or `new_str`, Gemini-CLI's write_file uses `file_text`, and some
                // ACP servers use plain `text`. Check all four so the diff card
                // renders the actual file content instead of falling through to
                // the JSON-envelope fallback (SOUL-SOUL_DESKTOP-032).
                let writeBody = rawInput["content"]?.stringValue
                    ?? rawInput["new_str"]?.stringValue
                    ?? rawInput["file_text"]?.stringValue
                    ?? rawInput["text"]?.stringValue
                if let writeBody {
                    // Capture line count of the file on disk the first time we
                    // see this toolCallId, before the agent's write lands. Reads
                    // are cheap (single stat + read) and gated by the cache so
                    // later update events don't see the post-write content.
                    if toolCallPreviousLineCount[toolId] == nil,
                       let path = writeTargetPath(payload: payload, rawInput: rawInput) {
                        toolCallPreviousLineCount[toolId] = previousLineCount(atPath: path)
                    }
                    let prev = toolCallPreviousLineCount[toolId]
                    return ToolCallDetails(
                        kind: .write(content: writeBody),
                        startLine: startLine,
                        previousLineCount: (prev ?? 0) > 0 ? prev : nil
                    )
                }
            }
            // Fallback: capture tool output (stdout/stderr) for non-edit tools.
            // Surfaced when the row is expanded; helps diagnose grep/shell failures.
            if let out = payload["output"]?.stringValue, !out.isEmpty {
                return ToolCallDetails(kind: .output(text: out))
            }
            return nil
        }()

        // SOUL-SOUL_DESKTOP-033 + -079: per-tool-call timeout bookkeeping.
        // Record start AND refresh lastActivityAt on every non-terminal
        // update; the watchdog keys off lastActivityAt.
        let isTerminal = (status == "completed" || status == "failed" || status == "stopped")
        if isTerminal {
            toolCallStartedAt.removeValue(forKey: toolId)
            toolCallLastActivityAt.removeValue(forKey: toolId)
            toolCallTimedOut.remove(toolId)
            toolCallPreviousLineCount.removeValue(forKey: toolId)
        } else if !isReplayingLoad {
            if toolCallStartedAt[toolId] == nil {
                toolCallStartedAt[toolId] = Date()
            }
            toolCallLastActivityAt[toolId] = Date()
        }

        if let existingId = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == existingId }),
           case .toolCall(let id, let oldKind, let oldTitle, _, let oldLoc, let oldDetails) = items[idx] {
            items[idx] = .toolCall(
                id: id,
                kind: oldKind,
                title: title.isEmpty ? oldTitle : title,
                status: status,
                locationHint: location ?? oldLoc,
                details: structuredDetails ?? oldDetails
            )
            return
        }

        // Closing the open agent message AND thought when a tool call arrives
        // keeps subsequent chunks in a fresh bubble below the call. Without
        // closing the thought, a stream of thought → tool → thought re-appends
        // the second batch into the original thinking card *above* the tool
        // rows, since openAgentThoughtId still points at it.
        openAgentMessageId = nil
        openAgentThoughtId = nil

        // First time we're seeing this toolCallId. Use structured details
        // when we have them; otherwise leave details = nil and the row
        // renders without an expand chevron. The previous JSON-envelope
        // fallback (SOUL-SOUL_DESKTOP-032) dumped the wrapper payload —
        // toolCallId, sessionUpdate, locations, etc. — into the diff
        // card's "new content" column, which was actively misleading on
        // any write-tool whose rawInput field name we didn't recognize.
        // The tool_call_update notifications that follow will supply the
        // real rawInput once the agent finishes streaming the call.
        let firstSeenDetails: ToolCallDetails? = structuredDetails

        // SOUL-SOUL_DESKTOP-034: surface known-stuck shell commands (tail -f,
        // watch, interactive top, …) with a warning row above the tool-call
        // card so the user knows to Recover instead of waiting on a turn that
        // will never resolve. Pure detection — the command still runs.
        if kind == "execute", !command.isEmpty,
           let reason = StuckCommandPatterns.reason(forExecuteCommand: command) {
            items.append(.status(id: UUID(), text: "⚠ \(reason)"))
        }

        let uuid = UUID()
        seenToolCallIds[toolId] = uuid
        items.append(.toolCall(
            id: uuid,
            kind: kind,
            title: title.isEmpty ? kind : title,
            status: status,
            locationHint: location,
            details: firstSeenDetails
        ))

        // Per-provider rawInput shape log. One entry per first-seen toolCallId
        // for edit/write tools, recording whether `structuredDetails` landed
        // (== whether the diff card will appear). Tail
        // `~/Library/Logs/Soul-Desktop/tool-schema.jsonl` to see what each
        // provider sends; grow the extractor matrix in `structuredDetails`
        // above when new field names appear.
        if case .object(let obj) = payload {
            ToolSchemaLog.record(
                toolCallId: toolId,
                kind: kind,
                toolName: payload["title"]?.stringValue ?? kind,
                rawInput: rawInput,
                payloadKeys: Array(obj.keys),
                provider: provider,
                sessionId: sessionId,
                extractedDetails: firstSeenDetails != nil
            )
        }
    }

#if DEBUG
    func _testApplyUpdate(_ update: SessionUpdate) {
        apply(update)
    }

    var _testTrackedToolCallCount: Int {
        toolCallStartedAt.count
    }

    func _testSetReplayingLoad(_ value: Bool) {
        isReplayingLoad = value
    }
#endif

    private func updateCommands(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["availableCommands"] ?? payload["commands"] else { return }
        let cmds: [SlashCommand] = raw.compactMap { c in
            guard let name = c["name"]?.stringValue else { return nil }
            let hint = c["input"]?["hint"]?.stringValue
            return SlashCommand(
                name: name,
                description: c["description"]?.stringValue,
                inputHint: hint
            )
        }
        availableCommands = cmds.sorted { $0.name < $1.name }
    }

    private func insertPlan(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["entries"] else { return }
        let entries: [PlanEntry] = raw.map { e in
            PlanEntry(
                content: e["content"]?.stringValue ?? "",
                priority: e["priority"]?.stringValue,
                status: e["status"]?.stringValue
            )
        }
        guard !entries.isEmpty else { return }

        if let idx = items.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
            if case .plan(let id, _) = items[idx] {
                items[idx] = .plan(id: id, entries: entries)
                return
            }
        }
        openAgentMessageId = nil
        items.append(.plan(id: UUID(), entries: entries))
    }

    /// Returns the absolute target path for a Write tool call. Tries the
    /// rawInput `file_path` / `path` field first (most providers), then
    /// `locations[0].path`. Relative paths resolve against the active
    /// project's working dir so disk reads land on the right file.
    private func writeTargetPath(payload: JSONValue, rawInput: JSONValue?) -> String? {
        var raw: String? =
            rawInput?["file_path"]?.stringValue
            ?? rawInput?["path"]?.stringValue
            ?? rawInput?["filePath"]?.stringValue
        if raw == nil, case .array(let locs)? = payload["locations"], let first = locs.first {
            raw = first["path"]?.stringValue
        }
        guard let p = raw, !p.isEmpty else { return nil }
        if p.hasPrefix("/") { return p }
        if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        return (project.path as NSString).appendingPathComponent(p)
    }

    /// Sync line count for a file. Returns 0 if missing — callers treat 0 as
    /// "no previous content," so a fresh write keeps the additions-only chip.
    private func previousLineCount(atPath path: String) -> Int {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        if data.isEmpty { return 0 }
        var n = data.components(separatedBy: "\n").count
        if data.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }

    private func firstLocation(_ payload: JSONValue) -> String? {
        guard case .array(let locs)? = payload["locations"], let first = locs.first else { return nil }
        let path = first["path"]?.stringValue ?? ""
        if let line = first["line"], case .int(let l) = line { return "\(path):\(l)" }
        return path.isEmpty ? nil : path
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
