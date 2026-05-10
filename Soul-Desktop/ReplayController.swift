import Foundation
import SwiftUI

/// Drives chronological playback of a finished session's timeline into the
/// canvas. Source is `hooks.jsonl` (kernel tool/agent events) merged with the
/// harness transcript's user prompts — same shape as soul_view.py.
///
/// Pacing is **derived from real wall-clock gaps** between events. A turn that
/// took 30 real seconds plays back in ~7.5s at the default 4× compression;
/// a 90s gap between prompts holds for ~22s. This preserves the session's
/// natural rhythm — long pauses stay long, fast tool bursts stay fast —
/// without us having to guess at per-event-type constants.
@MainActor
@Observable
final class ReplayController {
    let sessionId: String
    let project: SoulProject

    private(set) var allEvents: [ReplayEvent] = []
    private(set) var visible: [ThreadItem] = []
    private(set) var index: Int = 0
    private(set) var isPaused: Bool = false
    private(set) var finished: Bool = false

    /// Compression factor: real_gap / divisor → playback delay.
    /// speed=1.0 → divisor=4 (4× faster than real). speed=2.0 → divisor=8 (8×).
    var speed: Double = 1.0

    var promptCount: Int {
        allEvents.reduce(0) { n, e in
            if case .userMessage = e.item { return n + 1 } else { return n }
        }
    }
    var replyCount: Int {
        allEvents.reduce(0) { n, e in
            if case .agentMessage = e.item { return n + 1 } else { return n }
        }
    }
    var total: Int { allEvents.count }

    private var driver: Task<Void, Never>? = nil

    init(sessionId: String, project: SoulProject) {
        self.sessionId = sessionId
        self.project = project
        load()
        if !allEvents.isEmpty { start() }
    }

    func load() {
        allEvents = HooksReader.events(forSession: sessionId, project: project)
        visible = []
        index = 0
        finished = allEvents.isEmpty
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

    func seek(to target: Int) {
        let clamped = max(0, min(target, total))
        index = clamped
        visible = allEvents.prefix(clamped).map { $0.item }
        finished = clamped >= total
    }

    func setSpeed(_ s: Double) {
        speed = max(0.25, min(4.0, s))
    }

    private func run() async {
        while !Task.isCancelled, index < total {
            if isPaused {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            let event = allEvents[index]
            visible.append(event.item)
            index += 1
            if index >= total { break }
            let delaySec = delaySeconds(from: event, to: allEvents[index])
            let nanos = UInt64(delaySec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        finished = index >= total
        driver = nil
    }

    /// soul_view's pacing formula: real_gap / 4, clamped 0.3–2.5s for normal
    /// events and 3.0–5.0s when crossing into a new turn (user prompt boundary).
    /// `speed` further scales the divisor (speed=2 → /8, twice as fast).
    private func delaySeconds(from prev: ReplayEvent, to curr: ReplayEvent) -> Double {
        let realGap = curr.timestamp.timeIntervalSince(prev.timestamp)
        let isTurnBoundary: Bool = {
            if case .userMessage = curr.item { return true }
            return false
        }()
        let divisor = 4.0 * max(0.25, speed)
        let scaled = max(0, realGap) / divisor
        if isTurnBoundary {
            return min(5.0 / max(0.25, speed), max(3.0 / max(0.25, speed), scaled))
        }
        return min(2.5 / max(0.25, speed), max(0.3 / max(0.25, speed), scaled))
    }
}
