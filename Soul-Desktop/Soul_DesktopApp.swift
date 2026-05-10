import SwiftUI
import Darwin

@main
struct Soul_DesktopApp: App {
    init() {
        // Writing to a closed agent stdin would otherwise SIGPIPE the whole app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
