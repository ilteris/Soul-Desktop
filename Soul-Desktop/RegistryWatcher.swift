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
final class RegistryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "soul.registry-watcher", qos: .utility)
    private var pending: DispatchWorkItem?

    init(path: String, callback: @escaping () -> Void) {
        self.callback = callback
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

    /// Coalesce a burst of kernel notifications into one callback. Each
    /// new event cancels any pending work item and schedules a fresh one
    /// 250ms out; only when 250ms passes without further events does the
    /// callback actually run (on the main queue, since callers consume it
    /// in SwiftUI contexts).
    private func scheduleFire() {
        pending?.cancel()
        let cb = self.callback
        let work = DispatchWorkItem {
            DispatchQueue.main.async { cb() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    /// Watch the project's sessions/ directory for the sidebar chat list.
    static func watchSessions(forProject key: String, callback: @escaping () -> Void) -> RegistryWatcher? {
        let path = SoulRegistry.registryPath + "/sessions/\(key)"
        // Ensure path exists before opening
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return RegistryWatcher(path: path, callback: callback)
    }
}
