import Foundation
import SwiftUI

struct SoulRunRecord: Identifiable, Hashable, Sendable, Decodable {
    var runID: String
    var project: String
    var taskID: String?
    var goalID: String?
    var sessionID: String?
    var workspaceID: String?
    var objective: String?
    var status: String
    var createdAt: String?
    var updatedAt: String?
    var completedAt: String?
    var summary: String?
    var durationSeconds: Double?
    var retryCount: Int?
    var failureReasons: [String]
    var skillIDs: [String]
    var verifierOutcomes: [String: Int]
    var file: String?

    var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case project
        case taskID = "task_id"
        case goalID = "goal_id"
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
        case objective
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case summary
        case durationSeconds = "duration_sec"
        case retryCount = "retry_count"
        case failureReasons = "failure_reasons"
        case skillIDs = "skill_ids"
        case verifierOutcomes = "verifier_outcomes"
        case file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        project = try container.decode(String.self, forKey: .project)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        goalID = try container.decodeIfPresent(String.self, forKey: .goalID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        objective = try container.decodeIfPresent(String.self, forKey: .objective)
        status = (try container.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount)
        failureReasons = (try container.decodeIfPresent([String].self, forKey: .failureReasons)) ?? []
        skillIDs = (try container.decodeIfPresent([String].self, forKey: .skillIDs)) ?? []
        verifierOutcomes = (try container.decodeIfPresent([String: Int].self, forKey: .verifierOutcomes)) ?? [:]
        file = try container.decodeIfPresent(String.self, forKey: .file)
    }

    var isActive: Bool {
        ["initialized", "running", "waiting", "paused"].contains(status)
    }

    var displayTitle: String {
        if let taskID, !taskID.isEmpty {
            return "\(taskID) run"
        }
        return objective?.isEmpty == false ? objective! : runID
    }

    var displayDetail: String {
        let base = summary?.isEmpty == false ? summary! : objective ?? runID
        var parts: [String] = [base]
        if let retryCount, retryCount > 0 {
            parts.append(retryCount == 1 ? "1 retry" : "\(retryCount) retries")
        }
        if !verifierOutcomes.isEmpty {
            let verifier = verifierOutcomes
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            parts.append("verifier \(verifier)")
        }
        return parts.joined(separator: " · ")
    }

    var timestamp: Date? {
        Self.date(from: updatedAt) ?? Self.date(from: completedAt) ?? Self.date(from: createdAt)
    }

    var statusTint: Color {
        switch status {
        case "completed":
            return .green
        case "failed", "timed_out", "cancelled", "budget_exhausted", "max_iterations":
            return .red
        case "running", "initialized", "waiting", "paused":
            return SoulColor.accent
        default:
            return SoulColor.fgMuted
        }
    }

    var fileURL: URL {
        if let file, !file.isEmpty {
            return URL(fileURLWithPath: file.replacingOccurrences(of: "~", with: NSHomeDirectory()))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("soul_registry")
            .appendingPathComponent("runs")
            .appendingPathComponent(project)
            .appendingPathComponent(runID)
            .appendingPathComponent("run.json")
    }

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return timestampFormatter.date(from: value) ?? timestampFormatterWithFractionalSeconds.date(from: value)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let timestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct SoulRunStepRecord: Identifiable, Hashable, Sendable, Decodable {
    var stepID: String
    var runID: String
    var project: String?
    var kind: String?
    var objective: String?
    var status: String
    var createdAt: String?
    var updatedAt: String?
    var completedAt: String?
    var summary: String?
    var artifactRef: String?
    var file: String?

    var id: String { stepID }

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case runID = "run_id"
        case project
        case kind
        case objective
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case summary
        case artifactRef = "artifact_ref"
        case file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepID = try container.decode(String.self, forKey: .stepID)
        runID = try container.decode(String.self, forKey: .runID)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        objective = try container.decodeIfPresent(String.self, forKey: .objective)
        status = (try container.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        artifactRef = try container.decodeIfPresent(String.self, forKey: .artifactRef)
        file = try container.decodeIfPresent(String.self, forKey: .file)
    }
}

struct SoulRunEventRecord: Identifiable, Hashable, Sendable, Decodable {
    var event: String
    var timestamp: String?
    var runID: String?
    var taskID: String?
    var stepID: String?
    var kind: String?
    var status: String?
    var attemptCount: Int?
    var outputRef: String?
    var artifactRef: String?

    var id: String {
        [
            event,
            timestamp,
            runID,
            stepID,
            status
        ]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ":")
    }

    enum CodingKeys: String, CodingKey {
        case event
        case timestamp
        case runID = "run_id"
        case taskID = "task_id"
        case stepID = "step_id"
        case kind
        case status
        case attemptCount = "attempt_count"
        case outputRef = "output_ref"
        case artifactRef = "artifact_ref"
    }
}

struct SoulRunHistoryPayload: Decodable, Sendable {
    var project: String
    var runs: [SoulRunRecord]
}

struct SoulRunListPayload: Decodable, Sendable {
    var project: String
    var runs: [SoulRunRecord]
}

struct SoulRunStepListPayload: Decodable, Sendable {
    var project: String
    var runID: String
    var steps: [SoulRunStepRecord]

    enum CodingKeys: String, CodingKey {
        case project
        case runID = "run_id"
        case steps
    }
}

struct SoulRunEventsPayload: Decodable, Sendable {
    var project: String
    var runID: String
    var events: [SoulRunEventRecord]

    enum CodingKeys: String, CodingKey {
        case project
        case runID = "run_id"
        case events
    }
}

struct SoulRunReviewPayload: Decodable, Sendable {
    struct Summary: Decodable, Hashable, Sendable {
        var totalRuns: Int
        var completedRuns: Int
        var failedRuns: Int
        var successRate: Double?
        var averageDurationSeconds: Double?
        var retryCount: Int
        var failureReasons: [String: Int]
        var verifierOutcomes: [String: Int]

        enum CodingKeys: String, CodingKey {
            case totalRuns = "total_runs"
            case completedRuns = "completed_runs"
            case failedRuns = "failed_runs"
            case successRate = "success_rate"
            case averageDurationSeconds = "average_duration_sec"
            case retryCount = "retry_count"
            case failureReasons = "failure_reasons"
            case verifierOutcomes = "verifier_outcomes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalRuns = (try container.decodeIfPresent(Int.self, forKey: .totalRuns)) ?? 0
            completedRuns = (try container.decodeIfPresent(Int.self, forKey: .completedRuns)) ?? 0
            failedRuns = (try container.decodeIfPresent(Int.self, forKey: .failedRuns)) ?? 0
            successRate = try container.decodeIfPresent(Double.self, forKey: .successRate)
            averageDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .averageDurationSeconds)
            retryCount = (try container.decodeIfPresent(Int.self, forKey: .retryCount)) ?? 0
            failureReasons = (try container.decodeIfPresent([String: Int].self, forKey: .failureReasons)) ?? [:]
            verifierOutcomes = (try container.decodeIfPresent([String: Int].self, forKey: .verifierOutcomes)) ?? [:]
        }
    }

    var project: String
    var summary: Summary
    var runs: [SoulRunRecord]
}

struct SoulWorkStatusPayload: Decodable, Sendable {
    var project: String
    var task: SoulTaskStatusRecord?
    var runs: [SoulRunRecord]
}

struct SoulTaskStatusRecord: Identifiable, Hashable, Sendable, Decodable {
    var taskID: String
    var project: String
    var subject: String?
    var status: String?
    var rawStatus: String?
    var priority: String?
    var category: String?
    var doneCriteria: [String]
    var completedCriteria: [String]
    var file: String?
    var isActive: Bool?

    var id: String { taskID }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case fallbackID = "id"
        case project
        case subject
        case status
        case rawStatus = "raw_status"
        case priority
        case category
        case doneCriteria = "done_criteria"
        case completedCriteria = "completed_criteria"
        case file
        case isActive = "is_active"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
            ?? container.decode(String.self, forKey: .fallbackID)
        project = try container.decode(String.self, forKey: .project)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        rawStatus = try container.decodeIfPresent(String.self, forKey: .rawStatus)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        doneCriteria = (try container.decodeIfPresent([String].self, forKey: .doneCriteria)) ?? []
        completedCriteria = (try container.decodeIfPresent([String].self, forKey: .completedCriteria)) ?? []
        file = try container.decodeIfPresent(String.self, forKey: .file)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
    }
}

struct SoulSubagentRecord: Identifiable, Hashable, Sendable, Decodable {
    struct Finding: Hashable, Sendable, Decodable {
        var specialist: String?
        var provider: String?
        var task: String?
        var objective: String?
        var status: String?
        var summary: String?
        var timestamp: String?
        var completedAt: String?

        enum CodingKeys: String, CodingKey {
            case specialist
            case provider
            case task
            case objective
            case status
            case summary
            case timestamp
            case completedAt = "completed_at"
        }
    }

    var subagentID: String
    var project: String?
    var specialist: String?
    var provider: String?
    var task: String?
    var status: String?
    var summary: String?
    var createdAt: String?
    var updatedAt: String?
    var startedAt: Double?
    var completedAt: String?
    var parentSessionID: String?
    var liveLog: String?
    var liveLogBytes: Int?
    var findingPath: String?
    var finding: Finding?
    var file: String?

    var id: String { subagentID }

    var isActive: Bool {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty
        else { return false }
        return ["initialized", "running", "waiting", "pending", "in_progress"].contains(status)
    }

    var displayTitle: String {
        if let specialist = specialist ?? finding?.specialist, !specialist.isEmpty {
            return "@\(specialist)"
        }
        return subagentID
    }

    var displayDetail: String {
        if let summary, !summary.isEmpty { return summary }
        if let summary = finding?.summary, !summary.isEmpty { return summary }
        if let task, !task.isEmpty { return task }
        if let task = finding?.task ?? finding?.objective, !task.isEmpty { return task }
        if let provider, !provider.isEmpty { return provider }
        if let provider = finding?.provider, !provider.isEmpty { return provider }
        if let liveLogBytes, liveLogBytes > 0 { return "\(liveLogBytes) bytes in live log" }
        return subagentID
    }

    var timestamp: Date? {
        SoulRunRecord.date(from: updatedAt)
            ?? SoulRunRecord.date(from: completedAt)
            ?? SoulRunRecord.date(from: finding?.completedAt)
            ?? SoulRunRecord.date(from: finding?.timestamp)
            ?? SoulRunRecord.date(from: createdAt)
            ?? startedAt.map { Date(timeIntervalSince1970: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case subagentID = "subagent_id"
        case fallbackID = "id"
        case project
        case specialist
        case provider
        case task
        case status
        case summary
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case parentSessionID = "parent_session_id"
        case liveLog = "live_log"
        case liveLogBytes = "live_log_bytes"
        case findingPath = "finding_path"
        case finding
        case file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subagentID = try container.decodeIfPresent(String.self, forKey: .subagentID)
            ?? container.decode(String.self, forKey: .fallbackID)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        specialist = try container.decodeIfPresent(String.self, forKey: .specialist)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        parentSessionID = try container.decodeIfPresent(String.self, forKey: .parentSessionID)
        liveLog = try container.decodeIfPresent(String.self, forKey: .liveLog)
        liveLogBytes = try container.decodeIfPresent(Int.self, forKey: .liveLogBytes)
        findingPath = try container.decodeIfPresent(String.self, forKey: .findingPath)
        finding = try container.decodeIfPresent(Finding.self, forKey: .finding)
        file = try container.decodeIfPresent(String.self, forKey: .file)
    }
}

struct SoulSubagentListPayload: Decodable, Sendable {
    var project: String?
    var subagents: [SoulSubagentRecord]
}

struct SoulOrchestrationStatusResult: Decodable, Sendable {
    var projectKey: String
    var snapshot: SoulOrchestrationSnapshot

    enum CodingKeys: String, CodingKey {
        case projectKey = "project_key"
        case snapshot
    }
}

struct SoulOrchestrationSnapshot: Decodable, Sendable {
    var schema: String
    var project: String
    var projectKey: String?
    var version: String?
    var updatedAt: String?
    var workStatus: SoulWorkStatusPayload
    var runReview: SoulRunReviewPayload
    var subagentList: SoulSubagentListPayload
    var activeTask: SoulTaskStatusRecord?
    var runs: [SoulRunRecord]
    var subagents: [SoulSubagentRecord]

    enum CodingKeys: String, CodingKey {
        case schema
        case project
        case projectKey = "project_key"
        case version
        case updatedAt = "updated_at"
        case workStatus = "work_status"
        case runReview = "run_review"
        case subagentList = "subagent_list"
        case activeTask = "active_task"
        case runs
        case subagents
    }
}
