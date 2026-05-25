import SwiftUI

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

    @ObservationIgnored private var threadRecency: [String] = []

    var activeThread: ThreadController? {
        guard let key = activeThreadKey else { return nil }
        return threads[key]
    }

    var mountedThreads: [ThreadController] {
        Array(threads.values)
    }

    func bindingForDraft(_ id: String) -> Binding<String> {
        Binding(
            get: { self.threads[id]?.composerDraft ?? "" },
            set: { self.threads[id]?.composerDraft = $0 }
        )
    }

    func mount(_ controller: ThreadController, activate: Bool = true) {
        threads[controller.id] = controller
        if activate {
            setActiveThread(controller.id)
        } else {
            evictOverflowThreads()
        }
    }

    func setActiveThread(_ key: String?) {
        activeThreadKey = key
        if let key {
            threads[key]?.activationNonce &+= 1
            bumpThreadRecency(key)
        }
        evictOverflowThreads()
    }

    func closeThread(_ key: String) {
        guard let controller = threads[key] else { return }
        threads.removeValue(forKey: key)
        threadRecency.removeAll(where: { $0 == key })
        if activeThreadKey == key { activeThreadKey = nil }
        Task { await controller.teardown() }
    }

    func removeThread(_ key: String) -> ThreadController? {
        let controller = threads.removeValue(forKey: key)
        threadRecency.removeAll(where: { $0 == key })
        if activeThreadKey == key { activeThreadKey = nil }
        return controller
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

    private func bumpThreadRecency(_ key: String) {
        threadRecency.removeAll(where: { $0 == key })
        threadRecency.insert(key, at: 0)
    }

    private func evictOverflowThreads() {
        guard threadRecency.count > Self.maxMountedThreads else { return }
        let overflow = Array(threadRecency.suffix(threadRecency.count - Self.maxMountedThreads))
        for key in overflow {
            if key == activeThreadKey { continue }
            if let controller = threads[key] {
                Task { await controller.teardown() }
            }
            threads.removeValue(forKey: key)
        }
        threadRecency.removeAll(where: { threads.keys.contains($0) == false })
    }
}
