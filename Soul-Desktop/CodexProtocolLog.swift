import Foundation
import SoulACP

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

    /// Off by default. This log fires per codex notification (i.e. per token
    /// while streaming), so leaving it always-on did an ISO8601DateFormatter
    /// alloc + JSON build on the main thread per delta. Gated behind a trace
    /// flag like soul.acp.trace / soul.sidebar.trace, and read ONCE at launch
    /// (not per call — a per-token UserDefaults.bool read is the same
    /// CFString-keyed storm fixed in SOUL-378/6a3a679). Re-enable for codex
    /// payload-shape debugging with:
    ///   defaults write Soul-Desktop soul.codex.trace -bool true
    /// then relaunch.
    private static let traceEnabled = UserDefaults.standard.bool(forKey: "soul.codex.trace")

    /// Allocating an ISO8601DateFormatter per call is expensive; cache it.
    /// ISO8601DateFormatter is documented thread-safe.
    private static let isoFormatter = ISO8601DateFormatter()

    static func record(method: String, params: JSONValue?) {
        guard traceEnabled else { return }
        let timestamp = isoFormatter.string(from: Date())
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
