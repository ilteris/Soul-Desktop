import Testing
import Foundation
import SoulACP
import SoulCore
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
        controller.isHydrating = false
        
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
        #expect(controller.displayTitle == "Ls") // fallback to user if no agent yet
        
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

    @Test func registryActiveSubagentInjectsWorkingCard() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let record = try Self.registrySubagentRecord(
            id: "abc123",
            status: "running",
            startedAt: 105,
            liveLog: try Self.liveLogPath(firstLine: "--- Subagent @registry_guardian (ID: abc123, Provider: gemini) Started ---")
        )

        controller.applyRegistrySubagentRecords(
            [record],
            monitorStartedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(controller.items.count == 1)
        guard case .toolCall(_, let kind, let title, let status, _, let details) = controller.items[0],
              case .subagent(let specialist, _, let subagentId, _, _) = details?.kind else {
            Issue.record("Expected registry subagent tool row")
            return
        }
        #expect(kind == "delegate")
        #expect(title == "@registry_guardian")
        #expect(status == "in_progress")
        #expect(specialist == "registry_guardian")
        #expect(subagentId == "abc123")

        controller.applyRegistrySubagentRecords(
            [record],
            monitorStartedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(controller.items.count == 1)
    }

    @Test func registrySubagentFilteringUsesCurrentSessionDelegations() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let allowed = try Self.registrySubagentRecord(
            id: "abc123",
            status: "running",
            startedAt: 105,
            liveLog: try Self.liveLogPath(firstLine: "--- Subagent @registry_guardian (ID: abc123, Provider: gemini) Started ---")
        )
        let foreign = try Self.registrySubagentRecord(
            id: "foreign456",
            status: "running",
            startedAt: 106,
            liveLog: try Self.liveLogPath(firstLine: "--- Subagent @code_archaeologist (ID: foreign456, Provider: gemini) Started ---")
        )

        controller.applyRegistrySubagentRecords(
            [allowed, foreign],
            monitorStartedAt: Date(timeIntervalSince1970: 100),
            allowedSubagentIDs: ["abc123"],
            sessionId: "session-1"
        )

        #expect(controller.items.count == 1)
        guard case .toolCall(_, _, let title, _, _, let details) = controller.items[0],
              case .subagent(_, _, let subagentId, _, _) = details?.kind else {
            Issue.record("Expected allowed registry subagent row")
            return
        }
        #expect(title == "@registry_guardian")
        #expect(subagentId == "abc123")
    }

    @Test func acpSubagentUpdateMergesWithRegistryInjectedCard() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let record = try Self.registrySubagentRecord(
            id: "abc123",
            status: "running",
            startedAt: 105,
            liveLog: try Self.liveLogPath(firstLine: "--- Subagent @registry_guardian (ID: abc123, Provider: gemini) Started ---")
        )
        controller.applyRegistrySubagentRecords(
            [record],
            monitorStartedAt: Date(timeIntervalSince1970: 100)
        )

        controller._testApplyUpdate(.toolCall(.object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("gemini-delegate-tool"),
            "kind": .string("delegate_to_specialist"),
            "name": .string("delegate_to_specialist"),
            "title": .string("delegate_to_specialist"),
            "status": .string("in_progress"),
            "rawInput": .object([
                "specialist": .string("registry_guardian"),
                "task": .string("Review the layout stabilization change"),
            ]),
        ])))

        #expect(controller.items.count == 1)
        guard case .toolCall(_, _, _, let earlyStatus, _, let earlyDetails) = controller.items[0],
              case .subagent(_, let earlyObjective, let earlySubagentId, _, _) = earlyDetails?.kind else {
            Issue.record("Expected early ACP update to merge into registry row")
            return
        }
        #expect(earlyStatus == "in_progress")
        #expect(earlyObjective == "Review the layout stabilization change")
        #expect(earlySubagentId == "abc123")

        controller._testApplyUpdate(.toolCall(.object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("gemini-delegate-tool"),
            "kind": .string("delegate_to_specialist"),
            "name": .string("delegate_to_specialist"),
            "title": .string("delegate_to_specialist"),
            "status": .string("completed"),
            "rawInput": .object([
                "specialist": .string("registry_guardian"),
                "task": .string("Review the layout stabilization change"),
            ]),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(#"{"delegation_id":"abc123"}"#),
                ]),
            ]),
            "finding_path": .string("/tmp/finding.json"),
        ])))

        #expect(controller.items.count == 1)
        guard case .toolCall(_, _, _, let status, _, let details) = controller.items[0],
              case .subagent(let specialist, let objective, let subagentId, _, let findingPath) = details?.kind else {
            Issue.record("Expected merged subagent row")
            return
        }
        #expect(status == "completed")
        #expect(specialist == "registry_guardian")
        #expect(objective == "Review the layout stabilization change")
        #expect(subagentId == "abc123")
        #expect(findingPath == "/tmp/finding.json")
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

    @Test func readToolQuietPastGenericTimeoutDoesNotCancelTurn() async throws {
        let controller = ThreadController(provider: .claude, project: Self.testProject())
        controller.isWorking = true
        controller.lastActivityAt = Date()

        let rowId = UUID()
        controller.items.append(.toolCall(
            id: rowId,
            kind: "read",
            title: "Read /tmp/timeout_shot.jpg",
            status: "in_progress",
            locationHint: nil,
            details: nil
        ))
        controller.seenToolCallIds["read-image"] = rowId
        controller.toolCallStartedAt["read-image"] = Date(timeIntervalSinceNow: -301)
        controller.toolCallLastActivityAt["read-image"] = Date(timeIntervalSinceNow: -301)

        await controller.tickStallWatchdog(budget: 300, ceiling: 900)

        #expect(controller.isWorking)
        #expect(!controller.toolCallTimedOut.contains("read-image"))
        #expect(controller.items.contains {
            if case .status(_, let text) = $0 {
                return text.contains("tool call timed out")
            }
            return false
        } == false)
        guard case .toolCall(_, _, _, let status, _, _) = controller.items.first else {
            Issue.record("first item should remain the read tool row")
            return
        }
        #expect(status == "in_progress")
    }

    @Test func readToolEmitsLongRunningSignpostInsteadOfTimeout() async throws {
        let controller = ThreadController(provider: .claude, project: Self.testProject())
        controller.isWorking = true
        controller.lastActivityAt = Date()

        let rowId = UUID()
        controller.items.append(.toolCall(
            id: rowId,
            kind: "read",
            title: "Read /tmp/timeout_shot.jpg",
            status: "in_progress",
            locationHint: nil,
            details: nil
        ))
        controller.seenToolCallIds["read-image"] = rowId
        controller.toolCallStartedAt["read-image"] = Date(timeIntervalSinceNow: -451)
        controller.toolCallLastActivityAt["read-image"] = Date(timeIntervalSinceNow: -451)

        await controller.tickStallWatchdog(budget: 300, ceiling: 900)

        #expect(!controller.toolCallTimedOut.contains("read-image"))
        #expect(controller.toolCallSignposted.contains("read-image"))
        #expect(controller.items.contains {
            if case .status(_, let text) = $0 {
                return text.contains("quiet for") && text.contains("without automatic tool cancellation")
            }
            return false
        })
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

    @Test func firstSendResumeTakesPrecedenceOverExistingNativeSessionId() {
        let route = ThreadController.sessionEstablishmentRoute(
            pendingResumeOnFirstSend: true,
            sessionId: "kernel-session",
            nativeSessionId: "stale-native-session"
        )

        #expect(route == .pendingFirstSendResume)
    }

    @Test func existingNativeSessionIdWithoutPendingResumeUsesRecoveryRoute() {
        let route = ThreadController.sessionEstablishmentRoute(
            pendingResumeOnFirstSend: false,
            sessionId: "kernel-session",
            nativeSessionId: "stale-native-session"
        )

        #expect(route == .stopOrStallRecovery)
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

    @Test func testSwitchingActiveThreadClearsComposerDraftOnlyForActivatedThread() async throws {
        let project = Self.testProject()
        let first = ThreadController(provider: .geminiCLI, project: project)
        let second = ThreadController(provider: .codex, project: project)
        let sessions = AppSessionCoordinator()

        sessions.mount(first)
        first.composerDraft = "draft in first"
        sessions.mount(second)
        second.composerDraft = "draft in second"

        sessions.setActiveThread(first.id)

        #expect(first.composerDraft.isEmpty)
        #expect(second.composerDraft == "draft in second")

        first.composerDraft = "new first draft"
        sessions.setActiveThread(first.id)

        #expect(first.composerDraft == "new first draft")
    }

    @Test func testMountedWorkingThreadIsNotEvictedWhenBrowsingOtherSessions() async throws {
        let project = Self.testProject()
        let working = ThreadController(provider: .geminiCLI, project: project)
        working.assignSessionId("working-session")
        working.isWorking = true
        let second = ThreadController(provider: .codex, project: project)
        let third = ThreadController(provider: .claude, project: project)
        let fourth = ThreadController(provider: .pi, project: project)
        let sessions = AppSessionCoordinator()

        sessions.mount(working)
        sessions.mount(second)
        sessions.mount(third)
        sessions.mount(fourth)

        #expect(sessions.existingThread(sessionId: "working-session") === working)
        #expect(sessions.threads[working.id] != nil)
        #expect(sessions.threads.count == 3)
    }

    @Test func testComposerInputDisabledWhenControllerCannotAcceptTurns() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())

        #expect(!controller.canAcceptComposerInput)
        #expect(controller.acceptUserPrompt(display: "hello", agent: "hello") == nil)

        controller.items.append(.agentMessage(id: UUID(), text: "visible hydrated row", complete: true, timestamp: Date()))
        #expect(controller.canAcceptComposerInput)

        controller.isHydrating = false
        #expect(controller.canAcceptComposerInput)

        controller.isTornDown = true
        #expect(!controller.canAcceptComposerInput)
        #expect(controller.acceptUserPrompt(display: "hello", agent: "hello") == nil)
    }

    @Test func testAttachmentOnlyPromptIsAcceptedWhenControllerIsLive() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false

        let pending = controller.acceptUserPrompt(
            display: "[Screenshot.png](file:///tmp/Screenshot.png)",
            agent: "",
            extraBlocks: [.image(mimeType: "image/png", base64: "abc")]
        )

        #expect(pending != nil)
        #expect(controller.items.count == 1)
        #expect(pending?.extraBlocks.count == 1)
    }

    @Test func testVisibleHydratingControllerStillAcceptsQueuedPrompt() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.items.append(.agentMessage(id: UUID(), text: "existing visible transcript", complete: true, timestamp: Date()))
        controller.isWorking = true
        controller.isHydrating = true

        let pending = controller.acceptUserPrompt(display: "continue", agent: "continue")

        #expect(pending == nil)
        #expect(controller.items.count == 2)
        #expect(controller.queuedPrompts.count == 1)
        #expect(controller.scrollAnchorItemId == nil)
    }

    @Test func testClearQueueRemovesQueuedUserBubbles() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")

        #expect(controller.items.count == 2)
        #expect(controller.groupedItemsSplit.main.count == 1)
        #expect(controller.groupedItemsSplit.queued.count == 1)

        controller.clearQueue()

        #expect(controller.queuedPrompts.isEmpty)
        #expect(controller.items.count == 1)
        #expect(controller.groupedItemsSplit.main.count == 1)
        #expect(controller.groupedItemsSplit.queued.isEmpty)
        if case .userMessage(_, let text, _) = controller.items[0] {
            #expect(text == "active")
        } else {
            Issue.record("Expected active prompt to remain")
        }
    }

    @Test func testClearQueueRemovesAllQueuedBubblesFromMainTranscript() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued one", agent: "queued one")
        _ = controller.acceptUserPrompt(display: "queued two", agent: "queued two")

        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active"])
        #expect(controller.groupedItemsSplit.queued.compactMap(Self.userMessageText) == ["queued one", "queued two"])

        controller.clearQueue()

        #expect(controller.queuedPrompts.isEmpty)
        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active"])
        #expect(controller.groupedItemsSplit.queued.isEmpty)
        #expect(controller.items.compactMap(Self.userMessageText) == ["active"])
    }

    @Test func testSteeredPromptStaysVisibleAfterQueueClaimUntilTurnCompletes() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")
        let queuedId = try #require(controller.queuedPrompts.first?.itemId)

        await controller.steerToNextQueued()
        #expect(controller.steeredVisiblePromptId == queuedId)
        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active", "queued"])
        #expect(controller.groupedItemsSplit.queued.isEmpty)

        let claimed = try #require(controller.popNextQueuedPromptForDispatch())
        #expect(claimed.itemId == queuedId)
        #expect(controller.queuedPrompts.isEmpty)
        #expect(controller.steeredVisiblePromptId == queuedId)
        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active", "queued"])
        #expect(controller.groupedItemsSplit.queued.isEmpty)
        #expect(controller.steerPending)

        controller.beginQueuedTurnDispatch(claimed)
        #expect(!controller.steerPending)
        #expect(controller.items.compactMap(Self.statusText) == ["↪ steered to next prompt"])
        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active", "queued"])

        controller.finishSteeredPromptDispatch(claimed)
        #expect(controller.steeredVisiblePromptId == nil)
        #expect(controller.groupedItemsSplit.main.compactMap(Self.userMessageText) == ["active", "queued"])
    }

    @Test func testFrozenThreadPresentationPromotesSteeredPromptAsUserMessage() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")
        let frozenMain = controller.groupedItemsSplit.main
        let frozenQueued = controller.groupedItemsSplit.queued

        await controller.steerToNextQueued()

        let presentation = ThreadQueuePresentation.frozenPresentation(
            frozenQueuedItems: frozenQueued,
            liveItems: controller.groupedItems,
            frozenMainIDs: Set(frozenMain.map(\.id)),
            queuedItemIDs: controller.queuedItemIDs,
            steeredVisiblePromptId: controller.steeredVisiblePromptId
        )

        #expect(presentation.promoted.compactMap(Self.userMessageText) == ["queued"])
        #expect(presentation.queued.isEmpty)
    }

    @Test func testFollowUpBehaviorControlsQueuedPromptSteerSignal() async throws {
        #expect(FollowUpBehavior(storageValue: "lost") == .queue)
        #expect(FollowUpBehavior.queue.toggled() == .steer)
        #expect(FollowUpBehavior.steer.toggled() == .queue)

        let queueController = ThreadController(provider: .geminiCLI, project: Self.testProject())
        queueController.isHydrating = false
        queueController.ledger = NoopLedger()
        _ = queueController.acceptUserPrompt(display: "active", agent: "active")

        let queued = try #require(queueController.acceptUserPrompt(
            display: "queued",
            agent: "queued",
            followUpBehavior: .queue
        ))

        #expect(queued.pending == nil)
        #expect(!queued.shouldSteerQueuedPrompt)
        #expect(queueController.queuedPrompts.count == 1)

        let steerController = ThreadController(provider: .geminiCLI, project: Self.testProject())
        steerController.isHydrating = false
        steerController.ledger = NoopLedger()
        _ = steerController.acceptUserPrompt(display: "active", agent: "active")

        let steered = try #require(steerController.acceptUserPrompt(
            display: "queued",
            agent: "queued",
            followUpBehavior: .steer
        ))

        #expect(steered.pending == nil)
        #expect(steered.shouldSteerQueuedPrompt)
        #expect(steerController.queuedPrompts.count == 1)
    }

    @Test func testSteerAvailabilityDisablesDuringPendingSteer() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()
        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")

        #expect(controller.canSteerToNextQueued)
        #expect(controller.beginSteerToNextQueued())
        #expect(!controller.canSteerToNextQueued)
        #expect(!controller.beginSteerToNextQueued())
        #expect(controller.steerPending)
        #expect(controller.items.compactMap(Self.userMessageText) == ["active", "queued"])

        let claimed = try #require(controller.popNextQueuedPromptForDispatch())
        controller.beginQueuedRedispatch(claimed)

        #expect(!controller.steerPending)
        #expect(controller.items.compactMap(Self.statusText) == ["↪ steered to next prompt"])
    }

    @Test func testQueuedRedispatchConsumesSteerPending() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")

        await controller.steerToNextQueued()
        let claimed = try #require(controller.popNextQueuedPromptForDispatch())
        #expect(controller.steerPending)

        controller.beginQueuedRedispatch(claimed)

        #expect(!controller.steerPending)
        #expect(controller.isWorking)
        #expect(controller.items.compactMap(Self.statusText) == ["↪ steered to next prompt"])
        #expect(controller.items.compactMap(Self.userMessageText) == ["active", "queued"])
    }

    @Test func testCancelDropsQueuedAndSteeredBubblesThatHaveNotDispatched() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")

        await controller.steerToNextQueued()
        #expect(controller.items.compactMap(Self.userMessageText) == ["active", "queued"])
        #expect(controller.steeredVisiblePromptId != nil)

        await controller.cancel()

        #expect(controller.queuedPrompts.isEmpty)
        #expect(controller.steeredVisiblePromptId == nil)
        #expect(controller.items.compactMap(Self.userMessageText) == ["active"])
        #expect(controller.groupedItemsSplit.queued.isEmpty)
    }

    @Test func testQueuedTurnDispatchRefreshesActivityClock() async throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        _ = controller.acceptUserPrompt(display: "active", agent: "active")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")
        let claimed = try #require(controller.popNextQueuedPromptForDispatch())
        let stale = Date(timeIntervalSince1970: 100)
        controller.turnStartedAt = stale
        controller.lastActivityAt = stale

        controller.beginQueuedTurnDispatch(claimed)

        #expect(controller.turnStartedAt != nil)
        #expect(controller.turnStartedAt! > stale)
        #expect(controller.lastActivityAt > stale)
    }

    @Test func testSubstantiveTurnWithoutTraceRecordsHookWithoutVisibleStatus() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "I will summarize the changes and confirm the successful integration of the live job URL."
        controller.items.append(.agentProgress(id: UUID(), text: "I will edit the file.", complete: true, timestamp: Date()))
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start, sessionId: "test-sid")

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        #expect(controller.items.compactMap(Self.agentMessageText) == [reply])
        let hook = try #require(ledger.hooks.last)
        #expect(hook["event"] as? String == "TraceMissing")
        #expect(hook["provider"] as? String == "geminiCLI")
        #expect(hook["reply_characters"] as? Int == reply.count)
    }

    @Test func testNonGeminiSubstantiveTurnWithoutTraceStillAddsIntegrityStatus() throws {
        let controller = ThreadController(provider: .codex, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "I will summarize the changes and confirm the successful integration of the live job URL."
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start, sessionId: "test-sid")

        let status = try #require(controller.items.compactMap(Self.statusText).last)
        #expect(status.contains("trace missing"))
        let hook = try #require(ledger.hooks.last)
        #expect(hook["event"] as? String == "TraceMissing")
        #expect(hook["provider"] as? String == "codex")
    }

    @Test func testSubstantiveTurnWithTraceDoesNotAddIntegrityStatus() {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = """
        <soul_trace>{"intent":"Update URL","next_step":"Await operator","rationale":"Files were updated."}</soul_trace>

        Done.
        """
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        #expect(ledger.hooks.isEmpty)
    }

    @Test func testGeminiToolResultOnlyReplySkipsTraceMissingAndRequestsContinuation() {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "/Users/adele/Code/job-hunt/admin/legal/WorkNumber_Employment_Data_Report_2026-04-29.pdf has 28 pages. Read complete."
        controller.items.append(.agentProgress(
            id: UUID(),
            text: "I will read the initial pages of the employment report.",
            complete: true,
            timestamp: Date()
        ))
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "read",
            title: "WorkNumber_Employment_Data_Report_2026-04-29.pdf",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        #expect(controller.shouldAutoContinueGeminiToolResultOnlyTurn(reply: reply, outputStartIndex: start))
        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start, sessionId: "test-sid")

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        #expect(ledger.hooks.isEmpty)
    }

    @Test func testGeminiReadShapedAssistantReplyAfterNonReadToolStillRecordsTraceMissingHook() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "The document has 28 pages. Read complete."
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        #expect(!controller.shouldAutoContinueGeminiToolResultOnlyTurn(reply: reply, outputStartIndex: start))
        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start, sessionId: "test-sid")

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        let hook = try #require(ledger.hooks.last)
        #expect(hook["event"] as? String == "TraceMissing")
    }

    @Test func testSubstantiveTurnWithIncompleteTraceAddsIntegrityStatus() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.ledger = RecordingLedger()
        let start = controller.items.count
        let reply = """
        I edited the file.
        <soul_trace>{"intent":"Update URL"
        """
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        let status = try #require(controller.items.compactMap(Self.statusText).last)
        #expect(status.contains("trace missing"))
    }

    @Test func testSubstantiveTurnWithBareTraceOpenerAddsIntegrityStatus() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.ledger = RecordingLedger()
        let start = controller.items.count
        let reply = """
        I edited the file.
        <soul_trace>
        """
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        let status = try #require(controller.items.compactMap(Self.statusText).last)
        #expect(status.contains("trace missing"))
    }

    @Test func testSubstantiveTurnWithSchemaEmptyTraceAddsIntegrityStatus() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        controller.ledger = RecordingLedger()
        let start = controller.items.count
        let reply = """
        I edited the file.
        <soul_trace>{}</soul_trace>
        """
        controller.items.append(.toolCall(
            id: UUID(),
            kind: "edit",
            title: "APPLICATION_LOG.md",
            status: "completed",
            locationHint: nil,
            details: nil
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        let status = try #require(controller.items.compactMap(Self.statusText).last)
        #expect(status.contains("trace missing"))
    }

    @Test func testFinalizeOnlyTurnWithoutTraceRecordsHookWithoutVisibleStatus() throws {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "Finalized."
        controller.items.append(.finalize(
            id: UUID(),
            intent: "Close the session",
            summary: "Done",
            rationale: "Operator requested closure",
            fixed: nil,
            nextStep: "Reset context",
            timestamp: Date()
        ))
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        let hook = try #require(ledger.hooks.last)
        #expect(hook["event"] as? String == "TraceMissing")
    }

    @Test func testAnswerOnlyTurnWithoutTraceDoesNotAddIntegrityStatus() {
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject())
        let ledger = RecordingLedger()
        controller.ledger = ledger
        let start = controller.items.count
        let reply = "Done."
        controller.items.append(.agentMessage(id: UUID(), text: reply, complete: true, timestamp: Date()))

        controller.appendMissingTraceStatusIfNeeded(reply: reply, outputStartIndex: start)

        #expect(controller.items.compactMap(Self.statusText).isEmpty)
        #expect(ledger.hooks.isEmpty)
    }

    @Test func testNativeCompactOwnsWorkingStateUntilFinished() async throws {
        let controller = ThreadController(provider: .codex, project: Self.testProject())
        controller.isHydrating = false
        controller.ledger = NoopLedger()

        controller.beginNativeCompact()

        #expect(controller.nativeCompactInFlight)
        #expect(controller.nativeCompactOwnsWorkingState)
        #expect(controller.isWorking)
        #expect(controller.turnStartedAt != nil)

        controller.finishNativeCompact(reason: "timeout")

        #expect(!controller.nativeCompactInFlight)
        #expect(!controller.nativeCompactOwnsWorkingState)
        #expect(!controller.isWorking)
        #expect(controller.turnStartedAt == nil)
        #expect(controller.items.compactMap(Self.statusText) == ["⚠ context compact timed out; continuing"])
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

    private static func registrySubagentRecord(
        id: String,
        status: String,
        startedAt: Double,
        liveLog: String? = nil
    ) throws -> SoulSubagentRecord {
        var subagent: [String: Any] = [
            "subagent_id": id,
            "project": "test",
            "status": status,
            "started_at": startedAt,
        ]
        if let liveLog {
            subagent["live_log"] = liveLog
        }

        let payload: [String: Any] = [
            "project": "test",
            "subagents": [subagent],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SoulSubagentListPayload.self, from: data)
        return try #require(decoded.subagents.first)
    }

    private static func liveLogPath(firstLine: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-desktop-subagent-\(UUID().uuidString)")
            .appendingPathExtension("log")
        try "\(firstLine)\n".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private static func userMessageText(_ item: ThreadItem) -> String? {
        if case .userMessage(_, let text, _) = item {
            return text
        }
        return nil
    }

    private static func statusText(_ item: ThreadItem) -> String? {
        if case .status(_, let text) = item {
            return text
        }
        return nil
    }

    private static func agentMessageText(_ item: ThreadItem) -> String? {
        if case .agentMessage(_, let text, _, _) = item {
            return text
        }
        return nil
    }

    private struct NoopLedger: ThreadLedger {
        func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {}
        func retireAgentChunks(projectKey: String, sessionId: String) {}
        func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool { false }
    }

    private final class RecordingLedger: ThreadLedger {
        var hooks: [[String: Any]] = []

        func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
            var recorded = event
            recorded["projectKey"] = projectKey
            recorded["sessionId"] = sessionId
            hooks.append(recorded)
        }

        func retireAgentChunks(projectKey: String, sessionId: String) {}
        func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool { false }
    }
}
