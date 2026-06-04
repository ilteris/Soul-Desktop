import Foundation

/// UI-free identity for the provider runtime lifecycle.
///
/// Concrete process spawning, JSON-RPC clients, event streams, and app
/// rendering remain outside SoulCore. These contracts describe the requests
/// and results that a runtime adapter must support.
public struct ProviderRuntimeSession: Equatable, Sendable {
    public var provider: AgentProvider
    public var projectPath: String
    public var kernelSessionID: String?
    public var nativeSessionID: String?

    public init(
        provider: AgentProvider,
        projectPath: String,
        kernelSessionID: String? = nil,
        nativeSessionID: String? = nil
    ) {
        self.provider = provider
        self.projectPath = projectPath
        self.kernelSessionID = kernelSessionID
        self.nativeSessionID = nativeSessionID
    }

    public var rpcSessionID: String? {
        nativeSessionID ?? kernelSessionID
    }
}

public struct ProviderRuntimeCapabilities: Equatable, Sendable {
    public var supportsLoadSession: Bool
    public var supportsImageAttachments: Bool

    public init(supportsLoadSession: Bool = false, supportsImageAttachments: Bool = false) {
        self.supportsLoadSession = supportsLoadSession
        self.supportsImageAttachments = supportsImageAttachments
    }
}

public struct ProviderRuntimeStartRequest: Equatable, Sendable {
    public var session: ProviderRuntimeSession
    public var skipNewSession: Bool
    public var resumeSessionID: String?
    public var permissionMode: AgentPermissionMode

    public init(
        session: ProviderRuntimeSession,
        skipNewSession: Bool = false,
        resumeSessionID: String? = nil,
        permissionMode: AgentPermissionMode = .fullAccess
    ) {
        self.session = session
        self.skipNewSession = skipNewSession
        self.resumeSessionID = resumeSessionID
        self.permissionMode = permissionMode
    }
}

public struct ProviderRuntimeStartResult: Equatable, Sendable {
    public var nativeSessionID: String?
    public var capabilities: ProviderRuntimeCapabilities

    public init(
        nativeSessionID: String? = nil,
        capabilities: ProviderRuntimeCapabilities = ProviderRuntimeCapabilities()
    ) {
        self.nativeSessionID = nativeSessionID
        self.capabilities = capabilities
    }
}

public struct ProviderRuntimeLoadRequest: Equatable, Sendable {
    public var session: ProviderRuntimeSession
    public var requestedSessionID: String

    public init(session: ProviderRuntimeSession, requestedSessionID: String) {
        self.session = session
        self.requestedSessionID = requestedSessionID
    }
}

public struct ProviderRuntimeNewSessionRequest: Equatable, Sendable {
    public var session: ProviderRuntimeSession
    public var systemPrompt: String?

    public init(session: ProviderRuntimeSession, systemPrompt: String? = nil) {
        self.session = session
        self.systemPrompt = systemPrompt
    }
}

public struct ProviderRuntimeNewSessionResult: Equatable, Sendable {
    public var nativeSessionID: String

    public init(nativeSessionID: String) {
        self.nativeSessionID = nativeSessionID
    }
}

public struct ProviderRuntimePromptRequest<Attachment: Equatable & Sendable>: Equatable, Sendable {
    public var session: ProviderRuntimeSession
    public var text: String
    public var attachments: [Attachment]

    public init(session: ProviderRuntimeSession, text: String, attachments: [Attachment] = []) {
        self.session = session
        self.text = text
        self.attachments = attachments
    }

    public var canDispatch: Bool {
        session.rpcSessionID != nil
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
}

public struct ProviderRuntimeCancelRequest: Equatable, Sendable {
    public var session: ProviderRuntimeSession
    public var activeTurnID: String?

    public init(session: ProviderRuntimeSession, activeTurnID: String? = nil) {
        self.session = session
        self.activeTurnID = activeTurnID
    }
}

public protocol ProviderRuntime: Sendable {
    associatedtype PromptAttachment: Equatable & Sendable

    func start(_ request: ProviderRuntimeStartRequest) async throws -> ProviderRuntimeStartResult
    func loadSession(_ request: ProviderRuntimeLoadRequest) async throws
    func startNewSession(_ request: ProviderRuntimeNewSessionRequest) async throws -> ProviderRuntimeNewSessionResult
    func prompt(_ request: ProviderRuntimePromptRequest<PromptAttachment>) async throws
    func cancel(_ request: ProviderRuntimeCancelRequest) async
    func compact(threadID: String) async throws
    func stop() async
}

extension ProviderRuntime {
    public func compact(threadID: String) async throws {}
}
