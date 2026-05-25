import Foundation

public enum ACPEventRenderingInput: Equatable, Sendable {
    case agentMessageChunk(String)
    case agentThoughtChunk(String)
    case userMessageChunk(String)
    case toolCall(JSONValue)
    case toolCallUpdate(JSONValue)
    case plan(JSONValue)
    case availableCommandsUpdate(JSONValue)
    case currentModeUpdate
    case unknown(kind: String, payload: JSONValue)

    public init(update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(let block):
            self = .agentMessageChunk(block.textValue ?? "")
        case .agentThoughtChunk(let block):
            self = .agentThoughtChunk(block.textValue ?? "")
        case .userMessageChunk(let block):
            self = .userMessageChunk(block.textValue ?? "")
        case .toolCall(let payload):
            self = .toolCall(payload)
        case .toolCallUpdate(let payload):
            self = .toolCallUpdate(payload)
        case .plan(let payload):
            self = .plan(payload)
        case .availableCommandsUpdate(let payload):
            self = .availableCommandsUpdate(payload)
        case .currentModeUpdate:
            self = .currentModeUpdate
        case .unknown(let kind, let payload):
            self = .unknown(kind: kind, payload: payload)
        }
    }
}

public enum CodexEventRenderingInput: Equatable, Sendable {
    case itemStarted(itemType: String, itemID: String, item: [String: JSONValue])
    case agentMessageDelta(itemID: String, delta: String)
    case itemCompleted(itemType: String, itemID: String, item: [String: JSONValue])
    case turnCompleted(turnID: String?, status: String?, errorMessage: String?)
    case reasoningDelta(itemID: String, delta: String)
    case outputDelta
    case tokenUsage(lastTotalTokens: Int?, modelContextWindow: Int?)
    case ignored

    public init(method: String, params: JSONValue?) {
        switch method {
        case "item/started":
            guard let item = params?.objectField("item"),
                  let itemType = item.stringField("type"),
                  let itemID = item.stringField("id") else {
                self = .ignored
                return
            }
            self = .itemStarted(itemType: itemType, itemID: itemID, item: item)
        case "item/agentMessage/delta":
            guard let payload = params?.objectValue,
                  let itemID = payload.stringField("itemId"),
                  let delta = payload.stringField("delta") else {
                self = .ignored
                return
            }
            self = .agentMessageDelta(itemID: itemID, delta: delta)
        case "item/completed":
            guard let item = params?.objectField("item"),
                  let itemType = item.stringField("type"),
                  let itemID = item.stringField("id") else {
                self = .ignored
                return
            }
            self = .itemCompleted(itemType: itemType, itemID: itemID, item: item)
        case "turn/completed":
            guard let turn = params?.objectField("turn") else {
                self = .ignored
                return
            }
            let errorMessage = turn.objectField("error")?.stringField("message")
            self = .turnCompleted(
                turnID: turn.stringField("id"),
                status: turn.stringField("status"),
                errorMessage: errorMessage
            )
        case "item/reasoning/textDelta",
             "item/reasoning/summaryTextDelta",
             "item/reasoning/summaryPartAdded":
            guard let payload = params?.objectValue,
                  let itemID = payload.stringField("itemId") else {
                self = .ignored
                return
            }
            let delta = payload.codexReasoningDelta
            self = delta.isEmpty ? .ignored : .reasoningDelta(itemID: itemID, delta: delta)
        case "item/commandExecution/outputDelta",
             "item/fileChange/outputDelta",
             "item/plan/delta":
            self = .outputDelta
        case "thread/tokenUsage/updated":
            guard let usage = params?.objectField("tokenUsage") else {
                self = .ignored
                return
            }
            self = .tokenUsage(
                lastTotalTokens: usage.objectField("last")?.intField("totalTokens"),
                modelContextWindow: usage.intField("modelContextWindow")
            )
        default:
            self = .ignored
        }
    }
}

public extension ContentBlock {
    var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

public extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    func objectField(_ key: String) -> [String: JSONValue]? {
        guard case .object(let object) = self,
              case .object(let nested)? = object[key] else { return nil }
        return nested
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func stringField(_ key: String) -> String? {
        if case .string(let value)? = self[key] { return value }
        return nil
    }

    func intField(_ key: String) -> Int? {
        if case .int(let value)? = self[key] { return value }
        return nil
    }

    func objectField(_ key: String) -> [String: JSONValue]? {
        if case .object(let value)? = self[key] { return value }
        return nil
    }

    var codexReasoningDelta: String {
        if let value = stringField("delta") { return value }
        if let value = stringField("text") { return value }
        if let value = objectField("summaryPart")?.stringField("text") { return value }
        if let item = objectField("item") {
            if let value = item.stringField("text") { return value }
            if let value = item.stringField("content") { return value }
        }
        return ""
    }
}
