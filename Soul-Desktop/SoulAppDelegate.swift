import AppKit
import SwiftUI

/// SOUL-208: AppKit toolbar fallback. SwiftUI's `.toolbar` modifier
/// wouldn't bridge our ToolbarItem buttons into NSToolbar in this app's
/// view tree, so we install a real NSToolbar via NSApplicationDelegate
/// after launch. Items post NotificationCenter events; AppShell observes
/// and toggles the sidebar/right-pane state.
final class SoulAppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    static let toggleSidebarNotification = Notification.Name("soul.toolbar.toggleSidebar")
    static let toggleReviewNotification = Notification.Name("soul.toolbar.toggleReview")

    private let sidebarItemID = NSToolbarItem.Identifier("soul.sidebar.toggle")
    private let reviewItemID = NSToolbarItem.Identifier("soul.review.toggle")

    /// SOUL-208: identity of the toolbar instance WE installed. Compared
    /// against KVO updates to detect SwiftUI swapping us out.
    private var ourToolbarID: ObjectIdentifier?
    /// True while installToolbar is running, so the swap KVO observer
    /// doesn't react to OUR OWN nil→ours sequence and infinite-loop.
    private var reinstallInFlight = false
    private var toolbarObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installToolbar()
            self?.startToolbarSwapWatcher()
        }
    }

    private func startToolbarSwapWatcher() {
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil }) else { return }
        toolbarObserver = window.observe(\.toolbar, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            // Guard against our own swap triggering this observer mid-reinstall.
            if self.reinstallInFlight { return }
            let newID = change.newValue.flatMap { $0 }.map(ObjectIdentifier.init)
            if newID != self.ourToolbarID {
                DispatchQueue.main.async { [weak self] in
                    self?.installToolbar()
                }
            }
        }
    }

    private func installToolbar() {
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil }) else { return }
        reinstallInFlight = true
        defer {
            // Release the guard on the next runloop tick so any KVO
            // emissions queued by THIS swap don't trip the observer.
            DispatchQueue.main.async { [weak self] in self?.reinstallInFlight = false }
        }

        window.styleMask.insert(.fullSizeContentView)

        // SOUL-208: clean handoff — set window.toolbar = nil first so
        // SwiftUI's BarAppearanceBridge gets a chance to unregister its
        // KVO observer from the toolbar it was tracking. Then install
        // ours. Without the nil step, swapping the toolbar leaves the
        // bridge with a dangling observer that panics on next layout.
        window.toolbar = nil

        let toolbar = NSToolbar(identifier: "soul.main.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        ourToolbarID = ObjectIdentifier(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarItemID, .flexibleSpace, reviewItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarItemID, reviewItemID, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case sidebarItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.paletteLabel = "Sidebar"
            item.toolTip = "Toggle sidebar (⌘\\)"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")
            item.isBordered = false
            item.target = self
            item.action = #selector(sidebarToggleClicked(_:))
            return item
        case reviewItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Right pane"
            item.paletteLabel = "Right pane"
            item.toolTip = "Toggle right pane"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle right pane")
            item.isBordered = false
            item.target = self
            item.action = #selector(reviewToggleClicked(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func sidebarToggleClicked(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.toggleSidebarNotification, object: nil)
    }

    @objc private func reviewToggleClicked(_ sender: Any?) {
        NotificationCenter.default.post(name: Self.toggleReviewNotification, object: nil)
    }
}
