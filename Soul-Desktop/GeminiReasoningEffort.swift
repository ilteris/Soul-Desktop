import Foundation

enum GeminiReasoningEffort: String, CaseIterable, Identifiable {
    case inherit
    case minimal
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Auto"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var menuDescription: String {
        switch self {
        case .inherit:
            "Use Gemini CLI's model default"
        case .minimal:
            "Shortest reasoning path"
        case .low:
            "Light reasoning"
        case .medium:
            "Balanced reasoning"
        case .high:
            "Deepest reasoning"
        }
    }

    var environmentValue: String? {
        switch self {
        case .inherit:
            nil
        case .minimal, .low, .medium, .high:
            rawValue
        }
    }

    static func fromStorage(_ raw: String) -> GeminiReasoningEffort {
        GeminiReasoningEffort(rawValue: raw) ?? .inherit
    }
}
