import Foundation
import SoulCore
#if SWIFT_PACKAGE
public typealias ACPPermissionMode = AgentPermissionMode
#else
public typealias ACPPermissionMode = PermissionMode
#endif

public enum ACPClientError: Error {
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

public actor ACPClient {
    public enum Event: Sendable {
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

    public let events: AsyncStream<Event>
    private var eventCont: AsyncStream<Event>.Continuation?
    var autoAllowPermissions: Bool = false
    /// Per-thread permission policy. Overrides `autoAllowPermissions` when set.
    /// Package builds use SoulCore's UI-free `AgentPermissionMode`; the app
    /// target keeps using its local `PermissionMode` until the Xcode target is
    /// wired to import package products.
    var permissionMode: ACPPermissionMode = .fullAccess

    public init(spawn: ACPProviderSpawn) throws {
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

    public func start() async throws {
        try await transport.start()
        Task { await self.readLoop() }
        Task { await self.stderrLoop() }
        Task { await self.terminationLoop() }
    }

    public func stop() async {
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

    public func setAutoAllow(_ on: Bool) { autoAllowPermissions = on }
    public func setPermissionMode(_ mode: ACPPermissionMode) { permissionMode = mode }

    // MARK: high-level methods

    @discardableResult
    public func initialize(clientName: String = "Soul-Desktop", clientVersion: String = "0.1") async throws -> InitializeResponse {
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

    public func newSession(
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
        let mcpServersJSON: JSONValue? = {
            guard !mcpServers.isEmpty,
                  let data = try? encoder.encode(mcpServers),
                  let val = try? decoder.decode(JSONValue.self, from: data) else { return nil }
            return val
        }()
        let p = Self.newSessionParams(
            cwd: cwd,
            mcpServersJSON: mcpServersJSON,
            systemPrompt: systemPrompt!
        )
        let result = try await call(method: "session/new", params: p)
        let resp = try decode(NewSessionResponse.self, from: result)
        return resp.sessionId
    }

    /// Build the `session/new` params for the `_meta.systemPrompt` path.
    ///
    /// `mcpServers` is a required field of `session/new` — `NewSessionRequest`
    /// serializes it unconditionally, and claude-agent-acp rejects a request
    /// that omits it with `-32602 Invalid params`. This branch must therefore
    /// always emit the key, defaulting to an empty array when no servers are
    /// configured. SOUL-SOUL_DESKTOP-356: previously dropping it when empty
    /// wedged every Claude stall/stop-recovery, since that is the only path
    /// that carries an `_meta.systemPrompt` and most sessions run zero MCP
    /// servers. Pure so the param shape is unit-testable without a transport.
    static func newSessionParams(
        cwd: String,
        mcpServersJSON: JSONValue?,
        systemPrompt: String
    ) -> [String: JSONValue] {
        [
            "cwd": .string(cwd),
            "mcpServers": mcpServersJSON ?? .array([]),
            "_meta": .object(["systemPrompt": .string(systemPrompt)]),
        ]
    }

    public func newSession(id sid: String, cwd: String, mcpServers: [McpServer] = []) async throws -> String {
        // session/new doesn't normally accept a sessionId, but the protocol
        // doesn't forbid it in params. If the server supports it, this
        // enforces kernel identity from frame zero.
        var p: [String: JSONValue] = ["cwd": .string(cwd)]
        p["sessionId"] = .string(sid)
        // SOUL-SOUL_DESKTOP-356: `mcpServers` is required by `session/new`;
        // always emit it (empty array when none) or claude-agent-acp returns
        // `-32602 Invalid params`. Same omission class as the `_meta` branch
        // above. Currently uncalled, but kept consistent so a future caller
        // can't reintroduce the wedge.
        if !mcpServers.isEmpty,
           let data = try? encoder.encode(mcpServers),
           let val = try? decoder.decode(JSONValue.self, from: data) {
            p["mcpServers"] = val
        } else {
            p["mcpServers"] = .array([])
        }
        let result = try await call(method: "session/new", params: p)
        let resp = try decode(NewSessionResponse.self, from: result)
        return resp.sessionId
    }

    public func loadSession(sessionId: String, cwd: String, mcpServers: [McpServer] = []) async throws {
        let req = LoadSessionRequest(cwd: cwd, mcpServers: mcpServers, sessionId: sessionId)
        _ = try await call(method: "session/load", params: req)
    }

    public func prompt(sessionId: String, text: String, extraBlocks: [ContentBlock] = []) async throws -> String {
        let req = PromptRequest(sessionId: sessionId, prompt: [.text(text)] + extraBlocks)
        recordACPProtocolFrame(
            direction: "call",
            method: "session/prompt",
            params: promptDiagnosticParams(sessionId: sessionId, text: text, extraBlocks: extraBlocks)
        )
        let result = try await call(method: "session/prompt", params: req)
        let resp = try decode(PromptResponse.self, from: result)
        recordACPProtocolFrame(
            direction: "result",
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionId),
                "stopReason": .string(resp.stopReason)
            ])
        )
        return resp.stopReason
    }

    public func cancel(sessionId: String) async throws {
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

    public func respond(id: JSONRPCID, result: Encodable) throws {
        var env = JSONRPCEnvelope()
        env.id = id
        env.result = try toJSONValue(result)
        let data = try encoder.encode(env)
        // Best-effort: if the child is gone, the upcoming terminated event
        // tears everything down — losing this response notification is fine.
        Task { try? await transport.send(data) }
    }

    public func respondError(id: JSONRPCID, code: Int, message: String) {
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

    /// Per-message wire dump (every incoming JSON-RPC line) is debug-only.
    /// Gated behind the documented ACP trace flag, read ONCE. Enable with:
    ///   defaults write Soul-Desktop soul.acp.trace -bool true
    /// then relaunch. Parse-errors are never gated.
    private static let wireTraceEnabled = UserDefaults.standard.bool(forKey: "soul.acp.trace")

    private func readLoop() async {
        for await line in transport.incomingLines {
            if Self.wireTraceEnabled {
                eventCont?.yield(.stderr("\(wireTimestamp()) ← wire: \(line)"))
            }
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
        recordACPProtocolFrame(direction: "notification", method: method, params: params)
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
        recordACPProtocolFrame(direction: "request", method: method, params: params)
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
            if ACPPermissionMode.isReadOnlyTool(toolName) {
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

private func recordACPProtocolFrame(direction: String, method: String, params: JSONValue?) {
#if SWIFT_PACKAGE
    // Protocol-log persistence is currently an app diagnostic concern. Keep
    // SoulACP package builds free of user-Library filesystem side effects.
    _ = (direction, method, params)
#else
    ACPProtocolLog.record(direction: direction, method: method, params: params)
#endif
}

private func promptDiagnosticParams(sessionId: String, text: String, extraBlocks: [ContentBlock]) -> JSONValue {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return .object([
        "sessionId": .string(sessionId),
        "textChars": .int(text.count),
        "textPreview": .string(boundedPreview(trimmed, limit: 240)),
        "startsWithSlash": .bool(trimmed.hasPrefix("/")),
        "startsWithDollar": .bool(trimmed.hasPrefix("$")),
        "hasSessionContext": .bool(text.contains("<session_context>")),
        "hasComputerUseContext": .bool(text.contains("<computer_use>")),
        "extraBlocks": .int(extraBlocks.count)
    ])
}

private func boundedPreview(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "..."
}
