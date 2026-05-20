import SwiftUI
import AppKit

// MARK: - Advanced

/// SOUL-SOUL_DESKTOP-024: per-provider stall budgets + auto-cancel ceiling.
/// Steppers are bounded to keep the watchdog timer honest — sub-30s budgets
/// would trip the capsule on normal tool-call latency; ceilings under 60s
/// risk killing legitimate long-running turns before the agent recovers.
struct AdvancedPane: View {
    @AppStorage("soul.stall.budget.geminiCLI") private var geminiBudget: Int = 240
    @AppStorage("soul.stall.budget.claude")    private var claudeBudget: Int = 180
    @AppStorage("soul.stall.budget.pi")        private var piBudget: Int = 300
    @AppStorage("soul.stall.autoCancelCeiling") private var autoCancelCeiling: Int = 900
    @AppStorage("soul.toolCallTimeout.seconds") private var toolCallTimeout: Int = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Advanced",
                       subtitle: "Operational thresholds the watchdog uses to surface stall recovery.")

            SectionHeader("Stall budgets",
                          subtitle: "Per-provider seconds of agent silence before the Recover capsule appears and a StallDetected hook is written to hooks.jsonl.")

            StepperRow(title: "Gemini-CLI",
                       description: "Default 90s. Higher than Claude because gemini-cli's tool-call streams routinely run long on bigger repos.",
                       value: $geminiBudget,
                       range: 30...600,
                       suffix: "seconds")
            StepperRow(title: "Claude",
                       description: "Default 60s. Claude's most common stall mode is the end-of-turn omission after \"waiting for your go-ahead\" replies.",
                       value: $claudeBudget,
                       range: 30...600,
                       suffix: "seconds")
            StepperRow(title: "Pi",
                       description: "Default 120s. Pi's local-agent turns trend slower; keep this conservative until we have more signal.",
                       value: $piBudget,
                       range: 30...600,
                       suffix: "seconds")

            SectionHeader("Auto-recover",
                          subtitle: "Hard ceiling on agent silence before the watchdog cancels the turn for you. Independent of per-provider budgets.")

            StepperRow(title: "Auto-cancel ceiling",
                       description: "Default 300s (5 min). Set to a high value to disable; the manual Recover capsule still works.",
                       value: $autoCancelCeiling,
                       range: 60...3600,
                       suffix: "seconds")

            SectionHeader("Tool-call timeout",
                          subtitle: "Independent of the per-turn budgets above: any single tool call that sits in_progress past this threshold gets force-stopped, a ToolCallTimeout hook is written, and the turn is cancelled. Catches the `tail -f` / streaming-follow case where a hung tool keeps the turn from resolving.")

            StepperRow(title: "Per-tool-call timeout",
                       description: "Default 60s. Each in-flight tool call has its own deadline; only the stuck call gets stopped, not all of them.",
                       value: $toolCallTimeout,
                       range: 10...1800,
                       suffix: "seconds")
        }
    }
}

