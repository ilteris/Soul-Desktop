import SwiftUI

/// Read-only replay surface: playback bar on top, item stream below.
/// No composer, no agent — purely client-side scroll through a finished session.
struct ReplayView: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void

    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0
    /// Explicit user overrides for chapter expansion. Absent entries fall back
    /// to "only the latest chapter is open" — so as new prompts land, prior
    /// chapters auto-collapse without trapping any chapter the user opened.
    @State private var explicitExpansion: [Int: Bool] = [:]
    /// Tracks whether the bottom sentinel is on-screen. Replay only follows the
    /// stream when the user is parked at the bottom; if they scrolled up to
    /// read, new items land off-screen without yanking their position.
    @State private var atBottom: Bool = true

    private var chapters: [ReplayChapter] {
        ReplayView.chapters(from: controller.visible)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackBar(controller: controller, onExit: onExit)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
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
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
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
                .onChange(of: controller.visible.count) { _, _ in
                    guard atBottom else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
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
        VStack(alignment: .leading, spacing: 14) {
            if let header = chapter.header {
                ChapterHeader(
                    header: header,
                    bodyCount: chapter.body.count,
                    expanded: expanded,
                    onToggle: { toggle(chapter.id) }
                )
            } else if !chapter.body.isEmpty {
                // Pre-first-prompt prelude — no toggle, just render.
                EmptyView()
            }

            if expanded || chapter.header == nil {
                ForEach(chapter.body, id: \.id) { item in
                    ThreadItemRow(projectPath: controller.project.path, item: item, isHistorical: false)
                        .id(item.id)
                }
            }
        }
    }

    private func isExpanded(_ chapterId: Int, isLatest: Bool) -> Bool {
        if let v = explicitExpansion[chapterId] { return v }
        return isLatest
    }

    private func toggle(_ chapterId: Int) {
        let current = explicitExpansion[chapterId] ?? (chapterId == chapters.count - 1)
        explicitExpansion[chapterId] = !current
    }

    static func chapters(from items: [ThreadItem]) -> [ReplayChapter] {
        var result: [ReplayChapter] = []
        var headerItem: ThreadItem? = nil
        var body: [ThreadItem] = []

        func flush() {
            if headerItem != nil || !body.isEmpty {
                result.append(ReplayChapter(id: result.count, header: headerItem, body: body))
            }
        }

        for item in items {
            if case .userMessage = item {
                flush()
                headerItem = item
                body = []
            } else {
                body.append(item)
            }
        }
        flush()
        return result
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
        .buttonStyle(.soulHover)
        .padding(.top, 6)
    }
}
