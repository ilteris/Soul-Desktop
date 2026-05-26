import Foundation

/// Watches session storage for finalize changes.
/// Fires `onChange` on main (debounced ~250ms) whenever the directory
/// contents change, so the caller can re-run `latestFinalize(...)` and
/// inject a `.finalize` ThreadItem if a record now exists for the live
/// session id.
///
/// New kernel finalizes append a `Finalize` event to `<sid>/hooks.jsonl`;
/// legacy finalizes wrote JSON into the project session root. Watch both
/// so out-of-band finalizes surface without requiring a reopen.
final class FinalizeWatcher {
    private let directoryPaths: [String]
    private var fileDescriptors: [CInt] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "soul.finalize-watcher", qos: .utility)
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(directoryPaths: [String], onChange: @escaping () -> Void) {
        self.directoryPaths = Array(Set(directoryPaths))
        self.onChange = onChange
    }

    convenience init(directoryPath: String, onChange: @escaping () -> Void) {
        self.init(directoryPaths: [directoryPath], onChange: onChange)
    }

    func start() {
        stop()
        for directoryPath in directoryPaths {
            // The dir may not exist yet for a brand-new project; create it so
            // open() succeeds. Idempotent.
            try? FileManager.default.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true
            )
            let fd = open(directoryPath, O_EVTONLY)
            guard fd >= 0 else { continue }
            fileDescriptors.append(fd)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: queue
            )
            src.setEventHandler { [weak self] in self?.scheduleFire() }
            src.setCancelHandler {
                close(fd)
            }
            sources.append(src)
            src.resume()
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
        fileDescriptors.removeAll()
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
