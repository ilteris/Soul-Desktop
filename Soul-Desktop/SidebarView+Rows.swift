import SwiftUI
import AppKit

/// Sidebar row family + small helper views lifted out of SidebarView.
/// The main `SidebarView` container stays in SidebarView.swift; this file
/// holds every subview it composes:
///
/// - Row types: `ChatRow`, `ProjectSidebarRow`, `SidebarRow`,
///   `LiveSessionRow`, `WorktreeSubheader`
/// - Chip/dot helpers: `WorkingDot`, `EventCountChip`, `ReplayProgressChip`
/// - Misc utilities: `ProviderIcon` (enum), `NSScrollViewConfigurator`
///
/// Pure file shuffle, no behavior change. Refactor 14/N — agent
/// ergonomics: shrink SidebarView.swift below the threshold where
/// a coding agent can hold it in context.

struct ChatRow: View {
    let session: SoulSession
    var isSelected: Bool = false
    var isStarred: Bool = false
    var onReplay: (() -> Void)? = nil
    var isActiveReplay: Bool = false
    var replayProgress: Double = 0
    var replayIndex: Int = 0
    var replayTotal: Int = 0
    var replayPrompts: Int = 0
    var replayReplies: Int = 0
    @State private var hovering: Bool = false

    /// Drafts are rendered italic + with a muted "New chat" placeholder so
    /// the row reads as not-yet-real. The id prefix `draft-` is set by
    /// AppShell.newChat(). Computed at the row scope so child branches
    /// (title, meta-line, hover-Replay gate) all see the same value.
    private var isDraft: Bool { session.id.hasPrefix("draft-") }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fgSubtle)
                    .frame(width: 14)
                if session.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(SoulColor.sidebar, lineWidth: 1))
                        .offset(x: 3, y: -2)
                }
                if session.writer == .external {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(1)
                        .background(
                            Circle().fill(SoulColor.sidebar)
                        )
                        .offset(x: 4, y: 6)
                        .help("Started outside Soul-Desktop — kernel ledger only, no in-app transcript")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if session.isWorking {
                        WorkingDot()
                    }
                    if isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                    Text(isDraft ? "New chat" : cleanTitle(session.title ?? session.intent ?? session.summary))
                        .font(SoulFont.ui(14, weight: isSelected ? .medium : .regular))
                        .italic(isDraft)
                        .foregroundStyle(
                            isSelected ? SoulColor.accent
                                       : (isDraft ? SoulColor.fgSubtle : SoulColor.fg)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let taskBadgeText {
                        Text(taskBadgeText)
                            .font(SoulFont.ui(9, weight: .medium))
                            .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fgSubtle)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                SoulColor.surface.opacity(isSelected ? 0.65 : 0.9),
                                in: Capsule()
                            )
                            .help(taskHelpText)
                    }
                    if let slashBadgeText {
                        Text(slashBadgeText)
                            .font(SoulFont.ui(9, weight: .medium))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SoulColor.surface.opacity(0.75), in: Capsule())
                            .help(slashHelpText)
                    }
                }
                Text(isDraft ? "Draft · not sent yet" : metaLine(session))
                    .font(SoulFont.ui(11))
                    .italic(isDraft)
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
if isActiveReplay {
                ReplayProgressChip(
                    progress: replayProgress,
                    index: replayIndex,
                    total: replayTotal,
                    prompts: replayPrompts,
                    replies: replayReplies
                )
            } else if hovering, !isDraft, let onReplay {
                Button(action: onReplay) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SoulColor.accent)
                        Text("Replay")
                            .font(SoulFont.ui(11, weight: .regular))
                            .foregroundStyle(SoulColor.fg)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(SoulColor.accentMuted, in: Capsule())
                }
                .buttonStyle(.soulChip)
                .fixedSize()
                .help("Replay this session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isSelected
                ? SoulColor.accent.opacity(0.22)
                : (hovering ? SoulColor.surface.opacity(0.6) : Color.clear)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(SoulColor.accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var sourceIcon: String {
        // Always show the provider glyph as the leading icon — the small
        // inline `terminal` badge next to the title carries the external-
        // writer signal. Hiding the provider behind a terminal icon for
        // external sessions made it hard to tell which CLI authored a row.
        ProviderIcon.symbol(for: session.source ?? session.liveProvider)
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// Second-line text under the row title: "<N turns> · <time-ago>" when
    /// the session has prompts, else just "<time-ago>". Turn count (user
    /// prompts) is a far better "how rich is this conversation" signal
    /// than wall-clock duration — a 16h session that's just sitting open
    /// shouldn't look more substantial than a 30-minute 20-turn deep dive.
    private func metaLine(_ session: SoulSession) -> String {
        // Session-start time, not last-activity. Sidebar row stamps are
        // about "when did this conversation begin", not "when was the
        // hooks file last touched" — which can bump for non-conversation
        // reasons (preamble regen, finalize JSON rewrite, etc.). Falls
        // back to `timestamp` (the pinned sort key) when no first-hook
        // event is recorded.
        let ago = relative(session.startedAt ?? session.timestamp)
        let n = session.visibleTurnCount > 0
            ? session.visibleTurnCount
            : max(session.promptCount, session.transcriptTurns)
        // SOUL-SOUL_DESKTOP-268: surface "no reply" when prompts landed but
        // every AfterAgent envelope was empty AND no provider transcript
        // rescues the session. Row stays clickable — the user decides
        // whether to keep, archive, or trash it.
        let slash = slashMetaSuffix(session)
        let reply = session.agentReplyMissing ? " · no reply" : ""
        if n > 0 {
            let label = n == 1 ? "1 turn" : "\(n) turns"
            return "\(label) · \(ago)\(slash)\(reply)"
        }
        return "\(ago)\(slash)\(reply)"
    }

    private var taskBadgeText: String? {
        guard let taskId = normalizedTaskId else { return nil }
        return taskId.replacingOccurrences(of: "SOUL-", with: "")
    }

    private var taskHelpText: String {
        var parts: [String] = []
        if let taskId = normalizedTaskId { parts.append(taskId) }
        if let status = trimmed(session.taskStatus) { parts.append(status) }
        if let subject = trimmed(session.taskSubject) { parts.append(subject) }
        return parts.joined(separator: " · ")
    }

    private var normalizedTaskId: String? {
        trimmed(session.taskId)
    }

    private var slashBadgeText: String? {
        guard !session.slashSemantics.isEmpty else { return nil }
        if session.slashSemantics.values.contains(where: { $0.taskAffecting == true }) {
            return "task"
        }
        if session.slashSemantics.values.allSatisfy({ ($0.localOnly == true) || ($0.conversationWorthy == false) }) {
            return "local"
        }
        return nil
    }

    private var slashHelpText: String {
        let commands = session.slashSemantics.keys.sorted().map { "/\($0)" }.joined(separator: ", ")
        if let slashBadgeText {
            return "\(slashBadgeText.capitalized) slash command: \(commands)"
        }
        return "Slash command: \(commands)"
    }

    private func slashMetaSuffix(_ session: SoulSession) -> String {
        guard !session.slashSemantics.isEmpty else { return "" }
        if session.slashSemantics.values.contains(where: { $0.taskAffecting == true }) {
            return " · task command"
        }
        if session.slashSemantics.values.allSatisfy({ ($0.localOnly == true) || ($0.conversationWorthy == false) }) {
            return " · local command"
        }
        return ""
    }

    private func trimmed(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Humanized session length string for the row's second line. Defined
    /// as the wall-clock interval between the first hook event (`startedAt`)
    /// and the most-recent activity (`lastActivityAt`).
    /// Returns nil for sessions that don't have a startedAt yet or where
    /// the span is under ~30s (so brand-new chats don't display "0m").
    private func duration(_ session: SoulSession) -> String? {
        guard let started = session.startedAt else { return nil }
        let span = (session.lastActivityAt ?? session.timestamp).timeIntervalSince(started)
        if span < 30 { return nil }
        let total = Int(span)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }

    private func cleanTitle(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "untitled"
        }
        // Strip Claude's `<command-message>` / `<command-name>` tag noise
        // from legacy sessions whose firstUserPrompt was captured before
        // the producer-side strip landed.
        var s = SoulRegistry.stripCommandTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let noise = CharacterSet(charactersIn: "#[]-*> ")
        while let first = s.unicodeScalars.first, noise.contains(first) {
            s.removeFirst()
        }
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        return s.isEmpty ? "untitled" : s
    }
}

private struct WorkingDot: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .fill(SoulColor.accent)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.2 : 0.8)
            .opacity(pulsing ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// Project-row variant with a hover-revealed "Start new chat in <project>"
/// affordance. The hint pill floats to the right of the label and a trailing
/// pencil icon takes the click — tapping the row body still just selects the
/// project, so the existing single-click behavior stays intact.
///
/// SOUL-SOUL_DESKTOP-036: a leading chevron toggles per-project expand/collapse.
/// Expand state lives in the parent view (passed in as a Binding) so it can be
/// persisted to UserDefaults keyed by project id and survive relaunches.
struct ProjectSidebarRow: View {
    let project: SoulProject
    let isSelected: Bool
    @Binding var isExpanded: Bool
    var chatCount: Int = 0
    let onSelect: () -> Void
    let onNewChat: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: isExpanded ? "folder.fill" : "folder", color: SoulColor.fgMuted)
            Text(project.name)
                .font(SoulFont.ui(16))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            if chatCount > 0 {
                Text("\(chatCount)")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SoulColor.surface, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            hovering
                ? AnyShapeStyle(SoulColor.fg.opacity(0.06))
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-click toggles expand/collapse. `onSelect` still fires so
            // the rest of the app (composer footer chip, new-chat target)
            // tracks the most recently clicked project, but the row itself
            // shows no "selected" styling — hover + expanded chevron carry
            // all the visual feedback the user wanted.
            onSelect()
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .onHover { h in
            hovering = h
        }
    }
}

struct SidebarRow: View {
    let icon: String
    let label: String
    var trailing: String? = nil
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: icon, color: isSelected ? SoulColor.accent : SoulColor.fgMuted)
            Text(label)
                .font(SoulFont.ui(14, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? SoulColor.accent : SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? AnyShapeStyle(SoulColor.accentMuted)
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
    }
}

private struct EventCountChip: View {
    let events: Int
    let prompts: Int

    private var compactLabel: String {
        if prompts > 0 { return "\(prompts)p" }
        if events > 0 { return "\(events)e" }
        return ""
    }

    var body: some View {
        if events == 0 && prompts == 0 {
            EmptyView()
        } else {
            Text(compactLabel)
                .font(SoulFont.code(10))
                .foregroundStyle(SoulColor.fgSubtle)
                .lineLimit(1)
                .fixedSize()
                .help("\(events) kernel events · \(prompts) prompts")
        }
    }
}

private struct ReplayProgressChip: View {
    let progress: Double
    let index: Int
    let total: Int
    let prompts: Int
    let replies: Int

    var body: some View {
        HStack(spacing: 0) {
            label
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SoulColor.surface)
                    Capsule()
                        .fill(SoulColor.accent.opacity(0.35))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * clampedProgress)))
                }
            }
        }
        .clipShape(Capsule())
        .help("\(index) of \(total) · \(prompts) prompts · \(replies) replies")
    }

    private var clampedProgress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, progress))
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(SoulColor.accent)
            Text("\(index)/\(total)")
                .font(SoulFont.code(11, weight: .regular))
                .foregroundStyle(SoulColor.fg)
            Text("·")
                .font(SoulFont.ui(10))
                .foregroundStyle(SoulColor.fgSubtle)
            Text("\(prompts)p \(replies)r")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgMuted)
        }
    }
}

/// Tiny indented label under a project that names a git worktree bucket.
/// Rendered only when a project has more than one worktree group or a
/// non-main one — single-main projects keep the original flat look.
private struct WorktreeSubheader: View {
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10))
                .foregroundStyle(SoulColor.fgSubtle)
            Text(label)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgSubtle)
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }
}

private struct LiveSessionRow: View {
    let session: SoulSession
    var isSelected: Bool = false

    /// Single resume gate: `SoulSession.canSafelyResume`. Generalizes the
    /// previous origin+provider+stale ladder into one provider-agnostic
    /// check — desktop-authored OR finalized OR externally-authored-but-idle.
    private var canResume: Bool { session.canSafelyResume }

    /// True iff the writer is currently active (external + not stale).
    /// Drives the "active" chip and blue accent.
    private var isExternalActive: Bool {
        session.writer == .external && !session.isStale
    }

    /// Always show the provider glyph as the leading icon; the inline
    /// `terminal` badge next to the title carries the external-writer
    /// signal. Keeps "which CLI authored this" visible across all states.
    private var liveIcon: String {
        ProviderIcon.symbol(for: session.liveProvider ?? session.source)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: liveIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                if session.writer == .external {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isExternalActive ? .blue : SoulColor.fgSubtle)
                        .padding(1)
                        .background(Circle().fill(SoulColor.sidebar))
                        .offset(x: 4, y: 6)
                        .help("External writer (terminal CLI)")
                }
            }
            .padding(.leading, 14)
            Text(title)
                .font(SoulFont.ui(13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if isExternalActive {
                Text("active")
                    .font(SoulFont.ui(9, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
            Text(relative(session.lastActivityAt ?? session.timestamp))
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgSubtle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? AnyShapeStyle(SoulColor.accentMuted)
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
        )
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var iconColor: Color {
        if isSelected { return SoulColor.accent }
        if isExternalActive { return .blue }
        if !canResume { return SoulColor.fgMuted }
        return SoulColor.fgSubtle
    }

    private var textColor: Color {
        if isSelected { return SoulColor.accent }
        if !canResume { return SoulColor.fgMuted }
        return SoulColor.fg
    }

    private var tooltip: String {
        if isExternalActive {
            return "Currently active in a terminal. Resume disabled to prevent data loss."
        }
        return canResume
            ? "Click to resume this conversation."
            : "Started outside Soul-Desktop — clicking will not resume the original conversation (starts fresh)."
    }

    private var title: String {
        let s = (session.title ?? session.intent ?? session.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return "live · \(session.id.prefix(8))…"
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// Central SF Symbol mapping so finalized chats and live rows render with
/// the same provider-distinguishing glyph. Field shapes differ between the
/// two: finalized rows carry `source` ("claude" / "gemini" / "pi-native");
/// live rows carry `liveProvider` ("claude" / "geminiCLI" / nil) which is
/// derived from where the agent's persistence file actually lives.
/// Provider glyph resolver. Accepts either name convention:
///   - `SoulSession.source` (from finalize JSON): "claude" / "gemini" / "pi-native"
///   - `Provider.rawValue`  (in-memory + live rows): "claude" / "geminiCLI" / "pi" / "codex"
/// Either spelling normalizes to the same SF Symbol, so a row's icon stays
/// stable across its lifecycle (finalize → resume → re-finalize).
enum ProviderIcon {
    static func symbol(for raw: String?) -> String {
        switch raw {
        case "claude":                  return "circle.hexagongrid"
        case "gemini", "geminiCLI":     return "g.square"
        case "pi", "pi-native":         return "p.square"
        case "codex":                   return "atom"
        default:                        return "circle.dotted"
        }
    }
}

/// Tiny AppKit bridge to reach the NSScrollView that SwiftUI's `ScrollView`
/// sits inside. SwiftUI exposes `scrollBounceBehavior(.basedOnSize)` but
/// that only suppresses bounce when content fits — overflowing content
/// still rubber-bands. Setting `verticalScrollElasticity = .none` directly
/// turns it off unconditionally, which is what we want for tight-feeling
/// list panes (sidebar / settings). Walk up superviews because the
/// containing scroll view is one or two ancestors above the configurator
/// host depending on SwiftUI's layout this release.
struct NSScrollViewConfigurator: NSViewRepresentable {
    let configure: (NSScrollView) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var v: NSView? = nsView
            while let cur = v {
                if let sv = cur as? NSScrollView { configure(sv); return }
                if let sv = cur.subviews.compactMap({ $0 as? NSScrollView }).first { configure(sv); return }
                v = cur.superview
            }
        }
    }
}
