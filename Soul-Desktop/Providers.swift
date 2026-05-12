import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case geminiCLI
    case claude
    case pi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .geminiCLI: return "Gemini-CLI"
        case .claude:    return "Claude"
        case .pi:        return "Pi"
        }
    }

    var subtitle: String {
        switch self {
        case .geminiCLI: return "Google's coding agent"
        case .claude:    return "Anthropic Claude Code"
        case .pi:        return "Community pi agent"
        }
    }

    var icon: String {
        switch self {
        case .geminiCLI: return "sparkles"
        case .claude:    return "circle.hexagongrid"
        case .pi:        return "terminal"
        }
    }

    /// Hydration status as of the unified-generator cutover (2026-05-11).
    /// All three harnesses now boot into a Soul-aware session; only the
    /// delivery shape differs (native markdown file vs. mid-session XML).
    var soulContextStatus: String {
        switch self {
        case .geminiCLI: return "hydrated via GEMINI.md (soul_gemini_harness.py)"
        case .claude:    return "hydrated via CLAUDE.md (soul_claude_harness.py)"
        case .pi:        return "hydrated via soul-orchestrator extension"
        }
    }

    var isHydratedToday: Bool { true }

    /// User-tunable stall threshold (seconds) after which the WorkingIndicator
    /// surfaces a Recover capsule and ThreadController emits a `StallDetected`
    /// hook. Defaults are tuned per-provider from observed end-of-turn-omission
    /// rates: Gemini's session/load + tool-call streams run longer than
    /// Claude's, and Pi's slower turns warrant more headroom before we cry
    /// stall. Settings → Advanced "Stall budgets" pane writes these keys.
    var stallBudgetKey: String { "soul.stall.budget.\(rawValue)" }

    var stallBudgetDefault: Int {
        switch self {
        case .geminiCLI: return 90
        case .claude:    return 60
        case .pi:        return 120
        }
    }

    var stallBudgetSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: stallBudgetKey)
        return v > 0 ? v : stallBudgetDefault
    }
}

/// Hard ceiling after which a stalled turn is auto-cancelled by the
/// watchdog without user intervention. Independent of per-provider budgets:
/// budgets gate when the *user-facing* capsule + hook appear; ceiling gates
/// when we give up waiting and act. Defaults to 5 minutes.
enum StallPolicy {
    static let autoCancelCeilingKey = "soul.stall.autoCancelCeiling"
    static let autoCancelCeilingDefault: Int = 300

    static var autoCancelCeilingSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: autoCancelCeilingKey)
        return v > 0 ? v : autoCancelCeilingDefault
    }

    /// SOUL-SOUL_DESKTOP-033: per-tool-call timeout. Independent of the
    /// turn-level stall watchdog above. A single tool call (commonly a shell
    /// execute like `tail -f`) can sit in_progress forever while emitting
    /// enough output to keep `lastActivityAt` fresh, so the turn-level budget
    /// never trips. This threshold gives each in_progress tool call its own
    /// deadline; when exceeded, ThreadController flips the row to `.stopped`,
    /// writes a `ToolCallTimeout` hook, and cancels the turn (ACP has no
    /// per-toolCallId cancel today).
    static let toolCallTimeoutKey = "soul.toolCallTimeout.seconds"
    static let toolCallTimeoutDefault: Int = 60

    static var toolCallTimeoutSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: toolCallTimeoutKey)
        return v > 0 ? v : toolCallTimeoutDefault
    }
}
