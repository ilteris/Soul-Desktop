import SwiftUI
import AppKit

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

    /// Track which items are currently in the viewport so we can anchor to the
    /// top-most visible one when the user scrolls.
    @State private var visibleIds: Set<UUID> = []

    var body: some View {
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
                        let queuedIds = controller.queuedItemIDs
                        let mainItems = controller.items.filter { !queuedIds.contains($0.id) }
                        let queuedItems = controller.items.filter { queuedIds.contains($0.id) }
                        ForEach(Array(mainItems.enumerated()), id: \.element.id) { i, item in
                            ThreadItemRow(
                                item: item,
                                isHistorical: controller.historicalIDs.contains(item.id),
                                isQueued: false
                            )
                                .id(item.id)
                                .padding(.top, isTurnStart(item: item, index: i, items: mainItems) ? 10 : 0)
                                .onAppear {
                                    visibleIds.insert(item.id)
                                    updateAnchor()
                                }
                                .onDisappear {
                                    visibleIds.remove(item.id)
                                    updateAnchor()
                                }
                        }
                        if controller.isWorking {
                            WorkingIndicator(controller: controller)
                        }
                        ForEach(queuedItems, id: \.id) { item in
                            ThreadItemRow(
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
                                controller.scrollAnchorAtBottom = true
                            }
                            .onDisappear {
                                guard !suppressAnchorWrites else { return }
                                controller.scrollAnchorAtBottom = false
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
                    let atBottom = controller.scrollAnchorAtBottom
                    let anchorId = controller.scrollAnchorItemId
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
                    guard controller.scrollAnchorAtBottom || controller.isWorking else { return }
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
        if let firstVisible = controller.items.first(where: { visibleIds.contains($0.id) }) {
            controller.scrollAnchorItemId = firstVisible.id
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

}

struct ThreadItemRow: View {
    let item: ThreadItem
    var isHistorical: Bool = false
    var isQueued: Bool = false

    var body: some View {
        // Note: historical dimming is pushed into per-component foreground colors so the row layer
        // stays opaque — Core Animation disables subpixel text AA on translucent layers, which
        // shows up as slightly blurry / shimmering text during fractional-offset trackpad scroll.
        switch item {
        case .userMessage(_, let text, let ts):
            UserMessageRow(text: text, timestamp: ts, isHistorical: isHistorical, isQueued: isQueued)
        case .agentMessage(_, let text, _, let ts):
            AgentMessageRow(text: text, timestamp: ts, isHistorical: isHistorical)
        case .agentThought(_, let text, let complete, _):
            AgentThoughtRow(text: text, isStreaming: !complete, isHistorical: isHistorical)
        case .toolCall(_, let kind, let title, let status, let loc, let details):
            ToolCallRow(kind: kind, title: title, status: status, location: loc, details: details)
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

private struct AgentMessageRow: View {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    @State private var isHovering = false
    @State private var feedback: Feedback = .none

    enum Feedback { case none, up, down }

    private var split: (visible: String, trace: SoulTrace?) { SoulTrace.extract(from: text) }

    var body: some View {
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
    @State private var isHovering = false
    @State private var copied = false

    private var parsed: (commandName: String?, rest: String) {
        // SOUL-SOUL_DESKTOP-039: shared parser; same recognition rule the
        // replay path now uses for chapter-header chip detection.
        let p = SlashCommandParse.parse(text)
        return (p.commandName, p.rest)
    }

    var body: some View {
        let p = parsed
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
                if isHovering && !isHistorical && !isQueued {
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
        .onHover { isHovering = $0 }
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

private struct ToolCallRow: View {
    let kind: String
    let title: String
    let status: String
    let location: String?
    let details: ToolCallDetails?

    @State private var diffExpanded: Bool = false

    private var filePath: String? {
        if let loc = location, looksLikePath(loc) { return loc }
        if looksLikePath(title) { return title }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = filePath {
                FileChipRow(
                    kind: kind, status: status, path: path,
                    statusColor: statusColor, icon: icon,
                    trailing: { chevron }
                )
            } else {
                DefaultToolRow(
                    kind: kind, title: title, status: status, location: location,
                    statusColor: statusColor, icon: icon,
                    trailing: { chevron }
                )
            }
            if diffExpanded, let details {
                DiffView(details: details)
            }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if let details {
            HStack(spacing: 6) {
                diffStats(for: details)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { diffExpanded.toggle() }
                } label: {
                    Image(systemName: diffExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Compact git-diff-style line counter: green `+N` for added lines, red
    /// `-M` for removed. Edit shows both; Write is additions-only. Mirrors
    /// `git diff --shortstat` so the user can eyeball blast radius without
    /// expanding the card.
    @ViewBuilder
    private func diffStats(for details: ToolCallDetails) -> some View {
        let (added, removed) = countLines(details)
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .font(SoulFont.code(13, weight: .semibold))
                    .foregroundStyle(.green)
            }
            if removed > 0 {
                Text("-\(removed)")
                    .font(SoulFont.code(13, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private func countLines(_ details: ToolCallDetails) -> (added: Int, removed: Int) {
        switch details.kind {
        case .edit(let oldString, let newString):
            return (lineCount(newString), lineCount(oldString))
        case .write(let content):
            return (lineCount(content), details.previousLineCount ?? 0)
        }
    }

    private func lineCount(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        // Count newline-separated lines but treat a trailing newline as just
        // ending the previous line, not a blank line of its own (matches the
        // way `wc -l`-style stats are usually read).
        var n = s.components(separatedBy: "\n").count
        if s.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }

    private var icon: String {
        switch kind {
        case "read": return "📖"
        case "edit": return "✎"
        case "delete": return "🗑"
        case "move": return "→"
        case "search": return "🔎"
        case "execute": return ""
        case "think": return "💭"
        case "fetch": return "🌐"
        default: return "⚙️"
        }
    }

    private var statusColor: Color {
        switch status {
        case "pending", "in_progress": return .orange
        case "completed": return .green
        case "failed": return .red
        case "stopped": return .gray
        default: return SoulColor.fgSubtle
        }
    }

    private func looksLikePath(_ s: String) -> Bool {
        s.contains("/") || s.contains(".")
    }
}

private struct FileChipRow<Trailing: View>: View {
    let kind: String
    let status: String
    let path: String
    let statusColor: Color
    let icon: String
    @ViewBuilder var trailing: () -> Trailing
    /// SOUL-SOUL_DESKTOP-041: AppShell injects this to open the right-side
    /// preview pane instead of the default NSWorkspace fallback. Default is
    /// a no-op so unit tests / previews don't crash.
    @Environment(\.openFilePreview) private var openFilePreview

    init(kind: String, status: String, path: String, statusColor: Color, icon: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.kind = kind
        self.status = status
        self.path = path
        self.statusColor = statusColor
        self.icon = icon
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                openFilePreview(path)
            } label: {
                HStack(spacing: 6) {
                    Text(icon)
                    Text(kind)
                        .font(SoulFont.code(13, weight: .bold))
                        .foregroundStyle(SoulColor.fg)
                    Text((path as NSString).lastPathComponent)
                        .font(SoulFont.code(13, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SoulColor.border.opacity(0.6), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            if status != "completed" {
                Text(status)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
            }

            trailing()

            Spacer()
        }
    }
}

private struct DefaultToolRow<Trailing: View>: View {
    let kind: String
    let title: String
    let status: String
    let location: String?
    let statusColor: Color
    let icon: String
    @ViewBuilder var trailing: () -> Trailing

    init(kind: String, title: String, status: String, location: String?, statusColor: Color, icon: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.kind = kind
        self.title = title
        self.status = status
        self.location = location
        self.statusColor = statusColor
        self.icon = icon
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Text(icon) }
                Text(kind)
                    .font(SoulFont.code(13, weight: .bold))
                    .foregroundStyle(SoulColor.fg)
                Text(title)
                    .font(SoulFont.code(13, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if kind == "execute" {
                    Button {
                        // TODO: Re-run the command in the terminal panel?
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(width: 16, height: 16)
                            .background(SoulColor.bgElevated, in: Circle())
                            .overlay(Circle().strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SoulColor.border.opacity(0.6), lineWidth: 0.5)
            )

            if let loc = location, !loc.isEmpty {
                Text(loc)
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            if status != "completed" {
                Text(status)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
            }

            trailing()

            Spacer()
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
private struct DiffView: View {
    let details: ToolCallDetails

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            switch details.kind {
            case .edit(let oldString, let newString):
                column(text: oldString, sign: "-", tint: .red,
                       start: details.startLine, gutterWidth: gutterWidth(oldString, newString))
                column(text: newString, sign: "+", tint: .green,
                       start: details.startLine, gutterWidth: gutterWidth(oldString, newString))
            case .write(let content):
                // Write has no "before" — render an empty placeholder column
                // so the layout stays symmetrical and the eye doesn't have
                // to re-scan when switching between edits and writes.
                column(text: "", sign: " ", tint: SoulColor.fgSubtle,
                       start: nil, gutterWidth: gutterWidth("", content))
                column(text: content, sign: "+", tint: .green,
                       start: details.startLine ?? 1, gutterWidth: gutterWidth("", content))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single text-selection scope for the whole diff card. Without this
        // each per-line Text would become its own NSTextView; with N lines
        // that's N selection participants in every drag-tick layout pass —
        // the bug that pegged the main thread to 100% during selection. One
        // scope at this level lets AppKit treat the diff as a single
        // selectable block.
        .textSelection(.enabled)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(SoulColor.border, lineWidth: 1)
        )
    }

    /// Width of the line-number gutter sized to the longest line number we'll
    /// display. Each character ~7pt in monospace at 11pt. Falls back to 3
    /// chars (room for up to 999) when startLine is unknown.
    private func gutterWidth(_ a: String, _ b: String) -> CGFloat {
        let aLines = a.components(separatedBy: "\n").count
        let bLines = b.components(separatedBy: "\n").count
        let maxNum = (details.startLine ?? 1) + max(aLines, bLines)
        let chars = max(3, String(maxNum).count)
        return CGFloat(chars) * 7 + 4
    }

    private func column(text: String, sign: String, tint: Color,
                        start: Int?, gutterWidth: CGFloat) -> some View {
        let lines = text.isEmpty ? [" "] : text.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: 8) {
                    Text(start.map { "\($0 + i)" } ?? "")
                        .font(SoulFont.code(12))
                        .foregroundStyle(SoulColor.fgSubtle.opacity(0.7))
                        .frame(width: gutterWidth, alignment: .trailing)
                    Text(sign)
                        .font(SoulFont.code(12, weight: .bold))
                        .foregroundStyle(tint.opacity(0.7))
                        .frame(width: 10, alignment: .leading)
                    // No per-line .textSelection / no per-line .frame on the
                    // Text. The whole DiffView declares selection once at the
                    // outer HStack; the flex anchor moves down to the line
                    // HStack (single layout node) so the tint background
                    // still spans the column without promoting each Text to
                    // an NSTextView. Both modifiers on the Text triggered the
                    // layout-recursion storm during drag-select (sample
                    // 2026-05-14: 100% main thread inside _bellerophonTrack).
                    Text(line.isEmpty ? " " : line)
                        .font(SoulFont.code(12))
                        .foregroundStyle(SoulColor.fg)
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
