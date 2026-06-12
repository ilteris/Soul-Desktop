import Foundation
import SoulACP
import SoulCore

public actor CodexProviderRuntimeAdapter: ProviderRuntime {
    public typealias PromptAttachment = ContentBlock

    private let projectKey: String
    private let spawnResolver: RuntimeSpawnResolver
    private let hydrationPreparer: RuntimeHydrationPreparer
    private var client: CodexClient?
    private var currentTurnID: String?

    public init(
        projectKey: String,
        spawnResolver: @escaping RuntimeSpawnResolver,
        hydrationPreparer: @escaping RuntimeHydrationPreparer
    ) {
        self.projectKey = projectKey
        self.spawnResolver = spawnResolver
        self.hydrationPreparer = hydrationPreparer
    }

    public var isStarted: Bool {
        client != nil
    }

    public var activeTurnID: String? {
        currentTurnID
    }

    public func eventStream() async -> AsyncStream<CodexClient.Event>? {
        await client?.events
    }

    public func start(_ request: ProviderRuntimeStartRequest) async throws -> ProviderRuntimeStartResult {
        if let client {
            let threadID = try await client.threadStart(cwd: request.session.projectPath)
            return ProviderRuntimeStartResult(nativeSessionID: threadID)
        }
        guard var spawn = spawnResolver(.codex, nil) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex binary not found on PATH"])
        }

        let hydrationSessionID = request.session.kernelSessionID
            ?? request.session.nativeSessionID
            ?? UUID().uuidString.lowercased()
        let hydration = await hydrationPreparer(
            .codex,
            projectKey,
            request.session.projectPath,
            hydrationSessionID
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

        let client = try CodexClient(spawn: spawn)
        self.client = client
        try await client.start()
        _ = try await client.initializeAndAck()
        let threadID = try await client.threadStart(cwd: request.session.projectPath)
        return ProviderRuntimeStartResult(nativeSessionID: threadID)
    }

    public func loadSession(_ request: ProviderRuntimeLoadRequest) async throws {
        throw NSError(domain: "Soul-Desktop", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "codex runtime does not support session/load"])
    }

    public func startNewSession(_ request: ProviderRuntimeNewSessionRequest) async throws -> ProviderRuntimeNewSessionResult {
        guard let client else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        let threadID = try await client.threadStart(cwd: request.session.projectPath)
        return ProviderRuntimeNewSessionResult(nativeSessionID: threadID)
    }

    public func prompt(_ request: ProviderRuntimePromptRequest<ContentBlock>) async throws {
        guard let client,
              let threadID = request.session.rpcSessionID,
              request.canDispatch else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        let turnID = try await client.turnStart(threadId: threadID, text: request.text)
        currentTurnID = turnID
    }

    public func cancel(_ request: ProviderRuntimeCancelRequest) async {
        guard let client,
              let threadID = request.session.rpcSessionID,
              let turnID = request.activeTurnID ?? currentTurnID else { return }
        try? await client.turnInterrupt(threadId: threadID, turnId: turnID)
    }

    public func stop() async {
        await client?.stop()
        client = nil
        currentTurnID = nil
    }

    public func clearActiveTurn() {
        currentTurnID = nil
    }

    public func compact(threadID: String) async throws {
        guard let client else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized for compact"])
        }
        try await client.compact(threadId: threadID)
    }

    public func respond(id: JSONRPCID, result: JSONValue) async {
        try? await client?.respond(id: id, result: result)
    }
}
