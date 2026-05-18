import SwiftUI

/// Top playback strip for replay mode: pause/play, scrubber, counters, exit.
struct PlaybackBar: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void
    @State private var showWorkingSet: Bool = false

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
            .buttonStyle(.soulChip)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(controller.finished)

            // Jump-to-end: skip the rest of the playback and reveal the
            // entire transcript at once. Useful when you only care about the
            // final state and don't want to wait through the scrub.
            Button(action: { controller.seek(to: controller.total) }) {
                SoulIcon(name: "forward.end.fill", size: 10, color: SoulColor.fgMuted)
                    .frame(width: 22, height: 22)
                    .background(SoulColor.surface, in: Circle())
            }
            .buttonStyle(.soulChip)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .help("Jump to end (⌘→)")
            .disabled(controller.finished)

            Text(statusLabel)
                .font(SoulFont.ui(11, weight: .regular))
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

            workingSetTrigger

            SpeedSlider(speed: controller.speed) { controller.setSpeed($0) }

            Button(action: onExit) {
                Text("Exit replay")
                    .font(SoulFont.ui(11, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SoulColor.surface, in: Capsule())
            }
            .buttonStyle(.soulChip)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SoulColor.bgElevated.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
        }
    }

    private var workingSetTrigger: some View {
        Button {
            showWorkingSet.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("\(controller.workingSet.count)")
                    .font(SoulFont.code(11, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                Text(controller.workingSet.count == 1 ? "file" : "files")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.surface, in: Capsule())
        }
        .buttonStyle(.soulChip)
        .disabled(controller.workingSet.isEmpty)
        .opacity(controller.workingSet.isEmpty ? 0.5 : 1)
        .help("Files touched in this session")
        .popover(isPresented: $showWorkingSet, arrowEdge: .top) {
            WorkingSetPanel(entries: controller.workingSet)
        }
    }
}

/// Log-scale speed slider: 0.25× → 4× spaced as powers of 2 so 1× sits dead
/// center. Display label shows the current speed; cmd-click snaps to 1×.
private struct SpeedSlider: View {
    let speed: Double
    var onChange: (Double) -> Void

    // We treat the slider value as log2(speed): -2 (0.25×) ... 2 (4×).
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { log2(speed) },
            set: { onChange(pow(2.0, $0)) }
        )
    }

    private var label: String {
        if abs(speed - 1.0) < 0.05 { return "1×" }
        if speed < 1 { return String(format: "%.2f×", speed) }
        return String(format: "%.1f×", speed)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(SoulFont.code(10, weight: .regular))
                .foregroundStyle(SoulColor.fgMuted)
                .frame(width: 36, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { onChange(1.0) }
                .help("Click to reset to 1×")

            Slider(value: sliderBinding, in: -2.0...2.0)
                .controlSize(.mini)
                .tint(SoulColor.accent)
                .frame(width: 110)
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
