import Foundation
import SoulACP
import SoulCore

public struct RuntimeHydrationResult: Equatable, Sendable {
    public var env: [String: String]
    public var log: [String]

    public init(env: [String: String] = [:], log: [String] = []) {
        self.env = env
        self.log = log
    }
}

public typealias RuntimeSpawnResolver = @Sendable (_ provider: AgentProvider, _ resumeSessionID: String?) -> ACPProviderSpawn?
public typealias RuntimeHydrationPreparer = @Sendable (
    _ provider: AgentProvider,
    _ projectKey: String,
    _ projectPath: String,
    _ sessionID: String
) async -> RuntimeHydrationResult

public actor ACPProviderRuntimeAdapter: ProviderRuntime {
    public typealias PromptAttachment = ContentBlock

    private let provider: AgentProvider
    private let projectKey: String
    private let provisionalSessionID: String
    private let spawnResolver: RuntimeSpawnResolver
    private let hydrationPreparer: RuntimeHydrationPreparer
    private var client: ACPClient?
    private var capabilities = ProviderRuntimeCapabilities()

    public init(
        provider: AgentProvider,
        projectKey: String,
        provisionalSessionID: String,
        spawnResolver: @escaping RuntimeSpawnResolver,
        hydrationPreparer: @escaping RuntimeHydrationPreparer
    ) {
        self.provider = provider
        self.projectKey = projectKey
        self.provisionalSessionID = provisionalSessionID
        self.spawnResolver = spawnResolver
        self.hydrationPreparer = hydrationPreparer
    }

    public var isStarted: Bool {
        client != nil
    }

    public func eventStream() async -> AsyncStream<ACPClient.Event>? {
        await client?.events
    }

    public func start(_ request: ProviderRuntimeStartRequest) async throws -> ProviderRuntimeStartResult {
        if client != nil {
            return ProviderRuntimeStartResult(capabilities: capabilities)
        }

        guard var spawn = spawnResolver(provider, request.resumeSessionID) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no spawn config for \(provider.rawValue)"])
        }

        let workspacePath = Self.resolvedWorkspacePath(request.session.projectPath)
        guard Self.directoryExists(at: workspacePath) else {
            throw NSError(
                domain: "Soul-Desktop",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "workspace path does not exist: \(workspacePath)"]
            )
        }

        let hydration = await hydrationPreparer(provider, projectKey, workspacePath, provisionalSessionID)

        var env = spawn.environment ?? [:]
        for (key, value) in hydration.env {
            env[key] = value
        }
        env = Self.applyWorkspaceEnvironment(
            env,
            projectKey: projectKey,
            workspacePath: workspacePath,
            kernelSessionID: request.session.kernelSessionID
        )
        spawn.environment = env
        spawn.cwd = workspacePath

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

    static func resolvedWorkspacePath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    static func applyWorkspaceEnvironment(
        _ environment: [String: String],
        projectKey: String,
        workspacePath: String,
        kernelSessionID: String?
    ) -> [String: String] {
        var env = environment
        env["SOUL_PROJECT"] = projectKey
        env["SOUL_PROJECT_PATH"] = workspacePath
        env["SOUL_WORKSPACE_PATH"] = workspacePath
        env["SOUL_DESKTOP_WORKSPACE_PATH"] = workspacePath
        env["CODER_AGENT_WORKSPACE_PATH"] = workspacePath
        env["PWD"] = workspacePath
        if let sid = kernelSessionID {
            env["SOUL_SESSION_ID"] = sid
        }
        return env
    }

    private static func directoryExists(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func loadSession(_ request: ProviderRuntimeLoadRequest) async throws {
        guard let client else {
            throw ACPClientError.notInitialized
        }
        try await client.loadSession(
            sessionId: request.requestedSessionID,
            cwd: request.session.projectPath
        )
    }

    public func startNewSession(_ request: ProviderRuntimeNewSessionRequest) async throws -> ProviderRuntimeNewSessionResult {
        guard let client else {
            throw ACPClientError.notInitialized
        }
        let nativeSessionID = try await client.newSession(
            cwd: request.session.projectPath,
            systemPrompt: request.systemPrompt
        )
        return ProviderRuntimeNewSessionResult(nativeSessionID: nativeSessionID)
    }

    public func prompt(_ request: ProviderRuntimePromptRequest<ContentBlock>) async throws {
        guard let client, let sessionID = request.session.rpcSessionID, request.canDispatch else {
            throw ACPClientError.notInitialized
        }
        _ = try await client.prompt(
            sessionId: sessionID,
            text: request.text,
            extraBlocks: request.attachments
        )
    }

    public func cancel(_ request: ProviderRuntimeCancelRequest) async {
        guard let client, let sessionID = request.session.rpcSessionID else {
            return
        }
        try? await client.cancel(sessionId: sessionID)
    }

    public func stop() async {
        await client?.stop()
        client = nil
        capabilities = ProviderRuntimeCapabilities()
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) async {
        await client?.setPermissionMode(mode)
    }

    public func respondError(id: JSONRPCID, code: Int, message: String) async {
        await client?.respondError(id: id, code: code, message: message)
    }
}
