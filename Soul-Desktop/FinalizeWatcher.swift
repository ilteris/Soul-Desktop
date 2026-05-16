import Foundation

/// Watches a project's session directory for new finalize JSON files.
/// Fires `onChange` on main (debounced ~250ms) whenever the directory
/// contents change, so the caller can re-run `latestFinalize(...)` and
/// inject a `.finalize` ThreadItem if a record now exists for the live
/// session id.
///
/// SOUL-SOUL_DESKTOP-075 (b1): zero kernel coupling. The kernel still
/// writes `~/soul_registry/sessions/<project>/<sid>.json` exactly as
/// before; this watcher reacts to the dirent change.
final class FinalizeWatcher {
    private let directoryPath: String
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "soul.finalize-watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(directoryPath: String, onChange: @escaping () -> Void) {
        self.directoryPath = directoryPath
        self.onChange = onChange
    }

    func start() {
        stop()
        // The dir may not exist yet for a brand-new project; create it so
        // open() succeeds. Idempotent.
        try? FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true
        )
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleFire() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    deinit { stop() }
}
