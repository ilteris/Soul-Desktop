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

    /// Today, before Phase 0d hydration ships.
    var soulContextStatus: String {
        switch self {
        case .geminiCLI: return "raw — no Soul context yet"
        case .claude:    return "stale CLAUDE.md if any"
        case .pi:        return "hydrated via soul-orchestrator extension"
        }
    }

    var isHydratedToday: Bool { self == .pi }
}
