import SwiftUI
import AppKit
import Combine

struct ThreadView: View {
    @Bindable var controller: ThreadController
    @Binding var prompt: String
    var onCancel: () -> Void = {}
    var onPickHarness: (Provider) -> Void = { _ in }
    var onNewChat: () -> Void = {}

    @State private var renaming = false
    @State private var renameDraft = ""
    /// Suppress row `.onAppear` anchor writes during the brief window after
    /// the ScrollView re-mounts. Without this, rows appearing top-down on
    /// re-mount clobber the saved anchor (and flip `scrollAnchorAtBottom`
    /// false) before the restore call runs.
    @State private var suppressAnchorWrites = false
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 8)
                        // Queued user bubbles render at the *bottom* of the
                        // canvas (just above the working indicator) regardless
                        // of insertion order — they're "next up to send," not
                        // part of the agent's actual transcript yet. Filter
                        // them out of the main timeline; they're re-added
                        // below.
                        let split = splitGroupedItems(controller.groupedItems, queuedIds: controller.queuedItemIDs)
                        let mainItems = split.main
                        let queuedItems = split.queued
                        ForEach(Array(mainItems.enumerated()), id: \.element.id) { i, item in
                            ThreadItemRow(
                                projectPath: controller.project.path,
                                projectKey: controller.project.id,
                                item: item,
                                isHistorical: controller.historicalIDs.contains(item.id),
                                isQueued: false
                            )
                                .id(item.id)
                                .padding(.top, isTurnStart(item: item, index: i, items: mainItems) ? 10 : 0)
                                .onAppear {
                                    anchor.visibleIds.insert(item.id)
                                    updateAnchor()
                                }
                                .onDisappear {
                                    anchor.visibleIds.remove(item.id)
                                    updateAnchor()
                                }
                        }
                        if controller.isWorking {
                            WorkingIndicator(controller: controller)
                        }
                        ForEach(queuedItems, id: \.id) { item in
                            ThreadItemRow(
                                projectPath: controller.project.path,
                                projectKey: controller.project.id,
                                item: item,
                                isHistorical: false,
                                isQueued: true
                            )
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
                            // Sync the anchor once the dust has settled on the restore.
                            updateAnchor()
                        }
                    }
                }
                .onChange(of: controller.items.count) { _, _ in
                    // Follow the stream while a turn is active — the user
                    // just sent, they want to see the response land. Outside
                    // of a working turn, only follow if they were already at
                    // the bottom.
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
            }

            VStack(spacing: 8) {
                ComposerView(
                    prompt: $prompt,
                    projectName: controller.project.name,
                    projectPath: controller.project.path,
                    commands: controller.availableCommands,
                    onSend: { display, agent in
                        Task { await controller.send(display: display, agent: agent) }
                    },
                    onCancel: onCancel,
                    isWorking: controller.isWorking,
                    queuedCount: controller.queuedPrompts.count,
                    onClearQueue: { controller.clearQueue() },
                    onSteer: { Task { await controller.steerToNextQueued() } },
                    permissionMode: Binding(
                        get: { controller.permissionMode },
                        set: { controller.permissionMode = $0 }
                    ),
                    provider: controller.provider,
                    onPickHarness: onPickHarness,
                    isImageDropTargeted: $isImageDropTargeted,
                    droppedAttachments: $droppedAttachments
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

    private func updateAnchor() {
        guard !suppressAnchorWrites else { return }
        // Find the visible item with the minimum index in the items array.
        // This is our top-most visible item.
        if let firstVisible = controller.items.first(where: { anchor.visibleIds.contains($0.id) }) {
            // SOUL-SOUL_DESKTOP-094 + -096: write to the reference-type
            // holder, not controller and not @State — neither path
            // invalidates the view. See the `anchor` declaration comment.
            anchor.itemId = firstVisible.id
            // If the bottom sentinel isn't visible (handled by its own logic),
            // ensure atBottom is false.
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

    var body: some View {
        // SOUL-SOUL_DESKTOP-099: per-item scroll-perf telemetry.
        let _ = SoulSignposts.event("ThreadItemRow.body")
        // Note: historical dimming is pushed into per-component foreground colors so the row layer
        // stays opaque — Core Animation disables subpixel text AA on translucent layers, which
        // shows up as slightly blurry / shimmering text during fractional-offset trackpad scroll.
        switch item {
        case .userMessage(_, let text, let ts):
            UserMessageRow(text: text, timestamp: ts, isHistorical: isHistorical, isQueued: isQueued)
        case .agentMessage(_, let text, _, let ts):
            // SOUL-SOUL_DESKTOP-096: `.equatable()` so SwiftUI skips the
            // MarkdownView rebuild when the row's inputs haven't changed.
            AgentMessageRow(text: text, timestamp: ts, isHistorical: isHistorical)
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

