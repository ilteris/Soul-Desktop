import Foundation
import SwiftUI
import SoulACP
import SoulCore
import SoulLedger

struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String?
    let inputHint: String?
    var id: String { name }

    var isSoulSlashCommand: Bool {
        Self.soulSlashCommandNames.contains(name.lowercased())
    }

    private static let soulSlashCommandNames: Set<String> = [
        "compact",
        "decision",
        "delegate",
        "finalize",
        "pulse",
        "recall",
    ]

    /// SOUL-SOUL_DESKTOP-359: `/compact` is a client-intercepted command, not
    /// a prompt. It has no SKILL.md and isn't provider-reported — the composer
    /// routes it to `AutoCompactController.forceCompact` (kernel forced-dispatch
    /// + ledger `AutoCompactFired` + Codex/Pi toast degradation) instead of
    /// sending it to the agent. Always merged into the active-thread palette so
    /// it's discoverable alongside `/finalize`, `/pulse`, etc.
    static let compact = SlashCommand(
        name: "compact",
        description: "Compact the conversation context now",
        inputHint: nil
    )
}

extension Array where Element == SlashCommand {
    func deduplicatedByName() -> [SlashCommand] {
        var commands: [SlashCommand] = []
        var indexesByName: [String: Int] = [:]

        for command in self {
            let key = command.name.lowercased()
            if let index = indexesByName[key] {
                let existing = commands[index]
                commands[index] = SlashCommand(
                    name: existing.name,
                    description: existing.description ?? command.description,
                    inputHint: existing.inputHint ?? command.inputHint
                )
            } else {
                indexesByName[key] = commands.count
                commands.append(command)
            }
        }

        return commands
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
    var project: SoulProject
    /// The active project path, resolving to a session-specific Git worktree path if one exists on disk,
    /// otherwise falling back to the canonical project directory path.
    var activeProjectPath: String {
        project.path
    }
    /// Per-session Git worktree provisioning outcome (SOUL-364). Set by
    /// `SessionWorktreeProvisioner` on the fresh-session path; read by the
    /// block-guard in `_ensureSessionImpl` so a session whose isolated
    /// worktree could not be created never silently spawns in the shared
    /// checkout. `.notAttempted` for resumed sessions (already routed to
    /// their worktree by `loadSession`) and for non-git projects.
    enum WorktreeProvisionState: Equatable {
        case notAttempted
        case provisioned(path: String, branch: String)
        case skipped(reason: String)
        case fellBackToMain(error: String)
        case blocked(error: String)
    }
    @ObservationIgnored var worktreeProvisionState: WorktreeProvisionState = .notAttempted
    @ObservationIgnored var ledger: ThreadLedger = LiveThreadLedger.shared
    /// Best-effort wall-clock moment the underlying *session* started. For a
    /// fresh thread this is the instantiation time; AppShell overwrites it on
    /// session-load with the first hooks.jsonl event timestamp so the
    /// session-length chip reflects total session age, not "ms since this view
    /// opened."
    var startedAt: Date = Date()

    var items: [ThreadItem] = [] {
        didSet {
            itemsVersion &+= 1
            transcriptLayoutNonce &+= 1
            SoulSignposts.event("Flash.items.didSet", "old=\(oldValue.count) new=\(items.count)")
        }
    }
    /// Observable layout invalidation for the SwiftUI transcript viewport.
    /// The internal `itemsVersion` is intentionally ignored by Observation
    /// for cache churn, but LazyVStack sometimes needs an explicit identity
    /// bump when rows are inserted into a restored session.
    var transcriptLayoutNonce: Int = 0
    var historicalIDs: Set<UUID> = []
    /// Per-thread composer draft text. Lives on the controller (not on
    /// AppShell) so keystrokes don't invalidate the whole app's view tree —
    /// only ThreadView's body re-evaluates. Survives thread-switch without
    /// requiring a top-level dictionary.
    var composerDraft: String = ""
    var droppedAttachments: [String] = []
    /// True while a file drag is hovering the composer text field. Drives the
    /// shared CanvasDropOverlay so the composer and the transcript present one
    /// unified drop affordance instead of two different-looking zones.
    var isComposerDropActive: Bool = false
    var isWorking: Bool = false
    @ObservationIgnored var onRuntimeEnded: ((String?) -> Void)?
    var lastError: String?
    var availableCommands: [SlashCommand] = [SlashCommand.compact]
    var customTitle: String? = nil
    @ObservationIgnored var titleGenerationInFlight: Bool = false
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
            let runtime = runtimes.acp
            Task { await runtime?.setPermissionMode(mode.agentPermissionMode) }
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

    /// SOUL-SOUL_DESKTOP-379 (A): coalesce streaming `session/update` chunks.
    /// A model emits many token deltas per frame; applying each one inline
    /// mutated `items` (observed) per chunk, so SwiftUI re-rendered the
    /// transcript — and, via shared live state, the whole sidebar — once per
    /// chunk. Instead, incoming content updates accumulate here off the
    /// observation graph and flush as a single `items` mutation at most once
    /// per `streamCoalesceInterval`, collapsing N chunks/frame into one
    /// render. Non-content events (terminated/request) and the end-of-turn
    /// AfterAgent ledger read force a synchronous drain first so ordering and
    /// the authoritative ledger are never truncated.
    @ObservationIgnored var pendingStreamUpdates: [SessionUpdate] = []
    @ObservationIgnored var streamFlushScheduled = false
    @ObservationIgnored var agentStreamBuffer = AgentStreamBuffer()
    @ObservationIgnored static let streamCoalesceInterval: TimeInterval = 1.0 / 30.0

    /// Sends issued while a turn is already running get parked here and
    /// drained in order once the current `client.prompt` resolves. Each
    /// entry carries both halves of the two-channel send so slash-expanded
    /// agent text and the bare-`/cmd` display bubble stay paired.
    struct QueuedPrompt: Hashable {
        enum LedgerEvent: String, Hashable {
            case userPrompt = "UserPrompt"
            case branchSummary = "BranchSummary"
        }

        let itemId: UUID
        let display: String
        let agent: String
        var extraBlocks: [ContentBlock] = []
        var ledgerEvent: LedgerEvent = .userPrompt
        var sourceProvider: Provider? = nil
        var targetProvider: Provider? = nil
    }
    var queuedPrompts: [QueuedPrompt] = [] {
        didSet { queuedVersion &+= 1 }
    }

    /// Bumped on every `queuedPrompts` write so dependent caches
    /// (`queuedItemIDs`) can invalidate against a stable version key
    /// instead of recomputing on every read.
    @ObservationIgnored private var queuedVersion: Int = 0
    @ObservationIgnored private var queuedItemIDsCache: (version: Int, value: Set<UUID>)? = nil

    /// The set of `userMessage` item IDs that have been appended to `items`
    /// but not yet dispatched. ThreadView styles these bubbles with a
    /// "pending" look so the user can tell which prompts are queued vs. the
    /// one the agent is actively chewing on. Cached by `queuedVersion` —
    /// previously this allocated a fresh Set on every read, and
    /// `splitGroupedItems` called it on every body fire.
    var queuedItemIDs: Set<UUID> {
        if let cache = queuedItemIDsCache, cache.version == queuedVersion {
            return cache.value
        }
        let result = Set(queuedPrompts.map(\.itemId))
        queuedItemIDsCache = (queuedVersion, result)
        return result
    }

    var groupedItems: [ThreadItem] {
        if let cache = groupedItemsCache, cache.version == itemsVersion {
            return cache.value
        }
        let result = ThreadItemGrouper.group(items)
        groupedItemsCache = (itemsVersion, result)
        return result
    }

    /// Pre-computed split of `groupedItems` into "main" rows and queued
    /// rows. ThreadView previously called `splitGroupedItems` from its body
    /// (and the hydrate/restore handlers) — each call was an O(N) walk +
    /// fresh array allocation. Cached against `(itemsVersion, queuedVersion)`
    /// so a body re-eval that doesn't touch items OR queue returns the
    /// existing tuple by reference. Audit fix #1.
    @ObservationIgnored private var groupedSplitCache: (itemsVersion: Int, queuedVersion: Int, value: (main: [ThreadItem], queued: [ThreadItem]))? = nil

    var groupedItemsSplit: (main: [ThreadItem], queued: [ThreadItem]) {
        if let cache = groupedSplitCache,
           cache.itemsVersion == itemsVersion,
           cache.queuedVersion == queuedVersion {
            return cache.value
        }
        let queuedIds = queuedItemIDs
        var main: [ThreadItem] = []
        var queued: [ThreadItem] = []
        main.reserveCapacity(groupedItems.count)
        for item in groupedItems {
            if queuedIds.contains(item.id) {
                queued.append(item)
            } else {
                main.append(item)
            }
        }
        let result = (main: main, queued: queued)
        groupedSplitCache = (itemsVersion, queuedVersion, result)
        return result
    }

    /// Cached counts of tool calls + user-message chapters in `items`. The
    /// toolbar `SessionStatsChip` reads these on every TimelineView tick
    /// (once per second) for the elapsed-time help text; without caching,
    /// long sessions paid O(N) per tick forever. Cache piggybacks on
    /// `itemsVersion`, which the `items` didSet already bumps.
    var toolCount: Int {
        refreshStatsCache()
        return statsCache?.tools ?? 0
    }

    var chapterCount: Int {
        refreshStatsCache()
        return statsCache?.chapters ?? 0
    }

    private func refreshStatsCache() {
        if let c = statsCache, c.version == itemsVersion { return }
        var tools = 0
        var chapters = 0
        for item in items {
            switch item {
            case .userMessage:
                chapters += 1
            case .toolCall:
                tools += 1
            case .toolCallGroup(_, _, _, _, let inner):
                tools += inner.count
            default:
                break
            }
        }
        statsCache = (itemsVersion, tools, chapters)
    }

    /// Per-thread scroll anchor. ThreadView records the top-most visible item
    /// as the user scrolls and restores it on re-appear so switching threads
    /// (multiplexer) doesn't snap each view back to the top.
    var scrollAnchorItemId: UUID? = nil
    /// Incremented whenever AppSessionCoordinator makes this controller the
    /// visible thread. Mounted inactive threads are hidden with opacity, so
    /// SwiftUI does not fire `onAppear` when they become active again; this
    /// nonce gives ThreadView an explicit activation signal for scroll repair.
    var activationNonce: Int = 0

    /// True while a `session/load` is in flight. The agent replays the prior
    /// transcript through `user_message_chunk` / `agent_message_chunk`
    /// notifications during the load — we still paint them, but flag the
    /// items as historical so they don't accidentally trigger one-shot
    /// behaviors like first-turn title generation.
    var isReplayingLoad: Bool = false

    /// SOUL-SOUL_DESKTOP-231: true while `hydrateFromDisk` is reading the
    /// on-disk transcript and appending into `items`. Distinct from
    /// `isReplayingLoad` (which only covers the ACP `session/load` path);
    /// the sidebar-click read-first flow goes through hydrateFromDisk and
    /// would never trip isReplayingLoad. ThreadView's skeleton overlay
    /// gates on this so the user sees a loading state during the disk
    /// read instead of watching rows pop in one-by-one.
    ///
    /// Defaults to `true` so a freshly-constructed controller paints the
    /// skeleton from its very first body render — preventing the
    /// mount-before-hydration blank flash where the controller was visible
    /// at opacity 1 with `items=[]` AND `isHydrating=false` for one
    /// runloop tick before the detached hydrate Task scheduled. Callers
    /// that mount a controller WITHOUT going through hydrateFromDisk
    /// (`startThread`, `branchFrom`) must clear this explicitly before
    /// mount — they own their own loading affordance.
    var isHydrating: Bool = true

    /// True after this controller has been explicitly torn down. A normal
    /// composer must not be mounted against a torn-down controller; the user
    /// can branch or reopen into a fresh controller instead.
    var isTornDown: Bool = false

    var canAcceptComposerInput: Bool {
        !isTornDown && (!isHydrating || !items.isEmpty)
    }

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
    var pendingResumeOnFirstSend: Bool = false

    /// SOUL-SOUL_DESKTOP-245 (Phase B). When set, the next first-turn
    /// dispatch prefixes this text to its agent-channel prompt — giving
    /// the freshly-minted provider session the prior conversation as
    /// inline context instead of calling `session/load` (which re-feeds
    /// the entire history and blows the context window on long sessions).
    /// Cleared as soon as it's consumed.
    ///
    /// Known race (documented, not fixed in Phase B): if the user sends
    /// a prompt before `hydrateFromDisk`'s detached read returns, the
    /// send's `ensureSession` runs first, mints a fresh native sid
    /// without a preamble, and the late hydrate then populates this
    /// field — which gets consumed on the *second* user turn instead of
    /// the first. Mitigation today: AppShell chains hydrate→ensureSession
    /// in the click path so the warm-up beats the user typing. Phase A
    /// will add an explicit `awaitHydrate()` gate.
    var pendingContextPreamble: String? = nil

    /// SPEC-245-K step 4: where the staged preamble should be injected.
    /// `.claudeSystemMeta` → consumed by mintFreshNativeSession via
    /// `_meta.systemPrompt` on session/new. `.userPromptPrefix` →
    /// consumed by dispatchPending as a prefix on the first turn.
    /// Default protects the legacy code path when no kernel hint
    /// arrived (e.g. fallback to the in-process Swift renderer).
    var pendingPreambleChannel: PreambleChannel = .userPromptPrefix

    /// SPEC-245-K hotfix (post-step-4). Background Task that builds the
    /// preamble via the kernel CLI. Spawned at the tail of hydrateFromDisk
    /// rather than awaited inline, so a 20s summarizer call doesn't pin
    /// the canvas on the loading skeleton. ensureSession awaits this
    /// before reading pendingContextPreamble/Channel, so the preamble
    /// still lands on the first send even if the user types fast.
    @ObservationIgnored var preambleStagingTask: Task<Void, Never>? = nil

    /// Running task for ensureSession() to prevent concurrent executions.
    @ObservationIgnored var ensureSessionTask: Task<Void, Error>? = nil

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
        // SOUL-SOUL_DESKTOP-082 Phase 1: route through SessionTitleResolver
        // so live and disk surfaces compute titles identically. Previously
        // this had bespoke logic (strip bare slash, walk fallbacks) that the
        // sidebar didn't share — same /pulse session got different titles
        // when live vs read from disk.
        let userPrompts: [String] = items.compactMap { item -> String? in
            if case .userMessage(_, let t, _) = item {
                let cleaned = SoulRegistry.stripCommandTags(t)
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        }
        let firstBranchSummary: String? = items.lazy.compactMap {
            if case .branchSummary(_, let summary, _, _, _) = $0 { return summary } else { return nil }
        }.first
        let firstAgent: String? = items.lazy.compactMap {
            if case .agentMessage(_, let t, _, _) = $0 { return t } else { return nil }
        }.first
        let firstAgentLine: String? = firstAgent.flatMap { firstMeaningfulLine($0) }

        let inputs = SessionTitleResolver.Inputs(
            customTitle: customTitle.flatMap { raw in
                // Same stripping the previous code applied — keep the
                // semantics so a raw Title hook with command-message
                // scaffolding doesn't leak through.
                let stripped = SoulRegistry.stripCommandTags(raw)
                return stripped.isEmpty ? nil : stripped
            },
            finalizeIntent: nil, // live ThreadController has no finalize.intent yet
            prompts: userPrompts,
            firstAgentLine: firstAgentLine,
            branchSummary: firstBranchSummary,
            skillHint: nil
        )
        return SessionTitleResolver.resolve(inputs)
    }

    /// Most recent agent reply text in `items`, walking from the end.
    /// Used by `send()` to capture the just-completed turn for the kernel
    /// hooks ledger so Replay is durable against provider-side data loss.
    /// Returns nil if there's no agent message after the most recent user
    /// message (i.e. the agent didn't actually reply).
    func mostRecentAgentReplyText() -> String? {
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
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
                       .replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "`", with: "")
            let generic = line.trimmingCharacters(in: CharacterSet(charactersIn: ".!")).lowercased()
            if !line.isEmpty && !["fixed", "done", "ok", "okay", "updated", "complete", "completed"].contains(generic) {
                return line
            }
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
            case .branchSummary(_, let summary, let sourceProvider, let targetProvider, _):
                out += "---\n### Branch Summary\n"
                out += "**Intent:** Continue from \(sourceProvider.appProvider?.label ?? sourceProvider.rawValue) in \(targetProvider.appProvider?.label ?? targetProvider.rawValue)\n\n"
                out += "**Summary:** \(summary)\n\n"
                out += "---\n\n"
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

    /// Provider runtime adapter state. ThreadController owns app-facing state;
    /// concrete provider process lifecycle lives behind these runtime adapters.
    var runtimes = ThreadProviderRuntimeStore()
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
    /// SOUL-SOUL_DESKTOP-379: Codex streaming coalescing. The codex app-server
    /// emits agent-text / reasoning / output deltas token-by-token, and
    /// `handleCodex` mutated `items` (observed) per delta — a full transcript
    /// re-render per letter. The ACP coalescer (453b122) never covered this
    /// because codex doesn't flow through `apply(_:)`. Accumulate deltas here
    /// off the observation graph, keyed by codex item id, and flush as one
    /// batched `items` mutation at most once per `streamCoalesceInterval`. The
    /// universal turn-level drain (`flushPendingStreamUpdates`) and every
    /// inline non-delta codex mutation force this buffer first, so a status
    /// row, an item completion, or the AfterAgent ledger read can never paint
    /// ahead of buffered streamed text.
    enum CodexDeltaKind { case agentText, reasoning, output }
    @ObservationIgnored var pendingCodexDeltas: [String: (kind: CodexDeltaKind, text: String)] = [:]
    @ObservationIgnored var pendingCodexOrder: [String] = []
    @ObservationIgnored var codexFlushScheduled = false
    /// Per-thread ACP session state, constructed lazily on first need.
    /// Owns codex token counters (and, in later refactor steps, the agent
    /// client handles + event stream). Historical-only threads loaded from
    /// disk never allocate one. See ACPSession.swift.
    // ACPSession (the lazy holder from earlier refactor) was reverted in
    // SOUL-SOUL_DESKTOP-137 — its fields now live directly on
    // ThreadController so @Observable propagation works for sessionId /
    // nativeSessionId / lastActivityAt / codex token counters.

    // SOUL-SOUL_DESKTOP-137: session state lives DIRECTLY on ThreadController
    // (not forwarded through ACPSession). The earlier refactor (steps 2/3)
    // routed these via a computed-property forwarder over an
    // @ObservationIgnored _session reference — but the Observation framework
    // only registers a view as a dependency when it reads an @Observable
    // member through a tracked path. Reading `thread.sessionId` through the
    // forwarder did NOT register tracking on ACPSession.sessionId, so views
    // never re-rendered when `client.newSession()` assigned the id. Result:
    // ThreadTitleCluster (gates on sessionId), ContextUsageChip (also gates
    // on sessionId), and the sidebar's live-session match (looks up by
    // sessionId) all failed to update for fresh chats. Stored properties
    // here participate in ThreadController's @Observable tracking the way
    // every other UI-bound field on this class does.

    /// Kernel/registry session id. Stable for the entire thread lifetime.
    var sessionId: String?
    /// Agent-native session id used for ACP calls. nil until the first ACP
    /// id is known.
    var nativeSessionId: String?
    /// Convenience: native id when known, else the kernel id.
    var acpSessionId: String? { nativeSessionId ?? sessionId }
    /// Last time we received any event from the agent. Used to compute
    /// "quiet for Ns" once `isWorking` is true and nothing's streaming.
    ///
    /// SOUL-SOUL_DESKTOP-379 (C): OFF the observation graph. This was
    /// mutated on EVERY ACP event (including tool-progress updates that
    /// change no `items`), and the sidebar resolver reads it for all ~40
    /// projects — so each bump fanned a re-resolve across the whole sidebar
    /// at a rate above the coalesced item cadence. Nothing needs per-event
    /// precision here: the stall watchdog POLLS it (1s), the stall overlay
    /// reads it from a TimelineView (time-driven, not observation-driven),
    /// and the toolbar duration chip re-reads it whenever `items`/`toolCount`
    /// change — which is exactly when the duration meaningfully advances.
    @ObservationIgnored var lastActivityAt: Date = Date()
    /// Transport-level connectivity for the active turn. `.reconnecting` is set
    /// when the runtime emits a retrying `error` notification and cleared on the
    /// next real forward-progress event (or at turn end). Drives the
    /// WorkingIndicator's reconnecting affordance. SOUL-SOUL_DESKTOP-369.
    enum Connectivity: Equatable {
        case normal
        case reconnecting(message: String)
    }
    var connectivity: Connectivity = .normal
    /// Latest token count reported by codex's `thread/tokenUsage/updated`
    /// notification. nil until the first usage event lands.
    var codexTokensUsed: Int?
    /// Model context-window budget reported by the same notification.
    var codexContextWindow: Int?

    /// SOUL-IDENTITY-SPLIT: live transcript filename used by the provider
    /// on disk. Tracks Claude's `/compact` rotations — different from
    /// `nativeSessionId` once Claude rotates. nil until first detected.
    /// Persisted to hooks.jsonl as a `ProviderTranscriptID` event so
    /// chip + replay readers pick it up after restart.
    @ObservationIgnored var providerTranscriptId: String?
    /// FSEvents-backed watcher; created when the thread becomes a Claude
    /// session with a known native id. Re-armed after every prompt.
    @ObservationIgnored var transcriptWatcher: ProviderTranscriptWatcher?

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
        // SOUL-OWNERSHIP-MARKER: stamp Soul-Desktop's ownership of this kernel
        // session id BEFORE any async work runs. The existing desktop-signature
        // markers (NativeSessionID, Title) land only after the first agent
        // response completes — so a mid-session crash leaves an orphan whose
        // ledger has UserPrompt + AfterTool + AfterAgent but no desktop tag,
        // and `SoulRegistry+Sessions` then misreads it as terminal-owned and
        // blocks reopen with "Session is running elsewhere". Writing here
        // guarantees the marker lands at the same moment the controller
        // takes ownership, so any crash thereafter still leaves behind proof
        // the session was desktop-driven.
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sid,
            event: LedgerHookEvent.sessionOwner(
                writer: "soul-desktop",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                provider: provider.rawValue
            ).hookDictionary
        )
    }

    /// Watch finalize storage so an agent self-invoking `/finalize`
    /// surfaces a real FinalizeCard instead of just a bold
    /// "Finalization complete" line of stdout from the tool call.
    @ObservationIgnored var finalizeWatcher: FinalizeWatcher?

    private func startFinalizeWatcher() {
        finalizeWatcher?.stop()
        guard let sid = sessionId else { return }
        let projectDir = "\(SoulRegistry.primarySessionsRoot)/\(project.id)"
        let sessionDir = "\(projectDir)/\(sid)"
        let watcher = FinalizeWatcher(directoryPaths: [projectDir, sessionDir]) { [weak self] in
            guard let self, let sid = self.sessionId else { return }
            let projectId = self.project.id
            Task.detached(priority: .utility) {
                let rec = SoulRegistry.latestFinalize(projectKey: projectId, sessionId: sid)
                await MainActor.run {
                    guard self.sessionId == sid else { return }
                    self.injectFinalizeRecordIfFresh(rec, sessionId: sid)
                }
            }
        }
        finalizeWatcher = watcher
        watcher.start()
    }
    // `acpSessionId` is declared as a computed property above (next to
    // sessionId / nativeSessionId) — the duplicate definition that used to
    // live here is removed in SOUL-SOUL_DESKTOP-137.
    var hasInitialized = false
    var supportsLoadSession = false
    var supportsImageAttachments = false
    var openAgentMessageId: UUID?
    var openAgentThoughtId: UUID? = nil
    /// Last finalize timestamp the live-injection helper has surfaced
    /// during THIS controller\'s lifetime. Prevents re-injecting the same
    /// finalize card after every subsequent turn — we only push a new
    /// card when a fresh finalize JSON (newer timestamp) appears on disk.
    var lastFinalizeInjectedAt: Date? = nil
    var seenToolCallIds: [String: UUID] = [:]
    var eventTask: Task<Void, Never>?

    /// SOUL-SOUL_DESKTOP-024: per-turn stall watchdog. While `isWorking` is
    /// true, this task polls `lastActivityAt` and fires once at the provider's
    /// stall budget (StallDetected hook + UI capsule wakes up via TimelineView)
    /// and again at the hard auto-cancel ceiling (force-recovers the turn).
    /// One task per `send()` invocation; cleared on completion or cancel.
    var stallWatchdog: Task<Void, Never>?
    /// Single-fire guard so the StallDetected hook lands once per stall
    /// episode even though the watchdog ticks every second.
    var stallHookEmittedAt: Date?
    /// Most recent in_progress tool kind we observed when the stall fired,
    /// captured for the hook payload so post-mortems can pattern-match
    /// `swarm-status.py --oneshot` style hangs across sessions.
    var lastInProgressToolKind: String?
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
    var toolCallSignposted: Set<String> = []
    /// For Write tool calls: line count of the target file the first time
    /// we saw the toolCallId, captured before the agent's actual disk write
    /// lands. Lets the diff chip show `+N -M` for Writes against existing
    /// files. Keyed by toolCallId. Sentinel `0` means "file did not exist."
    var toolCallPreviousLineCount: [String: Int] = [:]
    /// Maps a subagent's inner-tool toolCallId to its outer (parent)
    /// Task/subagent toolCallId. Populated from `_meta.claudeCode.parentToolUseId`
    /// (claude-agent-acp) and `_meta.parentToolCallId` (Soul fork of gemini-cli,
    /// branch `soul/nested-subagent-acp`). The view layer reads this side map
    /// to render the inner tool rows nested under their parent subagent row
    /// instead of at top level.
    var subagentParentByChildId: [String: String] = [:]
    /// Inverse of `subagentParentByChildId`: parent toolCallId → ordered list
    /// of child toolCallIds (arrival order). View enumerates this to draw the
    /// nested timeline; append-once semantics so a tool_call_update for the
    /// same child doesn't duplicate the entry.
    var subagentChildrenByParentId: [String: [String]] = [:]

    /// Set of ThreadItem UUIDs that should be suppressed from top-level
    /// rendering because they're attached to a parent subagent row. Resolved
    /// from `subagentChildrenByParentId` via `seenToolCallIds`. Computed
    /// lazily per access — cheap enough at typical thread sizes (a handful of
    /// subagents per session).
    var nestedSubagentChildItemIds: Set<UUID> {
        var ids: Set<UUID> = []
        for children in subagentChildrenByParentId.values {
            for childToolId in children {
                if let uuid = seenToolCallIds[childToolId] {
                    ids.insert(uuid)
                }
            }
        }
        return ids
    }

    /// Resolves the child ThreadItems nested under a given subagent's
    /// toolCallId, preserving arrival order. Items not yet seen in
    /// `seenToolCallIds` (e.g. orphans that arrived before the parent) are
    /// skipped; they'll appear once their tool_call notification lands.
    func nestedSubagentChildren(parentToolCallId: String) -> [ThreadItem] {
        guard let childIds = subagentChildrenByParentId[parentToolCallId] else {
            return []
        }
        var result: [ThreadItem] = []
        result.reserveCapacity(childIds.count)
        for childToolId in childIds {
            guard let uuid = seenToolCallIds[childToolId] else { continue }
            if let item = items.first(where: { $0.id == uuid }) {
                result.append(item)
            }
        }
        return result
    }
    @ObservationIgnored private var itemsVersion: Int = 0
    @ObservationIgnored private var groupedItemsCache: (version: Int, value: [ThreadItem])?
    @ObservationIgnored private var statsCache: (version: Int, tools: Int, chapters: Int)?
    /// Set when Stop / Recover intentionally tears down the provider child to
    /// force an in-flight prompt continuation to unwind. The resulting
    /// childTerminated error is expected and should not render as a red row.
    var suppressNextInterruptedTurnError = false
    /// SOUL-210: gates incoming session/update events between the moment
    /// the user clicks Stop and the moment the child process is actually
    /// dead. Without this, the agent streams more text + tool rows after
    /// Stop because session/update notifications continue to arrive
    /// (and apply) while we await session/cancel + process teardown.
    /// That made Stop "feel" unresponsive — the UI flipped to !isWorking
    /// but new content still appeared.
    @ObservationIgnored var isCancelling = false
    /// Set by steerToNextQueued() so the next queued prompt that actually
    /// dispatches in the send() while-loop posts the "steered" status row at
    /// the moment the queue drains — not optimistically at cancel-send time,
    /// which leaves the bubble still marked "queued" until the cancel acks.
    var steerPending = false
    /// Wall-clock start of the currently-dispatching turn. Set when `isWorking`
    /// flips true (fresh send) and reset at the top of each while-loop
    /// iteration in `dispatchPending` so queued-drain turns get their own
    /// 0-anchor. WorkingIndicator renders elapsed time off this.
    var turnStartedAt: Date?

    init(provider: Provider, project: SoulProject) {
        self.provider = provider
        self.project = project
    }

    /// SOUL-SOUL_DESKTOP-063 diagnostic: every mutation of the live session
    /// triad (client / hasInitialized / nativeSessionId / sessionId) writes a
    /// line to both the in-memory agent log and ~/Library/Logs/Soul-Desktop/
    /// acp-protocol.jsonl (method="lifecycle") so post-mortems can correlate
    /// teardown order against the ACP wire trace.
    func logLifecycle(_ event: String, note: String = "") {
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

    /// Live filesystem watch on the current worktree's `.git` link, if rooted
    /// in one. `nonisolated(unsafe)` so `deinit` can cancel it — a resumed
    /// DispatchSource must be cancelled before release or libdispatch traps.
    @ObservationIgnored nonisolated(unsafe) private var worktreeWatch: DispatchSourceFileSystemObject?

    deinit { worktreeWatch?.cancel() }

    /// Dynamically forks the active session into a session-specific Git worktree
    /// on a unique provider branch. Gated by `isWorking` status.
    func forkToWorktree() async {
        guard let sid = sessionId else {
            self.items.append(.error(id: UUID(), text: "Cannot fork: No active session ID found."))
            return
        }
        guard !isWorking else {
            self.items.append(.error(id: UUID(), text: "Cannot fork: The agent is currently active. Please wait for the turn to complete."))
            return
        }

        self.items.append(.status(id: UUID(), text: "Creating isolated Git worktree for this session..."))

        let rawTitle = customTitle ?? displayTitle
        let cleanTitle = rawTitle.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let titleSlug = cleanTitle.isEmpty ? "untitled" : String(cleanTitle.prefix(40))
        let shortSid = String(sid.prefix(8))
        let branchName = "\(provider.rawValue)/\(titleSlug)-\(shortSid)"

        let homeDir = NSHomeDirectory()
        let worktreePath = (homeDir as NSString).appendingPathComponent(".soul/worktrees/\(project.id)/\(sid)")

        do {
            try await GitWorktreeService.addWorktree(
                projectPath: project.path,
                worktreePath: worktreePath,
                branchName: branchName
            )

            // Append WORKTREE_CREATED event to hooks
            SoulRegistry.appendHook(
                projectKey: project.id,
                sessionId: sid,
                event: LedgerHookEvent.worktreeCreated(
                    path: worktreePath,
                    branchName: branchName
                ).hookDictionary
            )

            // Update local project.path to point to the new worktree and arm
            // the removal watch. project.path is still the primary checkout
            // here, so capture it before adoptWorktree overwrites it.
            let primaryCheckout = self.project.path
            self.adoptWorktree(worktreePath, primaryCheckout: primaryCheckout)

            self.items.append(.status(
                id: UUID(),
                text: "↗ Forked successfully! Active directory isolated to branch: \(branchName)"
            ))
        } catch {
            self.items.append(.error(
                id: UUID(),
                text: "❌ Fork into worktree failed: \(error.localizedDescription). Running in main working tree."
            ))

            // Append WORKTREE_FALLBACK event to hooks
            SoulRegistry.appendHook(
                projectKey: project.id,
                sessionId: sid,
                event: [
                    "event": "WorktreeFallback",
                    "error": error.localizedDescription
                ]
            )
        }
    }

    /// Repoint this controller back to the primary checkout after its session
    /// worktree has been landed and removed. The inverse of `forkToWorktree`'s
    /// `self.project.path = worktreePath`. Because `SoulProject` is a value
    /// type and `ThreadController` is `@Observable`, mutating `project.path`
    /// re-fires `ComposerView`'s `.task(id: projectPath)`, so the branch label
    /// — and the working root the next turn spawns from — follow the primary
    /// branch instead of a now-deleted worktree directory. No-op if already
    /// rooted at the primary path.
    func detachFromWorktree(toPrimaryPath primaryPath: String) {
        teardownWorktreeWatch()
        guard project.path != primaryPath else { return }
        project.path = primaryPath
        items.append(.status(
            id: UUID(),
            text: "↩ Worktree landed — active directory back to the main checkout"
        ))
    }

    /// Point this controller at an isolated session worktree and arm a watch
    /// on the worktree's `.git` link. `forkToWorktree` and
    /// `SessionWorktreeProvisioner` both route through here, so the watch
    /// covers freshly-forked and resumed/adopted worktrees alike.
    func adoptWorktree(_ worktreePath: String, primaryCheckout: String) {
        project.path = worktreePath
        armWorktreeWatch(primaryCheckout: primaryCheckout)
    }

    /// A worktree checkout carries a `.git` *file* (a gitdir pointer) that
    /// `git worktree remove` deletes. Watch it: if it vanishes — via the
    /// in-app Land action *or* an out-of-band `git worktree remove` from a
    /// shell or another tool — repoint to the primary checkout, the same
    /// outcome `landSessionWorktree` produces in-process. Re-arming tears down
    /// any prior watch; safe no-op if the link can't be opened.
    private func armWorktreeWatch(primaryCheckout: String) {
        teardownWorktreeWatch()
        let gitLink = (project.path as NSString).appendingPathComponent(".git")
        let fd = open(gitLink, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.detachFromWorktree(toPrimaryPath: primaryCheckout)
            }
        }
        source.setCancelHandler { close(fd) }
        worktreeWatch = source
        source.resume()
    }

    private func teardownWorktreeWatch() {
        worktreeWatch?.cancel()  // the cancel handler closes the fd
        worktreeWatch = nil
    }
}

/// Shared classifier for Claude Code's `<local-command-*>` scaffolding. Used
/// by both the live ACP stream (`ThreadController.apply(_:.userMessageChunk)`)
/// and the read-first hydrate path (`ClaudeTranscriptReader`) so the two
/// surfaces never disagree on whether a caveat block should render as a user
/// bubble or as a compact status row.
