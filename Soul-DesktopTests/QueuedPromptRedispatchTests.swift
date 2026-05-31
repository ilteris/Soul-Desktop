import Foundation
import Testing
import SoulCore
@testable import Soul_Desktop

/// SOUL-SOUL_DESKTOP-357: a single user send must produce exactly one
/// `UserPrompt` ledger hook. The post-turn drain used to re-dispatch a queued
/// prompt through `send()`, which re-entered `acceptUserPrompt` and wrote a
/// second identical `UserPrompt` ~250ms after the queue-time write (the
/// "doubled prompt / doubled session" symptom). The drain now re-dispatches
/// the already-logged prompt directly, so no second write occurs.
@MainActor
@Suite("Queued prompt redispatch (no duplicate UserPrompt)")
struct QueuedPromptRedispatchTests {

    /// Thread-safe capture of every `appendHook` the controller emits.
    final class CapturingLedger: ThreadLedger, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [[String: Any]] = []

        var events: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        func userPromptCount(text: String) -> Int {
            events.filter {
                ($0["event"] as? String) == "UserPrompt" && ($0["text"] as? String) == text
            }.count
        }

        func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
            lock.lock(); _events.append(event); lock.unlock()
        }
        func retireAgentChunks(projectKey: String, sessionId: String) {}
        func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool { false }
    }

    private static func testProject() -> SoulProject {
        SoulProject(
            id: "soul-desktop",
            name: "Soul Desktop",
            path: "/tmp/soul-desktop",
            pillar: "Platform",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
    }

    @Test("redispatching a queued prompt does not re-log the UserPrompt hook")
    func redispatchDoesNotDuplicateLedgerEntry() {
        let ledger = CapturingLedger()
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = ledger

        // A turn is already in flight, so this send is parked on the queue.
        // acceptUserPrompt logs the UserPrompt hook exactly once, at queue time.
        controller.isWorking = true
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")
        #expect(ledger.userPromptCount(text: "queued") == 1)
        #expect(controller.queuedPrompts.count == 1)

        // The active turn completes; the defer drain pops and re-dispatches.
        controller.isWorking = false
        let popped = controller.popNextQueuedPromptForDispatch()
        #expect(popped?.display == "queued")
        controller.beginQueuedRedispatch(popped!)

        // The drain prep must NOT write a second UserPrompt (regression: was 2).
        #expect(ledger.userPromptCount(text: "queued") == 1)
        // It reclaims the active turn and keeps a single bubble for the prompt.
        #expect(controller.isWorking)
        let bubbles = controller.items.filter { item in
            if case .userMessage(_, let text, _) = item { return text == "queued" }
            return false
        }
        #expect(bubbles.count == 1)
    }
}
