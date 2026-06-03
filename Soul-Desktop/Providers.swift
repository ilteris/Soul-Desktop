import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case geminiCLI
    case claude
    case pi
    case codex

    var id: String { rawValue }

    /// Canonical provider identity from any recorded tag spelling. The kernel
    /// ledger, the live overlay, and the sidebar filter chip have historically
    /// used divergent strings for the same provider:
    ///   - "gemini" / "geminicli" / "geminiCLI"  all mean Gemini-CLI
    ///   - "pi" / "pi-native"                     both mean Pi
    /// Folding them here (case-insensitively) is the single source of truth so
    /// equality checks compare *identity*, not spelling. This closed the bug
    /// (SOUL-SOUL_DESKTOP-381) where the Gemini source filter set "gemini" but
    /// 22/28 sessions were tagged "geminicli", so rule 6's exact `!=` dropped
    /// them and the sidebar looked empty under the Gemini chip.
    /// Returns nil for empty/unknown tags so callers can choose a fallback.
    static func canonical(fromTag tag: String?) -> Provider? {
        guard let trimmed = tag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        var key = trimmed.lowercased()
        // SOUL-SOUL_DESKTOP-267: the kernel orphan-recovery path
        // (soul_finalize_orphans.py) stamps source="recovered_<tool>"
        // (recovered_gemini, recovered_pi, …). Strip that prefix so a
        // recovered session folds to the same identity as a live one and
        // isn't dropped by the sidebar Source filter or rendered with the
        // generic fallback glyph — same single-source-of-truth principle as
        // SOUL-381: every provider-string spelling resolves here, once.
        if key.hasPrefix("recovered_") {
            key = String(key.dropFirst("recovered_".count))
        }
        switch key {
        case "gemini", "geminicli": return .geminiCLI   // geminiCLI.lowercased() == "geminicli"
        case "claude":              return .claude
        case "pi", "pi-native":     return .pi
        case "codex":               return .codex
        default:                    return nil
        }
    }

    var label: String {
        switch self {
        case .geminiCLI: return "Gemini-CLI"
        case .claude:    return "Claude"
        case .pi:        return "Pi"
        case .codex:     return "Codex"
        }
    }

    var subtitle: String {
        switch self {
        case .geminiCLI: return "Google's coding agent"
        case .claude:    return "Anthropic Claude Code"
        case .pi:        return "Community pi agent"
        case .codex:     return "OpenAI Codex app-server"
        }
    }

    /// Delegates to `ProviderIcon.symbol` so the harness picker, sidebar
    /// chat rows, and live-row glyphs all resolve to the same SF Symbol.
    /// Single source of truth lives in `ProviderIcon` (SidebarView.swift)
    /// because it has to accept both `Provider.rawValue` and the legacy
    /// `SoulSession.source` spellings.
    var icon: String { ProviderIcon.symbol(for: rawValue) }

    /// Hydration status as of the unified-generator cutover (2026-05-11).
    /// All three harnesses now boot into a Soul-aware session; only the
    /// delivery shape differs (native markdown file vs. mid-session XML).
    var soulContextStatus: String {
        switch self {
        case .geminiCLI: return "hydrated via GEMINI.md (soul_gemini_harness.py)"
        case .claude:    return "hydrated via CLAUDE.md (soul_claude_harness.py)"
        case .pi:        return "hydrated via soul-orchestrator extension"
        case .codex:     return "phase 1 stub — no harness yet"
        }
    }

    var isHydratedToday: Bool { self != .codex }

    /// User-tunable stall threshold (seconds) after which the WorkingIndicator
    /// surfaces a Recover capsule and ThreadController emits a `StallDetected`
    /// hook. Defaults are tuned per-provider from observed end-of-turn-omission
    /// rates: Gemini's session/load + tool-call streams run longer than
    /// Claude's, and Pi's slower turns warrant more headroom before we cry
    /// stall. Settings → Advanced "Stall budgets" pane writes these keys.
    var stallBudgetKey: String { "soul.stall.budget.\(rawValue)" }

    var stallBudgetDefault: Int {
        // Stall budget = max seconds of agent silence before the
        // "Thinking…" alarm + Skip-ahead capsule appears. Bumped 2026-05-14
        // because the prior values (60-120s) flagged legitimate long-think
        // turns as hung. Real hangs still surface — auto-cancel ceiling
        // below catches anything that goes truly silent — and the user can
        // still hit Skip-ahead manually before this fires.
        switch self {
        case .geminiCLI: return 240
        case .claude:    return 180
        case .pi:        return 300
        case .codex:     return 240
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
    // Bumped 2026-05-14 from 300s. A 5-min ceiling killed turns that were
    // legitimately thinking through a complex multi-step task; 15 min is
    // generous enough that real hangs still get cancelled but a slow think
    // doesn't lose work. User can override via Settings → Advanced.
    static let autoCancelCeilingDefault: Int = 900

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
    ///
    /// SOUL-SOUL_DESKTOP-110: bumped 2026-05-16 from 60s to 300s. The 60s
    /// default killed legitimately-thinking tool calls — `delegate_to_specialist`
    /// and other think-heavy tools don't emit `tool_call_update` notifications
    /// while reasoning, so activity-based extension can't help them. 5 minutes
    /// is still aggressive enough to catch real hangs but lets reasoning
    /// complete. User can override via Settings → Advanced.
    static let toolCallTimeoutKey = "soul.toolCallTimeout.seconds"
    static let toolCallTimeoutDefault: Int = 300
    static let longRunningToolTimeoutFloorSeconds: Int = 900

    static var toolCallTimeoutSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: toolCallTimeoutKey)
        return v > 0 ? v : toolCallTimeoutDefault
    }

    /// SOUL-SOUL_DESKTOP-110: percentage of the timeout at which we emit a
    /// "still working" signpost so the user sees the tool is alive and how
    /// close it is to cancellation. Default 0.5 → at 150s of a 300s budget.
    /// Set to 0 to disable signposts entirely.
    static let toolCallSignpostFractionKey = "soul.toolCallTimeout.signpostFraction"
    static let toolCallSignpostFractionDefault: Double = 0.5

    static var toolCallSignpostFraction: Double {
        let v = UserDefaults.standard.double(forKey: toolCallSignpostFractionKey)
        return v > 0 ? v : toolCallSignpostFractionDefault
    }
}
