import Foundation
import SoulACP
import SoulCore

actor ACPProviderRuntimeAdapter: ProviderRuntime {
    typealias PromptAttachment = ContentBlock

    private let provider: Provider
    private let projectKey: String
    private let provisionalSessionID: String
    private var client: ACPClient?
    private var capabilities = ProviderRuntimeCapabilities()

    init(provider: Provider, projectKey: String, provisionalSessionID: String) {
        self.provider = provider
        self.projectKey = projectKey
        self.provisionalSessionID = provisionalSessionID
    }

    var isStarted: Bool {
        client != nil
    }

    func eventStream() async -> AsyncStream<ACPClient.Event>? {
        await client?.events
    }

    func start(_ request: ProviderRuntimeStartRequest) async throws -> ProviderRuntimeStartResult {
        if client != nil {
            return ProviderRuntimeStartResult(capabilities: capabilities)
        }

        guard var spawn = ACPProviderSpawn.resolve(provider, resumeSessionId: request.resumeSessionID) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no spawn config for \(provider.label)"])
        }

        let hydration = await SoulHydration.prepare(
            provider: provider,
            projectKey: projectKey,
            projectPath: request.session.projectPath,
            sessionId: provisionalSessionID
        )

        var env = spawn.environment ?? [:]
        for (key, value) in hydration.env {
            env[key] = value
        }
        env["SOUL_PROJECT"] = projectKey
        if let sid = request.session.kernelSessionID {
            env["SOUL_SESSION_ID"] = sid
        }
        spawn.environment = env
        spawn.cwd = request.session.projectPath

        let client = try ACPClient(spawn: spawn)
        self.client = client
        await client.setAutoAllow(true)
        await client.setPermissionMode(request.permissionMode)
        try await client.start()

        let initResp = try await client.initialize()
        capabilities = ProviderRuntimeCapabilities(
            supportsLoadSession: initResp.agentCapabilities?.loadSession ?? false,
            supportsImageAttachments: initResp.agentCapabilities?.promptCapabilities?.image ?? false
        )
        return ProviderRuntimeStartResult(capabilities: capabilities)
    }

    func loadSession(_ request: ProviderRuntimeLoadRequest) async throws {
        guard let client else {
            throw ACPClientError.notInitialized
        }
        try await client.loadSession(
            sessionId: request.requestedSessionID,
            cwd: request.session.projectPath
        )
    }

    func startNewSession(_ request: ProviderRuntimeNewSessionRequest) async throws -> ProviderRuntimeNewSessionResult {
        guard let client else {
            throw ACPClientError.notInitialized
        }
        let nativeSessionID = try await client.newSession(
            cwd: request.session.projectPath,
            systemPrompt: request.systemPrompt
        )
        return ProviderRuntimeNewSessionResult(nativeSessionID: nativeSessionID)
    }

    func prompt(_ request: ProviderRuntimePromptRequest<ContentBlock>) async throws {
        guard let client, let sessionID = request.session.rpcSessionID, request.canDispatch else {
            throw ACPClientError.notInitialized
        }
        _ = try await client.prompt(
            sessionId: sessionID,
            text: request.text,
            extraBlocks: request.attachments
        )
    }

    func cancel(_ request: ProviderRuntimeCancelRequest) async {
        guard let client, let sessionID = request.session.rpcSessionID else {
            return
        }
        try? await client.cancel(sessionId: sessionID)
    }

    func stop() async {
        await client?.stop()
        client = nil
        capabilities = ProviderRuntimeCapabilities()
    }

    func setPermissionMode(_ mode: AgentPermissionMode) async {
        await client?.setPermissionMode(mode)
    }

    func respondError(id: JSONRPCID, code: Int, message: String) async {
        await client?.respondError(id: id, code: code, message: message)
    }
}
