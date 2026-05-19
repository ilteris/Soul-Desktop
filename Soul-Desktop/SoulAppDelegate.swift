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

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installToolbar()
        }
    }

    private func installToolbar() {
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil }) else { return }
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
