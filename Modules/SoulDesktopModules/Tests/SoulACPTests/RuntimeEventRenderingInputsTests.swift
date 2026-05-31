import Testing
@testable import SoulACP

@Suite("Runtime event rendering inputs")
struct RuntimeEventRenderingInputsTests {
    @Test("ACP text chunks become UI-free rendering inputs")
    func acpTextChunksBecomeRenderingInputs() {
        let input = ACPEventRenderingInput(update: .agentMessageChunk(content: .text("hello")))
        #expect(input == .agentMessageChunk("hello"))
        #expect(ACPRuntimeRenderingAction(update: .agentMessageChunk(content: .text("hello"))) == .appendAgentText("hello"))
        #expect(ACPRuntimeRenderingAction(update: .agentThoughtChunk(content: .text("thinking"))) == .appendAgentThought("thinking"))
        #expect(ACPRuntimeRenderingAction(update: .toolCall(.object(["id": .string("tool-1")]))) == .renderToolCall(.object(["id": .string("tool-1")]), isUpdate: false))
        #expect(ACPRuntimeRenderingAction(update: .currentModeUpdate(.object([:]))) == .clearCurrentMode)
        #expect(ACPRuntimeRenderingAction(update: .unknown(kind: "session_info_update", payload: .object(["running": .bool(false)]))) == .handleUnknown(kind: "session_info_update", payload: .object(["running": .bool(false)])))
    }

    @Test("Codex started items decode into typed input")
    func codexStartedItemDecodes() {
        let params: JSONValue = .object([
            "item": .object([
                "type": .string("commandExecution"),
                "id": .string("item-1"),
                "command": .string("pwd"),
            ]),
        ])

        let input = CodexEventRenderingInput(method: "item/started", params: params)
        let action = CodexRuntimeRenderingAction(method: "item/started", params: params)

        guard case .itemStarted(let itemType, let itemID, let item) = input else {
            Issue.record("Expected itemStarted")
            return
        }
        #expect(itemType == "commandExecution")
        #expect(itemID == "item-1")
        #expect(item.stringField("command") == "pwd")
        #expect(action == .startItem(itemType: "commandExecution", itemID: "item-1", item: [
            "type": .string("commandExecution"),
            "id": .string("item-1"),
            "command": .string("pwd"),
        ]))
    }

    @Test("Codex reasoning deltas accept summary part shape")
    func codexReasoningSummaryPartDecodes() {
        let params: JSONValue = .object([
            "itemId": .string("reason-1"),
            "summaryPart": .object([
                "text": .string("thinking"),
            ]),
        ])

        #expect(CodexEventRenderingInput(method: "item/reasoning/summaryPartAdded", params: params) == .reasoningDelta(itemID: "reason-1", delta: "thinking"))
        #expect(CodexRuntimeRenderingAction(method: "item/reasoning/summaryPartAdded", params: params) == .appendReasoning(itemID: "reason-1", delta: "thinking"))
    }

    @Test("Codex agent message deltas become append text actions")
    func codexAgentMessageDeltaAction() {
        let params: JSONValue = .object([
            "itemId": .string("msg-1"),
            "delta": .string("hello"),
        ])

        #expect(CodexEventRenderingInput(method: "item/agentMessage/delta", params: params) == .agentMessageDelta(itemID: "msg-1", delta: "hello"))
        #expect(CodexRuntimeRenderingAction(method: "item/agentMessage/delta", params: params) == .appendAgentText(itemID: "msg-1", delta: "hello"))
    }

    @Test("Codex token usage decodes totals")
    func codexTokenUsageDecodes() {
        let params: JSONValue = .object([
            "tokenUsage": .object([
                "last": .object(["totalTokens": .int(123)]),
                "modelContextWindow": .int(200_000),
            ]),
        ])

        #expect(CodexEventRenderingInput(method: "thread/tokenUsage/updated", params: params) == .tokenUsage(lastTotalTokens: 123, modelContextWindow: 200_000))
        #expect(CodexRuntimeRenderingAction(method: "thread/tokenUsage/updated", params: params) == .updateTokenUsage(lastTotalTokens: 123, modelContextWindow: 200_000))
    }

    @Test("Codex command output deltas stream into append-output actions")
    func codexCommandOutputDeltaDecodes() {
        let params: JSONValue = .object([
            "itemId": .string("cmd-1"),
            "delta": .string("line of stdout\n"),
        ])

        #expect(CodexEventRenderingInput(method: "item/commandExecution/outputDelta", params: params) == .outputDelta(itemID: "cmd-1", delta: "line of stdout\n"))
        #expect(CodexRuntimeRenderingAction(method: "item/commandExecution/outputDelta", params: params) == .appendOutput(itemID: "cmd-1", delta: "line of stdout\n"))
        // fileChange output deltas route through the same action.
        #expect(CodexRuntimeRenderingAction(method: "item/fileChange/outputDelta", params: params) == .appendOutput(itemID: "cmd-1", delta: "line of stdout\n"))
    }

    @Test("Codex output deltas accept alternate chunk key shapes")
    func codexOutputDeltaAlternateKeys() {
        let chunk: JSONValue = .object(["itemId": .string("cmd-2"), "chunk": .string("via-chunk")])
        #expect(CodexEventRenderingInput(method: "item/commandExecution/outputDelta", params: chunk) == .outputDelta(itemID: "cmd-2", delta: "via-chunk"))

        let output: JSONValue = .object(["itemId": .string("cmd-3"), "output": .string("via-output")])
        #expect(CodexEventRenderingInput(method: "item/commandExecution/outputDelta", params: output) == .outputDelta(itemID: "cmd-3", delta: "via-output"))
    }

    @Test("Codex output deltas with no itemId or empty delta are ignored")
    func codexOutputDeltaIgnoredWhenEmpty() {
        let noId: JSONValue = .object(["delta": .string("orphan")])
        #expect(CodexRuntimeRenderingAction(method: "item/commandExecution/outputDelta", params: noId) == .noop)

        let emptyDelta: JSONValue = .object(["itemId": .string("cmd-4"), "delta": .string("")])
        #expect(CodexRuntimeRenderingAction(method: "item/commandExecution/outputDelta", params: emptyDelta) == .noop)
    }

    @Test("Codex plan deltas carry the updated plan item")
    func codexPlanDeltaDecodes() {
        let inlinePlan: JSONValue = .object([
            "itemId": .string("plan-1"),
            "plan": .array([.object(["step": .string("do thing")])]),
        ])
        #expect(CodexRuntimeRenderingAction(method: "item/plan/delta", params: inlinePlan) == .updatePlan(itemID: "plan-1", item: [
            "itemId": .string("plan-1"),
            "plan": .array([.object(["step": .string("do thing")])]),
        ]))

        // Nested `item` shape is unwrapped to the inner plan object.
        let nestedPlan: JSONValue = .object([
            "itemId": .string("plan-2"),
            "item": .object(["plan": .array([.object(["step": .string("nested")])])]),
        ])
        #expect(CodexRuntimeRenderingAction(method: "item/plan/delta", params: nestedPlan) == .updatePlan(itemID: "plan-2", item: [
            "plan": .array([.object(["step": .string("nested")])]),
        ]))
    }

    @Test("Codex plan deltas with no itemId are ignored")
    func codexPlanDeltaIgnoredWithoutId() {
        #expect(CodexRuntimeRenderingAction(method: "item/plan/delta", params: .object(["plan": .array([])])) == .noop)
    }

    @Test("Codex unknown events become no-op rendering actions")
    func codexUnknownNoop() {
        #expect(CodexRuntimeRenderingAction(method: "unknown/event", params: nil) == .noop)
    }

    // SOUL-SOUL_DESKTOP-369: connection-loss notifications used to fall to the
    // `default: .ignored` branch and never reach the controller. They must now
    // decode into the reconnecting / transport-warning actions so the UI can
    // surface a connecting affordance instead of spinning silently.
    @Test("Codex retrying error decodes into a reconnecting action")
    func codexRetryingErrorDecodes() {
        let params: JSONValue = .object([
            "error": .object([
                "message": .string("Reconnecting... 2/5"),
                "additionalDetails": .string("stream disconnected before completion: tls handshake eof"),
            ]),
            "willRetry": .bool(true),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])
        #expect(CodexEventRenderingInput(method: "error", params: params)
                == .connectionError(message: "Reconnecting... 2/5", willRetry: true))
        #expect(CodexRuntimeRenderingAction(method: "error", params: params)
                == .connectionRetrying(message: "Reconnecting... 2/5", willRetry: true))
    }

    @Test("Codex terminal error decodes with willRetry false")
    func codexTerminalErrorDecodes() {
        let params: JSONValue = .object([
            "error": .object(["message": .string("stream disconnected")]),
            "willRetry": .bool(false),
        ])
        #expect(CodexRuntimeRenderingAction(method: "error", params: params)
                == .connectionRetrying(message: "stream disconnected", willRetry: false))
    }

    @Test("Codex transport warning decodes into a transport-warning action")
    func codexTransportWarningDecodes() {
        let params: JSONValue = .object([
            "threadId": .string("thread-1"),
            "message": .string("Falling back from WebSockets to HTTPS transport."),
        ])
        #expect(CodexEventRenderingInput(method: "warning", params: params)
                == .transportWarning(message: "Falling back from WebSockets to HTTPS transport."))
        #expect(CodexRuntimeRenderingAction(method: "warning", params: params)
                == .transportWarning(message: "Falling back from WebSockets to HTTPS transport."))
    }

    @Test("Codex error with no willRetry flag defaults to non-retrying")
    func codexErrorDefaultsNonRetrying() {
        let params: JSONValue = .object([
            "error": .object(["message": .string("boom")]),
        ])
        #expect(CodexRuntimeRenderingAction(method: "error", params: params)
                == .connectionRetrying(message: "boom", willRetry: false))
    }
}
