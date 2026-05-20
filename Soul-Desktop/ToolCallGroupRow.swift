import SwiftUI

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



