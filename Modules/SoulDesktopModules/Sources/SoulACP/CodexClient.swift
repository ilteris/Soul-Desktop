import Foundation
import SoulCore

/// Minimal Codex app-server client (Phase 1 stub).
///
/// Speaks JSON-RPC 2.0 over stdio against `codex app-server`. Reuses the
/// existing `ACPTransport` for framing because Codex uses the same wire
/// shape (newline-delimited JSON envelopes) as ACP. Method names and event
/// vocabulary are different — that's what this client handles.
///
/// Surface area kept intentionally small for Phase 1:
///   - `initialize` → `initialized` notification
///   - `thread/start` (returns thread id)
///   - `turn/start` (sends user text)
///   - `turn/interrupt`
///   - Events stream: stderr, terminated, and selected codex notifications
///     (`thread/started`, `turn/started`, `item/*`, `turn/completed`).
///
/// Full ThreadController integration (read-first hydrate, approvals,
/// session resume via `thread/resume`, AGENTS.md harness) is out of scope
/// for this phase — see the design doc.
public enum CodexClientError: Error {
    case spawnFailed(String)
    case decodeFailed(String)
    case rpcError(JSONRPCError)
    case childTerminated(cause: String)
    case writeFailed(String)
    case notInitialized
}

public actor CodexClient {
    /// What the consumer sees. Notifications are kept as `raw` JSONValue
    /// payloads in this phase — we'll split into typed shapes once we know
    /// which events we're actually rendering in the canvas.
    public enum Event: Sendable {
        case notification(method: String, params: JSONValue?)
        case request(id: JSONRPCID, method: String, params: JSONValue?)
        case stderr(String)
        case terminated(cause: String)
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
    private var didTerminate = false
    private var initialized = false

    public let events: AsyncStream<Event>
    private var eventCont: AsyncStream<Event>.Continuation?

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
        drainPending(cause: "client stopped")
        eventCont?.finish()
    }

    // MARK: - High-level methods

    /// One-shot handshake: send `initialize`, then fire the `initialized`
    /// notification. Codex rejects any other RPC on the connection until
    /// this pair lands.
    @discardableResult
    public func initializeAndAck(clientName: String = "soul_desktop",
                                 clientVersion: String = "0.1.0") async throws -> JSONValue {
        let params: [String: Any] = [
            "clientInfo": [
                "name": clientName,
                "title": "Soul-Desktop",
                "version": clientVersion
            ]
        ]
        let result = try await call(method: "initialize", params: toJSONValue(params))
        try await notify(method: "initialized", params: JSONValue.object([:]))
        initialized = true
        return result
    }

    /// Start a new thread (codex 0.45+ protocol). Returns `thread.id`.
    @discardableResult
    public func threadStart(cwd: String? = nil, model: String? = nil) async throws -> String {
        guard initialized else { throw CodexClientError.notInitialized }
        var p: [String: Any] = [:]
        if let cwd { p["cwd"] = cwd }
        if let model { p["model"] = model }
        let result = try await call(method: "thread/start", params: toJSONValue(p))
        guard case .object(let r) = result,
              case .object(let thread)? = r["thread"],
              case .string(let id)? = thread["id"] else {
            throw CodexClientError.decodeFailed("thread/start: missing thread.id")
        }
        return id
    }

    /// Start a turn on `threadId` with a single user text input. Returns the
    /// turn id; streamed events arrive on `events`.
    @discardableResult
    public func turnStart(threadId: String, text: String) async throws -> String {
        guard initialized else { throw CodexClientError.notInitialized }
        let params: [String: Any] = [
            "threadId": threadId,
            "input": [
                ["type": "text", "text": text]
            ]
        ]
        let result = try await call(method: "turn/start", params: toJSONValue(params))
        guard case .object(let r) = result,
              case .object(let turn)? = r["turn"],
              case .string(let id)? = turn["id"] else {
            throw CodexClientError.decodeFailed("turn/start: missing turn.id")
        }
        return id
    }

    public func turnInterrupt(threadId: String, turnId: String) async throws {
        let params: [String: Any] = [
            "threadId": threadId,
            "turnId": turnId
        ]
        _ = try await call(method: "turn/interrupt", params: toJSONValue(params))
    }

    public func respond(id: JSONRPCID, result: JSONValue) async throws {
        let data = try Self.makeCodexResponseEnvelope(id: id, result: result, encoder: encoder)
        try await transport.send(data)
    }

    // MARK: - Low-level

    private func call(method: String, params: JSONValue) async throws -> JSONValue {
        if didTerminate {
            throw CodexClientError.childTerminated(cause: "transport already terminated")
        }
        let id = JSONRPCID.int(nextId); nextId += 1
        let envelope = try makeEnvelope(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { await self.sendOrFail(id: id, envelope: envelope) }
        }
    }

    /// Wire-protocol dump (every JSON-RPC envelope in/out) is debug-only and
    /// fires per message — per token while streaming. Off by default; the
    /// `[codex stderr] ← wire: …` console spam is gated behind the same flag
    /// as the codex protocol log. Read ONCE (a per-message UserDefaults read
    /// would itself be hot). Enable with:
    ///   defaults write Soul-Desktop soul.codex.trace -bool true
    /// then relaunch. Real stderr + parse-errors are never gated.
    private static let wireTraceEnabled = UserDefaults.standard.bool(forKey: "soul.codex.trace")

    private func sendOrFail(id: JSONRPCID, envelope: Data) async {
        if Self.wireTraceEnabled {
            eventCont?.yield(.stderr("→ wire: \(String(data: envelope, encoding: .utf8) ?? "?")"))
        }
        do {
            try await transport.send(envelope)
        } catch {
            pending.removeValue(forKey: id)?
                .resume(throwing: CodexClientError.writeFailed("\(error)"))
        }
    }

    private func notify(method: String, params: JSONValue) async throws {
        let envelope = try makeEnvelope(id: nil, method: method, params: params)
        if Self.wireTraceEnabled {
            eventCont?.yield(.stderr("→ wire (notify): \(String(data: envelope, encoding: .utf8) ?? "?")"))
        }
        try await transport.send(envelope)
    }

    private func makeEnvelope(id: JSONRPCID?, method: String, params: JSONValue) throws -> Data {
        try Self.makeCodexEnvelope(id: id, method: method, params: params, encoder: encoder)
    }

    public static func makeCodexEnvelope(
        id: JSONRPCID?,
        method: String,
        params: JSONValue,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        var env = JSONRPCEnvelope()
        // Codex app-server's docs are explicit: `"jsonrpc":"2.0"` is omitted
        // on the wire in both directions. Sending it back produces an
        // `Invalid request` (-32600). Clear the default so the encoder
        // skips it.
        env.jsonrpc = nil
        env.id = id
        env.method = method
        env.params = params
        return try encoder.encode(env)
    }

    public static func makeCodexResponseEnvelope(
        id: JSONRPCID,
        result: JSONValue,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        var env = JSONRPCEnvelope()
        env.jsonrpc = nil
        env.id = id
        env.result = result
        return try encoder.encode(env)
    }

    private func toJSONValue(_ value: Any) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder.decode(JSONValue.self, from: data)
    }

    // MARK: - Read loop

    private func readLoop() async {
        for await line in transport.incomingLines {
            if Self.wireTraceEnabled {
                eventCont?.yield(.stderr("\(wireTimestamp()) ← wire: \(line)"))
            }
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let env = try decoder.decode(JSONRPCEnvelope.self, from: data)
                handleEnvelope(env)
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

    private func terminationLoop() async {
        for await cause in transport.terminationEvents {
            handleTransportTermination(cause)
            break
        }
    }

    private func handleTransportTermination(_ cause: ACPTransportTermination) {
        guard !didTerminate else { return }
        didTerminate = true
        let description: String
        switch cause {
        case .eof:                description = "child closed stdout (EOF)"
        case .processExit(let s): description = "child exited (status=\(s))"
        case .explicit:           description = "explicit teardown"
        }
        drainPending(cause: description)
        eventCont?.yield(.terminated(cause: description))
    }

    private func drainPending(cause: String) {
        let snapshot = pending
        pending.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: CodexClientError.childTerminated(cause: cause))
        }
    }

    private func handleEnvelope(_ env: JSONRPCEnvelope) {
        // Response (has id, no method): resolve continuation.
        if let id = env.id, env.method == nil {
            if let err = env.error {
                pending.removeValue(forKey: id)?
                    .resume(throwing: CodexClientError.rpcError(err))
            } else {
                pending.removeValue(forKey: id)?
                    .resume(returning: env.result ?? .null)
            }
            return
        }
        if let event = Self.classifyEnvelope(env) {
            eventCont?.yield(event)
        }
    }

    public static func classifyEnvelope(_ env: JSONRPCEnvelope) -> Event? {
        guard let method = env.method else { return nil }
        if let id = env.id {
            return .request(id: id, method: method, params: env.params)
        }
        return .notification(method: method, params: env.params)
    }
}
