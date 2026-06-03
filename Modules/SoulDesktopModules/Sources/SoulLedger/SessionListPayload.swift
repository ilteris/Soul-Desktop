import Foundation

/// UI-free decoder for `soul session list -p <key> --json` and
/// `soul session show <sid> -p <key> --json` payloads.
public struct LedgerSessionListPayload: Decodable, Sendable {
    public var project: String
    public var sessions: [LedgerSessionListRecord]

    public init(project: String, sessions: [LedgerSessionListRecord]) {
        self.project = project
        self.sessions = sessions
    }
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
    public var raw_title: String?
    public var worktree_path: String?
    public var session_start_ppid: Int?
    public var session_visibility: String?
    public var session_kind: String?
    public var visibility_reason: String?
    public var provider: String?
    public var origin: String?
    public var writer: String?
    public var title_source: String?
    public var title_status: String?
    public var assistant_turn_count: Int?
    public var tool_call_count: Int?
    public var visible_turn_count: Int?
    public var has_conversation: Bool?
    public var loadable: Bool?
    public var replayable: Bool?
    public var resume_strategy: String?
    public var resume_target: String?
    public var loadability_reason: String?
    public var health: String?
    public var health_reasons: [String]?
    public var lifecycle: String?
    public var trashed_at: String?
    public var slash_semantics: [String: LedgerSlashCommandSemantics]?
    public var task_id: String?
    public var task_status: String?
    public var task_subject: String?
    public var has_desktop_signature: Bool?
    public var partial_capture: Bool?
    public var after_agent_content_count: Int?
    public var native_session_ids: [String: String]?
    public var finalize: LedgerSessionFinalizePayload?
}

public struct LedgerSlashCommandSemantics: Decodable, Sendable, Equatable {
    public var local_only: Bool?
    public var conversation_worthy: Bool?
    public var task_affecting: Bool?
    public var title_worthy: Bool?
    public var expansion_strategy: String?

    enum CodingKeys: String, CodingKey {
        case local_only, conversation_worthy, task_affecting, title_worthy, expansion_strategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        local_only = try container.decodeIfPresent(Bool.self, forKey: .local_only)
        conversation_worthy = try container.decodeIfPresent(Bool.self, forKey: .conversation_worthy)
        task_affecting = try container.decodeIfPresent(Bool.self, forKey: .task_affecting)
        title_worthy = try container.decodeIfPresent(Bool.self, forKey: .title_worthy)

        if let string = try? container.decodeIfPresent(String.self, forKey: .expansion_strategy) {
            expansion_strategy = string
        } else if let bool = try? container.decodeIfPresent(Bool.self, forKey: .expansion_strategy) {
            expansion_strategy = bool ? "enabled" : nil
        } else {
            expansion_strategy = nil
        }
    }
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
