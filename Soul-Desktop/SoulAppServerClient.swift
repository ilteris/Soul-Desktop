import Foundation
import Darwin
import CryptoKit
import SoulACP

enum SoulAppServerClientError: LocalizedError {
    case socketPathTooLong(String)
    case connectFailed(String)
    case notConnected
    case rpcError(JSONRPCError)
    case requestTimedOut(method: String)
    case connectionClosed
    case decodeFailed
    case invalidEndpoint(String)
    case missingAPIKey
    case authFailed(String)
    case authorityRequiredUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Soul app-server socket path is too long: \(path)"
        case .connectFailed(let detail):
            return "Could not connect to Soul app-server: \(detail)"
        case .notConnected:
            return "Soul app-server is not connected."
        case .rpcError(let error):
            return error.message
        case .requestTimedOut(let method):
            return "Soul app-server request timed out: \(method)"
        case .connectionClosed:
            return "Soul app-server connection closed."
        case .decodeFailed:
            return "Could not decode Soul app-server response."
        case .invalidEndpoint(let detail):
            return detail
        case .missingAPIKey:
            return "Soul registry authority requires SOUL_API_KEY or SOUL_AUTHORITY_API_KEY."
        case .authFailed(let detail):
            return "Soul registry authority authentication failed: \(detail)"
        case .authorityRequiredUnavailable(let detail):
            return "Required Soul registry authority unavailable: \(detail)"
        }
    }

    var disablesLocalFallback: Bool {
        if case .authorityRequiredUnavailable = self { return true }
        return false
    }
}

enum SoulAppServerEndpoint: Equatable, Sendable {
    case unixSocket(String)
    case tcp(host: String, port: UInt16)
    case invalid(String)

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SoulAppServerEndpoint {
        let authorityMode = (env["SOUL_REGISTRY_AUTHORITY"] ?? "").lowercased()
        let authorityRequired = authorityMode == "required"
        if let rawURL = env["SOUL_REGISTRY_AUTHORITY_URL"], !rawURL.isEmpty {
            guard let components = URLComponents(string: rawURL),
                  components.scheme == "tcp",
                  let host = components.host,
                  !host.isEmpty,
                  let port = components.port,
                  (1...65535).contains(port)
            else {
                return .invalid("Unsupported SOUL_REGISTRY_AUTHORITY_URL: \(rawURL)")
            }
            return .tcp(host: host, port: UInt16(port))
        }
        if authorityRequired {
            return .invalid("SOUL_REGISTRY_AUTHORITY=required needs SOUL_REGISTRY_AUTHORITY_URL.")
        }
        return .unixSocket(defaultSocketPath(env: env))
    }

    static func defaultSocketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let root = env["SOUL_REGISTRY"] ?? "\(NSHomeDirectory())/soul_registry"
        return URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .appendingPathComponent("run")
            .appendingPathComponent("app-server.sock")
            .path
    }
}

struct SoulAppServerNotification: Sendable {
    var method: String
    var params: JSONValue?
}

struct SoulOrchestrationUpdatedParams: Decodable, Sendable {
    var projectKey: String
    var version: String?
    var fileCount: Int?
    var updatedAt: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case projectKey = "project_key"
        case version
        case fileCount = "file_count"
        case updatedAt = "updated_at"
        case scope
    }
}

actor SoulAppServerClient {
    static func defaultSocketPath() -> String {
        SoulAppServerEndpoint.defaultSocketPath()
    }

    private let endpoint: SoulAppServerEndpoint
    private let apiKey: String?
    private let fallbackAllowed: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var handle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingTimeouts: [JSONRPCID: Task<Void, Never>] = [:]
    private let notificationStream: AsyncStream<SoulAppServerNotification>
    private let notificationContinuation: AsyncStream<SoulAppServerNotification>.Continuation

    nonisolated var notifications: AsyncStream<SoulAppServerNotification> {
        notificationStream
    }

    nonisolated var allowsLocalFallback: Bool {
        fallbackAllowed
    }

    init(
        endpoint: SoulAppServerEndpoint = SoulAppServerEndpoint.fromEnvironment(),
        apiKey: String? = SoulAppServerClient.defaultAPIKey(),
        allowsLocalFallback: Bool? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        let authorityMode = (ProcessInfo.processInfo.environment["SOUL_REGISTRY_AUTHORITY"] ?? "").lowercased()
        self.fallbackAllowed = allowsLocalFallback ?? (authorityMode != "required")
        var continuation: AsyncStream<SoulAppServerNotification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    init(socketPath: String = SoulAppServerClient.defaultSocketPath()) {
        self.endpoint = .unixSocket(socketPath)
        self.apiKey = nil
        self.fallbackAllowed = true
        var continuation: AsyncStream<SoulAppServerNotification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    deinit {
        readTask?.cancel()
        try? handle?.close()
        notificationContinuation.finish()
    }

    func connectAndInitialize() async throws {
        do {
            if handle == nil {
                handle = try Self.connect(endpoint: endpoint)
                startReader()
            }
            let result = try await call(
                method: "initialize",
                params: .object([
                    "client_name": .string(Self.clientID),
                    "client_version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"),
                    "client_capabilities": .object([:])
                ])
            )
            try await authenticateIfRequired(initializeResult: result)
        } catch {
            guard !fallbackAllowed else { throw error }
            if let clientError = error as? SoulAppServerClientError,
               clientError.disablesLocalFallback {
                throw clientError
            }
            throw SoulAppServerClientError.authorityRequiredUnavailable(error.localizedDescription)
        }
    }

    func subscribe(projectKey: String) async throws {
        _ = try await call(
            method: "project.subscribe",
            params: .object(["project_key": .string(projectKey)])
        )
    }

    func orchestrationStatus(
        projectKey: String,
        runLimit: Int = 12,
        reviewLimit: Int = 25,
        subagentLimit: Int = 25
    ) async throws -> SoulOrchestrationStatusResult {
        let result = try await call(
            method: "project.orchestrationStatus",
            params: .object([
                "project_key": .string(projectKey),
                "run_limit": .int(runLimit),
                "review_limit": .int(reviewLimit),
                "subagent_limit": .int(subagentLimit)
            ])
        )
        return try decode(SoulOrchestrationStatusResult.self, from: result)
    }

    func taskList(
        projectKey: String,
        includeCompleted: Bool = false,
        limit: Int = 100
    ) async throws -> SoulTaskListResult {
        let result = try await call(
            method: "task.list",
            params: .object([
                "project_key": .string(projectKey),
                "include_completed": .bool(includeCompleted),
                "limit": .int(limit)
            ])
        )
        return try decode(SoulTaskListResult.self, from: result)
    }

    func workProjection(
        projectKey: String,
        sessionID: String? = nil,
        tail: Int = 12
    ) async throws -> SoulWorkProjection {
        var params: [String: JSONValue] = [
            "project_key": .string(projectKey),
            "tail": .int(tail)
        ]
        if let sessionID {
            params["session_id"] = .string(sessionID)
        }
        let result = try await call(
            method: "work_projection.get",
            params: .object(params)
        )
        if let projection = result["work_projection"], projection != .null {
            return try decode(SoulWorkProjection.self, from: projection)
        }
        return try decode(SoulWorkProjection.self, from: result)
    }

    func decodeNotificationParams<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else { throw SoulAppServerClientError.decodeFailed }
        return try decode(type, from: value)
    }

    private func authenticateIfRequired(initializeResult: JSONValue) async throws {
        let auth = initializeResult["capabilities"]?["features"]?["auth"]
        guard Self.boolValue(auth?["required"]) == true,
              Self.boolValue(auth?["authenticated"]) != true
        else { return }
        guard let apiKey, !apiKey.isEmpty else {
            throw SoulAppServerClientError.missingAPIKey
        }
        let challengeResult = try await call(method: "auth.challenge", params: .object([:]))
        guard let challengeID = challengeResult["challenge"]?["challenge_id"]?.stringValue,
              let nonce = challengeResult["challenge"]?["nonce"]?.stringValue
        else {
            throw SoulAppServerClientError.authFailed("authority did not return a challenge")
        }
        let response = Self.challengeResponse(
            apiKey: apiKey,
            challengeID: challengeID,
            nonce: nonce,
            clientID: Self.clientID
        )
        let authResult = try await call(
            method: "auth.complete",
            params: .object([
                "challenge_id": .string(challengeID),
                "client_id": .string(Self.clientID),
                "response": .string(response)
            ])
        )
        guard Self.boolValue(authResult["authenticated"]) == true else {
            throw SoulAppServerClientError.authFailed("authority did not accept the challenge response")
        }
    }

    private func call(method: String, params: JSONValue, timeoutSeconds: UInt64 = 5) async throws -> JSONValue {
        guard let handle else { throw SoulAppServerClientError.notConnected }
        let id = JSONRPCID.int(nextID)
        nextID += 1
        let envelope = JSONRPCEnvelope(jsonrpc: nil, id: id, method: method, params: params)
        let data = try encoder.encode(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self?.resolvePending(id: id, result: .failure(SoulAppServerClientError.requestTimedOut(method: method)))
            }
            var line = data
            line.append(0x0A)
            do {
                try handle.write(contentsOf: line)
            } catch {
                resolvePending(id: id, result: .failure(error))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            let data = try encoder.encode(value)
            return try decoder.decode(type, from: data)
        } catch {
            throw SoulAppServerClientError.decodeFailed
        }
    }

    private func startReader() {
        guard let handle else { return }
        let fd = handle.fileDescriptor
        readTask = Task.detached(priority: .utility) { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            do {
                while !Task.isCancelled {
                    let count = Darwin.read(fd, &chunk, chunk.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw SoulAppServerClientError.connectFailed(String(cString: strerror(errno)))
                    }
                    buffer.append(contentsOf: chunk.prefix(count))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        guard !line.isEmpty else { continue }
                        await self?.handleLine(Data(line))
                    }
                }
            } catch {
                await self?.failAll(error)
                return
            }
            await self?.failAll(SoulAppServerClientError.connectionClosed)
        }
    }

    private func handleLine(_ data: Data) {
        guard let envelope = try? decoder.decode(JSONRPCEnvelope.self, from: data) else { return }
        if let id = envelope.id {
            if let error = envelope.error {
                resolvePending(id: id, result: .failure(SoulAppServerClientError.rpcError(error)))
            } else {
                resolvePending(id: id, result: .success(envelope.result ?? .null))
            }
            return
        }
        guard let method = envelope.method else { return }
        notificationContinuation.yield(SoulAppServerNotification(method: method, params: envelope.params))
    }

    private func resolvePending(id: JSONRPCID, result: Result<JSONValue, Error>) {
        let continuation = pending.removeValue(forKey: id)
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) {
            resolvePending(id: id, result: .failure(error))
        }
        notificationContinuation.finish()
    }

    private static let clientID = "Soul-Desktop"

    private static func defaultAPIKey(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env["SOUL_API_KEY"] ?? env["SOUL_AUTHORITY_API_KEY"]
    }

    private static func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    static func challengeResponse(apiKey: String, challengeID: String, nonce: String, clientID: String) -> String {
        let message = Data("\(challengeID):\(nonce):\(clientID)".utf8)
        let key = SymmetricKey(data: Data(apiKey.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private static func connect(endpoint: SoulAppServerEndpoint) throws -> FileHandle {
        switch endpoint {
        case .unixSocket(let path):
            return try connectUnixSocket(path: path)
        case .tcp(let host, let port):
            return try connectTCP(host: host, port: port)
        case .invalid(let detail):
            throw SoulAppServerClientError.invalidEndpoint(detail)
        }
    }

    private static func connectUnixSocket(path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SoulAppServerClientError.connectFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw SoulAppServerClientError.socketPathTooLong(path)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: pathBytes)
        }

        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }

        guard connected == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw SoulAppServerClientError.connectFailed(detail)
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func connectTCP(host: String, port: UInt16) throws -> FileHandle {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hints, &result)
        guard code == 0, let result else {
            throw SoulAppServerClientError.connectFailed(String(cString: gai_strerror(code)))
        }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        var lastError = "no address resolved"
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                }
                lastError = String(cString: strerror(errno))
                close(fd)
            } else {
                lastError = String(cString: strerror(errno))
            }
            cursor = info.pointee.ai_next
        }
        throw SoulAppServerClientError.connectFailed(lastError)
    }
}
