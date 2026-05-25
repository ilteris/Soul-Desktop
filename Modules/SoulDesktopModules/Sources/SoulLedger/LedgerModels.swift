import Foundation

/// UI-free project identity used by ledger readers.
public struct LedgerProject: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var pillar: String?
    public var tier: Int?
    public var status: String?
    public var primaryHost: String?

    public init(
        id: String,
        name: String,
        path: String,
        pillar: String? = nil,
        tier: Int? = nil,
        status: String? = nil,
        primaryHost: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.pillar = pillar
        self.tier = tier
        self.status = status
        self.primaryHost = primaryHost
    }
}

/// Provenance for a hooks.jsonl ledger. This is a persistence signal, not UI
/// policy; surface code decides what to do with unsafe live rows.
public enum LedgerSessionWriter: String, Codable, Hashable, Sendable {
    case soulDesktop
    case external
    case unknown
}

/// UI-free session row metadata derived from ledger and finalize files.
public struct LedgerSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var timestamp: Date
    public var intent: String?
    public var summary: String?
    public var source: String?
    public var status: String?
    public var eventCount: Int
    public var promptCount: Int
    public var transcriptTurns: Int
    public var isLive: Bool
    public var isDirty: Bool
    public var writer: LedgerSessionWriter
    public var worktreePath: String?
    public var liveProvider: String?
    public var loadable: Bool
    public var replayable: Bool
    public var sessionVisibility: String?
    public var delegationEventCount: Int
    public var sessionStartPpid: Int?
    public var hasFinalize: Bool
    public var partialCapture: Bool
    public var agentReplyMissing: Bool
    public var lastActivityAt: Date?
    public var startedAt: Date?
    public var isStale: Bool

    public init(
        id: String,
        project: String,
        timestamp: Date,
        intent: String? = nil,
        summary: String? = nil,
        source: String? = nil,
        status: String? = nil,
        eventCount: Int = 0,
        promptCount: Int = 0,
        transcriptTurns: Int = 0,
        isLive: Bool = false,
        isDirty: Bool = false,
        writer: LedgerSessionWriter = .unknown,
        worktreePath: String? = nil,
        liveProvider: String? = nil,
        loadable: Bool = true,
        replayable: Bool = true,
        sessionVisibility: String? = nil,
        delegationEventCount: Int = 0,
        sessionStartPpid: Int? = nil,
        hasFinalize: Bool = false,
        partialCapture: Bool = false,
        agentReplyMissing: Bool = false,
        lastActivityAt: Date? = nil,
        startedAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.id = id
        self.project = project
        self.timestamp = timestamp
        self.intent = intent
        self.summary = summary
        self.source = source
        self.status = status
        self.eventCount = eventCount
        self.promptCount = promptCount
        self.transcriptTurns = transcriptTurns
        self.isLive = isLive
        self.isDirty = isDirty
        self.writer = writer
        self.worktreePath = worktreePath
        self.liveProvider = liveProvider
        self.loadable = loadable
        self.replayable = replayable
        self.sessionVisibility = sessionVisibility
        self.delegationEventCount = delegationEventCount
        self.sessionStartPpid = sessionStartPpid
        self.hasFinalize = hasFinalize
        self.partialCapture = partialCapture
        self.agentReplyMissing = agentReplyMissing
        self.lastActivityAt = lastActivityAt
        self.startedAt = startedAt
        self.isStale = isStale
    }

    public var canSafelyResume: Bool {
        !isLive || isStale || writer == .soulDesktop
    }
}
