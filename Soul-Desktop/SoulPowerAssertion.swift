import Foundation

@MainActor
final class SoulPowerAssertion {
    static let shared = SoulPowerAssertion()

    private let defaultsKey = "soul.preventSleep"
    private var activity: NSObjectProtocol?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        apply(UserDefaults.standard.bool(forKey: defaultsKey))
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.apply(UserDefaults.standard.bool(forKey: self?.defaultsKey ?? "soul.preventSleep"))
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        disable()
    }

    private func apply(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    private func enable() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Soul Desktop is keeping this Mac available for active sessions and mobile streaming."
        )
    }

    private func disable() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
