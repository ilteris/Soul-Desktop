import Foundation

/// Watches the registry directory for a project and triggers a callback when
/// anything inside changes (new sessions, new hooks, finalized JSONs).
/// Uses DispatchSourceFileSystemObject for efficient kernel-level notification.
///
/// SOUL-SOUL_DESKTOP-163: callback is debounced ~250ms (cancel-and-reschedule)
/// and the dispatch source runs on a private utility queue. The previous
/// implementation fired synchronously on main per kernel event — during
/// streaming the kernel writes hooks.jsonl on every agent chunk, which
/// triggered a full session disk scan per chunk, pegging idle CPU at
/// 93-100% even after SOUL-161 and SOUL-162 removed the other body-time
/// hot paths. The debounce coalesces a burst of writes into a single
/// scan, matching what FinalizeWatcher already does.
///
/// SOUL-SOUL_DESKTOP-378: the debounced callback still shells out to
/// `soul session list`, which is a full registry scan. On large projects a
/// steady trickle of registry writes can therefore chain expensive scans even
/// though each burst is coalesced. Session watchers add a minimum interval
/// between full rescans so ordinary ledger churn cannot peg CPU.
final class RegistryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "soul.registry-watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let minimumFireInterval: TimeInterval
    private var lastFireAt: DispatchTime?

    init(
        path: String,
        debounceInterval: TimeInterval = 0.25,
        minimumFireInterval: TimeInterval = 0,
        callback: @escaping () -> Void
    ) {
        self.callback = callback
        self.debounceInterval = debounceInterval
        self.minimumFireInterval = minimumFireInterval
        self.fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            self.source = nil
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleFire()
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    /// Coalesce a burst of kernel notifications into one callback. When
    /// `minimumFireInterval` is set, also floor the full-rescan cadence so
    /// a steady write trickle cannot dispatch another expensive scan as soon
    /// as the prior subprocess finishes.
    private func scheduleFire() {
        pending?.cancel()
        let deadline = nextFireDeadline(now: .now())
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastFireAt = .now()
            let cb = self.callback
            DispatchQueue.main.async { cb() }
        }
        pending = work
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    private func nextFireDeadline(now: DispatchTime) -> DispatchTime {
        Self.nextFireDeadline(
            now: now,
            lastFireAt: lastFireAt,
            debounceInterval: debounceInterval,
            minimumFireInterval: minimumFireInterval
        )
    }

    static func nextFireDeadline(
        now: DispatchTime,
        lastFireAt: DispatchTime?,
        debounceInterval: TimeInterval,
        minimumFireInterval: TimeInterval
    ) -> DispatchTime {
        var deadline = now + debounceInterval
        guard minimumFireInterval > 0, let lastFireAt else { return deadline }

        let minimumDeadline = lastFireAt + minimumFireInterval
        if minimumDeadline > deadline {
            deadline = minimumDeadline
        }
        return deadline
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    /// Watch the project's sessions/ directory for the sidebar chat list.
    static func watchSessions(forProject key: String, callback: @escaping () -> Void) -> RegistryWatcher? {
        let path = SoulRegistry.primarySessionsRoot + "/\(key)"
        // Ensure path exists before opening
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return RegistryWatcher(
            path: path,
            minimumFireInterval: 5,
            callback: callback
        )
    }
}
