import Foundation
import SoulACP

enum ACPProtocolLog {
    private static let queue = DispatchQueue(label: "soul.acp-protocol-log")
    /// Allocating an ISO8601DateFormatter per frame is expensive; this is hit
    /// on every session/update notification plus every lifecycle + apply_timing
    /// snapshot. Cached once. ISO8601DateFormatter is documented thread-safe.
    private static let isoFormatter = ISO8601DateFormatter()

    static func record(direction: String, method: String, params: JSONValue?) {
        let timestamp = isoFormatter.string(from: Date())
        let entry: JSONValue = .object([
            "timestamp": .string(timestamp),
            "direction": .string(direction),
            "method": .string(method),
            "params": params ?? .null,
        ])
        queue.async {
            guard let url = logURL(),
                  let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    private static func logURL() -> URL? {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = library.appendingPathComponent("Logs/Soul-Desktop", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("acp-protocol.jsonl")
    }
}
