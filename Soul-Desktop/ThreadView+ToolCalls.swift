import SwiftUI
import SoulCore
import Combine

/// Tool-call view family lifted out of ThreadView. ToolCallRow is the
/// heart — it dispatches by kind (Edit/Write/Read/Bash/Glob/Plan/Output/
/// subagent) and renders the appropriate body (inline diff, file chip,
/// status capsule). The carousel and group rows handle consecutive
/// same-kind tool calls. DefaultToolRow is the generic catch-all.
/// DiffView is the helper used by the Edit/Write paths.
///
/// Pure file shuffle, no behavior change. ThreadView refactor 1/N —
/// agent ergonomics: shrink ThreadView.swift below the threshold where
/// a coding agent can hold it in context.

struct ToolCallRow: View {
    let kind: String
    let title: String
    let status: String
    let location: String?
    let details: ToolCallDetails?
    let projectPath: String?
    var isGrouped: Bool = false

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
                    isGrouped: isGrouped,
                    trailing: { chevron }
                )
            } else {
                DefaultToolRow(
                    kind: kind, title: title, status: status, location: location,
                    statusColor: statusColor, icon: icon,
                    isGrouped: isGrouped,
                    trailing: { chevron }
                )
            }
            // SOUL-SOUL_DESKTOP-168: diff content is embedded in `details`
            // (old/new strings); it never reads the live file off disk. The
            // prior `fileExists` gate hid valid historical diffs whenever
            // path resolution missed — renamed files, edits outside
            // `projectPath`, symlinks, sandbox quirks. The diff is the
            // record of what the agent *did*; render it unconditionally.
            if diffExpanded, let details {
                DiffView(details: details)
                ToolCallCollapseButton {
                    withAnimation(.easeOut(duration: 0.08)) { diffExpanded = false }
                }
            }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if let details {
            HStack(spacing: 6) {
                diffStats(for: details)
                Button {
                    withAnimation(.easeOut(duration: 0.08)) { diffExpanded.toggle() }
                } label: {
                    Image(systemName: diffExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(6)
                }
                .buttonStyle(.soulHover)
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
            // SOUL-SOUL_DESKTOP-181: compute actual diff stats instead of
            // raw old/new string lengths. The old behavior reported a 1-line
            // insertion inside a 6-line context block as "+7 -6" because
            // both strings carried the surrounding context. CollectionDifference
            // counts only the inserted/removed lines that actually changed,
            // matching the inline diff view's own row classifier.
            let oldLines = oldString.isEmpty ? [] : oldString.components(separatedBy: "\n")
            let newLines = newString.isEmpty ? [] : newString.components(separatedBy: "\n")
            let diff = newLines.difference(from: oldLines)
            return (diff.insertions.count, diff.removals.count)
        case .write(let content):
            return (lineCount(content), details.previousLineCount ?? 0)
        case .output, .subagent, .claudeAgent:
            return (0, 0)
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
        case "edit", "write": return "✎"
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

/// Compact carousel for runs of consecutive same-kind tool calls
/// (execute/read/search/fetch/…). The kind label stays pinned on the left;
/// the arg portion crossfades through each call's title. Stops on the last
/// call once everything is complete and we've cycled through at least once.
/// Hover pauses; click expands the row into the full list (each inner call
/// rendered via the normal ToolCallRow path).
struct FileChipRow<Trailing: View>: View {
    let kind: String
    let status: String
    let path: String
    let statusColor: Color
    let icon: String
    var isGrouped: Bool = false
    @ViewBuilder var trailing: () -> Trailing
    /// SOUL-SOUL_DESKTOP-041: AppShell injects this to open the right-side
    /// preview pane instead of the default NSWorkspace fallback. Default is
    /// a no-op so unit tests / previews don't crash.
    @Environment(\.openFilePreview) private var openFilePreview

    init(kind: String, status: String, path: String, statusColor: Color, icon: String,
         isGrouped: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.kind = kind
        self.status = status
        self.path = path
        self.statusColor = statusColor
        self.icon = icon
        self.isGrouped = isGrouped
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
                    if !isGrouped {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SoulColor.border.opacity(0.6), lineWidth: 0.5)
                )
            }
            .buttonStyle(.soulChip)
            // SOUL-SOUL_DESKTOP-182: pointing-hand cursor on the clickable
            // file chip. Without this the chip reads as a styled label and
            // users miss that it opens the preview pane.
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended:  NSCursor.arrow.set()
                }
            }

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            
            if !isGrouped || (status != "completed" && status != "pending") {
                Text(status)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
            }

            trailing()

            Spacer()
        }
    }
}

struct ToolCallCollapseButton: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Collapse")
                        .font(SoulFont.ui(11, weight: .semibold))
                }
                .foregroundStyle(SoulColor.fgSubtle)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SoulColor.border.opacity(0.45), lineWidth: 0.5)
                )
            }
            .buttonStyle(.soulHover)
            .help("Collapse tool output")
        }
        .padding(.top, 2)
    }
}

struct DefaultToolRow<Trailing: View>: View {
    let kind: String
    let title: String
    let status: String
    let location: String?
    let statusColor: Color
    let icon: String
    var isGrouped: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(kind: String, title: String, status: String, location: String?, statusColor: Color, icon: String,
         isGrouped: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.kind = kind
        self.title = title
        self.status = status
        self.location = location
        self.statusColor = statusColor
        self.icon = icon
        self.isGrouped = isGrouped
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Text(icon) }
                Text(kind)
                    .font(SoulFont.code(13, weight: .bold))
                    .foregroundStyle(SoulColor.fg)
                
                if title.lowercased() != kind.lowercased() {
                    Text(title)
                        .font(SoulFont.code(13, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if kind == "execute" && !isGrouped {
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
                    .buttonStyle(.soulChip)
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
            
            if !isGrouped || (status != "completed" && status != "pending") {
                Text(status)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
            }

            trailing()

            Spacer()
        }
    }
}

/// One aligned row in a side-by-side diff. `.unchanged` fills both columns
/// with the same text and no tint; `.removed` / `.added` fill only one side
/// and accent it with a thin colored left border + sign glyph (no full-line
/// background fill — that was the visual mud problem with the old renderer).
