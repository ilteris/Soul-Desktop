import SwiftUI

/// SOUL-SOUL_DESKTOP-234: central catalog for app-wide keyboard shortcuts.
///
/// Every binding lives here. `Soul_DesktopApp.swift`'s `Commands` block reads
/// from `SoulShortcut.allCases` to populate the menu bar; consumers subscribe
/// to the corresponding `Notification.Name` to handle the action. Per-context
/// shortcuts (composer-focused send/cancel, thread-focused find) stay on the
/// owning view via `.keyboardShortcut(_:modifiers:)` and do NOT route through
/// this enum — those don't need menu-bar discoverability and shouldn't fire
/// app-wide.
///
/// Adding a shortcut:
///   1. Add a case here.
///   2. Wire `binding`, `label`, and `notification` for it.
///   3. The Commands block in Soul_DesktopApp picks it up automatically.
///   4. Add an `.onReceive(NotificationCenter.default.publisher(for: .your))`
///      in the view that handles the action.
enum SoulShortcut: String, CaseIterable, Identifiable {
    case newChat
    case previousSession
    case olderSession
    case newerSession
    case forceCompact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newChat:         return "New Chat"
        case .previousSession: return "Previous Session"
        case .olderSession:    return "Older Session"
        case .newerSession:    return "Newer Session"
        case .forceCompact:    return "Compact Context"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newChat:         return "n"
        case .previousSession: return "o"
        case .olderSession:    return "["
        case .newerSession:    return "]"
        case .forceCompact:    return "k"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newChat: return [.command]
        // SOUL-SOUL_DESKTOP-234: started at ⇧⌃O but that combo is the
        // macOS "Speak selected text" trigger when Accessibility →
        // Spoken Content is enabled. macOS eats the key before SwiftUI
        // sees it. ⌘⇧O is free across default configs and reads as a
        // natural "Open prior" gesture.
        case .previousSession: return [.command, .shift]
        case .olderSession, .newerSession: return [.command]
        case .forceCompact: return [.command, .shift]
        }
    }

    var notification: Notification.Name {
        switch self {
        case .newChat:         return .soulNewChat
        case .previousSession: return .soulPreviousSession
        case .olderSession:    return .soulOlderSession
        case .newerSession:    return .soulNewerSession
        case .forceCompact:    return .soulForceCompact
        }
    }
}

extension Notification.Name {
    /// ⌘N — create a new draft chat in the current project. This intentionally
    /// replaces SwiftUI's default New Window command for Soul's single-window
    /// session model.
    static let soulNewChat = Notification.Name("soul.kbd.newChat")
    /// Posted when the user invokes the "previous session" shortcut. Subscribed
    /// by `SidebarView` (which owns session ordering per project).
    static let soulPreviousSession = Notification.Name("soul.kbd.previousSession")
    /// ⌘[ — walk one row down in the recency-sorted list (toward older sessions).
    static let soulOlderSession = Notification.Name("soul.kbd.olderSession")
    /// ⌘] — walk one row up in the recency-sorted list (toward newer sessions).
    static let soulNewerSession = Notification.Name("soul.kbd.newerSession")
    /// ⌘⇧K — manual context compaction. Subscribed by AppShell, which
    /// hands off to AutoCompactController.forceCompact() against the
    /// active thread. Routed through the menu-bar CommandMenu rather than
    /// a hidden `.background(Button)` because background views aren't in
    /// the responder chain and don't reliably receive keyboard shortcuts.
    static let soulForceCompact = Notification.Name("soul.kbd.forceCompact")
}
