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
                    onPickHarness: onPickHarness
                )
                .frame(maxWidth: 760)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
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

/// Live reasoning bubble fed by `agent_thought_chunk` notifications. Muted
/// italic styling so it reads as background context, not the agent's
/// official reply. Collapsed by default once streaming completes; expand to
/// re-read the reasoning trail.
private struct AgentThoughtRow: View {
    let text: String
    var isStreaming: Bool = false
    var isHistorical: Bool = false
    @State private var expanded: Bool = true

    /// Parse `text` as inline markdown (the AttributedString markdown
    /// initializer handles `**bold**`, `*italic*`, `` `code` ``, links,
    /// etc.). Falls back to plain text on parse failure. Cached implicitly
    /// by SwiftUI's view-identity diffing — the Text rebuilds only when
    /// `text` actually changes.
    private var thoughtAttributed: AttributedString {
        if let a = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return a
        }
        return AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgSubtle)
                Text(isStreaming ? "Thinking…" : "Thought")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                // Inline-markdown rendering via AttributedString: `**bold**`,
                // `*italic*`, `` `code` ``, links, etc. all parse into a
                // single Text view — flat layout, no nested stacks.
                //
                // We tried nesting MarkdownView (which uses an inner
                // VStack-of-blocks) here, but during streaming thought
                // chunks the entire block tree re-laid out on every chunk
                // and triggered exponential `_FlexFrameLayout.sizeThatFits`
                // recursion inside the outer ThreadView's LazyVStack —
                // 100% main thread beachball.
                Text(thoughtAttributed)
                    .font(SoulFont.code(12).italic())
                    .foregroundStyle(SoulColor.fgMuted.opacity(isHistorical ? 0.6 : 0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SoulColor.bgElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.3), lineWidth: 0.5)
        )
    }
}

/// Structured Quad card pulled from a session's finalize JSON. Renders at
/// the tail of a hydrated read-only transcript so opening a finalized
/// session immediately surfaces what was accomplished.
private struct FinalizeCard: View {
    let intent: String?
    let summary: String?
    let rationale: String?
    let fixed: String?
    let nextStep: String?

    var body: some View {
        // SOUL-SOUL_DESKTOP-100: confirm the FinalizeCard materialized.
        let _ = SoulSignposts.event("FinalizeCard.body")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SoulColor.accent)
                Text("Finalize")
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
            }
            if let intent, !intent.isEmpty {
                field(label: "Intent", value: intent)
            }
            if let summary, !summary.isEmpty {
                field(label: "Summary", value: summary)
            }
            if let rationale, !rationale.isEmpty {
                field(label: "Rationale", value: rationale)
            }
            if let fixed, !fixed.isEmpty {
                field(label: "Fixed", value: fixed)
            }
            if let nextStep, !nextStep.isEmpty {
                field(label: "Next", value: nextStep)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SoulColor.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func field(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .tracking(0.5)
            Text(value)
                .font(SoulFont.ui(13))
                .foregroundStyle(SoulColor.fg)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct AgentMessageRow: View, Equatable {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    @State private var isHovering = false
    @State private var feedback: Feedback = .none

    enum Feedback { case none, up, down }

    // SOUL-SOUL_DESKTOP-096: only the body-affecting inputs participate in
    // Equatable. @State storage (isHovering, feedback) is identity-tracked
    // by SwiftUI separately and must NOT be part of the comparison.
    static func == (lhs: AgentMessageRow, rhs: AgentMessageRow) -> Bool {
        lhs.text == rhs.text
            && lhs.timestamp == rhs.timestamp
            && lhs.isHistorical == rhs.isHistorical
    }

    private var split: (visible: String, trace: SoulTrace?) { SoulTrace.extract(from: text) }

    var body: some View {
        // SOUL-SOUL_DESKTOP-099: agent-bubble scroll-perf telemetry.
        let _ = SoulSignposts.event("AgentMessageRow.body")
        let mutedFg = SoulColor.fg.opacity(0.62)
        VStack(alignment: .leading, spacing: 4) {
            MarkdownView(
                text: split.visible,
                headerColor: isHistorical ? mutedFg : SoulColor.fg,
                bodyColor: isHistorical ? mutedFg : SoulColor.fg,
                codeColor: isHistorical ? mutedFg : SoulColor.fg
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let trace = split.trace {
                SoulTraceChip(trace: trace)
            }

            // Footer renders for live AND historical messages. Earlier
            // versions hid the buttons on historical bubbles, which left
            // every reply lacking copy/feedback after a session reload —
            // you couldn't act on prior content. Historical rows just get
            // slightly more muted styling via the parent `mutedFg`.
            HStack(spacing: 4) {
                FooterButton(systemName: "doc.on.doc", help: "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    // Drop the <soul_trace> envelope so the clipboard contains
                    // just the rendered markdown the user actually saw.
                    NSPasteboard.general.setString(split.visible, forType: .string)
                }
                FooterButton(
                    systemName: feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                    help: "Helpful",
                    active: feedback == .up
                ) {
                    feedback = feedback == .up ? .none : .up
                }
                FooterButton(
                    systemName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    help: "Not helpful",
                    active: feedback == .down
                ) {
                    feedback = feedback == .down ? .none : .down
                }
                FooterButton(systemName: "arrow.triangle.branch", help: "Fork (coming soon)") {
                    // TODO: SOUL-SOUL_DESKTOP-002 — fork into worktree
                }
                .disabled(true)
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(isHistorical ? SoulColor.fgSubtle.opacity(0.7) : SoulColor.fgSubtle)
                    .help(MessageTimestamp.absolute(timestamp))
                Spacer()
            }
            .opacity(isHovering ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .onHover { isHovering = $0 }
    }
}

enum MessageTimestamp {
    // SOUL-SOUL_DESKTOP-063 perf: DateFormatter allocation is expensive (~1-2ms
    // per call). These get hit on every AgentMessageRow / UserMessageRow body
    // evaluation, of which we have hundreds during heavy streaming. Cache one
    // instance per format so we pay the setup cost once. macOS 10.9+ makes
    // DateFormatter thread-safe for read.
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let pastFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func format(_ d: Date) -> String {
        (Calendar.current.isDateInToday(d) ? todayFormatter : pastFormatter).string(from: d)
    }
    static func absolute(_ d: Date) -> String {
        absoluteFormatter.string(from: d)
    }
}

private struct FooterButton: View {
    let systemName: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(active ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct UserMessageRow: View {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    /// True when this user message is sitting in the controller's queue —
    /// appended to `items` but not yet shipped to the agent. We paint a
    /// dashed, dimmer bubble so it visually reads as "waiting in line."
    var isQueued: Bool = false
    @State private var copied = false

    private var parsed: (commandName: String?, rest: String) {
        // SOUL-SOUL_DESKTOP-039: shared parser; same recognition rule the
        // replay path now uses for chapter-header chip detection.
        let p = SlashCommandParse.parse(text)
        return (p.commandName, p.rest)
    }

    var body: some View {
        let p = parsed
        // SOUL-SOUL_DESKTOP-102: a `/cmd` invocation with no body and no args
        // is a chip-only row. Slash commands logged to hooks.jsonl as bare
        // `/finalize` / `/pulse` (display text, not the expanded agent prompt)
        // render as standalone bubbles with empty bodies — visually they read
        // like a user message that got cut off. Collapse those to a compact
        // inline event marker so they read as "this command fired" instead of
        // "here is a message." Live and historical share the same treatment;
        // the user just typing /finalize sees the chip as a receipt either way.
        if let cmd = p.commandName, p.rest.isEmpty {
            HStack(spacing: 6) {
                Spacer(minLength: 32)
                SlashCommandChip(command: cmd, args: "", isHistorical: isHistorical)
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle.opacity(isHistorical ? 0.7 : 1.0))
                    .help(MessageTimestamp.absolute(timestamp))
            }
            .padding(.trailing, 4)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                bubble(p)
                HStack(spacing: 4) {
                    if isQueued {
                        Image(systemName: "hourglass")
                            .font(.system(size: 9))
                            .foregroundStyle(SoulColor.fgSubtle)
                        Text("queued")
                            .font(SoulFont.ui(10, weight: .medium))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .padding(.trailing, 4)
                    }
                    // SOUL-SOUL_DESKTOP-109: always show the copy button next
                    // to the timestamp instead of gating on bubble hover. The
                    // hover gate created a "moving target" problem — as soon
                    // as the cursor left the bubble heading toward the button,
                    // the hover state flipped false and the button vanished
                    // before it could be clicked. Always-on is the standard
                    // chat-UI pattern and cheap visually (12pt icon, muted).
                    if !isHistorical && !isQueued {
                        FooterButton(
                            systemName: copied ? "checkmark" : "doc.on.doc",
                            help: "Copy as Markdown"
                        ) {
                            let payload = p.commandName.map { "/\($0)\(p.rest.isEmpty ? "" : " \(p.rest)")" } ?? text
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                    }
                    Text(MessageTimestamp.format(timestamp))
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgSubtle.opacity(isHistorical ? 0.7 : 1.0))
                        .help(MessageTimestamp.absolute(timestamp))
                }
                .padding(.trailing, 4)
                .frame(minHeight: 18)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ p: (commandName: String?, rest: String)) -> some View {
        let mutedFg = SoulColor.fg.opacity(isQueued ? 0.55 : 0.62)
        // Neutral elevated fill — independent of the user's accent choice so
        // the bubble never picks up a hot color. Queued bubbles get a dimmer
        // fill and stroke so the user can tell at a glance which prompt is
        // actively being processed vs. parked behind it.
        let bubbleFill: Color = {
            if isQueued { return SoulColor.surface.opacity(0.5) }
            return isHistorical ? SoulColor.bgElevated.opacity(0.7) : SoulColor.bgElevated
        }()
        let bubbleStroke = SoulColor.border.opacity(
            isQueued ? 0.5 : (isHistorical ? 0.4 : 0.7)
        )
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 32)
            if let cmd = p.commandName {
                VStack(alignment: .trailing, spacing: 6) {
                    let lines = p.rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let firstLine = lines.first.map(String.init) ?? ""
                    let remaining = lines.count > 1 ? String(lines[1]) : ""

                    SlashCommandChip(command: cmd, args: firstLine, isHistorical: isHistorical)

                    if !remaining.isEmpty {
                        MarkdownView(
                            text: remaining,
                            headerColor: isHistorical ? mutedFg : SoulColor.fg,
                            bodyColor: isHistorical ? mutedFg : SoulColor.fg,
                            codeColor: isHistorical ? mutedFg : SoulColor.fg
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    bubbleStroke,
                                    style: StrokeStyle(
                                        lineWidth: isQueued ? 1.0 : 0.5,
                                        dash: isQueued ? [3, 3] : []
                                    )
                                )
                        )
                        .textSelection(.enabled)
                    }
                }
            } else {
                MarkdownView(
                    text: text,
                    headerColor: isHistorical ? mutedFg : SoulColor.fg,
                    bodyColor: isHistorical ? mutedFg : SoulColor.fg,
                    codeColor: isHistorical ? mutedFg : SoulColor.fg
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            bubbleStroke,
                            style: StrokeStyle(
                                lineWidth: isQueued ? 1.0 : 0.5,
                                dash: isQueued ? [3, 3] : []
                            )
                        )
                )
                .textSelection(.enabled)
            }
        }
    }
}


private struct PlanCard: View {
    let entries: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                Text("Plan")
                    .font(SoulFont.ui(12, weight: .bold))
            }
            .foregroundStyle(SoulColor.fgSubtle)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries, id: \.self) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(entry.status == "completed" ? .green : SoulColor.fgSubtle)
                            .padding(.top, 1)

                        Text(entry.content)
                            .font(SoulFont.ui(13))
                            .foregroundStyle(entry.status == "completed" ? SoulColor.fgMuted : SoulColor.fg)
                    }
                }
            }
        }
        .padding(12)
        .background(SoulColor.bgElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
        )
    }
}

private struct WorkingIndicator: View {
    @Bindable var controller: ThreadController
    @State private var rotation: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let secondsSinceActivity = Int(ctx.date.timeIntervalSince(controller.lastActivityAt))
            // SOUL-SOUL_DESKTOP-024: stall threshold is now provider-tuned
            // (Gemini 90s default, Claude 60s, Pi 120s — see Provider
            // .stallBudgetSeconds) instead of a hardcoded 30s. Settings →
            // Advanced "Stall budgets" lets the user override per provider.
            let budget = controller.provider.stallBudgetSeconds
            let isStalled = secondsSinceActivity >= budget
            let ceiling = StallPolicy.autoCancelCeilingSeconds
            let secondsUntilAutoCancel = max(0, ceiling - secondsSinceActivity)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(SoulColor.border.opacity(0.3), lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(isStalled ? Color.orange : SoulColor.accent, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(rotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isStalled ? "Thinking…" : "Agent working…")
                        .font(SoulFont.ui(12, weight: .medium))
                        .foregroundStyle(isStalled ? Color.orange : SoulColor.fg)

                    if isStalled {
                        HStack(spacing: 4) {
                            Text("No activity for \(secondsSinceActivity)s")
                                .font(SoulFont.ui(10))
                                .foregroundStyle(Color.orange.opacity(0.8))

                            // Auto-cancel countdown — only shows once we're
                            // within 60s of the hard ceiling so it doesn't
                            // distract during normal slow turns.
                            if secondsUntilAutoCancel <= 60 && secondsUntilAutoCancel > 0 {
                                Text("· auto-recover in \(secondsUntilAutoCancel)s")
                                    .font(SoulFont.ui(10))
                                    .foregroundStyle(Color.orange.opacity(0.6))
                            }

                            // Recover is always available once we've crossed
                            // the budget — queue depth no longer gates it.
                            // SOUL-SOUL_DESKTOP-024: prior Skip-ahead required
                            // a non-empty queue, which left empty-queue stalls
                            // (the common case) without any recovery
                            // affordance besides force-quit.
                            Button {
                                Task { await controller.recoverStalledTurn(source: "manual") }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: controller.queuedPrompts.isEmpty
                                          ? "arrow.uturn.backward.circle"
                                          : "forward.fill")
                                    Text(controller.queuedPrompts.isEmpty ? "Recover" : "Skip ahead")
                                }
                                .font(SoulFont.ui(10, weight: .bold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(controller.queuedPrompts.isEmpty
                                  ? "Cancel the stalled turn and unblock the thread"
                                  : "Cancel the stalled turn and dispatch the next queued message")
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
}

struct AgentLogPanel: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agent log")
                    .font(SoulFont.ui(12, weight: .bold))
                Spacer()
                Text("\(lines.count) lines")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(lines.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy log")
                .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SoulColor.bgElevated)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 500, height: 300)
        .background(SoulColor.bg)
    }
}

/// Unified-diff view for ToolCallDetails. Edit shows old (red `-`) above new
/// (green `+`); Write shows the full content as additions. Kept intentionally
/// simple: no LCS line alignment, just two stacked code blocks. For the
/// common Edit shape (a small old_string / new_string pair) this is plenty
/// readable; if a future need arises for line-level diffs we can swap the
/// inner blocks for a real LCS pass without changing the call site.
