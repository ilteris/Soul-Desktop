import Foundation
import Observation

/// Tails `~/soul_registry/sessions/<project>/subagents/<id>/live.log` for the duration of
/// a `delegate_to_specialist` tool call (SOUL-SOUL_DESKTOP-111).
///
/// Design notes:
///   - Polling, not kqueue. The file may not exist when the tailer starts — the kernel
///     creates the subagent dir lazily on first stdout write. A `DispatchSourceFileSystemObject`
///     against a missing path fails to open; a polling timer naturally bridges the gap.
///   - 500ms cadence. Cheap enough on a single file and still feels live to the user.
///   - Caps content at 2 MB. The card is a "tail," not a transcript archive — older bytes
///     scroll off the top. Prevents a runaway researcher from ballooning RAM.
///   - Stops on terminal status. Card flips status → stop() called → tail freezes. The
///     final bytes are read in the same tick that stop fires; nothing is lost.
@MainActor
@Observable
final class SubagentLogTailer {
    let path: String
    private(set) var content: String = ""
    private(set) var isTailing: Bool = false

    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stopped: Bool = false

    /// Soft cap on retained log bytes. New bytes still append but oldest are dropped
    /// from the head to keep `content` under this size. 2 MB ≈ 30k lines of plain text.
    private let maxBytes: Int = 2 * 1024 * 1024

    init(path: String) {
        self.path = path
    }

    func start() {
        guard !stopped, timer == nil else { return }
        isTailing = true
        // Fire immediately so the first paint can already include any pre-existing
        // bytes (the subagent may have written before the card mounted).
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Run timer on common modes so scroll / menu interactions don't pause tailing.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        stopped = true
        isTailing = false
        timer?.invalidate()
        timer = nil
        // Final read to drain anything written between the last tick and stop().
        tick()
        try? handle?.close()
        handle = nil
    }

    private func tick() {
        // Open lazily — the path may not exist on the first few ticks.
        if handle == nil {
            handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            guard handle != nil else { return }
        }
        guard let h = handle else { return }
        do {
            // Read whatever's currently buffered. read(upToCount:) returns up to N
            // bytes; available-bytes semantics aren't promised on macOS but in practice
            // a single read after seek-to-current-offset drains the pending tail.
            let chunk = try h.read(upToCount: 64 * 1024) ?? Data()
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                content.append(s)
                if content.utf8.count > maxBytes {
                    // Drop the first half so the buffer stays bounded.
                    let half = maxBytes / 2
                    let idx = content.index(content.startIndex, offsetBy: content.count - half, limitedBy: content.endIndex) ?? content.startIndex
                    content = "…[truncated]…\n" + String(content[idx...])
                }
            }
        } catch {
            // EBADF, ENOENT on rotation, etc. — drop the handle and let the next tick reopen.
            try? handle?.close()
            handle = nil
        }
    }

    deinit {
        timer?.invalidate()
        try? handle?.close()
    }
}
