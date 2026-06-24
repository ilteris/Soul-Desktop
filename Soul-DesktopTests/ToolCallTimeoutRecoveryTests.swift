import Foundation
import Testing
import SoulACP
import SoulCore
@testable import Soul_Desktop

/// Option-3 synthesis on top of `main`'s "Relax tool watchdog for quiet file
/// tools" (cf105a5): read-class tools stay signpost-only (never resolved), but
/// write-class tools (edit/write/replace) are routed to `.completeQuietly` —
/// at the long deadline the row is completed and the turn keeps running,
/// instead of either cancelling the turn (auto-cancel) or spinning forever
/// (signpost-only).
///
/// Regression anchor: session b22c618c logged two `edit` ToolCallTimeouts on
/// `soul/app_server/daemon.py` at exactly 300s with `afterTool_in_ledger:false`
/// — Gemini-CLI dropped the terminal `tool_call_update`, and the desktop nuked
/// the whole turn each time.
@MainActor
@Suite("Tool-call timeout recovery (write-class soft recovery)")
struct ToolCallTimeoutRecoveryTests {

    final class CapturingLedger: ThreadLedger, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [[String: Any]] = []

        var events: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        func eventCount(_ name: String) -> Int {
            events.filter { ($0["event"] as? String) == name }.count
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

    /// Build a controller with one in_progress tool row that has been quiet
    /// for `quietSeconds`, ready for a single watchdog tick.
    private static func controllerWithQuietTool(
        kind: String,
        title: String,
        toolId: String,
        quietSeconds: TimeInterval,
        ledger: CapturingLedger
    ) -> ThreadController {
        let controller = ThreadController(provider: .geminiCLI, project: testProject())
        controller.isHydrating = false
        controller.ledger = ledger
        controller.isWorking = true
        controller.lastActivityAt = Date()

        let rowId = UUID()
        controller.items.append(.toolCall(
            id: rowId,
            kind: kind,
            title: title,
            status: "in_progress",
            locationHint: nil,
            details: nil
        ))
        controller.seenToolCallIds[toolId] = rowId
        controller.toolCallStartedAt[toolId] = Date(timeIntervalSinceNow: -quietSeconds)
        controller.toolCallLastActivityAt[toolId] = Date(timeIntervalSinceNow: -quietSeconds)
        return controller
    }

    private static func firstToolRowStatus(_ controller: ThreadController) -> String? {
        for item in controller.items {
            if case .toolCall(_, _, _, let status, _, _) = item { return status }
        }
        return nil
    }

    private static func hasStatusRow(_ controller: ThreadController, containing needle: String) -> Bool {
        controller.items.contains { item in
            if case .status(_, let text) = item { return text.contains(needle) }
            return false
        }
    }

    @Test("an edit that loses its completion resolves the row and keeps the turn")
    func editTimeoutResolvesRowWithoutCancelling() async {
        let ledger = CapturingLedger()
        // Past the long-running floor (900s) that write-class tools get.
        let controller = Self.controllerWithQuietTool(
            kind: "edit",
            title: "soul/app_server/daemon.py: summary_path = sess_dir / ...",
            toolId: "replace__abc",
            quietSeconds: 901,
            ledger: ledger
        )

        await controller.tickStallWatchdog(budget: 300, ceiling: 1_000_000)

        // Row resolved to completed (spinner cleared), turn left running.
        #expect(Self.firstToolRowStatus(controller) == "completed")
        #expect(controller.isWorking == true)
        #expect(controller.toolCallTimedOut.contains("replace__abc"))
        #expect(Self.hasStatusRow(controller, containing: "recovered without cancelling"))
        #expect(!Self.hasStatusRow(controller, containing: "cancelling turn"))
        // Telemetry is still recorded.
        #expect(ledger.eventCount("ToolCallTimeout") == 1)
    }

    @Test("an execute tool that hangs still cancels the turn")
    func executeTimeoutStillCancelsTurn() async {
        let ledger = CapturingLedger()
        let controller = Self.controllerWithQuietTool(
            kind: "execute",
            title: "tail -f server.log",
            toolId: "bash__xyz",
            quietSeconds: 901,
            ledger: ledger
        )

        await controller.tickStallWatchdog(budget: 300, ceiling: 1_000_000)

        // Genuine-hang path is unchanged: row stopped, turn cancelled.
        #expect(Self.firstToolRowStatus(controller) == "stopped")
        #expect(Self.hasStatusRow(controller, containing: "cancelling turn"))
        #expect(!Self.hasStatusRow(controller, containing: "recovered without cancelling"))
        #expect(ledger.eventCount("ToolCallTimeout") == 1)
    }

    @Test("a steer-cancelling tool call does not also timeout")
    func steerCancellingToolSkipsTimeoutRace() async {
        let ledger = CapturingLedger()
        let controller = Self.controllerWithQuietTool(
            kind: "execute",
            title: "tail -f server.log",
            toolId: "bash__xyz",
            quietSeconds: 901,
            ledger: ledger
        )
        controller.steerCancellingToolCallIds.insert("bash__xyz")

        await controller.tickStallWatchdog(budget: 300, ceiling: 1_000_000)

        #expect(Self.firstToolRowStatus(controller) == "in_progress")
        #expect(!Self.hasStatusRow(controller, containing: "cancelling turn"))
        #expect(ledger.eventCount("ToolCallTimeout") == 0)
    }
}
