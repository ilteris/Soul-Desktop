import SwiftUI

/// Canvas-toolbar subviews lifted out of AppShell. The main AppShell
/// struct stays in AppShell.swift; the toolbar widgets it composes
/// live here:
///
/// - `CanvasToolbar` — the top bar above the active thread
/// - `ThreadTitleCluster` — title + rename pencil + breadcrumb
/// - `HarnessPicker` — Claude/Gemini/Pi/Codex switcher
/// - `ToolbarIcon` — small styled glyph button used by the bar
/// - `AgentLogChip` — inactivity capsule that opens AgentLogPanel
/// - `ContextUsageChip` — context window fill ~Nk / Nk %
/// - `SessionStatsChip` — tools/turns/elapsed (TimelineView-driven)
///
/// Pure file shuffle, no behavior change. Refactor 15/N — agent
/// ergonomics: shrink AppShell.swift below the threshold where
/// a coding agent can hold it in context.

struct CanvasToolbar: View {
    var harness: Provider
    var onPickHarness: (Provider) -> Void = { _ in }
    var onSmokeTest: () -> Void = {}
    var onNewChat: () -> Void = {}
    /// Cross-provider branch. The toolbar lives on the active thread, so
    /// "branch this chat" always means the currently-displayed thread —
    /// no chance of accidentally branching a different row the way the
    /// removed sidebar context menu could.
    var onBranch: (Provider) -> Void = { _ in }
    /// SOUL-SOUL_DESKTOP-179: hard reload of the active session. Drops the
    /// controller from `threads` and re-clicks the session row so hydrate
    /// runs again from scratch. Recovery for the empty-canvas case where
    /// the previous hydrate completed but populated no content rows.
    var onReload: () -> Void = {}
    var onForkWorktree: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onToggleTerminal: () -> Void = {}
    var onToggleReview: () -> Void = {}
    var threadActive: Bool = false
    var sidebarActive: Bool = true
    var terminalActive: Bool = false
    var reviewActive: Bool = false
    var replayActive: Bool = false
    var contextUsage: ContextUsage? = nil
    var thread: ThreadController? = nil

    /// Debug-affordance gate. Off by default; users who need the smoke-test
    /// harness can flip it on in Settings (or via `defaults write`). Keeps
    /// the main toolbar uncluttered for the 99% who never touch it.
    @AppStorage("soul.debug.showSmoke") private var showSmoke: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar toggle no longer lives in this toolbar — it floats at
            // the window-level top-leading slot. The previous toolbar
            // duplicate of "New chat" was removed (sidebar already exposes
            // its own row and ⌘N is bound globally).

            // Title cluster — codex-style header merged into the toolbar.
            // Only renders once the thread has a real session id (i.e. not a
            // brand-new chat that's still on the hero/empty state), so we
            // don't show an orphan rename button.
            if let thread, thread.sessionId != nil, !replayActive {
                ThreadTitleCluster(controller: thread)
            }

            Spacer()

            // Stats group — moved to the right so the title cluster gets
            // primary visual weight on the left. Order: context fill ·
            // session stats · agent log.
            if threadActive {
                if let usage = contextUsage {
                    ContextUsageChip(usage: usage)
                        .padding(.trailing, 6)
                }
                if let thread {
                    SessionStatsChip(controller: thread)
                        .padding(.trailing, 6)
                    AgentLogChip(controller: thread)
                        .padding(.trailing, 6)
                    ThreadOverflowMenu(
                        controller: thread,
                        onSmokeTest: onSmokeTest,
                        onBranch: onBranch,
                        onReload: onReload,
                        onForkWorktree: onForkWorktree
                    )
                    .padding(.trailing, 10)
                }
            }

            HStack(spacing: 14) {
                // HarnessPicker moved to the top-leading overlay alongside
                // the sidebar toggle. See `sidebarToggleOverlay` on AppShell.
                if showSmoke {
                    Button(action: onSmokeTest) {
                        Image(systemName: "ladybug")
                            .font(.system(size: SoulMetric.icon, weight: .regular))
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                    .buttonStyle(.soulHover)
                    .disabled(replayActive)
                    .help("Smoke-test the active provider (Debug)")
                }
                // SOUL-200: terminal toggle moved to the composer footer.
                // SOUL-208: sidebar.right moved to the native unified
                // titlebar (.toolbar on AppShell). Nothing else lives on
                // this row right now.
                EmptyView()
            }
            .opacity(replayActive ? 0.35 : 1)
        }
        // SOUL-208: sidebar toggle moved to the native titlebar (.toolbar
        // on AppShell), so the 60pt overlay-reservation gap is gone.
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(SoulColor.bg)
    }
}

/// SOUL-SOUL_DESKTOP-047: title cluster that lives inline in the toolbar.
/// Layout: title text · pencil (rename). Overflow menu lifted out to its
/// own trailing chip so the leading edge stays clean.
struct ThreadTitleCluster: View {
    @Bindable var controller: ThreadController

    var body: some View {
        HStack(spacing: 6) {
            if controller.displayTitle != "New chat" {
                Text(controller.displayTitle)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                Text("Untitled")
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .italic()
                    .frame(maxWidth: 320, alignment: .leading)
            }

            Button(action: { controller.requestRename() }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: SoulMetric.icon, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .buttonStyle(.soulHover)
            .help("Rename chat")
        }
    }
}

/// Trailing overflow chip — rename / reload / copy / branch / debug.
/// Capsule-styled to match SessionStatsChip / AgentLogChip; uses a vertical
/// ellipsis glyph so it reads as a distinct affordance, not a duplicate of
/// the menu indicator inside HarnessPicker.
struct ThreadOverflowMenu: View {
    @Bindable var controller: ThreadController
    var onSmokeTest: () -> Void = {}
    var onBranch: (Provider) -> Void = { _ in }
    var onReload: () -> Void = {}
    var onForkWorktree: () -> Void = {}
    @AppStorage("soul.debug.showSmoke") private var showSmoke: Bool = false

    var body: some View {
        Menu {
            Button("Rename chat") { controller.requestRename() }
            Button("Reload session") { onReload() }
            Divider()
            Button("Copy session ID") { controller.copySessionIdToPasteboard() }
            Button("Copy as Markdown") { controller.copyMarkdownToPasteboard() }
            Divider()
            Section("Workspace") {
                Button("Fork into new worktree") { onForkWorktree() }
                    .disabled(controller.isWorking)
            }
            Divider()
            Section("Branch to") {
                ForEach(Provider.allCases.filter { $0 != controller.provider }, id: \.self) { p in
                    Button(p.label) { onBranch(p) }
                }
            }
            Divider()
            Section("Debug") {
                Toggle("Show smoke-test button", isOn: $showSmoke)
                Button("Run smoke test now", action: onSmokeTest)
            }
            Divider()
            Section("Coming soon") {
                Button("Open side chat") {}.disabled(true)
                Button("Open in new window") {}.disabled(true)
                Button("Copy deeplink") {}.disabled(true)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: SoulMetric.icon, weight: .regular))
                .foregroundStyle(SoulColor.fgMuted)
                .rotationEffect(.degrees(90))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

struct HarnessPicker: View {
    var selection: Provider
    var onSelect: (Provider) -> Void

    var body: some View {
        Menu {
            ForEach(Provider.allCases) { p in
                Button {
                    onSelect(p)
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            CompactProviderGlyph(provider: p)
                            Text(p.label)
                            if selection == p { Image(systemName: "checkmark") }
                        }
                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                CompactProviderGlyph(provider: selection)
                    .foregroundStyle(SoulColor.fgMuted)
                Text(selection.label)
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SoulColor.surface.opacity(0.6), in: Capsule())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ToolbarIcon: View {
    let name: String
    var isActive: Bool = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: SoulMetric.icon, weight: .regular))
                .foregroundStyle(isActive ? SoulColor.accent : SoulColor.fgMuted)
        }
        .buttonStyle(SoulHoverButtonStyle(isActive: isActive))
    }
}

/// Always-on log surface tied to the active thread's agent log. Tap to open
/// the same popover the stall badge uses — useful when you want to peek at
/// what the agent is doing without waiting 30s for the stall threshold.
struct AgentLogChip: View {
    @Bindable var controller: ThreadController
    @State private var showing = false

    var body: some View {
        Button {
            controller.refreshAgentLogCount()
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scroll")
                    .font(.system(size: SoulMetric.iconHint))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(controller.agentLogCount)")
                    .font(SoulFont.code(11))
                    .foregroundStyle(controller.agentLogCount == 0 ? SoulColor.fgSubtle : SoulColor.fg)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .buttonStyle(.soulChip)
        .accessibilityLabel(Text(verbatim: "Agent log"))
        .accessibilityValue(Text(verbatim: "\(controller.agentLogCount) lines"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            AgentLogPanel(lines: controller.agentLog + controller.traceLog)
        }
    }
}

struct ContextUsageChip: View {
    let usage: ContextUsage

    private var tone: Color {
        if usage.max >= 1_000_000 {
            if usage.tokens >= 250_000 { return .red }
            if usage.tokens >= 100_000 { return .orange }
            return SoulColor.accent
        }
        if usage.fraction >= 0.9 { return .red }
        if usage.fraction >= 0.7 { return .orange }
        return SoulColor.fgMuted
    }

    private var maxLabel: String {
        if usage.max >= 1_000_000 { return "\(usage.max / 1_000_000)M" }
        return "\(usage.max / 1_000)k"
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(SoulColor.border, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(usage.fraction))
                    .stroke(tone, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            
            Text("\(usage.shortLabel)")
                .font(SoulFont.code(11, weight: .regular))
                .foregroundStyle(SoulColor.fg)
            Text("/ \(maxLabel)")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgSubtle)
            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)
            Text("\(Int(usage.fraction * 100))%")
                .font(SoulFont.code(11))
                .foregroundStyle(tone)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .accessibilityLabel(Text(verbatim: "Context usage"))
        .accessibilityValue(Text(verbatim: usage.tooltipText))
    }
}

/// Compact chip showing how "fat" the active thread has gotten: tool calls so
/// far and user-prompt chapters. Static — no TimelineView, no per-second
/// re-render. Counts only mutate when ThreadController observes a new
/// tool / chapter, so the chip refreshes on the SwiftUI graph naturally.
struct SessionStatsChip: View {
    @Bindable var controller: ThreadController

    private var toolCount: Int { controller.toolCount }
    private var chapterCount: Int { controller.displayTurnCount }

    /// Conversation duration = last activity − first activity. Static —
    /// not now() − startedAt, so the chip doesn't drift while the window
    /// is idle. Recomputes only when ThreadController appends a new hook
    /// that bumps `lastActivityAt`.
    private var elapsedLabel: String {
        let seconds = Int(max(0, controller.lastActivityAt.timeIntervalSince(controller.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h\(rem)m"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: SoulMetric.iconHint))
                .foregroundStyle(SoulColor.fgMuted)
            Text("\(toolCount)")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1).fixedSize()
            Text("tools")
                .font(SoulFont.ui(10))
                .foregroundStyle(SoulColor.fgSubtle)
                .padding(.trailing, 4)

            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)
                .lineLimit(1).fixedSize()

            Image(systemName: "text.bubble")
                .font(.system(size: SoulMetric.iconHint))
                .foregroundStyle(SoulColor.fgMuted)
            Text("\(chapterCount)")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1).fixedSize()
            Text("turns")
                .font(SoulFont.ui(10))
                .foregroundStyle(SoulColor.fgSubtle)

            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)
                .lineLimit(1).fixedSize()

            Image(systemName: "clock")
                .font(.system(size: SoulMetric.iconHint))
                .foregroundStyle(SoulColor.fgMuted)
            Text(elapsedLabel)
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1).fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .accessibilityLabel(Text(verbatim: "Session stats"))
        .accessibilityValue(Text(verbatim: "\(toolCount) tool calls, \(chapterCount) turns, \(elapsedLabel) span"))
    }
}

/// Strips trailing `:LINE` or `:LINE:COL` from a path token. The linkifier
/// in MarkdownView captures the full `file.swift:1470` form so that hover
/// preview text shows the line number, but the file-preview path resolver
/// only wants the filesystem path. Returns the input unchanged if it
/// doesn't end with a numeric `:N` suffix.
func stripLineSuffix(_ path: String) -> String {
    var result = path
    for _ in 0..<2 {
        if let colon = result.lastIndex(of: ":"),
           result.index(after: colon) < result.endIndex,
           result[result.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            result = String(result[..<colon])
        } else {
            break
        }
    }
    return result
}

/// Searches the top level of every active project's root directory plus a
/// short list of implicit kernel roots (`~/soul-cli/soul`) for a file
/// matching `filename` exactly. Returns the absolute path when exactly one
/// match exists across all roots — anything ambiguous (zero / multi) returns
/// nil so the caller falls through to its "not found" path.
///
/// The kernel roots cover bare references to PROJECTS.json / SOUL.md / etc.
/// — files that live under ~/soul-cli/soul/ but get name-dropped in prose
/// without an explicit project context. Same bounded BFS + skip-dirs as the
/// project search so a deep dependency tree can't make link clicks hitch.
func findFileInKnownProjects(filename: String) -> String? {
    // SOUL-SOUL_DESKTOP-185: widened from activeProjects() to all projects
    // and added ~/Code, ~/dotfiles roots. Agents frequently reference
    // files in archived projects (the search before missed those) or in
    // the dotfiles tree outside `~/soul-cli/soul/` (where UPSTREAM_PRS.md,
    // README.md etc. live). The path resolver used to dead-end into
    // "couldn't read file" for any of those cases.
    // SOUL-SOUL_DESKTOP-161: read cached project list rather than calling
    // SoulRegistry.projects() (which scans disk). Cache is kept fresh by
    // AppShell on launch + window key-back.
    var roots: [String] = LiveSoulRegistryStore.shared.projects()
        .map(\.path)
        .filter { !$0.isEmpty }
    let home = NSHomeDirectory()
    let extraRoots = [
        "\(home)/soul-cli/soul",
        "\(home)/dotfiles",
        "\(home)/Code",
    ]
    roots.append(contentsOf: extraRoots.filter {
        FileManager.default.fileExists(atPath: $0) && !roots.contains($0)
    })
    // First-match wins. Project roots come before kernel roots, so when an
    // agent says `README.md` and the active project has one at its root
    // that's what opens — only fall through to `~/soul-cli/soul` when no
    // project has it. Previous "exactly one match" guard returned nil on
    // collisions and silently failed; first-match is more useful in
    // practice and the bias matches user expectation.
    for root in roots {
        let direct = (root as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: direct) {
            return direct
        }
        if let match = shallowFindFile(named: filename, under: root, maxDepth: 4) {
            return match
        }
    }
    return nil
}

/// Bounded breadth-first search for a file named `filename` under `root`.
/// Skips hidden dirs and common heavy caches (`node_modules`, `.build`,
/// `DerivedData`, `.git`, `target`, `dist`, `__pycache__`) so a large repo
/// doesn't make link clicks hitch. Returns the first match; depth ≥ 4 is
/// enough for the typical `<root>/<package>/<file>` layout without
/// wandering into deep dependency trees.
private func shallowFindFile(named filename: String, under root: String, maxDepth: Int) -> String? {
    let fm = FileManager.default
    let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "target", "dist",
        "__pycache__", ".venv", "venv", ".next", ".turbo", "build",
    ]
    var frontier: [(path: String, depth: Int)] = [(root, 0)]
    while let (dir, depth) = frontier.first {
        frontier.removeFirst()
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in entries {
            if name == filename {
                let candidate = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                    return candidate
                }
            }
        }
        if depth >= maxDepth { continue }
        for name in entries {
            if name.hasPrefix(".") || skipDirs.contains(name) { continue }
            let sub = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue {
                frontier.append((sub, depth + 1))
            }
        }
    }
    return nil
}

/// If `path` contains a U+2026 ellipsis (LLM- or kernel-elided filename),
/// glob the parent directory for a single file matching the surrounding
/// fixed segments. Returns the resolved match, or the original path if
/// there's no ellipsis, no unique match, or the parent dir doesn't exist.
func resolveEllipsisPath(_ path: String) -> String {
    guard path.contains("…") else { return path }
    let parent = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    guard !parent.isEmpty,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: parent)
    else { return path }
    let parts = name.split(separator: "…", omittingEmptySubsequences: false).map(String.init)
    // Heuristic: every non-empty segment must appear in the candidate, in
    // order. Anchor first segment to prefix and last to suffix when present.
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return path }
    let prefix = parts.first ?? ""
    let suffix = parts.last ?? ""
    let matches = entries.filter { candidate in
        if !prefix.isEmpty && !candidate.hasPrefix(prefix) { return false }
        if !suffix.isEmpty && !candidate.hasSuffix(suffix) { return false }
        var idx = candidate.startIndex
        for seg in nonEmpty {
            guard let r = candidate.range(of: seg, range: idx..<candidate.endIndex) else { return false }
            idx = r.upperBound
        }
        return true
    }
    guard matches.count == 1 else { return path }
    return (parent as NSString).appendingPathComponent(matches[0])
}

#Preview {
    AppShell()
        .frame(width: 1200, height: 820)
}
