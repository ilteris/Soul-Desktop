import Foundation

/// UI-free permission policy for agent tool/action requests.
///
/// The app target still has presentation labels and symbols in its local
/// `PermissionMode` type. This package contract is the reusable policy shape
/// that ACP/runtime modules can depend on without importing SwiftUI/AppKit.
public enum AgentPermissionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case defaultAsk = "default"
    case autoReview = "auto-review"
    case fullAccess = "full-access"

    public var id: String { rawValue }

    /// Read-only tools that pass through under `.autoReview`.
    public static func isReadOnlyTool(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.isEmpty { return false }
        for safe in ["read", "grep", "glob", "search", "list", "find", "view", "fetch"] {
            if n.contains(safe) { return true }
        }
        return false
    }
}
