import Foundation

enum ToolFailureLog {
    private static let queue = DispatchQueue(label: "soul.tool-failure-log")

    static func dump(payload: JSONValue, provider: Provider, sessionId: String?) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry: [String: JSONValue] = [
            "timestamp": .string(timestamp),
            "provider": .string(provider.label),
            "sessionId": .string(sessionId ?? "unknown"),
            "payload": payload
        ]
        let value = JSONValue.object(entry)

        queue.async {
            guard let url = logURL(),
                  let data = try? JSONEncoder().encode(value) else { return }
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
        return dir.appendingPathComponent("tool-failures.jsonl")
    }
}
