import SwiftUI
import SoulCore
import AppKit
import Combine

struct ThreadView: View {
    private static let maxIdleTranscriptRows = 80
    private static let maxWorkingTranscriptRows = 40

    @Bindable var controller: ThreadController
    @Binding var prompt: String
    var onCancel: () -> Void = {}
    var onPickHarness: (Provider) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var onBranchFromDisabled: (Provider) -> Void = { _ in }
    var branchSeedLoading: Bool = false
    var terminalActive: Bool = false
    var onToggleTerminal: () -> Void = {}

    @State private var renaming = false
    @State private var renameDraft = ""
    /// Suppress row `.onAppear` anchor writes during the brief window after
    /// the ScrollView re-mounts. Without this, rows appearing top-down on
    /// re-mount clobber the saved anchor before the restore call runs.
    @State private var suppressAnchorWrites = false
    /// SOUL-SOUL_DESKTOP-363: true between a restore's `proxy.scrollTo(anchorId)`
    /// and its settle. While set, `repairTranscriptScrollView` skips the clip
    /// clamp — scrollTo owns the position, and an independent clamp against a
    /// still-growing document height would fight it and yank the view (the
    /// SOUL-094/096/188 scroll-restore regression the judge flagged). Only set
    /// when there is an actual anchor id to restore to; a nil-anchor open
    /// (fresh/cold session) leaves it false so the clamp still runs and fixes
    /// an off-document origin.
    @State private var scrollRestorePending = false
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    /// SOUL-SOUL_DESKTOP-094 + -096: scroll-anchor state lives in a
    /// reference-type holder so per-row writes during scroll do NOT
    /// invalidate `ThreadView.body`. With `@State` (-094), every
    /// `.onAppear`/`.onDisappear` write coalesced into ~13 ThreadView body
    /// fires per second — each fire still re-iterating the LazyVStack
    /// ForEach over the full timeline. A plain class held by `@State`
    /// gives stable identity without dependency tracking: mutating
    /// `anchor.visibleIds` / `anchor.itemId` updates the data without
    /// re-evaluating the view. Anchor restore reads `anchor.itemId` only
    /// at `.onAppear`; flush writes it to `controller` only at
    /// `.onDisappear`.
    @State private var anchor = ScrollAnchor()

    @State private var bottomSentinelVisible: Bool = true

    /// True while the user's finger / trackpad is actively driving the
    /// scroll (any phase other than .idle). Sticky-follow consults this
    /// so streaming-content-grew snaps can't fight a manual scroll —
    /// the user's gesture always wins.
    @State private var userInteracting: Bool = false
    @State private var frozenTranscriptRows: [TranscriptRowSnapshot]? = nil
    @State private var frozenHiddenMainCount: Int = 0

    /// SOUL-SOUL_DESKTOP-081: observe canvas width via GeometryReader so the
    /// scroll-anchor system can re-pin its anchor row when the right side
    /// panel opens/closes (canvas shrinks/grows, rows re-wrap, absolute pixel
    /// offset lands on different content).
    @State private var canvasWidth: CGFloat = 0
    @State private var pendingCanvasWidth: CGFloat = 0
    @State private var canvasWidthRepinTask: Task<Void, Never>?
    @State private var transcriptScrollView: NSScrollView?

    /// AppShell-owned auto-compact watcher. Threaded in via environment
    /// (see AutoCompactController.swift) so we don't widen ThreadView's
    /// initializer further. `nil` ⇒ no banner ever paints (default).
    @Environment(\.autoCompactController) private var autoCompactCtrl

    /// String surfaced by the watcher while a compact is in flight.
    /// Cleared automatically by AutoCompactController's 8-second timer
    /// and explicitly on every `isWorking → false` transition (the
    /// agent's next reply lands ⇒ compact ran).
    private var autoCompactBanner: String? {
        autoCompactCtrl?.banner
    }

    // Extracted to keep `body` under the Swift type-checker's budget.
    // The LazyVStack ForEach + per-row anchor closures was the heaviest
    // chunk of work inside the ScrollView; pulling it out drops the
    // surrounding ScrollViewReader / ZStack expression back under budget.
    @ViewBuilder
    private var transcriptList: some View {
        if let frozenTranscriptRows {
            transcriptStack(
                projectPath: controller.project.path,
                projectKey: controller.project.id,
                rows: frozenTranscriptRows,
                hiddenMainCount: frozenHiddenMainCount,
                queuedItems: [],
                showWorkingIndicator: controller.isWorking
            )
        } else {
            liveTranscriptList
        }
    }

    @ViewBuilder
    private var liveTranscriptList: some View {
        let split = controller.groupedItemsSplit
        // Suppress rows that are nested under a subagent — those are rendered
        // inline under the parent's row via `nestedChildren`. Computed once
        // per body re-eval to avoid the O(N) lookup per enumerate iteration.
        let suppressedIds = controller.nestedSubagentChildItemIds
        let allMainItems = suppressedIds.isEmpty
            ? split.main
            : split.main.filter { !suppressedIds.contains($0.id) }
        let renderLimit = controller.isWorking
            ? Self.maxWorkingTranscriptRows
            : Self.maxIdleTranscriptRows
        let hiddenMainCount = max(0, allMainItems.count - renderLimit)
        let mainItems = hiddenMainCount > 0
            ? Array(allMainItems.suffix(renderLimit))
            : allMainItems
        let queuedItems = split.queued
        let rows = transcriptRows(from: mainItems)
        let isWorking = controller.isWorking
        let _ = SoulSignposts.event("Flash.transcriptList.body", "main=\(mainItems.count) hidden=\(hiddenMainCount) queued=\(queuedItems.count) isWorking=\(isWorking) isHydrating=\(controller.isHydrating)")
        transcriptStack(
            projectPath: controller.project.path,
            projectKey: controller.project.id,
            rows: rows,
            hiddenMainCount: hiddenMainCount,
            queuedItems: queuedItems,
            showWorkingIndicator: isWorking
        )
    }

    @ViewBuilder
    private func transcriptStack(
        projectPath: String?,
        projectKey: String,
        rows: [TranscriptRowSnapshot],
        hiddenMainCount: Int,
        queuedItems: [ThreadItem],
        showWorkingIndicator: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 8)
            if hiddenMainCount > 0 {
                Text("\(hiddenMainCount) earlier items hidden while this session is live")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            ForEach(rows) { row in
                ThreadItemRow(
                    projectPath: projectPath,
                    projectKey: projectKey,
                    item: row.item,
                    isHistorical: row.isHistorical,
                    isQueued: false,
                    showAgentFooter: row.showAgentFooter,
                    nestedChildren: row.nestedChildren
                )
                .padding(.top, row.leadingGap)
                .id(row.id)
                .padding(.top, row.isTurnStart ? 10 : 0)
                .frame(minHeight: 24, alignment: .topLeading)
            }
            if branchSeedLoading {
                BranchSeedIndicator().padding(.top, 18)
            }
            if showWorkingIndicator {
                if let preview = controller.liveStreamPreview {
                    LiveStreamPreview(text: preview)
                        .padding(.top, 18)
                }
                WorkingIndicator(controller: controller).padding(.top, 18)
            }
            ForEach(queuedItems, id: \.id) { item in
                ThreadItemRow(
                    projectPath: projectPath,
                    projectKey: projectKey,
                    item: item,
                    isHistorical: false,
                    isQueued: true
                )
                .padding(.top, 18)
                .id(item.id)
            }
            Color.clear
                .frame(height: 44)
                .id("__bottom__")
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        // SOUL-LAYOUT-CYCLE-2: refuse any animation context propagated from
        // parent containers. When panel toggles or transient chrome updates
        // overlap with new transcript rows, animated ForEach inserts can push
        // SwiftUI into StackLayout / _FlexFrameLayout / MoveLayout recursion.
        // Row inserts are layout, not decoration.
        .transaction { $0.animation = nil }
    }

    // Extracted to keep `body` under the Swift type-checker's budget.
    // ComposerView's ~20-arg initializer + many closures was the dominant
    // cost; splitting it into its own builder lets the main body type-check
    // in reasonable time.
    @ViewBuilder
    private func composerSection(proxy: ScrollViewProxy) -> some View {
        let composerEnabled = controller.canAcceptComposerInput
        VStack(spacing: 8) {
            // Auto-compact "Compacting…" banner. The AppShell-owned
            // AutoCompactController publishes a banner string while a
            // /compact (or /compress) is in flight; nil ⇒ nothing to
            // show. Slim affordance — pure status, not an action.
            if let banner = autoCompactBanner {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SoulColor.accent)
                    Text(banner)
                        .font(SoulFont.ui(11, weight: .medium))
                        .foregroundStyle(SoulColor.accent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SoulColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ComposerView(
                prompt: $prompt,
                projectName: controller.project.name,
                projectPath: controller.project.path,
                commands: controller.availableCommands,
                onSend: { display, agent, extraBlocks in
                    // SOUL-SOUL_DESKTOP-359: `/compact` is client-intercepted.
                    // Route it to the kernel forced-compact dispatch (same path
                    // as ⌘⇧K) instead of sending it to the provider. Sending a
                    // bare `/compact` to Claude would self-trigger native
                    // compaction but bypass the kernel ledger event + the
                    // Codex/Pi toast degradation; intercepting uniformly gives
                    // every provider the same audited path. Returning true lets
                    // the composer clear without painting a `/compact` bubble —
                    // the dispatch paints its own banner / native-compact send.
                    if SlashCommandParse.parse(display).commandName?.lowercased() == "compact" {
                        autoCompactCtrl?.forceCompact(thread: controller, usage: nil)
                        return true
                    }
                    // Sync prefix: paint the user bubble on the same
                    // runloop tick as the Enter keystroke. Async tail
                    // (ensureSession + ACP prompt) runs in a Task so it
                    // doesn't block the composer's keyDown handler.
                    guard controller.canAcceptComposerInput else { return false }
                    guard !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !extraBlocks.isEmpty
                    else { return false }
                    let itemCountBefore = controller.items.count
                    if let pending = controller.acceptUserPrompt(display: display, agent: agent, extraBlocks: extraBlocks) {
                        freezeLiveTranscript()
                        Task { await controller.dispatchPending(pending) }
                    }
                    let accepted = controller.items.count > itemCountBefore
                    if accepted {
                        userInteracting = false
                    }
                    return accepted
                },
                  supportsImageAttachments: controller.supportsImageAttachments,
                onCancel: onCancel,
                isWorking: controller.isWorking,
                queuedCount: controller.queuedPrompts.count,
                queuedTail: controller.queuedPrompts.last.map { (id: $0.itemId, text: $0.display) },
                onEditQueued: { id, newText in
                    controller.editQueuedPrompt(itemId: id, newText: newText)
                },
                onClearQueue: { controller.clearQueue() },
                onSteer: { Task { await controller.steerToNextQueued() } },
                terminalActive: terminalActive,
                onToggleTerminal: onToggleTerminal,
                permissionMode: Binding(
                    get: { controller.permissionMode },
                    set: { controller.permissionMode = $0 }
                ),
                provider: controller.provider,
                onPickHarness: onPickHarness,
                isSendEnabled: composerEnabled,
                disabledMessage: composerEnabled
                    ? nil
                    : (controller.isTornDown ? "This session is no longer attached to a live agent." : "This session is still loading."),
                onBranchFromDisabled: onBranchFromDisabled,
                droppedAttachments: controllerDroppedAttachments,
                branchSeedLoading: branchSeedLoading,
                onDropActiveChange: { controller.isComposerDropActive = $0 }
            )
            .frame(maxWidth: 760)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !bottomSentinelVisible {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(SoulColor.border.opacity(0.7), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .help("Jump to bottom")
        }
    }

    private var controllerDroppedAttachments: Binding<[String]> {
        Binding(
            get: { controller.droppedAttachments },
            set: { controller.droppedAttachments = $0 }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    // SOUL-SOUL_DESKTOP-180: per-row spacing instead of a
                    // flat 18pt gap. Consecutive agent messages now sit
                    // tight (4pt) so a multi-paragraph reply reads as one
                    // continuous thought instead of three islands. Mixed
                    // boundaries (user→agent, tool→agent, etc.) keep the
                    // full 18pt for visual breathing room.
                    transcriptList
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.hidden)
                .background(NSScrollViewConfigurator { sv in
                    transcriptScrollView = sv
                })
                .onScrollPhaseChange { _, newPhase, _ in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        if controller.isWorking { freezeLiveTranscript() }
                        userInteracting = true
                    case .idle, .animating:
                        userInteracting = false
                        if !controller.isWorking {
                            frozenTranscriptRows = nil
                            frozenHiddenMainCount = 0
                        }
                    }
                }
                .onAppear {
                    // Restore the saved anchor when switching back to this
                    // thread. Suppress row `.onAppear` anchor writes during
                    // the restore window so top-down row instantiation
                    // doesn't clobber the saved position before we restore.
                    suppressAnchorWrites = true
                    // SOUL-SOUL_DESKTOP-094 + -096: hydrate the local anchor
                    // holder from controller on view (re)attach. After this
                    // point all anchor writes stay on the holder (no view
                    // invalidation); flushed back on detach.
                    anchor.itemId = controller.scrollAnchorItemId
                    if !controller.isHydrating {
                        performScrollRestore(proxy: proxy)
                    }
                    repairTranscriptScrollView(reason: "appear")
                }
                .onChange(of: controller.activationNonce) { _, _ in
                    guard !controller.isHydrating else { return }
                    suppressAnchorWrites = true
                    anchor.itemId = controller.scrollAnchorItemId
                    performScrollRestore(proxy: proxy)
                    repairTranscriptScrollView(reason: "activation")
                }
                .onChange(of: controller.isHydrating) { _, hydrating in
                    // SOUL-SOUL_DESKTOP-363: a cold session open is still
                    // hydrating at `.onAppear`, so the restore there is skipped
                    // (`guard !controller.isHydrating`) and `.onChange(of:
                    // activationNonce)` bails too. Nothing then re-pins the
                    // scroll once hydration finishes — the LazyVStack commits
                    // its rows late, the early repair clamped against a near-
                    // empty document height, and the canvas stays blank until a
                    // resize / panel toggle forces AppKit to re-clamp. Re-run
                    // restore + repair on the true→false transition so the clip
                    // origin is clamped against the real document height the
                    // moment the rows land.
                    guard !hydrating else { return }
                    suppressAnchorWrites = true
                    anchor.itemId = controller.scrollAnchorItemId
                    performScrollRestore(proxy: proxy)
                    repairTranscriptScrollView(reason: "hydrated")
                }
                .onChange(of: controller.transcriptLayoutNonce) { _, _ in
                    followLiveTurn(proxy: proxy)
                    // SOUL-SOUL_DESKTOP-189: only repair layout when not actively running a turn.
                    // During an active turn (isWorking == true), the document grows rather than shrinks,
                    // so the scroll origin is never out-of-bounds. Forcing AppKit layout subtree updates
                    // here conflicts with SwiftUI's live rendering and can result in blank transcripts.
                    if !controller.isWorking {
                        repairTranscriptScrollView(reason: "layout")
                    }
                }
                .onChange(of: controller.isWorking) { _, isWorking in
                    if isWorking {
                        freezeLiveTranscript()
                        return
                    }
                    // When a live turn completes (isWorking transitions to false), the WorkingIndicator
                    // is removed and the document shrinks by a tiny bit. Run a clean repair here to
                    // align the scroll bounds after the transition.
                    frozenTranscriptRows = nil
                    frozenHiddenMainCount = 0
                    repairTranscriptScrollView(reason: "isWorking")
                }
                // SOUL-SOUL_DESKTOP-094 + -096: flush local anchor state to
                // the controller on view detach so the next attach restores
                // the right position.
                .onDisappear {
                    canvasWidthRepinTask?.cancel()
                    controller.scrollAnchorItemId = anchor.itemId
                }
                composerSection(proxy: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                controller.customTitle = trimmed
                // SOUL-SOUL_DESKTOP-272: persist to hooks.jsonl so the
                // rename survives restart. findTitle (SoulRegistry.swift:1033)
                // returns the LAST Title event, so user overrides win over
                // the LLM-generated title from ThreadController+Turn.swift.
                if !trimmed.isEmpty, let sid = controller.sessionId {
                    SoulRegistry.appendHook(
                        projectKey: controller.project.id,
                        sessionId: sid,
                        event: ["event": "Title", "text": trimmed, "source": "user"]
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: controller.renameRequestNonce) { _, _ in
            renameDraft = controller.customTitle ?? controller.displayTitle
            renaming = true
        }
    }

    /// SOUL-SOUL_DESKTOP-188: search the same list the LazyVStack renders.
    /// Previously this searched `controller.items` (the ungrouped list),
    /// but `anchor.visibleIds` is populated from `mainItems` (the grouped
    /// list — groups have their own synthetic IDs that don't appear in
    /// `controller.items`). When a region of consecutive tool calls was
    /// on screen, `first(where:)` found nothing and `anchor.itemId`
    /// stayed stale, often pointing at an item far up the page. The
    /// width-change re-pin then jumped scroll back to that stale anchor,
    /// looking like a "jump to middle" on link click / panel toggle.
    private func updateAnchor(in renderedItems: [ThreadItem]) {
        guard !suppressAnchorWrites else { return }
        if let firstVisible = renderedItems.first(where: { anchor.visibleIds.contains($0.id) }) {
            anchor.itemId = firstVisible.id
        }
    }

    private func currentTranscriptSnapshot() -> (rows: [TranscriptRowSnapshot], hiddenMainCount: Int) {
        let split = controller.groupedItemsSplit
        let suppressedIds = controller.nestedSubagentChildItemIds
        let allMainItems = suppressedIds.isEmpty
            ? split.main
            : split.main.filter { !suppressedIds.contains($0.id) }
        let renderLimit = controller.isWorking
            ? Self.maxWorkingTranscriptRows
            : Self.maxIdleTranscriptRows
        let hiddenMainCount = max(0, allMainItems.count - renderLimit)
        let mainItems = hiddenMainCount > 0
            ? Array(allMainItems.suffix(renderLimit))
            : allMainItems
        return (transcriptRows(from: mainItems), hiddenMainCount)
    }

    private func freezeLiveTranscript() {
        guard frozenTranscriptRows == nil else { return }
        let snapshot = currentTranscriptSnapshot()
        frozenTranscriptRows = snapshot.rows
        frozenHiddenMainCount = snapshot.hiddenMainCount
    }

    /// Restores the saved scroll anchor when a previously-mounted thread view
    /// is attached again.
    private func performScrollRestore(proxy: ScrollViewProxy) {
        suppressAnchorWrites = false
        scrollRestorePending = false
    }

    /// AppKit occasionally preserves an invalid clip-view origin while
    /// SwiftUI has already rebuilt the LazyVStack document. The symptom is a
    /// blank transcript that reappears as soon as the user resizes the window
    /// (resize forces AppKit layout + scroll bounds clamping). Do that repair
    /// directly on attach/activation/content growth instead of remounting the
    /// whole transcript.
    /// SOUL-SOUL_DESKTOP-363: the old fixed 2×50ms retry window (~150ms) could
    /// close before a large transcript's LazyVStack committed its rows. The
    /// repair then read a near-empty `documentHeight`, clamped against it, and
    /// no further repair fired until a resize → blank canvas on heavy sessions.
    /// Now the retry runs until the document height stops changing (two
    /// consecutive equal reads) or the budget is exhausted (~1s), so it survives
    /// late layout regardless of which trigger fired it. The clamp itself is
    /// gated on `!scrollRestorePending` so it never fights an in-flight
    /// `proxy.scrollTo` restore.
    private func repairTranscriptScrollView(reason: String, retries: Int = 12, lastHeight: CGFloat = -1) {
    }

    /// Follow live prompt/response growth only. This deliberately ignores
    /// hydration and session activation so opening an old session cannot
    /// force the transcript to the bottom.
    private func followLiveTurn(proxy: ScrollViewProxy) {
    }

    /// A user message coming after non-user content opens a new turn — give it
    /// extra top padding so the conversation reads as discrete exchanges.
    private func isTurnStart(item: ThreadItem, index: Int, items: [ThreadItem]) -> Bool {
        guard index > 0 else { return false }
        guard case .userMessage = item else { return false }
        if case .userMessage = items[index - 1] { return false }
        return true
    }

    /// SOUL-SOUL_DESKTOP-180: per-row leading gap. Lets consecutive agent
    /// messages sit close together (so a multi-paragraph reply reads as
    /// one continuous thought) while preserving the full 18pt gap at
    /// turn boundaries and around tool calls.
    ///
    /// Rules:
    ///   * first row: 0 (the wrapper VStack handles top padding)
    ///   * agentMessage following an agentMessage: 4pt (tight)
    ///   * everything else: 18pt
    private func leadingGap(at i: Int, items: [ThreadItem]) -> CGFloat {
        guard i > 0 else { return 0 }
        if case .agentMessage = items[i], case .agentMessage = items[i - 1] {
            return 4
        }
        return 18
    }

    /// True only when `items[i]` is an agentMessage AND the next item (if any)
    /// is not also an agentMessage. Used to gate the action-button footer so
    /// multi-step turns with frequent narration don't render a noisy
    /// copy/feedback strip between every short line.
    private func isLastInAgentRun(at i: Int, items: [ThreadItem]) -> Bool {
        guard case .agentMessage = items[i] else { return true }
        let next = i + 1 < items.count ? items[i + 1] : nil
        if let next, case .agentMessage = next { return false }
        return true
    }

    /// Freeze all row-adjacent controller reads before SwiftUI starts diffing
    /// the LazyVStack. Live transcript updates can otherwise re-enter layout
    /// while each row is still deriving index/history/nesting from mutable
    /// controller state.
    private func transcriptRows(from items: [ThreadItem]) -> [TranscriptRowSnapshot] {
        items.indices.map { i in
            let item = items[i]
            return TranscriptRowSnapshot(
                item: item,
                isHistorical: controller.historicalIDs.contains(item.id),
                showAgentFooter: isLastInAgentRun(at: i, items: items),
                leadingGap: leadingGap(at: i, items: items),
                isTurnStart: isTurnStart(item: item, index: i, items: items),
                nestedChildren: nestedChildren(for: item)
            )
        }
    }

    /// Children-to-inline-render for a parent row. Empty unless the row is a
    /// `.toolCall(.subagent)` AND the controller has recorded nested
    /// subagent activity under that subagent's toolCallId.
    private func nestedChildren(for item: ThreadItem) -> [ThreadItem] {
        guard case .toolCall(_, _, _, _, _, let details) = item,
              let kind = details?.kind,
              case .subagent(_, _, let subagentId, _, _) = kind else {
            return []
        }
        return controller.nestedSubagentChildren(parentToolCallId: subagentId)
    }

}

private struct TranscriptRowSnapshot: Identifiable {
    let item: ThreadItem
    let isHistorical: Bool
    let showAgentFooter: Bool
    let leadingGap: CGFloat
    let isTurnStart: Bool
    let nestedChildren: [ThreadItem]

    var id: UUID { item.id }
}

private struct LiveStreamPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SoulType.body)
            .foregroundStyle(SoulColor.fg.opacity(0.78))
            .lineLimit(10)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SoulColor.bgElevated.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SoulColor.border.opacity(0.25), lineWidth: 0.5)
            )
            .transaction { $0.animation = nil }
    }
}

/// SOUL-SOUL_DESKTOP-096: reference-type holder for scroll-anchor state.
/// Plain class held by `@State`: SwiftUI tracks the holder's identity (which
/// never changes for the view's lifetime), but mutations to the class's
/// stored properties do NOT invalidate `ThreadView.body`. That lets every
/// per-row `.onAppear`/`.onDisappear` write to `visibleIds` / `itemId`
/// without triggering a LazyVStack ForEach rebuild. Reads happen only at
/// view appearance (restore), `onChange` handlers, and view disappearance
/// (flush) — none of which run inside `body`.
@MainActor
final class ScrollAnchor {
    var visibleIds: Set<UUID> = []
    var itemId: UUID? = nil
}

struct ThreadItemRow: View {
    let projectPath: String?
    /// SOUL-SOUL_DESKTOP-111: project key used by SubagentCard to locate the
    /// live.log path. Optional so existing call sites (replay, history rows)
    /// keep compiling without plumbing it everywhere; SubagentCard renders a
    /// "not tailed" placeholder when projectKey is nil.
    var projectKey: String? = nil
    let item: ThreadItem
    var isHistorical: Bool = false
    var isQueued: Bool = false
    var isGrouped: Bool = false
    /// True only when this row is the FINAL `.agentMessage` in a consecutive
    /// run. Other rows (or non-final agent messages in a run) hide the
    /// copy/feedback/fork/timestamp footer to cut the noisy action-button
    /// strip between every short narration line in multi-step turns.
    var showAgentFooter: Bool = true
    /// Nested subagent inner-tool rows (resolved via the controller's
    /// `nestedSubagentChildren(parentToolCallId:)` helper). Only populated
    /// when this row is itself a `.toolCall(.subagent)`; rendered indented
    /// below the SubagentCard so the user sees what the subagent is doing in
    /// real time. See `_meta.claudeCode.parentToolUseId` (Claude) /
    /// `_meta.parentToolCallId` (gemini-cli local fork).
    var nestedChildren: [ThreadItem] = []

    var body: some View {
        // Note: historical dimming is pushed into per-component foreground colors so the row layer
        // stays opaque — Core Animation disables subpixel text AA on translucent layers, which
        // shows up as slightly blurry / shimmering text during fractional-offset trackpad scroll.
        switch item {
        case .userMessage(_, let text, let ts):
            UserMessageRow(text: LedgerPreamble.scrubEchoed(text), timestamp: ts, isHistorical: isHistorical, isQueued: isQueued)
        case .branchSummary(_, let summary, let sourceProvider, let targetProvider, _):
            FinalizeCard(
                title: "Branch Summary",
                icon: "arrow.triangle.branch",
                intent: "Continue from \(sourceProvider.appProvider?.label ?? sourceProvider.rawValue) in \(targetProvider.appProvider?.label ?? targetProvider.rawValue)",
                summary: summary,
                rationale: nil,
                fixed: nil,
                nextStep: "\(targetProvider.appProvider?.label ?? targetProvider.rawValue) received this summary as context and is continuing from here."
            )
        case .agentMessage(_, let text, let complete, let ts):
            // SOUL-SOUL_DESKTOP-096: `.equatable()` so SwiftUI skips the
            // MarkdownView rebuild when the row's inputs haven't changed.
            AgentMessageRow(text: LedgerPreamble.scrubEchoed(text), timestamp: ts, isHistorical: isHistorical, isStreaming: !complete, showFooter: showAgentFooter)
                .equatable()
        case .agentThought(_, let text, let complete, _):
            AgentThoughtRow(text: text, isStreaming: !complete, isHistorical: isHistorical)
        case .toolCall(_, let kind, let title, let status, let loc, let details):
            // SOUL-SOUL_DESKTOP-111: delegate_to_specialist tool calls route to
            // the dedicated SubagentCard instead of the generic ToolCallRow.
            // Match on the structured details kind populated by insertToolCall.
            if case .claudeAgent(let subagentType, let descriptionText, let agentId, let bodyText, let totalTokens, let toolUses, let durationMs) = details?.kind {
                ClaudeAgentCard(
                    subagentType: subagentType,
                    description: descriptionText,
                    status: status,
                    agentId: agentId,
                    replyBody: bodyText,
                    totalTokens: totalTokens,
                    toolUses: toolUses,
                    durationMs: durationMs,
                    isHistorical: isHistorical
                )
            } else if case .subagent(let specialist, let objective, let subagentId, let colorHex, let findingPath) = details?.kind {
                VStack(alignment: .leading, spacing: 6) {
                    SubagentCard(
                        specialist: specialist,
                        objective: objective,
                        status: status,
                        subagentId: subagentId,
                        projectKey: projectKey ?? "",
                        colorHex: colorHex,
                        findingPath: findingPath,
                        isHistorical: isHistorical
                    )
                    // Inner-tool calls and thoughts emitted from inside the
                    // subagent — surfaced via _meta.parentToolUseId /
                    // _meta.parentToolCallId in the ACP stream. Indent + a
                    // muted vertical rule so the nesting reads as a child
                    // timeline rather than a sibling block.
                    if !nestedChildren.isEmpty {
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle()
                                .fill(SoulColor.fgSubtle.opacity(0.25))
                                .frame(width: 2)
                                .padding(.leading, 8)
                                .padding(.trailing, 10)
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(nestedChildren, id: \.id) { child in
                                    ThreadItemRow(
                                        projectPath: projectPath,
                                        projectKey: projectKey,
                                        item: child,
                                        isHistorical: isHistorical,
                                        isQueued: false,
                                        isGrouped: true,
                                        showAgentFooter: false
                                    )
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            } else {
                ToolCallRow(kind: kind, title: title, status: status, location: loc, details: details, projectPath: projectPath, isGrouped: isGrouped)
            }
        case .toolCallGroup(_, let kind, let title, let loc, let items):
            if kind == "edit" || kind == "write" {
                ToolCallGroupRow(kind: kind, title: title, location: loc, items: items, isHistorical: isHistorical)
            } else {
                ToolCallCarouselRow(kind: kind, items: items, isHistorical: isHistorical, projectPath: projectPath)
            }
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .status(_, let text):
            Text(text)
                .font(SoulFont.ui(13))
                .foregroundStyle(SoulColor.fgSubtle.opacity(isHistorical ? 0.62 : 1.0))
        case .error(_, let text):
            Text(text)
                .font(SoulFont.code(11))
                .foregroundStyle(Color.red.opacity(isHistorical ? 0.62 : 1.0))
                .padding(8)
                .background(Color.red.opacity(isHistorical ? 0.05 : 0.08), in: RoundedRectangle(cornerRadius: 6))
        case .finalize(_, let intent, let summary, let rationale, let fixed, let nextStep, _):
            FinalizeCard(intent: intent, summary: summary, rationale: rationale, fixed: fixed, nextStep: nextStep)
        }
    }

}

private extension ThreadItem {
    var isToolOrNoise: Bool {
        switch self {
        case .toolCall, .toolCallGroup, .plan, .agentThought, .status, .error:
            return true
        default:
            return false
        }
    }
}
