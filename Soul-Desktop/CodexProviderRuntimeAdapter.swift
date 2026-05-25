import Foundation
import SoulACP
import SoulCore

actor CodexProviderRuntimeAdapter: ProviderRuntime {
    typealias PromptAttachment = ContentBlock

    private let projectKey: String
    private var client: CodexClient?
    private var currentTurnID: String?

    init(projectKey: String) {
        self.projectKey = projectKey
    }

    var isStarted: Bool {
        client != nil
    }

    var activeTurnID: String? {
        currentTurnID
    }

    func eventStream() async -> AsyncStream<CodexClient.Event>? {
        await client?.events
    }

    func start(_ request: ProviderRuntimeStartRequest) async throws -> ProviderRuntimeStartResult {
        if let client {
            let threadID = try await client.threadStart(cwd: request.session.projectPath)
            return ProviderRuntimeStartResult(nativeSessionID: threadID)
        }
        guard var spawn = ACPProviderSpawn.resolve(.codex) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex binary not found on PATH"])
        }

        var env = spawn.environment ?? [:]
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

    func loadSession(_ request: ProviderRuntimeLoadRequest) async throws {
        throw NSError(domain: "Soul-Desktop", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "codex runtime does not support session/load"])
    }

    func startNewSession(_ request: ProviderRuntimeNewSessionRequest) async throws -> ProviderRuntimeNewSessionResult {
        guard let client else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        let threadID = try await client.threadStart(cwd: request.session.projectPath)
        return ProviderRuntimeNewSessionResult(nativeSessionID: threadID)
    }

    func prompt(_ request: ProviderRuntimePromptRequest<ContentBlock>) async throws {
        guard let client,
              let threadID = request.session.rpcSessionID,
              request.canDispatch else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        let turnID = try await client.turnStart(threadId: threadID, text: request.text)
        currentTurnID = turnID
    }

    func cancel(_ request: ProviderRuntimeCancelRequest) async {
        guard let client,
              let threadID = request.session.rpcSessionID,
              let turnID = request.activeTurnID ?? currentTurnID else { return }
        try? await client.turnInterrupt(threadId: threadID, turnId: turnID)
    }

    func stop() async {
        await client?.stop()
        client = nil
        currentTurnID = nil
    }

    func clearActiveTurn() {
        currentTurnID = nil
    }

    func respond(id: JSONRPCID, result: JSONValue) async {
        try? await client?.respond(id: id, result: result)
    }
}
