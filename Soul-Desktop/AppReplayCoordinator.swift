import SwiftUI

/// Owns ReplayController lifecycle for AppShell.
///
/// Replay is intentionally separate from active chat threads: entering replay
/// should not tear down or replace a live ThreadController.
@MainActor
@Observable
final class AppReplayCoordinator {
    var controller: ReplayController?

    @ObservationIgnored private var sidebarWasOpenBeforeReplay = true

    var isActive: Bool {
        controller != nil
    }

    var fraction: Double {
        guard let controller, controller.total > 0 else { return 0 }
        return Double(controller.index) / Double(controller.total)
    }

    func start(
        session: SoulSession,
        project: SoulProject,
        sidebarVisible: Bool,
        setSidebarVisible: (Bool) -> Void
    ) {
        sidebarWasOpenBeforeReplay = sidebarVisible
        if sidebarVisible {
            setSidebarVisible(false)
        }
        stop()
        controller = ReplayController(sessionId: session.id, project: project)
    }

    func exit(sidebarVisible: Bool, setSidebarVisible: (Bool) -> Void) {
        stop()
        if sidebarWasOpenBeforeReplay && !sidebarVisible {
            setSidebarVisible(true)
        }
    }

    func stop() {
        controller?.stop()
        if let outgoing = controller {
            controller = nil
            Task.detached(priority: .utility) {
                _ = outgoing
            }
        }
    }
}
