import SwiftUI

/// Top playback strip for replay mode: pause/play, scrubber, counters, exit.
struct PlaybackBar: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void

    private var progress: Double {
        guard controller.total > 0 else { return 0 }
        return Double(controller.index) / Double(controller.total)
    }

    private var statusLabel: String {
        if controller.finished { return "done" }
        if controller.isPaused { return "paused" }
        return "playing"
    }

    private var statusColor: Color {
        if controller.finished { return SoulColor.fgSubtle }
        if controller.isPaused { return .orange }
        return SoulColor.accent
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { controller.togglePause() }) {
                SoulIcon(
                    name: controller.isPaused || controller.finished ? "play.fill" : "pause.fill",
                    size: 11,
                    color: SoulColor.accent
                )
                .frame(width: 22, height: 22)
                .background(SoulColor.accentMuted, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(controller.finished)

            Text(statusLabel)
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 56, alignment: .leading)

            ProgressBar(progress: progress)
                .frame(height: 6)

            Text("\(controller.index)/\(controller.total)")
                .font(SoulFont.code(11))
                .foregroundStyle(SoulColor.fgMuted)

            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)

            Text("\(controller.promptCount) prompts, \(controller.replyCount) replies")
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgMuted)

            Text("·")
                .foregroundStyle(SoulColor.fgSubtle)

            Text("space to \(controller.isPaused ? "resume" : "pause")")
                .font(SoulFont.ui(11))
                .foregroundStyle(SoulColor.fgSubtle)

            Spacer(minLength: 8)

            Button(action: onExit) {
                Text("Exit replay")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SoulColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SoulColor.bgElevated.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
        }
    }
}

private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SoulColor.surface)
                Capsule()
                    .fill(SoulColor.accent)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * progress)))
            }
        }
    }
}
