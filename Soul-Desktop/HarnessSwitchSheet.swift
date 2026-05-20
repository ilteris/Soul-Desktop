import SwiftUI

/// SOUL-SOUL_DESKTOP-237: identifiable context bag for the harness-switch
/// confirmation sheet. Carries the active source thread and the provider
/// the user wants to switch to. Identifiable so `.sheet(item:)` drives
/// presentation declaratively.
struct HarnessSwitchContext: Identifiable {
    let id = UUID()
    let source: ThreadController
    let target: Provider
}

/// SOUL-SOUL_DESKTOP-237: confirmation sheet shown when the composer
/// harness picker selects a provider different from the active thread's
/// provider. Default focus on Continue (matches today's behavior); Branch
/// is the alternative that preserves the source session intact.
///
/// Default-Continue is intentional. The semantics:
///   - Continue: closes the current thread, opens a fresh draft using the
///     new provider. Functionally identical to clicking "+ New chat" and
///     swapping the harness picker. The current session stays on disk
///     untouched.
///   - Branch: routes through `AppShell.branchFrom(_:to:)`, which
///     summarizes the current thread, writes a `BranchedTo` event into
///     the source's ledger, and mounts a fresh ThreadController with a
///     new sid. Source session continues to exist; the new session has
///     a branch-summary seed at its head.
struct HarnessSwitchSheet: View {
    let context: HarnessSwitchContext
    var onContinue: (_ rememberChoice: Bool) -> Void
    var onBranch: (_ rememberChoice: Bool) -> Void
    var onCancel: () -> Void

    @State private var rememberChoice: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch harness?")
                        .font(SoulFont.ui(16, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                    Text("\(context.source.provider.label) → \(context.target.label)")
                        .font(SoulFont.ui(12))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                Spacer()
            }

            // Two-choice copy
            VStack(alignment: .leading, spacing: 12) {
                choiceRow(
                    title: "Continue in a new chat",
                    body: "Close this thread and start fresh with \(context.target.label). The current conversation stays on disk untouched.",
                    isPrimary: true
                )
                choiceRow(
                    title: "Branch into a new session",
                    body: "Summarize this thread into a seed, then fork it into a new \(context.target.label) session with its own sid. Use this when you want to continue the work in a different agent without merging providers in one ledger.",
                    isPrimary: false
                )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(SoulColor.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
            )

            // Remember toggle
            Toggle(isOn: $rememberChoice) {
                Text("Don't ask again this session")
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .toggleStyle(.checkbox)

            // Buttons
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Branch") { onBranch(rememberChoice) }
                Button("Continue") { onContinue(rememberChoice) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private func choiceRow(title: String, body: String, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isPrimary {
                    Text("Default")
                        .font(SoulFont.ui(10, weight: .semibold))
                        .foregroundStyle(SoulColor.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoulColor.accent.opacity(0.12), in: Capsule())
                }
                Text(title)
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
            }
            Text(body)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
