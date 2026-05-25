import Foundation
import SoulCore

/// Umbrella permission policy for a thread. Drives how Soul-Desktop's ACP
/// client responds to `session/request_permission` from the agent.
///
/// Important caveat: this only governs requests the agent actually sends.
/// Gemini-CLI today rarely asks (its own `tools.autoAccept` short-circuits
/// most paths), so mode changes mostly affect Claude. Real cross-provider
/// enforcement would require also rewriting `~/.gemini/settings.json` — we
/// deliberately don't, to avoid stomping user-maintained config.
public enum PermissionMode: String, CaseIterable, Identifiable, Codable {
    /// Ask for every action. With no interactive sheet yet, this currently
    /// rejects every permission request — useful for "read-only chat" mode.
    case defaultAsk = "default"
    /// Auto-approve reads (Read, Grep, Glob, Search), deny writes/exec until
    /// the user picks a more permissive mode. The pragmatic middle.
    case autoReview = "auto-review"
    /// Auto-approve every option labeled `allow*`. Matches the pre-picker
    /// behavior — fastest, no safety net.
    case fullAccess = "full-access"

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultAsk:  return "Default permissions"
        case .autoReview:  return "Auto-review"
        case .fullAccess:  return "Full access"
        }
    }

    var sfSymbol: String {
        switch self {
        case .defaultAsk:  return "hand.raised"
        case .autoReview:  return "eyeglasses"
        case .fullAccess:  return "exclamationmark.triangle"
        }
    }

    var subtitle: String {
        switch self {
        case .defaultAsk:  return "Ask for each tool call"
        case .autoReview:  return "Allow reads, deny writes"
        case .fullAccess:  return "Allow everything"
        }
    }

    /// Read-only tools that pass through under `.autoReview`. Anything not in
    /// this list (Edit, Write, Bash, MultiEdit, Delete, …) gets denied.
    static func isReadOnlyTool(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.isEmpty { return false }
        for safe in ["read", "grep", "glob", "search", "list", "find", "view", "fetch"] {
            if n.contains(safe) { return true }
        }
        return false
    }

    var agentPermissionMode: AgentPermissionMode {
        switch self {
        case .defaultAsk: .defaultAsk
        case .autoReview: .autoReview
        case .fullAccess: .fullAccess
        }
    }
}
