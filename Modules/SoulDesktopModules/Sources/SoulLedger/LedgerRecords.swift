import Foundation

public struct LedgerHookRecord {
    public var timestamp: Date
    public var object: [String: Any]
    public var payload: LedgerHookPayload

    public init(timestamp: Date, object: [String: Any], payload: LedgerHookPayload? = nil) {
        self.timestamp = timestamp
        self.object = object
        self.payload = payload ?? LedgerHookPayload(object: object)
    }

    public var event: String {
        payload.event
    }
}

public enum LedgerHookPayload {
    case afterTool(LedgerAfterToolPayload)
    case afterAgent(LedgerAfterAgentPayload)
    case userPrompt(LedgerUserPromptPayload)
    case branchSummary(LedgerBranchSummaryPayload)
    case delegationStarted(LedgerDelegationStartedPayload)
    case delegationCompleted(LedgerDelegationCompletedPayload)
    case delegationFailed(LedgerDelegationCompletedPayload)
    case codexApproval(LedgerDecisionPayload)
    case decision(LedgerDecisionPayload)
    case metadata(String)
    case unknown(String)

    public init(object: [String: Any]) {
        let event = (object["event"] as? String) ?? ""
        switch event {
        case "AfterTool":
            self = .afterTool(LedgerAfterToolPayload(object: object))
        case "AfterAgent":
            self = .afterAgent(LedgerAfterAgentPayload(object: object))
        case "UserPrompt", "UserMessage":
            self = .userPrompt(LedgerUserPromptPayload(event: event, object: object))
        case "BranchSummary":
            self = .branchSummary(LedgerBranchSummaryPayload(object: object))
        case "DelegationStarted":
            self = .delegationStarted(LedgerDelegationStartedPayload(object: object))
        case "DelegationCompleted":
            self = .delegationCompleted(LedgerDelegationCompletedPayload(event: event, object: object))
        case "DelegationFailed":
            self = .delegationFailed(LedgerDelegationCompletedPayload(event: event, object: object))
        case "CodexApproval":
            self = .codexApproval(LedgerDecisionPayload(event: event, object: object))
        case "SESSION_START", "NativeSessionID", "Title":
            self = .metadata(event)
        default:
            if let op = object["op"] as? String,
               let intent = object["intent"] as? String {
                self = .decision(LedgerDecisionPayload(event: event, op: op, intent: intent))
            } else {
                self = .unknown(event)
            }
        }
    }

    public var event: String {
        switch self {
        case .afterTool: "AfterTool"
        case .afterAgent: "AfterAgent"
        case .userPrompt(let payload): payload.event
        case .branchSummary: "BranchSummary"
        case .delegationStarted: "DelegationStarted"
        case .delegationCompleted: "DelegationCompleted"
        case .delegationFailed: "DelegationFailed"
        case .codexApproval: "CodexApproval"
        case .decision(let payload): payload.event
        case .metadata(let event): event
        case .unknown(let event): event
        }
    }
}

public struct LedgerAfterToolPayload: Equatable, Hashable, Sendable {
    public var tool: String
    public var target: String
    public var rationale: String?
    public var reward: Double?

    public init(tool: String, target: String, rationale: String? = nil, reward: Double? = nil) {
        self.tool = tool
        self.target = target
        self.rationale = rationale
        self.reward = reward
    }

    init(object: [String: Any]) {
        self.init(
            tool: (object["tool"] as? String) ?? "tool",
            target: (object["target"] as? String) ?? "",
            rationale: object["rationale"] as? String,
            reward: object["reward"] as? Double
        )
    }
}

public struct LedgerAfterAgentPayload: Equatable, Hashable, Sendable {
    public var content: String
    public var reward: Double?

    public init(content: String, reward: Double? = nil) {
        self.content = content
        self.reward = reward
    }

    init(object: [String: Any]) {
        self.init(
            content: object["content"] as? String ?? "",
            reward: object["reward"] as? Double
        )
    }
}

public struct LedgerUserPromptPayload: Equatable, Hashable, Sendable {
    public var event: String
    public var text: String

    public init(event: String, text: String) {
        self.event = event
        self.text = text
    }

    init(event: String, object: [String: Any]) {
        self.init(
            event: event,
            text: (object["text"] as? String)
                ?? (object["content"] as? String)
                ?? (object["prompt"] as? String)
                ?? ""
        )
    }
}

public struct LedgerBranchSummaryPayload: Equatable, Hashable, Sendable {
    public var summary: String
    public var fromProvider: String?
    public var toProvider: String?

    public init(summary: String, fromProvider: String? = nil, toProvider: String? = nil) {
        self.summary = summary
        self.fromProvider = fromProvider
        self.toProvider = toProvider
    }

    init(object: [String: Any]) {
        self.init(
            summary: (object["summary"] as? String)
                ?? (object["text"] as? String)
                ?? (object["content"] as? String)
                ?? "",
            fromProvider: object["from_provider"] as? String,
            toProvider: object["to_provider"] as? String
        )
    }
}

public struct LedgerDelegationStartedPayload: Equatable, Hashable, Sendable {
    public var delegationId: String
    public var specialist: String
    public var objective: String
    public var findingPath: String?
    public var color: String?

    public init(
        delegationId: String,
        specialist: String,
        objective: String,
        findingPath: String? = nil,
        color: String? = nil
    ) {
        self.delegationId = delegationId
        self.specialist = specialist
        self.objective = objective
        self.findingPath = findingPath
        self.color = color
    }

    init(object: [String: Any]) {
        self.init(
            delegationId: object["delegation_id"] as? String ?? "",
            specialist: object["specialist"] as? String ?? "specialist",
            objective: (object["objective"] as? String)
                ?? (object["task"] as? String)
                ?? "",
            findingPath: object["finding_path"] as? String,
            color: object["color"] as? String
        )
    }
}

public struct LedgerDelegationCompletedPayload: Equatable, Hashable, Sendable {
    public var event: String
    public var delegationId: String
    public var findingPath: String?
    public var color: String?

    public init(event: String, delegationId: String, findingPath: String? = nil, color: String? = nil) {
        self.event = event
        self.delegationId = delegationId
        self.findingPath = findingPath
        self.color = color
    }

    init(event: String, object: [String: Any]) {
        self.init(
            event: event,
            delegationId: object["delegation_id"] as? String ?? "",
            findingPath: object["finding_path"] as? String,
            color: object["color"] as? String
        )
    }
}

public struct LedgerDecisionPayload: Equatable, Hashable, Sendable {
    public var event: String
    public var op: String
    public var intent: String

    public init(event: String, op: String, intent: String) {
        self.event = event
        self.op = op
        self.intent = intent
    }

    init(event: String, object: [String: Any]) {
        self.init(
            event: event,
            op: object["op"] as? String ?? "APPROVAL",
            intent: object["intent"] as? String ?? "Codex command approval handled"
        )
    }
}

public struct LedgerAgentChunkRecord: Equatable, Hashable, Sendable {
    public var bubbleId: String
    public var chunk: String
    public var timestamp: Date?

    public init(bubbleId: String, chunk: String, timestamp: Date?) {
        self.bubbleId = bubbleId
        self.chunk = chunk
        self.timestamp = timestamp
    }
}

public func parseLedgerTimestamp(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let isoWithFractionalSeconds = ISO8601DateFormatter()
    isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoSeconds = ISO8601DateFormatter()
    isoSeconds.formatOptions = [.withInternetDateTime]
    if let date = isoWithFractionalSeconds.date(from: value)
        ?? isoSeconds.date(from: value) {
        return date
    }

    let localWithFractionalSeconds = DateFormatter()
    localWithFractionalSeconds.locale = Locale(identifier: "en_US_POSIX")
    localWithFractionalSeconds.timeZone = TimeZone.current
    localWithFractionalSeconds.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    let localSeconds = DateFormatter()
    localSeconds.locale = Locale(identifier: "en_US_POSIX")
    localSeconds.timeZone = TimeZone.current
    localSeconds.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    if let date = localWithFractionalSeconds.date(from: value)
        ?? localSeconds.date(from: value) {
        return date
    }
    return nil
}

public func readHookRecords(atPath path: String) -> [LedgerHookRecord] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }

    var records: [LedgerHookRecord] = []
    enumerateJSONLines(atPath: path) { data in
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = parseLedgerTimestamp(object["timestamp"] as? String) else {
            return
        }
        records.append(LedgerHookRecord(timestamp: timestamp, object: object))
    }
    return records
}

public func readAgentChunkRecords(atPath path: String) -> [LedgerAgentChunkRecord] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }

    var records: [LedgerAgentChunkRecord] = []
    enumerateJSONLines(atPath: path) { data in
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bubbleId = object["bubble_id"] as? String,
              let chunk = object["chunk"] as? String else {
            return
        }
        records.append(LedgerAgentChunkRecord(
            bubbleId: bubbleId,
            chunk: chunk,
            timestamp: parseLedgerTimestamp(object["ts"] as? String)
        ))
    }
    return records
}
