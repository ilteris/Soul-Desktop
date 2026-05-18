import SwiftUI
import AppKit
import Darwin

@main
struct Soul_DesktopApp: App {
    init() {
        // SOUL-SOUL_DESKTOP-114: refuse to launch a second instance of the same
        // bundle. Two Soul-Desktops spawn two gemini-cli child pools that race on
        // claimNewSlug → ~/.gemini/tmp/<slug>-1 collisions (e.g. soul-1). Dev and
        // Release have distinct bundle IDs so they still coexist freely.
        Self.enforceSingleInstance()

        // Writing to a closed agent stdin would otherwise SIGPIPE the whole app.
        signal(SIGPIPE, SIG_IGN)

        NotificationManager.shared.requestAuthorization()
    }

    private static func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard let firstOther = others.first else { return }
        NSLog("[soul] another Soul-Desktop (\(bundleID)) instance is running (pid \(firstOther.processIdentifier)); activating it and exiting self (pid \(me.processIdentifier)).")
        firstOther.activate()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .frame(minWidth: 1000, minHeight: 700)
                // SOUL-SOUL_DESKTOP-156: every Button without an explicit
                // .buttonStyle override picks up hit-area expansion + press
                // feedback. The hover BG layer is OPT-IN — only icon-only
                // buttons that want the gray hover/active bg use
                // `.buttonStyle(.soulHover)` explicitly. Buttons with their
                // own background (capsule chips, rounded-rect action
                // buttons) inherit this default and stay paint-free, so a
                // gray hover layer never leaks around a chip's own bg.
                .buttonStyle(.soulChip)
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
