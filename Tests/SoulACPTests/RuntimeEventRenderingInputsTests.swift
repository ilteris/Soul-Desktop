import Testing
@testable import SoulACP

@Suite("Runtime event rendering inputs")
struct RuntimeEventRenderingInputsTests {
    @Test("ACP text chunks become UI-free rendering inputs")
    func acpTextChunksBecomeRenderingInputs() {
        let input = ACPEventRenderingInput(update: .agentMessageChunk(content: .text("hello")))
        #expect(input == .agentMessageChunk("hello"))
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

        guard case .itemStarted(let itemType, let itemID, let item) = input else {
            Issue.record("Expected itemStarted")
            return
        }
        #expect(itemType == "commandExecution")
        #expect(itemID == "item-1")
        #expect(item.stringField("command") == "pwd")
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
    }
}
