import Foundation

enum ACPClientError: Error {
    case notInitialized
    case spawnFailed(String)
    case decodeFailed(String)
    case rpcError(JSONRPCError)
    /// The child agent process is gone (EOF, exit, or crash). Any in-flight
    /// JSON-RPC call resumes with this so callers unblock instead of hanging.
    case childTerminated(cause: String)
    /// Write to the child's stdin failed (broken pipe). Same idea: surface
    /// to the caller instead of swallowing.
    case writeFailed(String)
}

actor ACPClient {
    enum Event {
        case request(id: JSONRPCID, method: String, params: JSONValue?)
        case sessionUpdate(SessionNotification)
        case stderr(String)
        case unknownNotification(method: String, params: JSONValue?)
        /// Child agent has gone away. Emitted exactly once per client; the
        /// client is no longer usable after this.
        case terminated(cause: String)
    }

    private var didTerminate = false

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
    /// Per-thread permission policy. Overrides `autoAllowPermissions` when set.
    /// See `PermissionMode` for what each mode does.
    var permissionMode: PermissionMode = .fullAccess

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
        Task { await self.terminationLoop() }
    }

    func stop() async {
        await transport.terminate()
        // The transport will yield .explicit through terminationEvents and
        // terminationLoop will drain pending continuations; we don't need to
        // duplicate that here. Belt-and-braces drain follows in case the loop
        // hasn't run yet (e.g. stop() before the first await).
        drainPending(cause: "client stopped")
        eventCont?.finish()
    }

    private func terminationLoop() async {
        for await cause in transport.terminationEvents {
            handleTransportTermination(cause)
            break  // stream yields exactly once
        }
    }

    private func handleTransportTermination(_ cause: ACPTransportTermination) {
        guard !didTerminate else { return }
        didTerminate = true
        let description: String
        switch cause {
        case .eof:                 description = "child closed stdout (EOF)"
        case .processExit(let s):  description = "child exited (status=\(s))"
        case .explicit:            description = "explicit teardown"
        }
        drainPending(cause: description)
        eventCont?.yield(.terminated(cause: description))
    }

    /// Resume every outstanding JSON-RPC continuation with childTerminated so
    /// callers (loadSession, prompt, initialize, …) unblock instead of waiting
    /// on a response that will never arrive.
    private func drainPending(cause: String) {
        let snapshot = pending
        pending.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: ACPClientError.childTerminated(cause: cause))
        }
    }

    func setAutoAllow(_ on: Bool) { autoAllowPermissions = on }
    func setPermissionMode(_ mode: PermissionMode) { permissionMode = mode }

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

    func newSession(
        cwd: String,
        mcpServers: [McpServer] = [],
        systemPrompt: String? = nil
    ) async throws -> String {
        // SPEC-245-K step 4: optional systemPrompt rides via _meta to
        // providers that read it. Claude (claude-agent-acp) consumes
        // params._meta.systemPrompt as the session's system message;
        // other providers ignore unknown _meta keys. When nil we send
        // the legacy two-param shape unchanged.
        if systemPrompt == nil {
            let req = NewSessionRequest(cwd: cwd, mcpServers: mcpServers)
            let result = try await call(method: "session/new", params: req)
            let resp = try decode(NewSessionResponse.self, from: result)
            return resp.sessionId
        }
        var p: [String: JSONValue] = ["cwd": .string(cwd)]
        if !mcpServers.isEmpty,
           let data = try? encoder.encode(mcpServers),
           let val = try? decoder.decode(JSONValue.self, from: data) {
            p["mcpServers"] = val
        }
        p["_meta"] = .object(["systemPrompt": .string(systemPrompt!)])
        let result = try await call(method: "session/new", params: p)
        let resp = try decode(NewSessionResponse.self, from: result)
        return resp.sessionId
    }

    func newSession(id sid: String, cwd: String, mcpServers: [McpServer] = []) async throws -> String {
        // session/new doesn't normally accept a sessionId, but the protocol
        // doesn't forbid it in params. If the server supports it, this
        // enforces kernel identity from frame zero.
        var p: [String: JSONValue] = ["cwd": .string(cwd)]
        p["sessionId"] = .string(sid)
        if !mcpServers.isEmpty {
            if let data = try? encoder.encode(mcpServers),
               let val = try? decoder.decode(JSONValue.self, from: data) {
                p["mcpServers"] = val
            }
        }
        let result = try await call(method: "session/new", params: p)
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
        // Fail fast if the transport is already dead — otherwise we'd register
        // a continuation that drainPending already missed.
        if didTerminate {
            throw ACPClientError.childTerminated(cause: "transport already terminated")
        }
        let id = JSONRPCID.int(nextId); nextId += 1
        let envelope = try makeEnvelope(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { await self.sendOrFail(id: id, envelope: envelope) }
        }
    }

    /// Send the envelope; on write failure, pop the just-registered
    /// continuation and resume it with writeFailed so the caller doesn't hang.
    private func sendOrFail(id: JSONRPCID, envelope: Data) async {
        do {
            try await transport.send(envelope)
        } catch {
            pending.removeValue(forKey: id)?
                .resume(throwing: ACPClientError.writeFailed("\(error)"))
        }
    }

    private func notify<P: Encodable>(method: String, params: P) async throws {
        let envelope = try makeEnvelope(id: nil, method: method, params: params)
        // Notification has no id and no continuation to resume; if the write
        // fails the caller learns via the throw and the upcoming terminated
        // event will tear everything down anyway.
        try await transport.send(envelope)
    }

    func respond(id: JSONRPCID, result: Encodable) throws {
        var env = JSONRPCEnvelope()
        env.id = id
        env.result = try toJSONValue(result)
        let data = try encoder.encode(env)
        // Best-effort: if the child is gone, the upcoming terminated event
        // tears everything down — losing this response notification is fine.
        Task { try? await transport.send(data) }
    }

    func respondError(id: JSONRPCID, code: Int, message: String) {
        var env = JSONRPCEnvelope()
        env.id = id
        env.error = JSONRPCError(code: code, message: message)
        if let data = try? encoder.encode(env) {
            Task { try? await transport.send(data) }
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
            eventCont?.yield(.stderr("\(wireTimestamp()) ← wire: \(line)"))
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
        ACPProtocolLog.record(direction: "notification", method: method, params: params)
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
        ACPProtocolLog.record(direction: "request", method: method, params: params)
        switch method {
        case "fs/read_text_file":
            handleFsRead(id: id, params: params)
        case "fs/write_text_file":
            handleFsWrite(id: id, params: params)
        case "session/request_permission":
            handlePermissionRequest(id: id, params: params)
        default:
            eventCont?.yield(.request(id: id, method: method, params: params))
        }
    }

    private func handlePermissionRequest(id: JSONRPCID, params: JSONValue?) {
        guard case .array(let opts)? = params?["options"], !opts.isEmpty else {
            respondError(id: id, code: -32602, message: "missing options"); return
        }

        // Pull the tool name hint from the request so .autoReview can decide
        // whether this is read-only vs state-mutating.
        let toolName: String = {
            if case .string(let n)? = params?["toolCall"]?["kind"] { return n }
            if case .string(let n)? = params?["toolCall"]?["title"] { return n }
            return ""
        }()

        func cancel() {
            try? respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
        }

        func allowFirstMatching() {
            var pick: JSONValue? = nil
            for opt in opts {
                if case .string(let kind)? = opt["kind"], kind.hasPrefix("allow") {
                    pick = opt; break
                }
            }
            let chosen = pick ?? opts.first!
            guard case .string(let optionId)? = chosen["optionId"] ?? chosen["id"] else {
                respondError(id: id, code: -32603, message: "no optionId on permission option"); return
            }
            try? respond(id: id, result: [
                "outcome": ["outcome": "selected", "optionId": optionId]
            ])
        }

        switch permissionMode {
        case .fullAccess:
            allowFirstMatching()
        case .autoReview:
            if PermissionMode.isReadOnlyTool(toolName) {
                allowFirstMatching()
            } else {
                // State-mutating tool: deny until an interactive sheet exists.
                // Agent will surface the rejection as an error in its own log.
                cancel()
            }
        case .defaultAsk:
            // No sheet yet — fall back to cancelled. Lands proper UI in a follow-up.
            cancel()
        }
    }

    private func handleFsRead(id: JSONRPCID, params: JSONValue?) {
        guard case .string(let path)? = params?["path"] else {
            respondError(id: id, code: -32602, message: "missing path"); return
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            try respond(id: id, result: ["content": content])
        } catch {
            respondError(id: id, code: -32000, message: "read failed: \(error.localizedDescription)")
        }
    }

    private func handleFsWrite(id: JSONRPCID, params: JSONValue?) {
        guard case .string(let path)? = params?["path"],
              case .string(let content)? = params?["content"] else {
            respondError(id: id, code: -32602, message: "missing path/content"); return
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            try respond(id: id, result: [String: String]())
        } catch {
            respondError(id: id, code: -32000, message: "write failed: \(error.localizedDescription)")
        }
    }
}
