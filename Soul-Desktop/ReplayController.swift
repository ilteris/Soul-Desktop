import Foundation
import SwiftUI

/// Drives chronological playback of a finished session's items into the canvas.
///
/// Phase 1 source: the harness's own transcript via `ClaudeTranscriptReader`
/// (works for any Claude Code session under the project's cwd). Later phases
/// will merge `hooks.jsonl` tool events.
///
/// Read-only: the controller never sends to an agent, so cancellation is
/// always immediate — `togglePause()` or `stop()` returns control instantly.
@MainActor
@Observable
final class ReplayController {
    let sessionId: String
    let project: SoulProject

    private(set) var allEvents: [ThreadItem] = []
    private(set) var visible: [ThreadItem] = []
    private(set) var index: Int = 0
    private(set) var isPaused: Bool = false
    private(set) var finished: Bool = false

    /// ms between event appends while playing. 80ms ≈ 12 events/sec.
    var tickMillis: Int = 80

    var promptCount: Int {
        allEvents.reduce(0) { n, it in
            if case .userMessage = it { return n + 1 } else { return n }
        }
    }
    var replyCount: Int {
        allEvents.reduce(0) { n, it in
            if case .agentMessage = it { return n + 1 } else { return n }
        }
    }
    var total: Int { allEvents.count }

    private var driver: Task<Void, Never>? = nil

    init(sessionId: String, project: SoulProject) {
        self.sessionId = sessionId
        self.project = project
        load()
    }

    func load() {
        let items = ClaudeTranscriptReader.transcript(forSession: sessionId, cwd: project.path) ?? []
        allEvents = items
        visible = []
        index = 0
        finished = items.isEmpty
    }

    func start() {
        guard driver == nil else { return }
        isPaused = false
        finished = false
        driver = Task { [weak self] in
            await self?.run()
        }
    }

    func togglePause() {
        if finished { return }
        isPaused.toggle()
        if !isPaused, driver == nil {
            start()
        }
    }

    func stop() {
        driver?.cancel()
        driver = nil
        isPaused = true
    }

    /// Jump to a specific event index (0 ... total). Re-slices `visible`.
    func seek(to target: Int) {
        let clamped = max(0, min(target, total))
        index = clamped
        visible = Array(allEvents.prefix(clamped))
        finished = clamped >= total
    }

    private func run() async {
        let interval = UInt64(max(20, tickMillis)) * 1_000_000
        while !Task.isCancelled, index < total {
            if isPaused {
                try? await Task.sleep(nanoseconds: interval)
                continue
            }
            visible.append(allEvents[index])
            index += 1
            if index >= total { break }
            try? await Task.sleep(nanoseconds: interval)
        }
        finished = index >= total
        driver = nil
    }
}
