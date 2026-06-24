import Foundation

public enum LedgerTranscriptRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

public enum LedgerTranscriptContent: Equatable, Hashable, Sendable {
    case message(role: LedgerTranscriptRole, text: String, timestamp: Date)
    case thought(text: String, timestamp: Date)
    case progress(text: String, timestamp: Date)
    case tool(LedgerToolRecord, timestamp: Date)
    case status(text: String)
}

public struct LedgerTranscriptTurn: Equatable, Hashable, Sendable {
    public var content: LedgerTranscriptContent

    public init(content: LedgerTranscriptContent) {
        self.content = content
    }
}

public struct LedgerToolRecord: Equatable, Hashable, Sendable {
    public var name: String
    public var arguments: [String: LedgerJSONValue]

    public init(name: String, arguments: [String: LedgerJSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    public func string(_ key: String) -> String? {
        arguments[key]?.stringValue
    }
}

public enum LedgerJSONValue: Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LedgerJSONValue])
    case array([LedgerJSONValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let object as [String: Any]:
            self = .object(object.mapValues { LedgerJSONValue(any: $0) })
        case let array as [Any]:
            self = .array(array.map { LedgerJSONValue(any: $0) })
        default:
            self = .null
        }
    }
}

public struct LedgerTranscriptReadResult: Equatable, Sendable {
    public var turns: [LedgerTranscriptTurn]
    public var stats: JSONLineStats

    public init(turns: [LedgerTranscriptTurn], stats: JSONLineStats = JSONLineStats()) {
        self.turns = turns
        self.stats = stats
    }
}

public struct LedgerReplayRecord: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case afterTool(LedgerAfterToolPayload)
        case afterAgent(LedgerAfterAgentPayload)
        case userPrompt(LedgerUserPromptPayload)
        case branchSummary(LedgerBranchSummaryPayload)
        case delegationStarted(LedgerDelegationStartedPayload, completed: LedgerDelegationCompletedPayload?)
        case codexApproval(LedgerDecisionPayload)
        case decision(LedgerDecisionPayload)
    }

    public var timestamp: Date
    public var kind: Kind

    public init(timestamp: Date, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

public func readLedgerReplayRecords(atPath path: String) -> [LedgerReplayRecord] {
    let records = readHookRecords(atPath: path)

    var completedDelegations: [String: LedgerDelegationCompletedPayload] = [:]
    for record in records {
        switch record.payload {
        case .delegationCompleted(let payload), .delegationFailed(let payload):
            guard !payload.delegationId.isEmpty else { continue }
            completedDelegations[payload.delegationId] = payload
        default:
            continue
        }
    }

    return records.compactMap { record in
        switch record.payload {
        case .afterTool(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .afterTool(payload))
        case .afterAgent(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .afterAgent(payload))
        case .userPrompt(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .userPrompt(payload))
        case .branchSummary(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .branchSummary(payload))
        case .delegationStarted(let payload):
            return LedgerReplayRecord(
                timestamp: record.timestamp,
                kind: .delegationStarted(payload, completed: completedDelegations[payload.delegationId])
            )
        case .delegationCompleted, .delegationFailed, .metadata, .unknown:
            return nil
        case .codexApproval(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .codexApproval(payload))
        case .decision(let payload):
            return LedgerReplayRecord(timestamp: record.timestamp, kind: .decision(payload))
        }
    }
}
