import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func sendTurnCompletedNotification(threadTitle: String, project: String) {
        // Only notify if the app is not active.
        if NSApp.isActive { return }

        let content = UNMutableNotificationContent()
        content.title = "Agent turn completed"
        content.subtitle = project
        content.body = threadTitle
        content.sound = .default

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
