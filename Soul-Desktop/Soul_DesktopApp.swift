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
        .commands {
            CommandGroup(after: .windowArrangement) {
                TypographyLabMenuItem()
            }
        }

        Window("Typography Lab", id: "typography-lab") {
            TypographyLab()
                .frame(minWidth: 820, minHeight: 540)
        }
    }
}

private struct TypographyLabMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Typography Lab") {
            openWindow(id: "typography-lab")
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
    }
}
