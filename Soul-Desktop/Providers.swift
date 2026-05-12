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
}
