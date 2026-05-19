import SwiftUI
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
        // SOUL-SOUL_DESKTOP-099: tool-call scroll-perf telemetry.
        let _ = SoulSignposts.event("ToolCallRow.body")
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
        case .output, .subagent:
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
struct ToolCallCarouselRow: View {
    let kind: String
    let items: [ThreadItem]
    var isHistorical: Bool = false
    let projectPath: String?

    @State private var index: Int = 0
    @State private var paused: Bool = false
    @State private var expanded: Bool = false

    private let cycleSeconds: Double = 0.9
    private let crossfadeSeconds: Double = 0.25
    private let timer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    private func title(of item: ThreadItem) -> String {
        if case .toolCall(_, _, let t, _, _, _) = item { return t }
        return ""
    }
    private func status(of item: ThreadItem) -> String {
        if case .toolCall(_, _, _, let s, _, _) = item { return s }
        return "completed"
    }

    private var aggregateStatus: String {
        let s = items.map { status(of: $0) }
        if s.contains(where: { $0 == "pending" || $0 == "in_progress" }) { return "in_progress" }
        if s.contains("stopped") { return "stopped" }
        // Only call the whole group "failed" when every child failed.
        // Agents routinely run probe-style shell calls that return non-zero
        // (grep with no match, `git diff --quiet`, optional cleanups) on the
        // way to a successful outcome — flagging the group "failed (3)" when
        // 2 of 3 succeeded misrepresents what happened. If at least one
        // child completed, treat the group as completed.
        if s.allSatisfy({ $0 == "failed" || $0 == "error" }) { return "failed" }
        return "completed"
    }

    private var allComplete: Bool { aggregateStatus == "completed" }

    private var statusColor: Color {
        switch aggregateStatus {
        case "pending", "in_progress": return .orange
        case "completed": return .green
        case "failed": return .red
        case "stopped": return .gray
        default: return SoulColor.fgSubtle
        }
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

    private var shouldAdvance: Bool {
        // Advance forward through items as they appear; stop at the last
        // one. When new items append (more tool calls arrive in the same
        // run), `index < items.count - 1` becomes true again and we
        // resume advancing toward the new tail. Never wrap.
        items.count > 1 && !paused && !expanded && index < items.count - 1
    }

    private var currentTitle: String {
        guard !items.isEmpty else { return "" }
        return title(of: items[min(index, items.count - 1)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.08)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if !icon.isEmpty { Text(icon) }
                        Text(kind)
                            .font(SoulFont.code(13, weight: .bold))
                            .foregroundStyle(SoulColor.fg)
                        Text(currentTitle)
                            .font(SoulFont.code(13, weight: .regular))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: crossfadeSeconds), value: index)
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
                .onHover { paused = $0 }

                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(aggregateStatus)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)

                Text("(\(items.count))")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)

                if kind == "execute" || kind == "read" {
                    Button {
                        copyAllTitles()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .padding(6)
                    }
                    .buttonStyle(.soulHover)
                    .help("Copy all \(kind) arguments")
                }

                Spacer()
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.id) { item in
                        ThreadItemRow(projectPath: projectPath, item: item, isHistorical: isHistorical, isGrouped: true)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .onReceive(timer) { _ in
            guard shouldAdvance else { return }
            withAnimation(.easeInOut(duration: crossfadeSeconds)) {
                index = min(index + 1, items.count - 1)
            }
        }
    }

    private func copyAllTitles() {
        let titles = items.compactMap { item -> String? in
            if case .toolCall(_, _, let t, _, _, _) = item { return t }
            return nil
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(titles, forType: .string)
    }
}

struct ToolCallGroupRow: View {
    let kind: String
    let title: String
    let location: String?
    let items: [ThreadItem]
    var isHistorical: Bool = false

    @State private var expanded: Bool = false

    private var filePath: String? {
        if let loc = location, looksLikePath(loc) { return loc }
        if looksLikePath(title) { return title }
        return nil
    }

    private var status: String {
        // Use the status of the last item in the group
        if case .toolCall(_, _, _, let s, _, _) = items.last {
            return s
        }
        return "completed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = filePath {
                FileChipRow(
                    kind: kind, status: status, path: path,
                    statusColor: statusColor, icon: icon,
                    trailing: { chevron }
                )
                .contextMenu {
                    Button("Copy combined diff") { copyCombinedDiff() }
                }
            } else {
                DefaultToolRow(
                    kind: kind, title: title, status: status, location: location,
                    statusColor: statusColor, icon: icon,
                    trailing: { chevron }
                )
                .contextMenu {
                    Button("Copy combined diff") { copyCombinedDiff() }
                }
            }
            if expanded {
                let visibleItems = items.prefix(10)
                let remainingCount = items.count - visibleItems.count
                
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleItems, id: \.id) { item in
                        ThreadItemRow(projectPath: nil, item: item, isHistorical: isHistorical, isGrouped: true)
                    }
                    
                    if remainingCount > 0 {
                        Text("\(remainingCount) more...")
                            .font(SoulFont.ui(11, weight: .bold))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        HStack(spacing: 6) {
            diffStats
            Button {
                copyCombinedDiff()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(6)
            }
            .buttonStyle(.soulChip)
            .help("Copy combined diff")

            Button {
                withAnimation(.easeOut(duration: 0.08)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(6)
            }
            .buttonStyle(.soulHover)
        }
    }

    @ViewBuilder
    private var diffStats: some View {
        let (added, removed) = items.reduce((0, 0)) { res, item in
            if case .toolCall(_, _, _, _, _, let details) = item, let details = details {
                let (a, r) = countLines(details)
                return (res.0 + a, res.1 + r)
            }
            return res
        }
        
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
        case .output, .subagent:
            return (0, 0)
        }
    }

    private func lineCount(_ s: String) -> Int {
        if s.isEmpty { return 0 }
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

    private func copyCombinedDiff() {
        var combined = ""
        for item in items {
            if case .toolCall(_, _, let t, _, _, let details) = item,
               let details = details {
                let filename = (t as NSString).lastPathComponent
                switch details.kind {
                case .edit(let oldS, let newS):
                    combined += "--- \(filename) (old)\n+++ \(filename) (new)\n"
                    combined += oldS.components(separatedBy: "\n").map { "-\($0)" }.joined(separator: "\n") + "\n"
                    combined += newS.components(separatedBy: "\n").map { "+\($0)" }.joined(separator: "\n") + "\n"
                case .write(let content):
                    combined += "--- /dev/null\n+++ \(filename)\n"
                    combined += content.components(separatedBy: "\n").map { "+\($0)" }.joined(separator: "\n") + "\n"
                case .output(let text):
                    combined += "--- \(filename) output ---\n\(text)\n"
                case .subagent:
                    // Subagent rows aren't part of file-diff aggregation.
                    continue
                }
                combined += "\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }
}



private struct FileChipRow<Trailing: View>: View {
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

private struct DefaultToolRow<Trailing: View>: View {
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
private enum DiffRow {
    case unchanged(leftNum: Int, rightNum: Int, text: String)
    case removed(num: Int, text: String)
    case added(num: Int, text: String)
}

private struct DiffView: View {
    let details: ToolCallDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch details.kind {
            case .edit(let oldString, let newString):
                diffRows(old: oldString, new: newString, startLine: details.startLine ?? 1)
            case .write(let content):
                // Pure addition: every line is `.added`. Same renderer; the
                // left column shows blank for each row.
                diffRows(old: "", new: content, startLine: details.startLine ?? 1)
            case .output(let text):
                Text(text)
                    .font(SoulFont.code(12))
                    .foregroundStyle(SoulColor.fg)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .subagent:
                // Subagent calls render via SubagentCard at the ThreadItemRow
                // level — they don't reach DiffView. Defensive empty case to
                // keep the switch exhaustive.
                EmptyView()
            }
        }
        .padding(.vertical, details.kind.isOutput ? 0 : 6)
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

    /// Compute aligned diff rows via Swift's `CollectionDifference` so
    /// unchanged lines render once across both columns (no tint) instead of
    /// once per column (full red + full green wash). Drops the wholesale-
    /// rewrite case from 600+ noisy rows to ~the actual change count.
    @ViewBuilder
    private func diffRows(old: String, new: String, startLine: Int) -> some View {
        let rows = Self.computeRows(old: old, new: new, startLine: startLine)
        let gutter = Self.gutterWidth(for: rows)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                diffRowView(row, gutterWidth: gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// SOUL-SOUL_DESKTOP-169: unified inline diff layout. The old two-column
    /// side-by-side split removed/added pairs across the row, which wasted
    /// horizontal space and made cmd-F scanning awkward. New layout mirrors
    /// `git diff --unified` / GitHub's inline view: two narrow gutters
    /// (old | new line nums), then one full-width text body with a 2pt
    /// colored left bar on changed rows.
    @ViewBuilder
    private func diffRowView(_ row: DiffRow, gutterWidth: CGFloat) -> some View {
        switch row {
        case .unchanged(let lNum, let rNum, let text):
            inlineRow(oldNum: lNum, newNum: rNum, sign: " ", text: text, tint: nil, gutterWidth: gutterWidth)
        case .removed(let num, let text):
            inlineRow(oldNum: num, newNum: nil, sign: "-", text: text, tint: .red, gutterWidth: gutterWidth)
        case .added(let num, let text):
            inlineRow(oldNum: nil, newNum: num, sign: "+", text: text, tint: .green, gutterWidth: gutterWidth)
        }
    }

    /// Inline row: `oldNum | newNum | ±  text`. `tint == nil` means unchanged
    /// (no left bar, no background); tinted rows get a 2pt colored left bar
    /// + a very faint background wash — enough signal at scroll-skim
    /// distance, light enough that hundred-line diffs don't read as a stripe
    /// pattern.
    private func inlineRow(oldNum: Int?, newNum: Int?, sign: String, text: String,
                           tint: Color?, gutterWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(oldNum.map(String.init) ?? "")
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fgSubtle.opacity(0.6))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text(newNum.map(String.init) ?? "")
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fgSubtle.opacity(0.6))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Text(sign)
                .font(SoulFont.code(12, weight: .bold))
                .foregroundStyle((tint ?? SoulColor.fgSubtle).opacity(0.85))
                .frame(width: 10, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(tint?.opacity(0.06) ?? Color.clear)
        .overlay(alignment: .leading) {
            if let tint {
                Rectangle()
                    .fill(tint.opacity(0.65))
                    .frame(width: 2)
            }
        }
    }

    /// Walk `oldLines` and `newLines` in tandem using the diff's
    /// removed/added offset sets as an oracle. Unchanged lines emit a single
    /// aligned row; removed and added lines emit one-sided rows.
    private static func computeRows(old: String, new: String, startLine: Int) -> [DiffRow] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        // CollectionDifference.removals/insertions are arrays of `Change`
        // enum cases — pattern-match to extract the offset.
        var removedOffsets: Set<Int> = []
        for change in diff.removals {
            if case let .remove(offset, _, _) = change { removedOffsets.insert(offset) }
        }
        var addedOffsets: Set<Int> = []
        for change in diff.insertions {
            if case let .insert(offset, _, _) = change { addedOffsets.insert(offset) }
        }

        var rows: [DiffRow] = []
        var i = 0  // oldLines cursor
        var j = 0  // newLines cursor
        let lBase = startLine
        let rBase = startLine

        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedOffsets.contains(i) {
                rows.append(.removed(num: lBase + i, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, addedOffsets.contains(j) {
                rows.append(.added(num: rBase + j, text: newLines[j]))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                // Both cursors on common (unchanged) content.
                rows.append(.unchanged(leftNum: lBase + i, rightNum: rBase + j, text: oldLines[i]))
                i += 1
                j += 1
            } else if i < oldLines.count {
                // Defensive: trailing old past the diff's known removals.
                rows.append(.removed(num: lBase + i, text: oldLines[i]))
                i += 1
            } else {
                rows.append(.added(num: rBase + j, text: newLines[j]))
                j += 1
            }
        }
        return rows
    }

    /// Gutter wide enough for the largest line number that appears in any
    /// row. Each char ~7pt in 12pt monospace, plus 4pt of breathing room.
    private static func gutterWidth(for rows: [DiffRow]) -> CGFloat {
        var maxNum = 1
        for row in rows {
            switch row {
            case .unchanged(let l, let r, _): maxNum = max(maxNum, l, r)
            case .removed(let n, _): maxNum = max(maxNum, n)
            case .added(let n, _): maxNum = max(maxNum, n)
            }
        }
        let chars = max(3, String(maxNum).count)
        return CGFloat(chars) * 7 + 4
    }
}
