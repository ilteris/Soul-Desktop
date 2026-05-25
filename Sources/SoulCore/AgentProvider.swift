import Foundation

/// UI-free identity for supported agent providers.
///
/// Display labels, icons, user defaults, and stall-budget presentation belong
/// in the app/runtime layer. This enum is intentionally just the stable
/// provider key used by packageable protocol and ledger code.
public enum AgentProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case geminiCLI
    case claude
    case pi
    case codex

    public var id: String { rawValue }
}
