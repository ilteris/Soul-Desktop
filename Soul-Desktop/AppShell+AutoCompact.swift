import SwiftUI

/// Bundles all the AppShell.body modifiers needed to wire the
/// AutoCompactController into the view tree. Pulled into its own
/// modifier so AppShell.body stays under the Swift type-checker's
/// budget (we hit it last time after inlining four `.onChange` +
/// `.overlay` + `.background` modifiers directly).
private struct AutoCompactBridge: ViewModifier {
    let controller: AutoCompactController
    let fraction: Double?
    let activeThread: ThreadController?
    let contextUsage: ContextUsage?
    let onBranch: (Provider) -> Void

    func body(content: Content) -> some View {
        content
            // Threshold watcher.
            .onChange(of: fraction) { _, _ in
                guard let thread = activeThread, let usage = contextUsage else { return }
                controller.evaluate(thread: thread, usage: usage)
            }
            // ⌘⇧K — manual force-compact. Routed through the menu-bar
            // CommandMenu (Soul_DesktopApp.commands) → notification, NOT
            // a hidden Button in `.background` (background views aren't
            // in the responder chain on macOS and don't get key events).
            .onReceive(NotificationCenter.default.publisher(for: .soulForceCompact)) { _ in
                NSLog("[autocompact] ⌘⇧K notification received; activeThread=\(activeThread?.id ?? "nil")")
                guard let thread = activeThread else { return }
                controller.forceCompact(thread: thread, usage: contextUsage)
            }
            // Inject controller into the environment so ThreadView can
            // read `\.autoCompactController` for the in-flight banner.
            .environment(\.autoCompactController, controller)
            // Branch-suggestion toast (Codex/Pi).
            .overlay(alignment: .bottomTrailing) { toastOverlay }
            .animation(.easeInOut(duration: 0.2), value: controller.pendingToast)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = controller.pendingToast {
            AutoCompactToastView(
                toast: toast,
                onPick: { provider in
                    controller.dismissToast()
                    onBranch(provider)
                },
                onDismiss: { controller.dismissToast() }
            )
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

extension View {
    func autoCompactBridge(
        controller: AutoCompactController,
        fraction: Double?,
        activeThread: ThreadController?,
        contextUsage: ContextUsage?,
        onBranch: @escaping (Provider) -> Void
    ) -> some View {
        modifier(AutoCompactBridge(
            controller: controller,
            fraction: fraction,
            activeThread: activeThread,
            contextUsage: contextUsage,
            onBranch: onBranch
        ))
    }
}
