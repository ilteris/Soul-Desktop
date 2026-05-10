import Foundation

enum ACPClientError: Error {
    case notInitialized
    case spawnFailed(String)
    case decodeFailed(String)
    case rpcError(JSONRPCError)
}

actor ACPClient {
    enum Event {
        case sessionUpdate(SessionNotification)
        case stderr(String)
        case unknownNotification(method: String, params: JSONValue?)
    }

    private let transport: ACPTransport
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let decoder = JSONDecoder()

    private var nextId = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]

    let events: AsyncStream<Event>
    private var eventCont: AsyncStream<Event>.Continuation?
    var autoAllowPermissions: Bool = false

    init(spawn: ACPProviderSpawn) throws {
        let url = URL(fileURLWithPath: spawn.executablePath)
        self.transport = ACPTransport(
            executableURL: url,
            arguments: spawn.arguments,
            environment: spawn.environment,
            scrubEnvKeys: spawn.scrubEnvKeys,
            cwd: spawn.cwd
        )
        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventCont = cont
    }

    func start() async throws {
        try await transport.start()
        Task { await self.readLoop() }
        Task { await self.stderrLoop() }
    }

    func stop() async {
        await transport.terminate()
        eventCont?.finish()
    }

    func setAutoAllow(_ on: Bool) { autoAllowPermissions = on }

    // MARK: high-level methods

    @discardableResult
    func initialize(clientName: String = "Soul-Desktop", clientVersion: String = "0.1") async throws -> InitializeResponse {
        let req = InitializeRequest(
            protocolVersion: ACPProtocolVersion.current,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapability(readTextFile: true, writeTextFile: true),
                terminal: false
            ),
            clientInfo: Implementation(name: clientName, version: clientVersion)
        )
        let result = try await call(method: "initialize", params: req)
        return try decode(InitializeResponse.self, from: result)
    }

    func newSession(cwd: String, mcpServers: [McpServer] = []) async throws -> String {
        let req = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
        let result = try await call(method: "session/new", params: req)
        let resp = try decode(NewSessionResponse.self, from: result)
        return resp.sessionId
    }

    func loadSession(sessionId: String, cwd: String, mcpServers: [McpServer] = []) async throws {
        let req = LoadSessionRequest(cwd: cwd, mcpServers: mcpServers, sessionId: sessionId)
        _ = try await call(method: "session/load", params: req)
    }

    func prompt(sessionId: String, text: String) async throws -> String {
        let req = PromptRequest(sessionId: sessionId, prompt: [.text(text)])
        let result = try await call(method: "session/prompt", params: req)
        let resp = try decode(PromptResponse.self, from: result)
        return resp.stopReason
    }

    func cancel(sessionId: String) async throws {
        let note = CancelNotification(sessionId: sessionId)
        try await notify(method: "session/cancel", params: note)
    }

    // MARK: low-level

    private func call<P: Encodable>(method: String, params: P) async throws -> JSONValue {
        let id = JSONRPCID.int(nextId); nextId += 1
        let envelope = try makeEnvelope(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { await transport.send(envelope) }
        }
    }

    private func notify<P: Encodable>(method: String, params: P) async throws {
        let envelope = try makeEnvelope(id: nil, method: method, params: params)
        await transport.send(envelope)
    }

    private func sendResponse(id: JSONRPCID, result: Encodable) throws {
        var env = JSONRPCEnvelope()
        env.id = id
        env.result = try toJSONValue(result)
        let data = try encoder.encode(env)
        Task { await transport.send(data) }
    }

    private func sendError(id: JSONRPCID, code: Int, message: String) {
        var env = JSONRPCEnvelope()
        env.id = id
        env.error = JSONRPCError(code: code, message: message)
        if let data = try? encoder.encode(env) {
            Task { await transport.send(data) }
        }
    }

    private func makeEnvelope<P: Encodable>(id: JSONRPCID?, method: String, params: P) throws -> Data {
        var env = JSONRPCEnvelope()
        env.id = id
        env.method = method
        env.params = try toJSONValue(params)
        return try encoder.encode(env)
    }

    private func toJSONValue<E: Encodable>(_ value: E) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try decoder.decode(JSONValue.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: read loop

    private func readLoop() async {
        for await line in transport.incomingLines {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let env = try decoder.decode(JSONRPCEnvelope.self, from: data)
                handleEnvelope(env, raw: data)
            } catch {
                eventCont?.yield(.stderr("[parse-error] \(error) line=\(line.prefix(200))"))
            }
        }
    }

    private func stderrLoop() async {
        for await line in transport.stderrLines {
            eventCont?.yield(.stderr(line))
        }
    }

    private func handleEnvelope(_ env: JSONRPCEnvelope, raw: Data) {
        if let id = env.id, env.method == nil {
            if let err = env.error {
                pending.removeValue(forKey: id)?.resume(throwing: ACPClientError.rpcError(err))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: env.result ?? .null)
            }
            return
        }
        guard let method = env.method else { return }

        if let id = env.id {
            handleClientRequest(id: id, method: method, params: env.params)
            return
        }

        handleNotification(method: method, params: env.params)
    }

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "session/update":
            if let params,
               let data = try? encoder.encode(params),
               let note = try? decoder.decode(SessionNotification.self, from: data) {
                eventCont?.yield(.sessionUpdate(note))
            } else {
                eventCont?.yield(.unknownNotification(method: method, params: params))
            }
        default:
            eventCont?.yield(.unknownNotification(method: method, params: params))
        }
    }

    private func handleClientRequest(id: JSONRPCID, method: String, params: JSONValue?) {
        switch method {
        case "fs/read_text_file":
            handleFsRead(id: id, params: params)
        case "fs/write_text_file":
            handleFsWrite(id: id, params: params)
        case "session/request_permission":
            handlePermissionRequest(id: id, params: params)
        default:
            sendError(id: id, code: -32601, message: "method not implemented: \(method)")
        }
    }

    private func handlePermissionRequest(id: JSONRPCID, params: JSONValue?) {
        guard case .array(let opts)? = params?["options"], !opts.isEmpty else {
            sendError(id: id, code: -32602, message: "missing options"); return
        }
        if !autoAllowPermissions {
            try? sendResponse(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        var pick: JSONValue? = nil
        for opt in opts {
            if case .string(let kind)? = opt["kind"], kind.hasPrefix("allow") {
                pick = opt; break
            }
        }
        let chosen = pick ?? opts.first!
        guard case .string(let optionId)? = chosen["optionId"] ?? chosen["id"] else {
            sendError(id: id, code: -32603, message: "no optionId on permission option"); return
        }
        try? sendResponse(id: id, result: [
            "outcome": ["outcome": "selected", "optionId": optionId]
        ])
    }

    private func handleFsRead(id: JSONRPCID, params: JSONValue?) {
        guard case .string(let path)? = params?["path"] else {
            sendError(id: id, code: -32602, message: "missing path"); return
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            try sendResponse(id: id, result: ["content": content])
        } catch {
            sendError(id: id, code: -32000, message: "read failed: \(error.localizedDescription)")
        }
    }

    private func handleFsWrite(id: JSONRPCID, params: JSONValue?) {
        guard case .string(let path)? = params?["path"],
              case .string(let content)? = params?["content"] else {
            sendError(id: id, code: -32602, message: "missing path/content"); return
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            try sendResponse(id: id, result: [String: String]())
        } catch {
            sendError(id: id, code: -32000, message: "write failed: \(error.localizedDescription)")
        }
    }
}
