import Foundation

/// Append-only log of every codex JSON-RPC notification, written to
/// `~/Library/Logs/Soul-Desktop/codex-protocol.jsonl`. Built to answer
/// "why is the Thinking card empty / the execute row bare?" — the answer
/// is always whether the payload shape we expected actually matches what
/// codex's app-server sends. Without this log we're guessing extractor
/// shapes from limited evidence; with it, we can tail the file during a
/// real session and grow the extractor's matrix to match observed reality.
///
/// Output format: one JSON object per line with `{timestamp, method,
/// params}` — exactly the wire shape the handler receives. Tail with:
///   `tail -f ~/Library/Logs/Soul-Desktop/codex-protocol.jsonl`
enum CodexProtocolLog {
    private static let queue = DispatchQueue(label: "soul.codex-protocol-log")

    static func record(method: String, params: JSONValue?) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry: JSONValue = .object([
            "timestamp": .string(timestamp),
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
        return dir.appendingPathComponent("codex-protocol.jsonl")
    }
}
