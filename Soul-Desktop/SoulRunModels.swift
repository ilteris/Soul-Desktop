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
