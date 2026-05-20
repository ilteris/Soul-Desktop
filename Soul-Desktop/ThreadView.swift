import SwiftUI
import AppKit
import Combine

struct ThreadView: View {
    @Bindable var controller: ThreadController
    @Binding var prompt: String
    var onCancel: () -> Void = {}
    var onPickHarness: (Provider) -> Void = { _ in }
    var onNewChat: () -> Void = {}
    var branchSeedLoading: Bool = false
    var terminalActive: Bool = false
    var onToggleTerminal: () -> Void = {}

    @State private var renaming = false
    @State private var renameDraft = ""
    /// Suppress row `.onAppear` anchor writes during the brief window after
    /// the ScrollView re-mounts. Without this, rows appearing top-down on
    /// re-mount clobber the saved anchor (and flip `scrollAnchorAtBottom`
    /// false) before the restore call runs.
    @State private var suppressAnchorWrites = false
    /// SOUL-SOUL_DESKTOP-233: true for ~0.4s after `isHydrating` flips false.
    /// Gates the .onChange(items.count) auto-scroll so it doesn't fight the
    /// two-pass scrollTo that the .onChange(isHydrating) handler is running.
    @State private var recentlyHydrated = false
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    /// SOUL-SOUL_DESKTOP-094 + -096: scroll-anchor state lives in a
    /// reference-type holder so per-row writes during scroll do NOT
    /// invalidate `ThreadView.body`. With `@State` (-094), every
    /// `.onAppear`/`.onDisappear` write coalesced into ~13 ThreadView body
    /// fires per second — each fire still re-iterating the LazyVStack
    /// ForEach over the full timeline. A plain class held by `@State`
    /// gives stable identity without dependency tracking: mutating
    /// `anchor.visibleIds` / `anchor.itemId` updates the data without
    /// re-evaluating the view. Anchor restore reads `anchor.atBottom` /
    /// `anchor.itemId` only at `.onAppear`; flush writes them to
    /// `controller` only at `.onDisappear`.
    @State private var anchor = ScrollAnchor()

    /// SOUL-SOUL_DESKTOP-081: observe canvas width via GeometryReader so the
    /// scroll-anchor system can re-pin its anchor row when the right side
    /// panel opens/closes (canvas shrinks/grows, rows re-wrap, absolute pixel
    /// offset lands on different content).
    @State private var canvasWidth: CGFloat = 0

    /// SOUL-SOUL_DESKTOP-146: drag-target state lifted from ComposerView so
    /// the whole ThreadView accepts image/file drops, not just the composer
    /// chip strip. Bound into ComposerView so the chips render and submit
    /// behavior stays unchanged.
    @State private var droppedAttachments: [String] = []
    @State private var isImageDropTargeted: Bool = false

    var body: some View {
        // SOUL-SOUL_DESKTOP-099: permanent scroll-perf telemetry.
        let _ = SoulSignposts.event("ThreadView.body")
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack {
                ScrollView {
                    // SOUL-SOUL_DESKTOP-180: per-row spacing instead of a
                    // flat 18pt gap. Consecutive agent messages now sit
                    // tight (4pt) so a multi-paragraph reply reads as one
                    // continuous thought instead of three islands. Mixed
                    // boundaries (user→agent, tool→agent, etc.) keep the
                    // full 18pt for visual breathing room.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 8)
                        let split = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
                        let mainItems = split.main
                        let queuedItems = split.queued
                        ForEach(Array(mainItems.enumerated()), id: \.element.id) { i, item in
                            ThreadItemRow(
                                projectPath: controller.project.path,
                                projectKey: controller.project.id,
                                item: item,
                                isHistorical: controller.historicalIDs.contains(item.id),
                                isQueued: false,
                                showAgentFooter: isLastInAgentRun(at: i, items: mainItems)
                            )
                                .padding(.top, leadingGap(at: i, items: mainItems))
                                .id(item.id)
                                .padding(.top, isTurnStart(item: item, index: i, items: mainItems) ? 10 : 0)
                                // SOUL-SOUL_DESKTOP-192: floor every row at the
                                // status-row height. Gives LazyVStack a non-zero
                                // baseline so the scrollbar thumb tracks closer
                                // to true contentSize, mitigating the fast-drag
                                // blank-band without eagerly rendering bubbles.
                                .frame(minHeight: 24, alignment: .topLeading)
                                .onAppear {
                                    // SOUL-SOUL_DESKTOP-233: row anchor writes
                                    // must respect suppressAnchorWrites. Without
                                    // this guard, rows mounting after hydrate
                                    // landed an empty ScrollView would clobber
                                    // the saved anchor before performScrollRestore
                                    // had a chance to run, producing
                                    // top/middle/bottom inconsistency on session
                                    // open.
                                    guard !suppressAnchorWrites else { return }
                                    anchor.visibleIds.insert(item.id)
                                    updateAnchor(in: mainItems)
                                }
                                .onDisappear {
                                    guard !suppressAnchorWrites else { return }
                                    anchor.visibleIds.remove(item.id)
                                    updateAnchor(in: mainItems)
                                }
                        }
                        if branchSeedLoading {
                            BranchSeedIndicator()
                                .padding(.top, 18)
                        }
                        if controller.isWorking {
                            WorkingIndicator(controller: controller)
                                .padding(.top, 18)
                        }
                        ForEach(queuedItems, id: \.id) { item in
                            ThreadItemRow(
                                projectPath: controller.project.path,
                                projectKey: controller.project.id,
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
                            .onAppear {
                                guard !suppressAnchorWrites else { return }
                                anchor.atBottom = true
                            }
                            .onDisappear {
                                guard !suppressAnchorWrites else { return }
                                anchor.atBottom = false
                            }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
                // Vertical bounce always on (so reaching top/bottom rubber-bands
                // — natural macOS feel). Horizontal elasticity killed via the
                // AppKit configurator since the canvas never scrolls X.
                .scrollBounceBehavior(.always, axes: .vertical)
                .background(NSScrollViewConfigurator { sv in
                    sv.horizontalScrollElasticity = .none
                })
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
                    anchor.atBottom = controller.scrollAnchorAtBottom
                    anchor.itemId = controller.scrollAnchorItemId
                    // SOUL-SOUL_DESKTOP-233: if hydrate is already done (we're
                    // re-attaching to a thread whose items have been loaded
                    // for a while), restore immediately. Otherwise wait for
                    // isHydrating to flip false - see the .onChange below.
                    // The pre-fix path ran the restore on mount unconditionally,
                    // which raced against the still-empty items list and left
                    // the ScrollView in an undefined position.
                    if !controller.isHydrating {
                        performScrollRestore(proxy: proxy)
                    }
                }
                .onChange(of: controller.isHydrating) { _, nowHydrating in
                    // SOUL-SOUL_DESKTOP-233: fresh session open lands at the
                    // bottom — that's where the conclusion of the conversation
                    // is, and that's what the user came to see.
                    //
                    // The earlier fix scrolled to "__bottom__" (a trailing
                    // Color.clear marker AFTER the ForEach). On long
                    // transcripts this landed in the middle because LazyVStack
                    // hadn't materialized the bottom rows yet, so SwiftUI's
                    // position estimate for the marker was wrong. Scrolling
                    // to the LAST REAL ITEM's id instead is reliable —
                    // LazyVStack materializes it on demand and lands precisely
                    // because the item's own height anchors the calculation.
                    guard !nowHydrating else { return }
                    anchor.atBottom = true
                    recentlyHydrated = true
                    // Resolve target id once: prefer the very last visible
                    // row (queued or main). Fall back to __bottom__ only if
                    // items is somehow empty.
                    let splitInit = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
                    let targetId: AnyHashable = {
                        if let lastQueued = splitInit.queued.last { return lastQueued.id }
                        if let lastMain = splitInit.main.last { return lastMain.id }
                        return "__bottom__"
                    }()
                    // Two passes: first warms the LazyVStack to materialize
                    // rows near the target; second corrects after layout
                    // settles. Most sessions only need pass 1, but very
                    // long transcripts need pass 2.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(targetId, anchor: .bottom)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            proxy.scrollTo(targetId, anchor: .bottom)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                suppressAnchorWrites = false
                                recentlyHydrated = false
                                let splitNow = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
                                updateAnchor(in: splitNow.main)
                            }
                        }
                    }
                }
                .onChange(of: controller.items.count) { _, _ in
                    // Follow the stream while a turn is active — the user
                    // just sent, they want to see the response land. Outside
                    // of a working turn, only follow if they were already at
                    // the bottom.
                    //
                    // SOUL-SOUL_DESKTOP-233: skip during the post-hydrate
                    // window. The hydrate handler is running a two-pass
                    // scrollTo; an animated scrollTo from here lands in the
                    // middle because the LazyVStack hasn't materialized the
                    // bottom rows yet, and the two calls would fight.
                    guard !recentlyHydrated else { return }
                    guard anchor.atBottom || controller.isWorking else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                .onChange(of: controller.isWorking) { _, newValue in
                    // Transitioning into a working turn: snap to bottom even
                    // if the count didn't change (e.g., the first user row
                    // already landed before this view observed the change).
                    guard newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
                // SOUL-SOUL_DESKTOP-081: re-pin the anchor when canvas width
                // changes (right side panel opens / closes / resizes).
                // Without this, LazyVStack row remeasurement leaves
                // ScrollView's absolute offset pointing at different content.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { canvasWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in
                                canvasWidth = newWidth
                            }
                    }
                )
                .onChange(of: canvasWidth) { _, _ in
                    // SOUL-SOUL_DESKTOP-188: with the anchor source-of-truth
                    // fixed (updateAnchor now searches the rendered list,
                    // not controller.items), re-pinning on width change
                    // correctly keeps the topmost-visible item at the
                    // viewport top — preserving the user's reading
                    // position when the file preview panel opens or
                    // closes. The -184 "skip re-pin unless at bottom"
                    // workaround was a band-aid for the stale-anchor bug
                    // and is no longer needed.
                    guard !suppressAnchorWrites else { return }
                    if anchor.atBottom {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    } else if let id = anchor.itemId {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                // SOUL-SOUL_DESKTOP-094 + -096: flush local anchor state to
                // the controller on view detach so the next attach restores
                // the right position.
                .onDisappear {
                    controller.scrollAnchorAtBottom = anchor.atBottom
                    controller.scrollAnchorItemId = anchor.itemId
                }
                // SOUL-SOUL_DESKTOP-231: skeleton renders as a peer of the
                // ScrollView inside a ZStack, NOT as an .overlay on the
                // ScrollView, and the cross-fade .animation(value:) is
                // attached to the ZStack — not the ScrollView. Earlier
                // attempt put .overlay { ... }.animation(value: isHydrating)
                // on the ScrollView itself; that installed an animation
                // context spanning the entire LazyVStack subtree. Combined
                // with row-level .fixedSize markdown and concurrent
                // items.count growth + a scroll gesture during streaming,
                // SwiftUI's ideal-size negotiation never converged and the
                // main thread spun in StackLayout/_FlexFrameLayout/MoveTransition
                // recursion until the stack overflowed.
                if controller.isHydrating {
                    ThreadSkeletonView()
                        .background(SoulColor.bg)
                        .transition(.opacity)
                }
                }
                .animation(.easeOut(duration: 0.18), value: controller.isHydrating)
            }

            VStack(spacing: 8) {
                ComposerView(
                    prompt: $prompt,
                    projectName: controller.project.name,
                    projectPath: controller.project.path,
                    commands: controller.availableCommands,
                    onSend: { display, agent in
                        // Sync prefix: paint the user bubble on the same
                        // runloop tick as the Enter keystroke. Async tail
                        // (ensureSession + ACP prompt) runs in a Task so it
                        // doesn't block the composer's keyDown handler.
                        guard let pending = controller.acceptUserPrompt(display: display, agent: agent) else { return }
                        Task { await controller.dispatchPending(pending) }
                    },
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
                    isImageDropTargeted: $isImageDropTargeted,
                    droppedAttachments: $droppedAttachments,
                    branchSeedLoading: branchSeedLoading
                )
                .frame(maxWidth: 760)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // SOUL-SOUL_DESKTOP-147: dashed-border drop-target affordance now
        // traces the whole ThreadView so the user can see exactly where
        // drops will land. Inset slightly so the border doesn't clip
        // against the window chrome.
        .overlay {
            RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                .strokeBorder(
                    SoulColor.accent,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .padding(8)
                .opacity(isImageDropTargeted ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isImageDropTargeted)
                .allowsHitTesting(false)
        }
        // SOUL-SOUL_DESKTOP-146: whole-canvas drop target. Drops anywhere
        // in the ThreadView area land in `droppedAttachments`, which the
        // composer below renders as chips and submits as markdown links.
        // The composer keeps its own inner `.onDrop` too — innermost wins
        // for drops directly on it, but both write through the same
        // Binding so the canvas-wide highlight tracks targeting state.
        .onDrop(
            of: DropAttachmentHandler.acceptedTypes,
            isTargeted: $isImageDropTargeted
        ) { providers in
            let new = DropAttachmentHandler.process(
                providers: providers,
                projectPath: controller.project.path,
                existing: droppedAttachments
            )
            guard !new.isEmpty else { return false }
            droppedAttachments.append(contentsOf: new)
            return true
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameDraft)
            Button("Save") { controller.customTitle = renameDraft.trimmingCharacters(in: .whitespaces) }
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

    /// SOUL-SOUL_DESKTOP-233: scroll-restore for the re-attach case - ScrollView
    /// re-mounting on a thread whose controller was already hydrated (e.g., the
    /// LRU evicted it and the user navigated back). Restores wherever they were.
    /// Fresh-load (just-hydrated) doesn't use this - it scrolls unconditionally
    /// to bottom; see the .onChange(of: controller.isHydrating) handler.
    private func performScrollRestore(proxy: ScrollViewProxy) {
        let atBottom = anchor.atBottom
        let anchorId = anchor.itemId
        DispatchQueue.main.async {
            if atBottom {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            } else if let id = anchorId {
                proxy.scrollTo(id, anchor: .top)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                suppressAnchorWrites = false
                let splitNow = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
                updateAnchor(in: splitNow.main)
            }
        }
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

    private func splitGroupedItems(_ items: [ThreadItem], queuedIds: Set<UUID>) -> (main: [ThreadItem], queued: [ThreadItem]) {
        guard !queuedIds.isEmpty else { return (items, []) }
        var main: [ThreadItem] = []
        var queued: [ThreadItem] = []
        main.reserveCapacity(items.count)
        queued.reserveCapacity(queuedIds.count)
        for item in items {
            if queuedIds.contains(item.id) {
                queued.append(item)
            } else {
                main.append(item)
            }
        }
        return (main, queued)
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
    var atBottom: Bool = true
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

    var body: some View {
        // SOUL-SOUL_DESKTOP-099: per-item scroll-perf telemetry.
        let _ = SoulSignposts.event("ThreadItemRow.body")
        // Note: historical dimming is pushed into per-component foreground colors so the row layer
        // stays opaque — Core Animation disables subpixel text AA on translucent layers, which
        // shows up as slightly blurry / shimmering text during fractional-offset trackpad scroll.
        switch item {
        case .userMessage(_, let text, let ts):
            UserMessageRow(text: text, timestamp: ts, isHistorical: isHistorical, isQueued: isQueued)
        case .branchSummary(_, let summary, let sourceProvider, let targetProvider, _):
            FinalizeCard(
                title: "Branch Summary",
                icon: "arrow.triangle.branch",
                intent: "Continue from \(sourceProvider.label) in \(targetProvider.label)",
                summary: summary,
                rationale: nil,
                fixed: nil,
                nextStep: "\(targetProvider.label) received this summary as context and is continuing from here."
            )
        case .agentMessage(_, let text, _, let ts):
            // SOUL-SOUL_DESKTOP-096: `.equatable()` so SwiftUI skips the
            // MarkdownView rebuild when the row's inputs haven't changed.
            AgentMessageRow(text: text, timestamp: ts, isHistorical: isHistorical, showFooter: showAgentFooter)
                .equatable()
        case .agentThought(_, let text, let complete, _):
            AgentThoughtRow(text: text, isStreaming: !complete, isHistorical: isHistorical)
        case .toolCall(_, let kind, let title, let status, let loc, let details):
            // SOUL-SOUL_DESKTOP-111: delegate_to_specialist tool calls route to
            // the dedicated SubagentCard instead of the generic ToolCallRow.
            // Match on the structured details kind populated by insertToolCall.
            if case .subagent(let specialist, let objective, let subagentId, let colorHex, let findingPath) = details?.kind {
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
