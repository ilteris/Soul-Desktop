import SwiftUI

/// Popover content listing files the agent touched in this session, sorted
/// by recency. Each row shows time, op count, the tools used, and the path
/// (home-relative). Mirrors soul_view's `render_workingset`.
struct WorkingSetPanel: View {
    let entries: [WorkingSetEntry]

    private var home: String { NSHomeDirectory() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Working set")
                    .font(SoulFont.ui(12, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Text("\(entries.count) \(entries.count == 1 ? "file" : "files")")
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)

            if entries.isEmpty {
                Text("No files touched yet")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
        .background(SoulColor.bgElevated)
    }

    private func row(_ entry: WorkingSetEntry) -> some View {
        let display = entry.path.replacingOccurrences(of: home, with: "~")
        let tools = entry.tools.sorted().joined(separator: ",")
        return HStack(spacing: 8) {
            Text(timeLabel(entry.lastTimestamp))
                .font(SoulFont.code(10))
                .foregroundStyle(SoulColor.fgSubtle)
                .frame(width: 56, alignment: .leading)
            Text("×\(entry.count)")
                .font(SoulFont.code(10, weight: .semibold))
                .foregroundStyle(SoulColor.accent)
                .frame(width: 28, alignment: .leading)
            Text(tools)
                .font(SoulFont.code(10))
                .foregroundStyle(Color.green.opacity(0.85))
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(display)
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let url = URL(fileURLWithPath: (entry.path as NSString).expandingTildeInPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .help(entry.path)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

#if canImport(AppKit)
import AppKit
#endif
