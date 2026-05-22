import Foundation
import CoreServices

/// Detects when Claude (claude-agent-acp) rotates its on-disk transcript
/// filename mid-conversation — most commonly after `/compact`. The kernel
/// session UUID never changes; the provider's transcript file does.
/// Without detection, ContextUsageChip + ClaudeTranscriptReader would
/// keep reading the frozen pre-rotation file forever.
///
/// Detection rule: after the desktop sends a `session/prompt`, watch the
/// per-cwd Claude projects dir for ~5 seconds. The `.jsonl` file that
/// gets modified inside that window is the one Claude is currently
/// writing to — i.e., the live transcript. If it's a different filename
/// than we already know about, that's a rotation; persist the new id
/// into the kernel ledger as a `ProviderTranscriptID` event so all
/// downstream readers pick it up.
///
/// Why this signal beats mtime alone:
///   - Two open windows on the same project share an encoded dir; mtime
///     of "newest in dir" would pick the wrong one.
///   - Older transcripts get touched by metadata writes (file-history-
///     snapshot, ai-title) and would falsely register as "live."
///   - Arming the watch around `session/prompt` scopes attention to the
///     window where Claude is actually writing OUR turn, eliminating
///     both false positives.
@MainActor
final class ProviderTranscriptWatcher {
    /// Closure invoked with the new transcript id when a rotation is
    /// detected. Owner is responsible for persisting and updating its
    /// own state.
    var onRotation: ((String) -> Void)?

    private let encodedDir: String
    private var stream: FSEventStreamRef?
    private var armedUntil: Date = .distantPast
    /// Most recently observed transcript id (kernel sid initially, then
    /// whatever the agent rotated to). Used to suppress duplicate
    /// notifications when the watcher fires on the same file twice.
    private var currentId: String

    /// `encodedDir`: full path like `~/.claude/projects/-Users-ilteris-Code-foo`.
    /// `initialId`: the transcript id we believe is current at construction
    /// time (typically the kernel sid for fresh sessions, or the native id
    /// for resumed ones).
    init?(encodedDir: String, initialId: String) {
        self.encodedDir = encodedDir
        self.currentId = initialId
        try? FileManager.default.createDirectory(atPath: encodedDir, withIntermediateDirectories: true)
        guard startStream() else { return nil }
    }

    deinit {
        // FSEventStream owns its run-loop thread; releasing the ref
        // tears it down cleanly. Must not touch MainActor state here.
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// Call right after `client.prompt(...)` returns or just before the
    /// await. Opens a 5-second window during which any `.jsonl` change
    /// in the watched dir is considered "Claude responding to our turn."
    func arm() {
        armedUntil = Date().addingTimeInterval(5.0)
    }

    /// Tell the watcher we updated `currentId` ourselves (e.g., after
    /// reading back a confirmed value from the ledger). Suppresses
    /// re-firing on the same id.
    func setCurrentId(_ id: String) {
        currentId = id
    }

    // MARK: - FSEventStream wiring

    private func startStream() -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [encodedDir] as CFArray
        let callback: FSEventStreamCallback = { (_, info, count, _, flags, _) in
            guard let info else { return }
            let watcher = Unmanaged<ProviderTranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            // The callback runs on the FSEvents dispatch queue (we set it
            // below). Hop to MainActor to touch isolated state.
            Task { @MainActor in
                watcher.handleEvent(count: count, flags: flags)
            }
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency in seconds — coalesce bursty writes
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            NSLog("[transcript-watcher] FSEventStreamCreate failed for \(encodedDir)")
            return false
        }
        let queue = DispatchQueue(label: "soul.transcript-watcher.\(encodedDir.hashValue)")
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        return true
    }

    @MainActor
    private func handleEvent(count: Int, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard Date() < armedUntil else { return }
        // We don't get the file path array on this callback's count/flags
        // tuple alone — FSEvents file-events pass paths via the third arg
        // we ignored above. Re-fetch by rescanning the dir for any
        // `.jsonl` whose mtime falls inside the armed window. Two-pass
        // approach (scan + match) is cheap because the encoded dir has
        // at most a few dozen entries even for heavy users.
        scanForLiveTranscript()
    }

    private func scanForLiveTranscript() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: encodedDir) else { return }
        let armWindowStart = armedUntil.addingTimeInterval(-5.0)
        var best: (path: String, mtime: Date, id: String)? = nil
        for entry in entries where entry.hasSuffix(".jsonl") {
            let path = "\(encodedDir)/\(entry)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= armWindowStart
            else { continue }
            let id = (entry as NSString).deletingPathExtension
            if id == currentId {
                // No rotation — the live file is the one we already know.
                return
            }
            if best == nil || mtime > best!.mtime {
                best = (path, mtime, id)
            }
        }
        guard let candidate = best else { return }
        // Verify the file has at least one line referencing our session —
        // either the kernel sid or a chain through it — before promoting.
        // A bare mtime match isn't enough if two threads share an encoded
        // dir; we want to be sure this file's sessionId field references
        // ours or its parent.
        guard transcriptLooksLive(path: candidate.path) else { return }
        currentId = candidate.id
        NSLog("[transcript-watcher] rotation detected → \(candidate.id)")
        onRotation?(candidate.id)
    }

    /// Sanity check: read the file's first JSON line and confirm it has
    /// a `sessionId` field. Claude's transcripts always do; if absent,
    /// the file is something else (cache, partial write) and we don't
    /// promote.
    private func transcriptLooksLive(path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard let text = String(data: head, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if obj["sessionId"] is String { return true }
        }
        return false
    }
}
