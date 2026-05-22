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

    /// Latched reader-mode gate for streaming auto-follow. A real upward scroll
    /// detaches from bottom-follow immediately; only reaching the bottom again
    /// clears it. This is more reliable than sampling "am I at bottom?" during
    /// a row append, because SwiftUI/AppKit may still report the pre-layout
    /// bottom while streamed content is growing.
    @State private var scrollFollow = ScrollFollowState()

    /// True while an auto-scroll animation is in flight. The ScrollView's
    /// indicators are pinned hidden during this window so the scrollbar
    /// doesn't flash on every streamed chunk — auto-scroll is system-driven,
    /// the user didn't ask to see it. Auto-flips off after the animation
    /// duration completes.
    @State private var isAutoScrolling: Bool = false
    /// True while the user's finger / trackpad is actively driving the
    /// scroll (any phase other than .idle). Sticky-follow consults this
    /// so streaming-content-grew snaps can't fight a manual scroll —
    /// the user's gesture always wins.
    @State private var userInteracting: Bool = false

    /// SOUL-SOUL_DESKTOP-081: observe canvas width via GeometryReader so the
    /// scroll-anchor system can re-pin its anchor row when the right side
    /// panel opens/closes (canvas shrinks/grows, rows re-wrap, absolute pixel
    /// offset lands on different content).
    @State private var canvasWidth: CGFloat = 0

    /// SOUL-SOUL_DESKTOP-146: drag-target state lifted from ComposerView so
    /// the whole ThreadView accepts image/file drops, not just the composer
    /// chip strip. Bound into ComposerView so the chips render and submit
    /// behavior stays unchanged.
    @Binding var isImageDropTargeted: Bool

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
        let split = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
        // Suppress rows that are nested under a subagent — those are rendered
        // inline under the parent's row via `nestedChildren`. Computed once
        // per body re-eval to avoid the O(N) lookup per enumerate iteration.
        let suppressedIds = controller.nestedSubagentChildItemIds
        let mainItems = suppressedIds.isEmpty
            ? split.main
            : split.main.filter { !suppressedIds.contains($0.id) }
        let queuedItems = split.queued
        LazyVStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 8)
            ForEach(Array(mainItems.enumerated()), id: \.element.id) { i, item in
                ThreadItemRow(
                    projectPath: controller.project.path,
                    projectKey: controller.project.id,
                    item: item,
                    isHistorical: controller.historicalIDs.contains(item.id),
                    isQueued: false,
                    showAgentFooter: isLastInAgentRun(at: i, items: mainItems),
                    nestedChildren: nestedChildren(for: item)
                )
                .padding(.top, leadingGap(at: i, items: mainItems))
                .id(item.id)
                .padding(.top, isTurnStart(item: item, index: i, items: mainItems) ? 10 : 0)
                .frame(minHeight: 24, alignment: .topLeading)
                .onAppear {
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
                BranchSeedIndicator().padding(.top, 18)
            }
            if controller.isWorking {
                WorkingIndicator(controller: controller).padding(.top, 18)
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

    // Extracted to keep `body` under the Swift type-checker's budget.
    // ComposerView's ~20-arg initializer + many closures was the dominant
    // cost; splitting it into its own builder lets the main body type-check
    // in reasonable time.
    @ViewBuilder
    private var composerSection: some View {
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
                .transition(.opacity)
            }
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
                droppedAttachments: controllerDroppedAttachments,
                branchSeedLoading: branchSeedLoading
            )
            .frame(maxWidth: 760)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }

    private var controllerDroppedAttachments: Binding<[String]> {
        Binding(
            get: { controller.droppedAttachments },
            set: { controller.droppedAttachments = $0 }
        )
    }

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
                    transcriptList
                }
                // Vertical bounce always on (so reaching top/bottom rubber-bands
                // — natural macOS feel). Horizontal elasticity killed via the
                // AppKit configurator since the canvas never scrolls X.
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(isAutoScrolling ? .hidden : .automatic)
                .overlay(alignment: .bottom) {
                    if scrollFollow.userDetachedFromBottom {
                        Button {
                            scrollFollow.userDetachedFromBottom = false
                            autoScroll(to: "__bottom__", proxy: proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SoulColor.fg)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 14)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .help("Jump to bottom")
                    }
                }
                .animation(.easeOut(duration: 0.16), value: scrollFollow.userDetachedFromBottom)
                .background(NSScrollViewConfigurator { sv in
                    sv.horizontalScrollElasticity = .none
                })
                .onScrollPhaseChange { _, newPhase, context in
                    let viewportBottom = context.geometry.contentOffset.y + context.geometry.containerSize.height
                    let contentBottom = context.geometry.contentSize.height
                    // Track interaction state so sticky-follow can yield
                    // to manual scroll. Set BEFORE the isAutoScrolling
                    // guard so the flag is correct even when we skip
                    // the rest of the body.
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        userInteracting = true
                    case .idle, .animating:
                        userInteracting = false
                    }
                    guard !isAutoScrolling else { return }
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        // Drop the isWorking gate: detaching from the
                        // bottom is a user-intent signal regardless of
                        // whether the agent happens to be streaming.
                        // Without this, scrolling up while idle never
                        // sets the detach flag and the jump button
                        // doesn't reappear.
                        if viewportBottom < contentBottom - 200 {
                            scrollFollow.userDetachedFromBottom = true
                        }
                    case .idle, .animating:
                        // Clear the flag once scrolling settles at the
                        // bottom. The geometry-change handler does this
                        // too, but if the final frame's offset == content
                        // size the matching geometry tick may not fire,
                        // leaving the button stranded visible.
                        if viewportBottom >= contentBottom - 200 {
                            scrollFollow.userDetachedFromBottom = false
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
                    scrollFollow.userDetachedFromBottom = false
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
                    // Only follow until the user explicitly scrolls upward.
                    // The send-start snap (onChange of isWorking below) gets
                    // them there; the streaming response keeps painting at
                    // the bottom while they stay parked there. The moment
                    // scroll geometry reports upward motion away from the
                    // bottom, we stop forcing them back. Previously we ORed
                    // in `controller.isWorking`, which hijacked the scroll
                    // for the entire streamed turn even if they were trying
                    // to read earlier content.
                    //
                    // SOUL-SOUL_DESKTOP-233: skip during the post-hydrate
                    // window. The hydrate handler is running a two-pass
                    // scrollTo; an animated scrollTo from here lands in the
                    // middle because the LazyVStack hasn't materialized the
                    // bottom rows yet, and the two calls would fight.
                    guard !recentlyHydrated else { return }
                    guard !scrollFollow.userDetachedFromBottom else { return }
                    autoScroll(to: "__bottom__", proxy: proxy)
                }
                .onChange(of: controller.isWorking) { _, newValue in
                    // Transitioning into a working turn: snap to bottom.
                    // This is an explicit user action (Send or Steer), so
                    // we force the snap regardless of detachment — if the
                    // user scrolled up to re-read history, then typed a
                    // new prompt and pressed Enter, they want to see what
                    // they just sent, not stay parked mid-history.
                    guard newValue else { return }
                    scrollFollow.userDetachedFromBottom = false
                    autoScroll(to: "__bottom__", proxy: proxy)
                }
                .onChange(of: controller.steerPending) { _, newValue in
                    // Steer is an explicit user action — they clicked the
                    // button to advance the queue. Force-scroll to bottom
                    // regardless of detachment / stale-anchor state. Without
                    // this, the width-change re-pin (canvasWidth handler
                    // below) can race the items[] reorder triggered by
                    // cancelActiveProviderTurn + status-row insert, landing
                    // the scroll at a stale anchor mid-content.
                    guard newValue else { return }
                    scrollFollow.userDetachedFromBottom = false
                    autoScroll(to: "__bottom__", proxy: proxy)
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

            composerSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

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

    /// Coalesce bottom-follow requests into a short frame window. Streaming
    /// can append rows faster than a 150 ms animation can finish; animating
    /// every append stacks scrollTo calls and feels sticky. This keeps the
    /// latest request only, then performs one gentle correction after SwiftUI
    /// has had a chance to lay out the new row height.
    private func autoScroll(to id: AnyHashable, proxy: ScrollViewProxy) {
        scrollFollow.autoScrollGeneration += 1
        let generation = scrollFollow.autoScrollGeneration
        isAutoScrolling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            guard generation == scrollFollow.autoScrollGeneration else { return }
            guard !scrollFollow.userDetachedFromBottom else {
                isAutoScrolling = false
                return
            }
            withAnimation(.smooth(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
            // Second-pass correction. The first scrollTo can land short
            // because LazyVStack hasn't finished sizing the freshly-
            // appended row by then, leaving the user's just-sent prompt
            // half-clipped at the bottom. A no-animation scrollTo once
            // the row's true height is known snaps it into place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard generation == scrollFollow.autoScrollGeneration else { return }
                guard !scrollFollow.userDetachedFromBottom else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard generation == scrollFollow.autoScrollGeneration else { return }
                isAutoScrolling = false
            }
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

final class ScrollFollowState {
    var userDetachedFromBottom: Bool = false
    var autoScrollGeneration: Int = 0
}

struct ScrollFollowGeometry: Equatable {
    let offsetY: CGFloat
    let atBottom: Bool
    /// Total content height. Tracked so the action handler can detect
    /// content growth during streaming (agent text appended to an
    /// existing AgentMessageRow doesn't change `items.count`, but it
    /// does grow `contentSize.height`).
    let contentHeight: CGFloat
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
        case .agentMessage(_, let text, let complete, let ts):
            // SOUL-SOUL_DESKTOP-096: `.equatable()` so SwiftUI skips the
            // MarkdownView rebuild when the row's inputs haven't changed.
            AgentMessageRow(text: text, timestamp: ts, isHistorical: isHistorical, isStreaming: !complete, showFooter: showAgentFooter)
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
