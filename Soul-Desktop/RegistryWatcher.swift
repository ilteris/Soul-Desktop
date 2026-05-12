import Foundation

/// Watches the registry directory for a project and triggers a callback when
/// anything inside changes (new sessions, new hooks, finalized JSONs).
/// Uses DispatchSourceFileSystemObject for efficient kernel-level notification.
final class RegistryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    private let callback: () -> Void

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
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.callback()
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    deinit {
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
