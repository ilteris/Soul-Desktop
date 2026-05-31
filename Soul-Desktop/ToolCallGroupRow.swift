import SwiftUI
import SoulCore

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

    /// The `ToolCallDetails` for each edit in the consolidated card, in arrival
    /// order. This is the "append" sequence — each new edit to the file lands
    /// as another entry, and the stacked diff below grows by one hunk.
    private var editDetails: [ToolCallDetails] {
        items.compactMap { item in
            if case .toolCall(_, _, _, _, _, let details) = item { return details }
            return nil
        }
    }

    /// Anchor line for the header chip. A consolidated card spans several
    /// edits at different lines, so a single `:line` only makes sense when
    /// every edit shares the same anchor — otherwise the per-hunk gutters
    /// below carry the precise lines and the header stays a bare filename.
    private var sharedStartLine: Int? {
        let lines = editDetails.map { $0.startLine }
        guard let first = lines.first ?? nil, lines.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = filePath {
                FileChipRow(
                    kind: kind, status: status, path: path,
                    statusColor: statusColor, icon: icon,
                    startLine: sharedStartLine,
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
            // Consolidated single-card body: each edit's diff stacked in
            // arrival order, no per-edit chips and no "N more…" cap. Reads as
            // one edit card whose diff keeps appending as the agent makes
            // successive edits to the same file.
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(editDetails.enumerated()), id: \.offset) { _, details in
                        DiffView(details: details)
                    }
                    ToolCallCollapseButton {
                        withAnimation(.easeOut(duration: 0.08)) { expanded = false }
                    }
                }
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
        case .output, .subagent, .claudeAgent:
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
                case .subagent, .claudeAgent:
                    // Agent rows aren't part of file-diff aggregation.
                    continue
                }
                combined += "\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }
}

