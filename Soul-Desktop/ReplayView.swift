import SwiftUI

/// Read-only replay surface: playback bar on top, item stream below.
/// No composer, no agent — purely client-side scroll through a finished session.
struct ReplayView: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void

    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0
    /// Reading-mode toggle (persisted). When true, ReplayView.chapters
    /// strips tool calls / plans / status / errors / agent thoughts so the
    /// replay reads as a long-form transcript. PlaybackBar owns the toggle
    /// UI; this view just consumes the same @AppStorage key.
    @AppStorage("soul.replay.readingMode") private var readingMode: Bool = true
    /// Explicit user overrides for chapter expansion. Absent entries fall back
    /// to "only the latest chapter is open" — so as new prompts land, prior
    /// chapters auto-collapse without trapping any chapter the user opened.
    @State private var explicitExpansion: [Int: Bool] = [:]
    /// Replay auto-follow gate. A user scroll upward detaches playback from
    /// bottom-follow; reaching bottom again re-arms it.
    @State private var scrollFollow = ScrollFollowState()
    @State private var isAutoScrolling: Bool = false

    private var chapters: [ReplayChapter] {
        ReplayView.chapters(from: controller.visible, readingMode: readingMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackBar(controller: controller, onExit: onExit)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: readingMode ? 0 : 14) {
                        Color.clear.frame(height: 8)
                        if controller.isLoading {
                            loadingState
                        } else if controller.total == 0 {
                            emptyState
                        } else {
                            ForEach(chapters) { chapter in
                                chapterView(chapter, isLatest: chapter.id == chapters.count - 1)
                            }
                        }
                        Color.clear
                            .frame(height: 60)
                            .id("__bottom__")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
                // Vertical bounce always on; horizontal elasticity killed
                // via the AppKit configurator (the canvas never scrolls X).
                .scrollBounceBehavior(.always, axes: .vertical)
                .background(NSScrollViewConfigurator { sv in
                    sv.horizontalScrollElasticity = .none
                })
                .onScrollGeometryChange(for: ScrollFollowGeometry.self) { geometry in
                    let viewportBottom = geometry.contentOffset.y + geometry.containerSize.height
                    let contentBottom = geometry.contentSize.height
                    return ScrollFollowGeometry(
                        offsetY: geometry.contentOffset.y,
                        atBottom: viewportBottom >= contentBottom - 8,
                        contentHeight: contentBottom
                    )
                } action: { oldValue, newValue in
                    if newValue.atBottom {
                        scrollFollow.userDetachedFromBottom = false
                    } else if newValue.offsetY < oldValue.offsetY - 1 {
                        scrollFollow.userDetachedFromBottom = true
                    }
                }
                .onScrollPhaseChange { _, newPhase, context in
                    let viewportBottom = context.geometry.contentOffset.y + context.geometry.containerSize.height
                    let contentBottom = context.geometry.contentSize.height
                    guard !isAutoScrolling else { return }
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        if viewportBottom < contentBottom - 8 {
                            scrollFollow.userDetachedFromBottom = true
                        }
                    case .idle, .animating:
                        break
                    }
                }
                .onChange(of: controller.visible.count) { _, _ in
                    guard !scrollFollow.userDetachedFromBottom else { return }
                    autoScroll(to: "__bottom__", proxy: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard generation == scrollFollow.autoScrollGeneration else { return }
                isAutoScrolling = false
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("loading replay…")
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgSubtle)
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No transcript")
                .font(SoulFont.ui(13, weight: .regular))
                .foregroundStyle(SoulColor.fgMuted)
            Text("Session \(controller.sessionId.prefix(8))… has no hooks or transcript on disk.")
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgSubtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chapterView(_ chapter: ReplayChapter, isLatest: Bool) -> some View {
        let expanded = isExpanded(chapter.id, isLatest: isLatest)
        let isFirst = chapter.id == 0
        VStack(alignment: .leading, spacing: readingMode ? 18 : 14) {
            if readingMode, !isFirst, chapter.header != nil {
                // Chapter break: thin hairline rule before each new user
                // prompt so a long read-through scans as discrete chapters
                // instead of one continuous wall of text. The rule sits in
                // the gutter (no inset) so it reads as a structural seam
                // rather than a UI element.
                Rectangle()
                    .fill(SoulColor.border.opacity(0.35))
                    .frame(height: 1)
                    .padding(.top, 12)
            }
            if let header = chapter.header {
                if readingMode {
                    // Reading mode: render the user prompt through the same
                    // UserMessageRow as ThreadView. We deliberately pass
                    // `isHistorical: false` so the bubble keeps its full
                    // `bgElevated` fill + visible stroke — at 0.7 opacity
                    // the historical bubble fades into the background and
                    // the right-aligned prompt reads as a title instead of
                    // a chat bubble. The "we are in the history" cue is
                    // carried by the agent prose below, which IS historical-
                    // muted; the bright user bubble acts as a clear "I said
                    // this" anchor at the top of each chapter — same metaphor
                    // as Apple Messages' history view.
                    ThreadItemRow(
                        projectPath: controller.project.path,
                        item: header,
                        isHistorical: false
                    )
                    .id(header.id)
                } else {
                    ChapterHeader(
                        header: header,
                        bodyCount: chapter.body.count,
                        expanded: expanded,
                        onToggle: { toggle(chapter.id) }
                    )
                }
            } else if !chapter.body.isEmpty {
                // Pre-first-prompt prelude — no toggle, just render.
                EmptyView()
            }

            if expanded || chapter.header == nil {
                ForEach(chapter.body, id: \.id) { item in
                    ThreadItemRow(
                        projectPath: controller.project.path,
                        item: item,
                        isHistorical: readingMode
                    )
                    .id(item.id)
                }
            }
        }
        .padding(.bottom, readingMode ? 16 : 0)
    }

    private func isExpanded(_ chapterId: Int, isLatest: Bool) -> Bool {
        // Reading mode always renders the full chapter — the accordion
        // metaphor only exists for the chat-shaped replay.
        if readingMode { return true }
        if let v = explicitExpansion[chapterId] { return v }
        return isLatest
    }

    private func toggle(_ chapterId: Int) {
        let current = explicitExpansion[chapterId] ?? (chapterId == chapters.count - 1)
        explicitExpansion[chapterId] = !current
    }

    static func chapters(from items: [ThreadItem], readingMode: Bool = false) -> [ReplayChapter] {
        var result: [ReplayChapter] = []
        var headerItem: ThreadItem? = nil
        var body: [ThreadItem] = []

        func flush() {
            if headerItem != nil || !body.isEmpty {
                // Reading mode: drop chapters whose body filtered to nothing.
                // They render as orphan prompt headings with no reply, which
                // is just noise. Chapters with content under a different
                // prompt heading still flow naturally.
                if readingMode, headerItem != nil, body.isEmpty {
                    headerItem = nil
                    return
                }
                result.append(ReplayChapter(id: result.count, header: headerItem, body: body))
            }
        }

        for item in items {
            if case .userMessage = item {
                flush()
                headerItem = item
                body = []
            } else if !readingMode || isReadable(item) {
                body.append(item)
            }
        }
        flush()
        return result
    }

    /// Items that survive reading-mode filtering. Keep the narrative spine
    /// (assistant prose, branch summaries, finalize quad); drop the plumbing
    /// (tool calls, plans, transient status, errors, agent thoughts).
    private static func isReadable(_ item: ThreadItem) -> Bool {
        switch item {
        case .agentMessage, .branchSummary, .finalize:
            return true
        case .userMessage:
            // userMessage never reaches here (handled as a chapter header
            // upstream), but include for switch exhaustiveness.
            return true
        case .agentThought, .toolCall, .toolCallGroup, .plan, .status, .error:
            return false
        }
    }
}

struct ReplayChapter: Identifiable {
    let id: Int
    let header: ThreadItem?
    let body: [ThreadItem]
}

/// Header bar shown above each chapter body. Click to collapse/expand;
/// includes a short prompt preview and the event count in the chapter.
private struct ChapterHeader: View {
    let header: ThreadItem
    let bodyCount: Int
    let expanded: Bool
    let onToggle: () -> Void

    /// Parsed slash command if the user-message header is one, else nil.
    /// SOUL-SOUL_DESKTOP-039: routes through the shared SlashCommandParse so
    /// chapter headers chip-render the same way ThreadView's UserMessageRow does.
    private var slashCommand: SlashCommandParse.Parsed? {
        guard case .userMessage(_, let text, _) = header else { return nil }
        let p = SlashCommandParse.parse(text)
        return p.commandName == nil ? nil : p
    }

    private var preview: String {
        if case .userMessage(_, let text, _) = header {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t
            if firstLine.count > 120 { return String(firstLine.prefix(120)) + "…" }
            return firstLine
        }
        return ""
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 12)
                if let cmd = slashCommand {
                    let lines = cmd.rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let firstLine = lines.first.map(String.init) ?? ""
                    SlashCommandChip(command: cmd.commandName ?? "", args: firstLine, isHistorical: false, lineLimit: 1)
                } else {
                    Text(preview)
                        .font(SoulFont.ui(15, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text("\(bodyCount) \(bodyCount == 1 ? "event" : "events")")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulChip)
        .padding(.top, 6)
    }
}
