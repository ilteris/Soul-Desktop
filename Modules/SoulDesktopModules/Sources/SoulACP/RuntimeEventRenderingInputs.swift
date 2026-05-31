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

public enum ACPRuntimeRenderingAction: Equatable, Sendable {
    case appendAgentText(String)
    case appendAgentThought(String)
    case replayUserText(String)
    case renderToolCall(JSONValue, isUpdate: Bool)
    case renderPlan(JSONValue)
    case updateAvailableCommands(JSONValue)
    case clearCurrentMode
    case handleUnknown(kind: String, payload: JSONValue)

    public init(input: ACPEventRenderingInput) {
        switch input {
        case .agentMessageChunk(let text):
            self = .appendAgentText(text)
        case .agentThoughtChunk(let text):
            self = .appendAgentThought(text)
        case .userMessageChunk(let text):
            self = .replayUserText(text)
        case .toolCall(let payload):
            self = .renderToolCall(payload, isUpdate: false)
        case .toolCallUpdate(let payload):
            self = .renderToolCall(payload, isUpdate: true)
        case .plan(let payload):
            self = .renderPlan(payload)
        case .availableCommandsUpdate(let payload):
            self = .updateAvailableCommands(payload)
        case .currentModeUpdate:
            self = .clearCurrentMode
        case .unknown(let kind, let payload):
            self = .handleUnknown(kind: kind, payload: payload)
        }
    }

    public init(update: SessionUpdate) {
        self.init(input: ACPEventRenderingInput(update: update))
    }
}

public enum CodexEventRenderingInput: Equatable, Sendable {
    case itemStarted(itemType: String, itemID: String, item: [String: JSONValue])
    case agentMessageDelta(itemID: String, delta: String)
    case itemCompleted(itemType: String, itemID: String, item: [String: JSONValue])
    case turnCompleted(turnID: String?, status: String?, errorMessage: String?)
    case reasoningDelta(itemID: String, delta: String)
    /// Live stdout/stderr chunk for an open command/file tool-call row
    /// (`item/commandExecution/outputDelta`, `item/fileChange/outputDelta`).
    case outputDelta(itemID: String, delta: String)
    /// Live plan revision streamed mid-turn (`item/plan/delta`). Carries the
    /// updated plan item so the app can re-parse entries exactly as it does
    /// for `item/started`/`item/completed` plan payloads.
    case planDelta(itemID: String, item: [String: JSONValue])
    case tokenUsage(lastTotalTokens: Int?, modelContextWindow: Int?)
    /// Codex `error` wire notification — a transport/stream disconnect. When
    /// `willRetry` is true the runtime is auto-reconnecting ("Reconnecting…
    /// N/5"); when false the turn has exhausted its retries. SOUL-369.
    case connectionError(message: String, willRetry: Bool)
    /// Codex `warning` wire notification — a non-fatal transport advisory, e.g.
    /// "Falling back from WebSockets to HTTPS transport." SOUL-369.
    case transportWarning(message: String)
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
             "item/fileChange/outputDelta":
            guard let payload = params?.objectValue,
                  let itemID = payload.stringField("itemId") else {
                self = .ignored
                return
            }
            let delta = payload.codexOutputDelta
            self = delta.isEmpty ? .ignored : .outputDelta(itemID: itemID, delta: delta)
        case "item/plan/delta":
            guard let payload = params?.objectValue,
                  let itemID = payload.stringField("itemId") else {
                self = .ignored
                return
            }
            // The updated plan lives under `item` on some builds, inline on
            // others — hand whichever we find to the app's existing parser.
            let planItem = payload.objectField("item") ?? payload
            self = .planDelta(itemID: itemID, item: planItem)
        case "thread/tokenUsage/updated":
            guard let usage = params?.objectField("tokenUsage") else {
                self = .ignored
                return
            }
            self = .tokenUsage(
                lastTotalTokens: usage.objectField("last")?.intField("totalTokens"),
                modelContextWindow: usage.intField("modelContextWindow")
            )
        case "error":
            // Shape: {"error":{"message":"Reconnecting... 2/5", ...},
            //         "willRetry":true, "threadId":..., "turnId":...}
            guard let payload = params?.objectValue else {
                self = .ignored
                return
            }
            let willRetry = payload.boolField("willRetry") ?? false
            let message = payload.objectField("error")?.stringField("message")
                ?? payload.stringField("message")
                ?? "Connection error"
            self = .connectionError(message: message, willRetry: willRetry)
        case "warning":
            // Shape: {"threadId":..., "message":"Falling back from WebSockets…"}
            guard let payload = params?.objectValue,
                  let message = payload.stringField("message"), !message.isEmpty else {
                self = .ignored
                return
            }
            self = .transportWarning(message: message)
        default:
            self = .ignored
        }
    }
}

public enum CodexRuntimeRenderingAction: Equatable, Sendable {
    case startItem(itemType: String, itemID: String, item: [String: JSONValue])
    case appendAgentText(itemID: String, delta: String)
    case completeItem(itemType: String, itemID: String, item: [String: JSONValue])
    case completeTurn(turnID: String?, status: String?, errorMessage: String?)
    case appendReasoning(itemID: String, delta: String)
    /// Append a streamed stdout/stderr chunk to the open command/file row.
    case appendOutput(itemID: String, delta: String)
    /// Re-render an open plan row from a streamed plan revision.
    case updatePlan(itemID: String, item: [String: JSONValue])
    case updateTokenUsage(lastTotalTokens: Int?, modelContextWindow: Int?)
    /// Transport stream dropped; the runtime is reconnecting (or, when
    /// `willRetry` is false, has given up). SOUL-369.
    case connectionRetrying(message: String, willRetry: Bool)
    /// Non-fatal transport advisory — log it, but don't raise a
    /// connection-loss affordance. SOUL-369.
    case transportWarning(message: String)
    case noop

    public init(input: CodexEventRenderingInput) {
        switch input {
        case .itemStarted(let itemType, let itemID, let item):
            self = .startItem(itemType: itemType, itemID: itemID, item: item)
        case .agentMessageDelta(let itemID, let delta):
            self = .appendAgentText(itemID: itemID, delta: delta)
        case .itemCompleted(let itemType, let itemID, let item):
            self = .completeItem(itemType: itemType, itemID: itemID, item: item)
        case .turnCompleted(let turnID, let status, let errorMessage):
            self = .completeTurn(turnID: turnID, status: status, errorMessage: errorMessage)
        case .reasoningDelta(let itemID, let delta):
            self = .appendReasoning(itemID: itemID, delta: delta)
        case .outputDelta(let itemID, let delta):
            self = .appendOutput(itemID: itemID, delta: delta)
        case .planDelta(let itemID, let item):
            self = .updatePlan(itemID: itemID, item: item)
        case .tokenUsage(let lastTotalTokens, let modelContextWindow):
            self = .updateTokenUsage(
                lastTotalTokens: lastTotalTokens,
                modelContextWindow: modelContextWindow
            )
        case .connectionError(let message, let willRetry):
            self = .connectionRetrying(message: message, willRetry: willRetry)
        case .transportWarning(let message):
            self = .transportWarning(message: message)
        case .ignored:
            self = .noop
        }
    }

    public init(method: String, params: JSONValue?) {
        self.init(input: CodexEventRenderingInput(method: method, params: params))
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

    func boolField(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { return value }
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

    /// Pull the live stdout/stderr chunk out of a codex `outputDelta` payload.
    /// Codex has shipped the chunk under `delta`, `chunk`, and `output` across
    /// builds; mirror `codexReasoningDelta`'s defensive shape-matching so a
    /// key rename doesn't silently revert this back to a no-op.
    var codexOutputDelta: String {
        if let value = stringField("delta") { return value }
        if let value = stringField("chunk") { return value }
        if let value = stringField("output") { return value }
        if let value = stringField("text") { return value }
        if let item = objectField("item") {
            if let value = item.stringField("delta") { return value }
            if let value = item.stringField("chunk") { return value }
            if let value = item.stringField("text") { return value }
        }
        return ""
    }
}
