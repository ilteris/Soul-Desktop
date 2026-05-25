import Foundation

/// UI-free decoder for `soul session list -p <key> --json` and
/// `soul session show <sid> -p <key> --json` payloads.
public struct LedgerSessionListPayload: Decodable, Sendable {
    public var project: String
    public var sessions: [LedgerSessionListRecord]
}

public struct LedgerSessionListRecord: Decodable, Sendable {
    public var session_id: String
    public var session_dir: String?
    public var hooks_path: String?
    public var hooks_mtime: Double?
    public var finalize_path: String?
    public var finalize_mtime: Double?
    public var has_finalize: Bool?
    public var event_count: Int?
    public var prompt_count: Int?
    public var delegation_event_count: Int?
    public var first_event_ts: String?
    public var last_event_ts: String?
    public var first_user_prompt: String?
    public var first_user_prompts: [String]?
    public var title: String?
    public var worktree_path: String?
    public var session_start_ppid: Int?
    public var session_visibility: String?
    public var session_kind: String?
    public var has_desktop_signature: Bool?
    public var partial_capture: Bool?
    public var after_agent_content_count: Int?
    public var native_session_ids: [String: String]?
    public var finalize: LedgerSessionFinalizePayload?
}

public struct LedgerSessionFinalizePayload: Decodable, Sendable {
    public var intent: String?
    public var summary: String?
    public var rationale: String?
    public var fixed: String?
    public var next_step: String?
    public var timestamp: String?
    public var source: String?
    public var status: String?
    public var worktree_path: String?

    enum CodingKeys: String, CodingKey {
        case intent, summary, rationale, fixed, next_step
        case timestamp, source, status, worktree_path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        next_step = try container.decodeIfPresent(String.self, forKey: .next_step)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        worktree_path = try container.decodeIfPresent(String.self, forKey: .worktree_path)
        if let string = try? container.decodeIfPresent(String.self, forKey: .fixed) {
            fixed = string
        } else if let array = try? container.decodeIfPresent([String].self, forKey: .fixed) {
            fixed = array.isEmpty ? nil : array.joined(separator: "\n")
        } else {
            fixed = nil
        }
    }
}

public func decodeLedgerSessionListPayload(from data: Data) throws -> LedgerSessionListPayload {
    try JSONDecoder().decode(LedgerSessionListPayload.self, from: data)
}

public func decodeLedgerSessionListRecord(from data: Data) throws -> LedgerSessionListRecord {
    try JSONDecoder().decode(LedgerSessionListRecord.self, from: data)
}
