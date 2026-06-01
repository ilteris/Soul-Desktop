import SwiftUI
import SoulCore

/// Non-row canvas content lifted out of ThreadView: the finalize and
/// plan cards that appear inline as ThreadItems, the working indicator
/// that floats at the canvas bottom while a turn is in flight, and the
/// agent log popover (stderr + protocol trace) shown when the user
/// clicks the inactivity capsule.
///
/// Pure file shuffle, no behavior change. ThreadView refactor 3/N —
/// agent ergonomics: shrink ThreadView.swift below the threshold where
/// a coding agent can hold it in context.

/// Structured Quad card pulled from a session's finalize JSON. Renders at
/// the tail of a hydrated read-only transcript so opening a finalized
/// session immediately surfaces what was accomplished.
struct FinalizeCard: View {
    var title: String = "Finalize"
    var icon: String = "checkmark.seal.fill"
    let intent: String?
    let summary: String?
    let rationale: String?
    let fixed: String?
    let nextStep: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(SoulColor.accent)
                Text(title)
                    .font(SoulFont.ui(15, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
            }
            if let intent, !intent.isEmpty {
                field(label: "Intent", value: intent)
            }
            if let summary, !summary.isEmpty {
                field(label: "Summary", value: summary)
            }
            if let rationale, !rationale.isEmpty {
                field(label: "Rationale", value: rationale)
            }
            if let fixed, !fixed.isEmpty {
                field(label: "Fixed", value: fixed)
            }
            if let nextStep, !nextStep.isEmpty {
                field(label: "Next", value: nextStep)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SoulColor.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func field(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(SoulFont.ui(11, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .tracking(0.5)
            Text(value)
                .font(SoulFont.ui(15))
                .foregroundStyle(SoulColor.fg)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}



struct PlanCard: View {
    let entries: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                Text("Plan")
                    .font(SoulFont.ui(12, weight: .bold))
            }
            .foregroundStyle(SoulColor.fgSubtle)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries, id: \.self) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(entry.status == "completed" ? .green : SoulColor.fgSubtle)
                            .padding(.top, 1)

                        Text(entry.content)
                            .font(SoulFont.ui(13))
                            .foregroundStyle(entry.status == "completed" ? SoulColor.fgMuted : SoulColor.fg)
                    }
                }
            }
        }
        .padding(12)
        .background(SoulColor.bgElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
        )
    }
}

/// Inline canvas indicator shown while the background `claude -p`
/// subprocess is composing the seed prompt for a freshly-branched chat.
/// Mirrors `WorkingIndicator`'s visual treatment so the transition into
/// the agent's first reply feels continuous: spinner → user bubble →
/// agent working.
struct BranchSeedIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(SoulColor.border.opacity(0.3), lineWidth: 2)
                    .frame(width: 14, height: 14)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(SoulColor.accent, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
            Text("Summarizing previous chat…")
                .font(SoulFont.ui(12, weight: .medium))
                .foregroundStyle(SoulColor.fg)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct WorkingIndicator: View {
    @Bindable var controller: ThreadController

    /// Compact elapsed format: "5s" under a minute, "1:23" under an hour,
    /// "1:23:45" otherwise. Keeps the indicator narrow while a turn is short
    /// and still readable on long-running agents.
    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let _ = SoulSignposts.event("Flash.WorkingIndicator.body", "isWorking=\(controller.isWorking) items=\(controller.items.count)")
        return TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let secondsSinceActivity = Int(ctx.date.timeIntervalSince(controller.lastActivityAt))
            // SOUL-SOUL_DESKTOP-024: stall threshold is now provider-tuned
            // (Gemini 90s default, Claude 60s, Pi 120s — see Provider
            // .stallBudgetSeconds) instead of a hardcoded 30s. Settings →
            // Advanced "Stall budgets" lets the user override per provider.
            let budget = controller.provider.stallBudgetSeconds
            // SOUL-SOUL_DESKTOP-378: only escalate to the stalled-warning
            // treatment when a turn is actually in flight. `loadSession`
            // sets isWorking=true to drive the loading affordance but never
            // sets turnStartedAt; without this gate the quiet time since the
            // controller was constructed crosses the budget and we render the
            // full "Thinking… / No activity for Ns / auto-recover" warning —
            // and its spinner — for a session that is merely hydrating from
            // disk, with no watchdog running to ever clear it.
            let hasLiveTurn = controller.turnStartedAt != nil
            let isStalled = hasLiveTurn && secondsSinceActivity >= budget
            let ceiling = StallPolicy.autoCancelCeilingSeconds
            let secondsUntilAutoCancel = max(0, ceiling - secondsSinceActivity)
            // SOUL-SOUL_DESKTOP-369: transport-level reconnect is a distinct,
            // higher-fidelity signal than the quiet-time stall heuristic, and
            // takes visual priority — the runtime told us the stream dropped.
            let reconnectMessage: String? = {
                if case .reconnecting(let message) = controller.connectivity { return message }
                return nil
            }()

            HStack(spacing: 12) {
                // SOUL-203 revision: drop the sparkle glyph — the shimmer
                // alone reads as motion. Stalled state keeps the small
                // orange ring spinner so the warning has a static anchor.
                if isStalled || reconnectMessage != nil {
                    let ringColor: Color = reconnectMessage != nil ? .yellow : .orange
                    ZStack {
                        Circle()
                            .stroke(SoulColor.border.opacity(0.3), lineWidth: 2)
                            .frame(width: 12, height: 12)
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(ringColor, lineWidth: 2)
                            .frame(width: 12, height: 12)
                        // SOUL-SOUL_DESKTOP-378: static ring, no rotation. A
                        // `repeatForever` rotationEffect is a SwiftUI shape
                        // animation — SwiftUI drives it on the main thread and
                        // re-encodes the DisplayList every frame (60-120fps).
                        // Whenever a stalled/wedged indicator stayed mounted
                        // that pinned ~20% CPU at idle. The stalled state is a
                        // warning anchor, not a progress spinner; a steady ring
                        // reads correctly and costs nothing.
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if reconnectMessage != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.system(size: 11))
                                Text("Reconnecting…")
                            }
                            .font(SoulFont.ui(13, weight: .medium))
                            .foregroundStyle(Color.yellow)
                        } else if isStalled {
                            Text("Thinking…")
                                .font(SoulFont.ui(13, weight: .medium))
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("Agent working…")
                                .font(SoulFont.ui(13, weight: .medium))
                                .foregroundStyle(SoulColor.accent)
                        }
                        if let started = controller.turnStartedAt {
                            let elapsed = max(0, Int(ctx.date.timeIntervalSince(started)))
                            Text(Self.formatElapsed(elapsed))
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                                .monospacedDigit()
                        }
                    }

                    if let reconnectMessage {
                        // The runtime's own wire detail, e.g. "Reconnecting… 2/5".
                        // Higher fidelity than NWPathMonitor, which would report
                        // "online" through a captive portal or TLS-handshake death.
                        Text(reconnectMessage)
                            .font(SoulFont.ui(10))
                            .foregroundStyle(Color.yellow.opacity(0.85))
                            .lineLimit(1)
                    } else if isStalled {
                        HStack(spacing: 4) {
                            Text("No activity for \(secondsSinceActivity)s")
                                .font(SoulFont.ui(10))
                                .foregroundStyle(Color.orange.opacity(0.8))

                            // Auto-cancel countdown — only shows once we're
                            // within 60s of the hard ceiling so it doesn't
                            // distract during normal slow turns.
                            if secondsUntilAutoCancel <= 60 && secondsUntilAutoCancel > 0 {
                                Text("· auto-recover in \(secondsUntilAutoCancel)s")
                                    .font(SoulFont.ui(10))
                                    .foregroundStyle(Color.orange.opacity(0.6))
                            }

                            // Recover is always available once we've crossed
                            // the budget — queue depth no longer gates it.
                            // SOUL-SOUL_DESKTOP-024: prior Skip-ahead required
                            // a non-empty queue, which left empty-queue stalls
                            // (the common case) without any recovery
                            // affordance besides force-quit.
                            Button {
                                Task { await controller.recoverStalledTurn(source: "manual") }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: controller.queuedPrompts.isEmpty
                                          ? "arrow.uturn.backward.circle"
                                          : "forward.fill")
                                    Text(controller.queuedPrompts.isEmpty ? "Recover" : "Skip ahead")
                                }
                                .font(SoulFont.ui(10, weight: .bold))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.soulChip)
                            .accessibilityHint(Text(verbatim: controller.queuedPrompts.isEmpty
                                ? "Cancel the stalled turn and unblock the thread"
                                : "Cancel the stalled turn and dispatch the next queued message"))
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
}

struct AgentLogPanel: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agent log")
                    .font(SoulFont.ui(12, weight: .bold))
                Spacer()
                Text("\(lines.count) lines")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(lines.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy log")
                .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SoulColor.bgElevated)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(Self.attributed(line))
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 500, height: 300)
        .background(SoulColor.bg)
    }

    /// SOUL-201: bold the `key` portion of every `key=value` token in a log
    /// line so structured payloads (`event=lifecycle provider=claude note=…`)
    /// are scannable at a glance without forcing the whole line into bold.
    /// Anything that isn't a `key=value` token stays in regular weight.
    private static func attributed(_ line: String) -> AttributedString {
        var out = AttributedString(line)
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_.\-]*)(?==)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: line, range: range)
        for m in matches.reversed() {
            guard m.numberOfRanges >= 1,
                  let r = Range(m.range, in: line),
                  let attrRange = Range(r, in: out) else { continue }
            out[attrRange].font = SoulFont.code(11, weight: .bold)
        }
        return out
    }
}

/// SOUL-203: Claude Code-style cycling-sparkle spinner. Walks through a
/// short list of star glyphs at ~8 Hz so the eye sees a single morphing
/// shape instead of N rotations. This is what the user sees while the
/// agent is working.
struct SparkleSpinner: View {
    var tint: Color = .accentColor
    var size: CGFloat = 13

    // Frame order chosen to look like one shape rotating + pulsing.
    // Mix of point-counts smooths the cadence; period of 8 keeps it short.
    private static let frames: [String] = ["·", "✢", "✳", "✶", "✷", "✸", "✺", "✻"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let idx = Int(ctx.date.timeIntervalSince1970 / 0.12) % Self.frames.count
            Text(Self.frames[idx])
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14, alignment: .center)
                .contentTransition(.opacity)
        }
    }
}

