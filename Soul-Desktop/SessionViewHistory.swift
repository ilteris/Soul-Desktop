import Foundation

/// Browser-style back/forward history of sessions the user has actually
/// viewed. Crosses project boundaries — opening a Claude session in project A
/// and then a Gemini session in project B produces a back stack of `[A]` with
/// B as current; ⌘[ returns to A regardless of which project the sidebar is
/// currently focused on.
///
/// Wired in `AppShell.loadSession`: any user-initiated open pushes onto the
/// back stack and clears forward. Loads triggered BY a back/forward
/// navigation skip the push (the `isNavigatingHistory` flag in `AppShell`).
@Observable
final class SessionViewHistory {
    private(set) var back: [SoulSession] = []
    private(set) var forward: [SoulSession] = []
    private(set) var current: SoulSession? = nil

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Record a user-initiated session open. Dedupes against `current` so
    /// re-clicking the same row doesn't pile up no-op history entries.
    func push(_ session: SoulSession) {
        if let cur = current, cur.id == session.id { return }
        if let cur = current { back.append(cur) }
        current = session
        forward.removeAll()
    }

    /// Pop one off the back stack. Returns the session to load, or nil if at
    /// the start of history.
    func goBack() -> SoulSession? {
        guard let prev = back.popLast() else { return nil }
        if let cur = current { forward.append(cur) }
        current = prev
        return prev
    }

    /// Pop one off the forward stack. Returns the session to load, or nil if
    /// at the end of history.
    func goForward() -> SoulSession? {
        guard let next = forward.popLast() else { return nil }
        if let cur = current { back.append(cur) }
        current = next
        return next
    }
}
