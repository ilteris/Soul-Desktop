import SwiftUI

struct LiveSessionRecord: Identifiable, Equatable {
    var id: String
    var projectId: String
    var provider: String
    var title: String
    var startedAt: Date
    var lastActivityAt: Date
    var isWorking: Bool
}

/// Owns the mounted chat controllers for AppShell.
///
/// AppShell remains the composition root, but thread storage, active-thread
/// selection, draft-row selection, and LRU eviction are centralized here so the
/// view no longer has to manage the multiplexer mechanics inline.
@MainActor
@Observable
final class AppSessionCoordinator {
    private static let maxMountedThreads = 3

    var threads: [String: ThreadController] = [:]
    var activeThreadKey: String?
    var pendingActiveId: String?
    var draftSession: SoulSession?
    var liveRecords: [String: LiveSessionRecord] = [:]

    @ObservationIgnored private var threadRecency: [String] = []

    var activeThread: ThreadController? {
        guard let key = activeThreadKey else { return nil }
        return threads[key]
    }

    var mountedThreads: [ThreadController] {
        Array(threads.values)
    }

    var sidebarLiveRecords: [LiveSessionRecord] {
        var records = liveRecords
        for controller in threads.values {
            let record = LiveSessionRecord(controller: controller)
            records[record.id] = record
        }
        return Array(records.values)
    }

    func bindingForDraft(_ id: String) -> Binding<String> {
        Binding(
            get: { self.threads[id]?.composerDraft ?? "" },
            set: { self.threads[id]?.composerDraft = $0 }
        )
    }

    func mount(_ controller: ThreadController, activate: Bool = true) {
        threads[controller.id] = controller
        rememberLiveRecord(for: controller)
        controller.onRuntimeEnded = { [weak self, weak controller] sessionId in
            Task { @MainActor in
                if let sessionId {
                    self?.forgetLiveRecord(sessionId: sessionId)
                }
                if let controller {
                    self?.forgetLiveRecord(for: controller)
                }
            }
        }
        if activate {
            setActiveThread(controller.id)
        } else {
            evictOverflowThreads()
        }
    }

    func setActiveThread(_ key: String?) {
        let switchingThreads = activeThreadKey != key
        activeThreadKey = key
        if let key {
            if switchingThreads {
                threads[key]?.composerDraft = ""
            }
            threads[key]?.activationNonce &+= 1
            bumpThreadRecency(key)
        }
        evictOverflowThreads()
    }

    func closeThread(_ key: String) {
        guard let controller = threads[key] else { return }
        forgetLiveRecord(for: controller)
        threads.removeValue(forKey: key)
        threadRecency.removeAll(where: { $0 == key })
        if activeThreadKey == key { activeThreadKey = nil }
        Task { await controller.teardown() }
    }

    func removeThread(_ key: String) -> ThreadController? {
        let controller = threads.removeValue(forKey: key)
        if let controller {
            forgetLiveRecord(for: controller)
        }
        threadRecency.removeAll(where: { $0 == key })
        if activeThreadKey == key { activeThreadKey = nil }
        return controller
    }

    func forgetLiveRecord(sessionId: String) {
        liveRecords.removeValue(forKey: sessionId)
        if sessionId.hasPrefix("thread-") {
            liveRecords.removeValue(forKey: String(sessionId.dropFirst("thread-".count)))
        }
    }

    func existingThread(sessionId: String) -> ThreadController? {
        threads.values.first { $0.sessionId == sessionId }
    }

    func existingThread(syntheticSessionId: String) -> ThreadController? {
        guard syntheticSessionId.hasPrefix("thread-") else { return nil }
        let raw = String(syntheticSessionId.dropFirst("thread-".count))
        return threads.values.first { $0.id.lowercased() == raw.lowercased() }
    }

    func clearDraftIfProjectChanged(to projectId: String?) {
        guard let draftSession, draftSession.project != projectId else { return }
        self.draftSession = nil
        if pendingActiveId == draftSession.id {
            pendingActiveId = nil
        }
    }

    func showProjectDraftOrEmpty(projectId: String?) {
        activeThreadKey = nil
        if let draftSession, draftSession.project == projectId {
            pendingActiveId = draftSession.id
        } else {
            pendingActiveId = nil
        }
    }

    private func bumpThreadRecency(_ key: String) {
        threadRecency.removeAll(where: { $0 == key })
        threadRecency.insert(key, at: 0)
    }

    private func evictOverflowThreads() {
        guard threadRecency.count > Self.maxMountedThreads else { return }
        let evictable = threadRecency.filter { key in
            key != activeThreadKey && threads[key]?.isWorking != true
        }
        let overflowCount = max(0, threadRecency.count - Self.maxMountedThreads)
        let overflow = Array(evictable.suffix(overflowCount))
        for key in overflow {
            if let controller = threads[key] {
                rememberLiveRecord(for: controller, forceIdle: true)
                Task { await controller.teardown() }
            }
            threads.removeValue(forKey: key)
        }
        threadRecency.removeAll(where: { threads.keys.contains($0) == false })
    }

    private func rememberLiveRecord(for controller: ThreadController, forceIdle: Bool = false) {
        let record = LiveSessionRecord(controller: controller, forceIdle: forceIdle)
        liveRecords[record.id] = record
    }

    private func forgetLiveRecord(for controller: ThreadController) {
        liveRecords.removeValue(forKey: controller.sessionId ?? "thread-\(controller.id)")
        liveRecords.removeValue(forKey: controller.id)
    }
}

@MainActor
private extension LiveSessionRecord {
    init(controller: ThreadController, forceIdle: Bool = false) {
        self.id = controller.sessionId ?? "thread-\(controller.id)"
        self.projectId = controller.project.id
        self.provider = controller.provider.rawValue
        self.title = controller.displayTitle
        self.startedAt = controller.startedAt
        self.lastActivityAt = controller.lastActivityAt
        self.isWorking = forceIdle ? false : controller.isWorking
    }
}
