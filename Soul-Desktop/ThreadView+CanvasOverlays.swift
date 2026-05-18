import SwiftUI

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
    let intent: String?
    let summary: String?
    let rationale: String?
    let fixed: String?
    let nextStep: String?

    var body: some View {
        // SOUL-SOUL_DESKTOP-100: confirm the FinalizeCard materialized.
        let _ = SoulSignposts.event("FinalizeCard.body")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SoulColor.accent)
                Text("Finalize")
                    .font(SoulFont.ui(13, weight: .semibold))
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
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .tracking(0.5)
            Text(value)
                .font(SoulFont.ui(13))
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

struct WorkingIndicator: View {
    @Bindable var controller: ThreadController
    @State private var rotation: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let secondsSinceActivity = Int(ctx.date.timeIntervalSince(controller.lastActivityAt))
            // SOUL-SOUL_DESKTOP-024: stall threshold is now provider-tuned
            // (Gemini 90s default, Claude 60s, Pi 120s — see Provider
            // .stallBudgetSeconds) instead of a hardcoded 30s. Settings →
            // Advanced "Stall budgets" lets the user override per provider.
            let budget = controller.provider.stallBudgetSeconds
            let isStalled = secondsSinceActivity >= budget
            let ceiling = StallPolicy.autoCancelCeilingSeconds
            let secondsUntilAutoCancel = max(0, ceiling - secondsSinceActivity)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(SoulColor.border.opacity(0.3), lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(isStalled ? Color.orange : SoulColor.accent, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(rotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isStalled ? "Thinking…" : "Agent working…")
                        .font(SoulFont.ui(12, weight: .medium))
                        .foregroundStyle(isStalled ? Color.orange : SoulColor.fg)

                    if isStalled {
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
                                .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.soulHover)
                            .help(controller.queuedPrompts.isEmpty
                                  ? "Cancel the stalled turn and unblock the thread"
                                  : "Cancel the stalled turn and dispatch the next queued message")
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
                        Text(line)
                            .font(SoulFont.code(11))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 500, height: 300)
        .background(SoulColor.bg)
    }
}
