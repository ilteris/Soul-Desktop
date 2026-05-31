import SwiftUI
import SoulCore
import AppKit
import Combine

struct ThreadView: View {
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
        let split = controller.groupedItemsSplit
        // Suppress rows that are nested under a subagent — those are rendered
        // inline under the parent's row via `nestedChildren`. Computed once
        // per body re-eval to avoid the O(N) lookup per enumerate iteration.
        let suppressedIds = controller.nestedSubagentChildItemIds
        let mainItems = suppressedIds.isEmpty
            ? split.main
            : split.main.filter { !suppressedIds.contains($0.id) }
        let queuedItems = split.queued
        let _ = SoulSignposts.event("Flash.transcriptList.body", "items=\(controller.items.count) main=\(mainItems.count) queued=\(queuedItems.count) isWorking=\(controller.isWorking) isHydrating=\(controller.isHydrating)")
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
                .onAppear { bottomSentinelVisible = true }
                .onDisappear { bottomSentinelVisible = false }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        // SOUL-LAYOUT-CYCLE-2: refuse animation contexts propagated from
        // above. AppShell attaches `.animation(sidePanelAnimation, value:
        // showSidebar / reviewVisible / filePreviewPath)` to the
        // NavigationSplitView root — those modifiers install an animation
        // context on the WHOLE subtree, including this LazyVStack. When a
        // panel toggles AND new agent rows land in the same animation
        // window, every ForEach insert + structural `if` toggle inside the
        // stack animates with MoveTransition, spinning the layout engine in
        // StackLayout / _FlexFrameLayout / MoveLayout recursion. Row inserts
        // should not inherit parent-driven animation; per-row hover/footer
        // animations stay intact because they're scoped to their own
        // subtrees.
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
                .transition(.opacity)
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
                        Task { await controller.dispatchPending(pending) }
                    }
                    let accepted = controller.items.count > itemCountBefore
                    if accepted {
                        userInteracting = false // Reset manual scroll override so following can activate
                        DispatchQueue.main.async {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                            repairTranscriptScrollView(reason: "send")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo("__bottom__", anchor: .bottom)
                                repairTranscriptScrollView(reason: "send_settled")
                            }
                        }
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
                branchSeedLoading: branchSeedLoading
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
            .transition(.opacity)
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
                .onScrollPhaseChange { _, newPhase, context in
                    // Track interaction state so sticky-follow can yield
                    // to manual scroll.
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        userInteracting = true
                    case .idle, .animating:
                        userInteracting = false
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
                // SOUL-SOUL_DESKTOP-081: re-pin the anchor when canvas width
                // changes (right side panel opens / closes / resizes).
                // Without this, LazyVStack row remeasurement leaves
                // ScrollView's absolute offset pointing at different content.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { canvasWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in
                                guard abs(newWidth - canvasWidth) > 0.5 else { return }
                                if transcriptScrollView?.window?.inLiveResize == true {
                                    canvasWidth = newWidth
                                    return
                                }
                                pendingCanvasWidth = newWidth
                            }
                    }
                )
                .onChange(of: pendingCanvasWidth) { _, newWidth in
                    canvasWidthRepinTask?.cancel()
                    canvasWidthRepinTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled else { return }
                        canvasWidth = newWidth
                    }
                }
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
                    if let id = anchor.itemId {
                        proxy.scrollTo(id, anchor: .top)
                    }
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
                    // When a live turn completes (isWorking transitions to false), the WorkingIndicator
                    // is removed and the document shrinks by a tiny bit. Run a clean repair here to
                    // align the scroll bounds after the transition.
                    if !isWorking {
                        repairTranscriptScrollView(reason: "isWorking")
                    }
                }
                // SOUL-SOUL_DESKTOP-094 + -096: flush local anchor state to
                // the controller on view detach so the next attach restores
                // the right position.
                .onDisappear {
                    canvasWidthRepinTask?.cancel()
                    controller.scrollAnchorItemId = anchor.itemId
                }
                HStack {
                    Spacer(minLength: 0)
                    jumpToBottomButton(proxy: proxy)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .frame(height: 0, alignment: .bottomTrailing)
                .offset(y: -18)
                .zIndex(1)

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

    /// Restores the saved scroll anchor when a previously-mounted thread view
    /// is attached again.
    private func performScrollRestore(proxy: ScrollViewProxy) {
        let anchorId = anchor.itemId
        DispatchQueue.main.async {
            if let id = anchorId {
                // SOUL-SOUL_DESKTOP-363: mark the restore in flight so the
                // concurrent repair leaves the clip origin alone — scrollTo
                // owns the position here. A nil anchor (fresh/cold open) skips
                // this so the repair's clamp still runs and fixes an
                // off-document origin → blank canvas.
                scrollRestorePending = true
                proxy.scrollTo(id, anchor: .top)
            }
            repairTranscriptScrollView(reason: "restore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                suppressAnchorWrites = false
                scrollRestorePending = false
                let splitNow = controller.groupedItemsSplit
                updateAnchor(in: splitNow.main)
            }
        }
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
        DispatchQueue.main.async {
            guard let scrollView = transcriptScrollView else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        repairTranscriptScrollView(reason: reason, retries: retries - 1, lastHeight: lastHeight)
                    }
                }
                return
            }
            let clip = scrollView.contentView
            scrollView.needsLayout = true
            scrollView.documentView?.needsLayout = true
            scrollView.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()

            guard let documentView = scrollView.documentView else { return }
            let documentHeight = max(documentView.bounds.height, documentView.frame.height)
            let clipHeight = clip.bounds.height
            // Skip the clamp while a scrollTo restore owns the position — see
            // performScrollRestore / scrollRestorePending.
            if !scrollRestorePending, documentHeight > 0, clipHeight > 0 {
                let maxY = max(0, documentHeight - clipHeight)
                let currentY = clip.bounds.origin.y
                let clampedY = min(max(0, currentY), maxY)
                if abs(clampedY - currentY) > 0.5 {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clampedY))
                }
                scrollView.reflectScrolledClipView(clip)
            }

            // Stop as soon as the document height stabilizes; otherwise keep
            // polling so a late LazyVStack layout still gets re-clamped.
            let stabilized = documentHeight > 0 && abs(documentHeight - lastHeight) < 0.5
            if retries > 0, !stabilized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    repairTranscriptScrollView(reason: reason, retries: retries - 1, lastHeight: documentHeight)
                }
            }
        }
    }

    /// Follow live prompt/response growth only. This deliberately ignores
    /// hydration and session activation so opening an old session cannot
    /// force the transcript to the bottom.
    private func followLiveTurn(proxy: ScrollViewProxy) {
        guard controller.isWorking, !controller.isHydrating, !userInteracting else { return }
        guard bottomSentinelVisible else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("__bottom__", anchor: .bottom)
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
