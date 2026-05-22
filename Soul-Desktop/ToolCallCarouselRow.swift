import SwiftUI
import Combine

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
                    ToolCallCollapseButton {
                        withAnimation(.easeOut(duration: 0.08)) { expanded = false }
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
