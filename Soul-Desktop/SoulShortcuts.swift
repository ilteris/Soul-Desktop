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
    case previousSession

    var id: String { rawValue }

    var label: String {
        switch self {
        case .previousSession: return "Previous Session"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .previousSession: return "o"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        // SOUL-SOUL_DESKTOP-234: started at ⇧⌃O but that combo is the
        // macOS "Speak selected text" trigger when Accessibility →
        // Spoken Content is enabled. macOS eats the key before SwiftUI
        // sees it. ⌘⇧O is free across default configs and reads as a
        // natural "Open prior" gesture.
        case .previousSession: return [.command, .shift]
        }
    }

    var notification: Notification.Name {
        switch self {
        case .previousSession: return .soulPreviousSession
        }
    }
}

extension Notification.Name {
    /// Posted when the user invokes the "previous session" shortcut. Subscribed
    /// by `SidebarView` (which owns session ordering per project).
    static let soulPreviousSession = Notification.Name("soul.kbd.previousSession")
}
