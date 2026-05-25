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

    @Test("Codex unknown events become no-op rendering actions")
    func codexUnknownNoop() {
        #expect(CodexRuntimeRenderingAction(method: "unknown/event", params: nil) == .noop)
    }
}
