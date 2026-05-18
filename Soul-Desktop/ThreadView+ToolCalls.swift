import SwiftUI
import Combine

/// Tool-call view family lifted out of ThreadView. ToolCallRow is the
/// heart — it dispatches by kind (Edit/Write/Read/Bash/Glob/Plan/Output/
/// subagent) and renders the appropriate body (inline diff, file chip,
/// status capsule). The carousel and group rows handle consecutive
/// same-kind tool calls. DefaultToolRow is the generic catch-all.
/// MissingFilePlaceholder and DiffView are helpers used by the Edit/Write
/// paths.
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

    private var resolvedPath: String? {
        guard let path = filePath else { return nil }
        if path.hasPrefix("/" ) { return path }
        guard let projectPath = projectPath else { return path }
        return (projectPath as NSString).appendingPathComponent(path)
    }

    private var fileExists: Bool {
        guard let path = resolvedPath else { return true }
        return FileManager.default.fileExists(atPath: path)
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
            if diffExpanded, let details {
                if !fileExists && filePath != nil {
                    MissingFilePlaceholder(path: filePath!)
                        .padding(.leading, 12)
                } else {
                    DiffView(details: details)
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
                    withAnimation(.easeInOut(duration: 0.15)) { diffExpanded.toggle() }
                } label: {
                    Image(systemName: diffExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(SoulColor.fgSubtle)
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
            return (lineCount(newString), lineCount(oldString))
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

private struct MissingFilePlaceholder: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 11))
                .foregroundStyle(SoulColor.fgSubtle)
            Text("File no longer on disk")
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgMuted)
            Text((path as NSString).lastPathComponent)
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgSubtle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
        )
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
    @State private var fullyToured: Bool = false
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
        if s.contains(where: { $0 == "failed" || $0 == "error" }) { return "failed" }
        if s.contains(where: { $0 == "pending" || $0 == "in_progress" }) { return "in_progress" }
        if s.contains("stopped") { return "stopped" }
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
        items.count > 1 && !paused && !expanded && (!allComplete || !fullyToured)
    }

    private var currentTitle: String {
        guard !items.isEmpty else { return "" }
        return title(of: items[min(index, items.count - 1)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
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
            guard items.count > 1 else { return }
            if !shouldAdvance {
                // Once complete and toured, settle on the last item.
                if allComplete && fullyToured && index != items.count - 1 {
                    withAnimation(.easeInOut(duration: crossfadeSeconds)) {
                        index = items.count - 1
                    }
                }
                return
            }
            let next = (index + 1) % items.count
            index = next
            if next == items.count - 1 { fullyToured = true }
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
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgSubtle)
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
            return (lineCount(newString), lineCount(oldString))
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

private struct DiffView: View {
    let details: ToolCallDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch details.kind {
            case .edit(let oldString, let newString):
                HStack(alignment: .top, spacing: 1) {
                    column(text: oldString, sign: "-", tint: .red,
                           start: details.startLine, gutterWidth: gutterWidth(oldString, newString))
                    column(text: newString, sign: "+", tint: .green,
                           start: details.startLine, gutterWidth: gutterWidth(oldString, newString))
                }
            case .write(let content):
                HStack(alignment: .top, spacing: 1) {
                    column(text: "", sign: " ", tint: SoulColor.fgSubtle,
                           start: nil, gutterWidth: gutterWidth("", content))
                    column(text: content, sign: "+", tint: .green,
                           start: details.startLine ?? 1, gutterWidth: gutterWidth("", content))
                }
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
