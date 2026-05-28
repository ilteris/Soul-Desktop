import Testing
import Foundation
import SoulACP
@testable import Soul_Desktop

@MainActor
struct ThreadControllerTests {

    @Test func testScrollAnchorClearsOnSend() async throws {
        let project = SoulProject(
            id: "test",
            name: "Test Project",
            path: "/tmp",
            pillar: "test",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
        let controller = ThreadController(provider: .geminiCLI, project: project)
        
        // Simulate a scroll anchor being set
        let midId = UUID()
        controller.scrollAnchorItemId = midId
        
        // Accepting a live message should clear the saved read-position
        // anchor so ThreadView's live-follow path can drive the new turn.
        _ = controller.acceptUserPrompt(display: "hello", agent: "hello")
        
        #expect(controller.scrollAnchorItemId == nil)
    }

    @Test func testDisplayTitleHeuristics() async throws {
        let project = SoulProject(
            id: "test",
            name: "Test Project",
            path: "/tmp",
            pillar: "test",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
        let controller = ThreadController(provider: .geminiCLI, project: project)
        
        #expect(controller.displayTitle == "New chat")
        
        // First user message should become the title
        let id1 = UUID()
        controller.items.append(ThreadItem.userMessage(id: id1, text: "How to bake a cake?", timestamp: Date()))
        #expect(controller.displayTitle == "How to bake a cake?")
        
        // Multi-line should be truncated and flattened
        let id2 = UUID()
        controller.items[0] = ThreadItem.userMessage(id: id2, text: "First line\nSecond line", timestamp: Date())
        #expect(controller.displayTitle == "First line Second line")
        
        // Slash commands should be skipped in favor of agent response if possible
        let id3 = UUID()
        controller.items[0] = ThreadItem.userMessage(id: id3, text: "/ls", timestamp: Date())
        #expect(controller.displayTitle == "/ls") // fallback to user if no agent yet
        
        let id4 = UUID()
        controller.items.append(ThreadItem.agentMessage(id: id4, text: "Here is the list of files:\n- index.ts\n- package.json", complete: true, timestamp: Date()))
        #expect(controller.displayTitle == "Here is the list of files:")
    }

    @Test func generatedTitleRejectsCopiedPromptText() {
        let prompt = "I am running soul-desktop in production and it went into beachball mode again!"

        #expect(ThreadController._testCleanedGeneratedTitle(prompt, userPrompts: [prompt]) == nil)
        #expect(ThreadController._testCleanedGeneratedTitle("Fix Production Beachball", userPrompts: [prompt]) == "Fix Production Beachball")
    }

    @Test func titleGenerationExtractsCodexEnvelopeRequest() {
        let envelope = """
        # Files mentioned by the user:

        ## Screenshot.png: /var/folders/example/Screenshot.png

        ## My request for Codex:
        why do I get this when I try to resume?
        """

        #expect(SessionTitleResolver.titleCandidateText(fromPrompt: envelope) == "why do I get this when I try to resume?")
    }

    @Test func testPiReplayToolCallsDoNotArmTimeoutWatchdog() async throws {
        let controller = ThreadController(provider: .pi, project: Self.testProject())

        controller._testSetReplayingLoad(true)
        controller._testApplyUpdate(.toolCall(.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("replayed-tool"),
            "kind": .string("other"),
            "title": .string("bash"),
            "status": .string("in_progress"),
        ])))
        controller._testSetReplayingLoad(false)

        #expect(controller._testTrackedToolCallCount == 0)
    }

    @Test func testPiIdleTelemetryClearsStaleToolTimeouts() async throws {
        let controller = ThreadController(provider: .pi, project: Self.testProject())

        controller._testApplyUpdate(.toolCall(.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("live-tool"),
            "kind": .string("other"),
            "title": .string("bash"),
            "status": .string("in_progress"),
        ])))
        #expect(controller._testTrackedToolCallCount == 1)

        controller._testApplyUpdate(.unknown(kind: "session_info_update", payload: .object([
            "_meta": .object([
                "piAcp": .object([
                    "running": .bool(false),
                    "queueDepth": .int(0),
                ]),
            ]),
            "sessionUpdate": .string("session_info_update"),
        ])))

        #expect(controller._testTrackedToolCallCount == 0)
    }

    @Test func testProviderTerminationInvalidatesReusableRuntimeState() async throws {
        let controller = ThreadController(provider: .claude, project: Self.testProject())
        controller.assignSessionId("kernel-session")
        controller.nativeSessionId = "native-session"
        controller.hasInitialized = true
        controller.supportsLoadSession = true

        controller.markProviderProcessTerminated(cause: "child closed stdout (EOF)")

        #expect(controller.hasInitialized == false)
        #expect(controller.supportsLoadSession == false)
        #expect(controller.nativeSessionId == "native-session")
        #expect(controller.sessionId == "kernel-session")
    }

    @Test func testSetActiveThreadBumpsActivationNonceOnlyForSelectedThread() async throws {
        let project = Self.testProject()
        let first = ThreadController(provider: .geminiCLI, project: project)
        let second = ThreadController(provider: .codex, project: project)
        let sessions = AppSessionCoordinator()

        sessions.mount(first)
        let firstNonceAfterMount = first.activationNonce

        sessions.mount(second)
        let secondNonceAfterMount = second.activationNonce

        sessions.setActiveThread(first.id)

        #expect(first.activationNonce == firstNonceAfterMount + 1)
        #expect(second.activationNonce == secondNonceAfterMount)
    }

    private static func testProject() -> SoulProject {
        SoulProject(
            id: "test",
            name: "Test Project",
            path: "/tmp",
            pillar: "test",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
    }
}
