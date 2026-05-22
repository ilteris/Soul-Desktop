import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Posted when the user clicks a turn-completed notification. userInfo
    /// keys: `sessionId` (String), `projectKey` (String). AppShell observes
    /// this and routes through loadSession.
    static let openSessionFromNotification = Notification.Name("soul.notification.openSession")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func sendTurnCompletedNotification(threadTitle: String, project: String, sessionId: String, projectKey: String) {
        // Only notify if the app is not active.
        if NSApp.isActive { return }

        let content = UNMutableNotificationContent()
        content.title = "Agent turn completed"
        content.subtitle = project
        content.body = threadTitle
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId,
            "projectKey": projectKey,
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding notification: \(error)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show banner even when the app is in foreground (rarely fires because
    /// sendTurnCompletedNotification gates on `!NSApp.isActive`, but defensive).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// User clicked the notification — pop the existing app forward and
    /// route to the originating session. The userInfo was set in
    /// sendTurnCompletedNotification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String
        let projectKey = info["projectKey"] as? String

        Task { @MainActor in
            // Activate the existing instance instead of letting LaunchServices
            // open a fresh process. Single-instance enforcement in
            // Soul_DesktopApp.init handles the case where launchd spawned a
            // second copy — but `activate(ignoringOtherApps:)` here ensures
            // the running window comes forward right away.
            NSApp.activate(ignoringOtherApps: true)
            if let sid = sessionId, let key = projectKey {
                NotificationCenter.default.post(
                    name: Self.openSessionFromNotification,
                    object: nil,
                    userInfo: ["sessionId": sid, "projectKey": key]
                )
            }
            completionHandler()
        }
    }
}
