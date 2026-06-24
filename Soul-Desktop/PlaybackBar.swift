import SwiftUI

/// Top playback strip for replay mode: pause/play, scrubber, counters, exit.
struct PlaybackBar: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void
    @State private var showWorkingSet: Bool = false
    @State private var availableWidth: CGFloat = 0
    /// Persisted across launches so a user who lives in reading mode doesn't
    /// re-toggle on every replay open. ReplayView reads the same key via
    /// @AppStorage.
    @AppStorage("soul.replay.readingMode") private var readingMode: Bool = true

    private enum LayoutMode {
        case regular
        case compact
        case minimal
    }

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

    private var layoutMode: LayoutMode {
        guard availableWidth > 0 else { return .regular }
        if availableWidth < 540 { return .minimal }
        if availableWidth < 1_040 { return .compact }
        return .regular
    }

    var body: some View {
        Group {
            switch layoutMode {
            case .regular:
                regularLayout
            case .compact:
                compactLayout
            case .minimal:
                minimalLayout
            }
        }
        .padding(.horizontal, layoutMode == .minimal ? 10 : 16)
        .padding(.vertical, 8)
        .background(SoulColor.bgElevated.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in
                        availableWidth = width
                    }
            }
        )
    }

    private var regularLayout: some View {
        HStack(spacing: 12) {
            playbackControls
            statusText(width: 56)
            readingModeTrigger(showTitle: true)

            Scrubber(
                progress: progress,
                total: controller.total,
                onSeek: { idx in controller.seek(to: idx) }
            )
            .frame(height: 14)
            .frame(minWidth: 90)
            .layoutPriority(1)

            progressText
            separator
            replaySummaryText(short: false)
            separator
            spaceHintText

            Spacer(minLength: 8)

            workingSetTrigger(showTitle: true)

            SpeedSlider(speed: controller.speed) { controller.setSpeed($0) }

            exitButton(title: "Exit replay")
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                playbackControls
                statusText(width: 54)
                readingModeTrigger(showTitle: false)
                replaySummaryText(short: true)
                Spacer(minLength: 8)
                workingSetTrigger(showTitle: false)
                exitButton(title: "Exit")
            }

            HStack(spacing: 10) {
                Scrubber(
                    progress: progress,
                    total: controller.total,
                    onSeek: { idx in controller.seek(to: idx) }
                )
                .frame(height: 14)
                .frame(minWidth: 160)
                .layoutPriority(1)

                progressText
                SpeedSlider(speed: controller.speed, sliderWidth: 86) { controller.setSpeed($0) }
            }
        }
    }

    private var minimalLayout: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                playbackControls
                statusText(width: 50)
                compactProgressText
                Spacer(minLength: 6)
                readingModeTrigger(showTitle: false)
                workingSetTrigger(showTitle: false)
                exitButton(title: nil)
            }

            HStack(spacing: 8) {
                Scrubber(
                    progress: progress,
                    total: controller.total,
                    onSeek: { idx in controller.seek(to: idx) }
                )
                .frame(height: 14)
                .frame(minWidth: 120)
                .layoutPriority(1)

                SpeedSlider(speed: controller.speed, sliderWidth: 72, showLabel: false) { controller.setSpeed($0) }
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
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
                SoulIcon(name: "forward.end.fill", size: SoulMetric.iconHint, color: SoulColor.fgMuted)
                    .frame(width: 22, height: 22)
                    .background(SoulColor.surface, in: Circle())
            }
            .buttonStyle(.soulChip)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .help("Jump to end (⌘→)")
            .disabled(controller.finished)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func statusText(width: CGFloat) -> some View {
        Text(statusLabel)
            .font(SoulFont.ui(11, weight: .regular))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private var progressText: some View {
        playbackPositionText(short: false)
    }

    private var compactProgressText: some View {
        playbackPositionText(short: true)
    }

    private func playbackPositionText(short: Bool) -> some View {
        Text("\(positionLabel(controller.index, short: short))/\(positionLabel(controller.total, short: short))")
            .font(SoulFont.code(11))
            .foregroundStyle(SoulColor.fgMuted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func positionLabel(_ value: Int, short: Bool) -> String {
        guard short else { return "\(value)" }
        let n = Double(value)
        if value >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000).replacingOccurrences(of: ".0", with: "") }
        if value >= 1_000 { return String(format: "%.1fk", n / 1_000).replacingOccurrences(of: ".0", with: "") }
        return "\(value)"
    }

    private func replaySummaryText(short: Bool) -> some View {
        Text(short ? "\(controller.promptCount)p / \(controller.replyCount)r" : "\(controller.promptCount) prompts, \(controller.replyCount) replies")
            .font(SoulFont.ui(11))
            .foregroundStyle(SoulColor.fgMuted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help("\(controller.promptCount) prompts, \(controller.replyCount) replies")
    }

    private var spaceHintText: some View {
        Text("space to \(controller.isPaused ? "resume" : "pause")")
            .font(SoulFont.ui(11))
            .foregroundStyle(SoulColor.fgSubtle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(SoulColor.fgSubtle)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Reading-mode toggle. Strips tool calls, plans, status, errors, and
    /// agent-thought rows so the replay reads like a long-form transcript
    /// (user prompts + assistant prose + finalize quad). Useful for skimming
    /// "what did I decide here" on an old session; the full plumbing is one
    /// click away.
    private func readingModeTrigger(showTitle: Bool) -> some View {
        Button {
            readingMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: readingMode ? "book.fill" : "book")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(readingMode ? .white : SoulColor.accent)
                if showTitle {
                    Text(readingMode ? "Reading on" : "Reading")
                        .font(SoulFont.ui(11, weight: .semibold))
                        .foregroundStyle(readingMode ? .white : SoulColor.accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minWidth: showTitle ? nil : 28)
            .padding(.horizontal, showTitle ? 10 : 6)
            .padding(.vertical, 4)
            .background(
                readingMode ? SoulColor.accent : SoulColor.accentMuted,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(SoulColor.accent.opacity(readingMode ? 0 : 0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.soulChip)
        .help(readingMode
              ? "Reading mode — tool calls hidden. Click for full transcript."
              : "Reading mode — show only prompts, replies, and finalize.")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func workingSetTrigger(showTitle: Bool) -> some View {
        Button {
            showWorkingSet.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgMuted)
                if showTitle {
                    Text("\(controller.workingSet.count)")
                        .font(SoulFont.code(11, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                    Text(controller.workingSet.count == 1 ? "file" : "files")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: showTitle ? nil : 28)
            .padding(.horizontal, showTitle ? 8 : 6)
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
        .fixedSize(horizontal: true, vertical: false)
    }

    private func exitButton(title: String?) -> some View {
        Button(action: onExit) {
            HStack(spacing: 5) {
                if let title {
                    Text(title)
                        .font(SoulFont.ui(11, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                }
            }
            .frame(minWidth: title == nil ? 28 : nil)
            .padding(.horizontal, title == nil ? 6 : 8)
            .padding(.vertical, 4)
            .background(SoulColor.surface, in: Capsule())
        }
        .buttonStyle(.soulChip)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Exit replay (Esc)")
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Log-scale speed slider: 0.25× → 4× spaced as powers of 2 so 1× sits dead
/// center. Display label shows the current speed; cmd-click snaps to 1×.
private struct SpeedSlider: View {
    let speed: Double
    var sliderWidth: CGFloat = 110
    var showLabel: Bool = true
    var onChange: (Double) -> Void

    // We treat the slider value as log2(speed): -2 (0.25×) ... 3 (8×).
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
            if showLabel {
                Text(label)
                    .font(SoulFont.code(10, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                    .lineLimit(1)
                    .frame(width: 36, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { onChange(1.0) }
                    .help("Click to reset to 1×")
            }

            Slider(value: sliderBinding, in: -2.0...3.0)
                .controlSize(.mini)
                .tint(SoulColor.accent)
                .frame(width: sliderWidth)
        }
        .fixedSize(horizontal: true, vertical: false)
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

/// Interactive scrubber: click anywhere to seek, drag to scrub. The hit
/// region is the full 14pt height so the bar is comfortably grabbable even
/// though the visible track is only 6pt tall. Shows a playhead disc at the
/// current position that grows slightly while dragging.
private struct Scrubber: View {
    let progress: Double
    let total: Int
    var onSeek: (Int) -> Void

    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0, min(1, progress))
            let knobX = width * clamped
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SoulColor.surface)
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                Capsule()
                    .fill(SoulColor.accent)
                    .frame(width: max(0, knobX), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                Circle()
                    .fill(SoulColor.accent)
                    .frame(width: isDragging ? 12 : 10, height: isDragging ? 12 : 10)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: knobX - (isDragging ? 6 : 5))
                    .animation(.easeOut(duration: 0.1), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        applySeek(at: value.location.x, width: width)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }

    private func applySeek(at x: CGFloat, width: CGFloat) {
        guard total > 0, width > 0 else { return }
        let fraction = max(0, min(1, x / width))
        let target = Int((fraction * Double(total)).rounded())
        onSeek(target)
    }
}
