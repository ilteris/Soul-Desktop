import Foundation

struct SoulProjectionError: Decodable, Hashable, Sendable {
    var code: String?
    var message: String?
}

struct SoulTrajectoryStatus: Decodable, Hashable, Sendable {
    var schema: String?
    var projectKey: String?
    var sessionID: String?
    var exists: Bool?
    var stale: Bool?
    var reason: String?
    var trajectoryStatus: String?
    var compiledAt: String?
    var hooksSHA256: String?
    var currentHooksSHA256: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case projectKey = "project_key"
        case sessionID = "session_id"
        case exists
        case stale
        case reason
        case trajectoryStatus = "trajectory_status"
        case compiledAt = "compiled_at"
        case hooksSHA256 = "hooks_sha256"
        case currentHooksSHA256 = "current_hooks_sha256"
    }
}

struct SoulTrajectoryVerification: Decodable, Hashable, Sendable {
    var run: [String]
    var passed: [String]
    var failed: [String]

    init(run: [String] = [], passed: [String] = [], failed: [String] = []) {
        self.run = run
        self.passed = passed
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey {
        case run
        case passed
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = (try? container.decodeIfPresent([String].self, forKey: .run)) ?? []
        passed = (try? container.decodeIfPresent([String].self, forKey: .passed)) ?? []
        failed = (try? container.decodeIfPresent([String].self, forKey: .failed)) ?? []
    }
}

struct SoulTrajectorySummary: Decodable, Hashable, Sendable {
    var status: String?
    var statusDetail: SoulTrajectoryStatus?
    var primaryIntent: String?
    var compiledAt: String?
    var compilerVersion: String?
    var turnCount: Int?
    var decisionCount: Int?
    var verification: SoulTrajectoryVerification?
    var evalCandidateRefs: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case primaryIntent = "primary_intent"
        case compiledAt = "compiled_at"
        case compilerVersion = "compiler_version"
        case turnCount = "turn_count"
        case decisionCount = "decision_count"
        case verification
        case evalCandidateRefs = "eval_candidate_refs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawStatus = try? container.decodeIfPresent(String.self, forKey: .status) {
            status = rawStatus
            statusDetail = nil
        } else if let detail = try? container.decodeIfPresent(SoulTrajectoryStatus.self, forKey: .status) {
            statusDetail = detail
            status = detail.trajectoryStatus ?? detail.reason
        } else {
            status = nil
            statusDetail = nil
        }
        primaryIntent = try container.decodeIfPresent(String.self, forKey: .primaryIntent)
        compiledAt = try container.decodeIfPresent(String.self, forKey: .compiledAt)
        compilerVersion = try container.decodeIfPresent(String.self, forKey: .compilerVersion)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        decisionCount = try container.decodeIfPresent(Int.self, forKey: .decisionCount)
        verification = try? container.decodeIfPresent(SoulTrajectoryVerification.self, forKey: .verification)
        evalCandidateRefs = (try? container.decodeIfPresent([String].self, forKey: .evalCandidateRefs)) ?? []
    }
}

struct SoulSemanticTimelineCheckpoint: Decodable, Hashable, Sendable {
    var semanticEventID: String?
    var semanticSeq: Int?
    var checkpoint: String?
    var timestamp: String?
    var actor: String?
    var summary: String?
    var confidence: Double?
    var refs: [String]

    enum CodingKeys: String, CodingKey {
        case semanticEventID = "semantic_event_id"
        case semanticSeq = "semantic_seq"
        case checkpoint
        case timestamp
        case actor
        case summary
        case confidence
        case refs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        semanticEventID = try container.decodeIfPresent(String.self, forKey: .semanticEventID)
        semanticSeq = try container.decodeIfPresent(Int.self, forKey: .semanticSeq)
        checkpoint = try container.decodeIfPresent(String.self, forKey: .checkpoint)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        actor = try container.decodeIfPresent(String.self, forKey: .actor)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        refs = (try? container.decodeIfPresent([String].self, forKey: .refs)) ?? []
    }
}

struct SoulWorkProjectionAuthority: Decodable, Hashable, Sendable {
    var mode: String?
    var readOnly: Bool?
    var registryFingerprint: String?
    var transport: String?
    var writes: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case readOnly = "read_only"
        case registryFingerprint = "registry_fingerprint"
        case transport
        case writes
    }
}

struct SoulWorkProjection: Decodable, Sendable {
    var schema: String
    var projectKey: String
    var sessionID: String?
    var generatedAt: String?
    var projectionFingerprint: String?
    var authority: SoulWorkProjectionAuthority?
    var activeTask: SoulTaskStatusRecord?
    var activeRun: SoulRunRecord?
    var runs: [SoulRunRecord]
    var trajectoryStatus: SoulTrajectoryStatus?
    var trajectory: SoulTrajectorySummary?
    var semanticTimelineTail: [SoulSemanticTimelineCheckpoint]
    var nextStep: String?

    var inferredCentralHomeDirectory: String? {
        let candidates = ([activeRun?.file] + runs.map(\.file))
            .compactMap { $0 }
        for candidate in candidates {
            guard let range = candidate.range(of: "/soul_registry/"),
                  candidate.hasPrefix("/")
            else { continue }
            let home = String(candidate[..<range.lowerBound])
            if !home.isEmpty {
                return home
            }
        }
        return nil
    }

    private struct CurrentWork: Decodable {
        var taskID: String?
        var project: String?
        var subject: String?
        var status: String?
        var nextStep: String?
        var priority: String?
        var category: String?
        var doneCriteria: [String]
        var completedCriteria: [String]
        var file: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case fallbackID = "id"
            case project
            case subject
            case status
            case nextStep = "next_step"
            case priority
            case category
            case doneCriteria = "done_criteria"
            case completedCriteria = "completed_criteria"
            case file
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
                ?? container.decodeIfPresent(String.self, forKey: .fallbackID)
            project = try container.decodeIfPresent(String.self, forKey: .project)
            subject = try container.decodeIfPresent(String.self, forKey: .subject)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep)
            priority = try container.decodeIfPresent(String.self, forKey: .priority)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            doneCriteria = (try container.decodeIfPresent([String].self, forKey: .doneCriteria)) ?? []
            completedCriteria = (try container.decodeIfPresent([String].self, forKey: .completedCriteria)) ?? []
            file = try container.decodeIfPresent(String.self, forKey: .file)
        }

        func taskRecord(defaultProject: String) -> SoulTaskStatusRecord? {
            guard let taskID, !taskID.isEmpty else { return nil }
            return SoulTaskStatusRecord(
                taskID: taskID,
                project: project ?? defaultProject,
                subject: subject,
                status: status,
                priority: priority,
                category: category,
                doneCriteria: doneCriteria,
                completedCriteria: completedCriteria,
                file: file
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case projectKey = "project_key"
        case sessionID = "session_id"
        case generatedAt = "generated_at"
        case projectionFingerprint = "projection_fingerprint"
        case authority
        case activeTask = "active_task"
        case activeRun = "active_run"
        case runs
        case currentWork = "current_work"
        case trajectoryStatus = "trajectory_status"
        case trajectory
        case semanticTimelineTail = "semantic_timeline_tail"
        case nextStep = "next_step"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        projectKey = try container.decode(String.self, forKey: .projectKey)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        projectionFingerprint = try container.decodeIfPresent(String.self, forKey: .projectionFingerprint)
        authority = try container.decodeIfPresent(SoulWorkProjectionAuthority.self, forKey: .authority)
        let currentWork = try container.decodeIfPresent(CurrentWork.self, forKey: .currentWork)
        activeTask = try container.decodeIfPresent(SoulTaskStatusRecord.self, forKey: .activeTask)
            ?? currentWork?.taskRecord(defaultProject: projectKey)
        activeRun = try container.decodeIfPresent(SoulRunRecord.self, forKey: .activeRun)
        runs = (try container.decodeIfPresent([SoulRunRecord].self, forKey: .runs)) ?? []
        trajectoryStatus = try container.decodeIfPresent(SoulTrajectoryStatus.self, forKey: .trajectoryStatus)
        trajectory = try container.decodeIfPresent(SoulTrajectorySummary.self, forKey: .trajectory)
        semanticTimelineTail = (try container.decodeIfPresent([SoulSemanticTimelineCheckpoint].self, forKey: .semanticTimelineTail)) ?? []
        nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep) ?? currentWork?.nextStep
    }
}

struct SoulWorkProjectionUpdatedParams: Decodable, Sendable {
    var schema: String?
    var projectKey: String
    var sessionID: String?
    var source: String?
    var status: String?
    var updatedAt: String?
    var projectionFingerprint: String?
    var trajectoryStatus: SoulTrajectoryStatus?
    var nextStep: String?
    var scope: String?
    var projectionError: SoulProjectionError?

    enum CodingKeys: String, CodingKey {
        case schema
        case projectKey = "project_key"
        case sessionID = "session_id"
        case source
        case status
        case updatedAt = "updated_at"
        case projectionFingerprint = "projection_fingerprint"
        case trajectoryStatus = "trajectory_status"
        case nextStep = "next_step"
        case scope
        case projectionError = "projection_error"
    }
}
