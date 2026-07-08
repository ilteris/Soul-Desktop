import Foundation
import Darwin
import SoulACP

enum SoulRegistryServerClientError: LocalizedError {
    case socketPathTooLong(String)
    case connectFailed(String)
    case notConnected
    case rpcError(JSONRPCError)
    case requestTimedOut(method: String)
    case connectionClosed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Soul Registry Server socket path is too long: \(path)"
        case .connectFailed(let detail):
            return "Could not connect to Soul Registry Server: \(detail)"
        case .notConnected:
            return "Soul Registry Server is not connected."
        case .rpcError(let error):
            return error.message
        case .requestTimedOut(let method):
            return "Soul Registry Server request timed out: \(method)"
        case .connectionClosed:
            return "Soul Registry Server connection closed."
        case .decodeFailed:
            return "Could not decode Soul Registry Server response."
        }
    }
}

struct SoulRegistryServerNotification: Sendable {
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

actor SoulRegistryServerClient {
    static func defaultSocketPath() -> String {
        let root = ProcessInfo.processInfo.environment["SOUL_REGISTRY"] ?? "\(NSHomeDirectory())/soul_registry"
        return URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .appendingPathComponent("run")
            // Compatibility window: the canonical role is Registry Server,
            // while the daemon still exposes the legacy app-server socket.
            .appendingPathComponent("app-server.sock")
            .path
    }

    private let socketPath: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var handle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingTimeouts: [JSONRPCID: Task<Void, Never>] = [:]
    private let notificationStream: AsyncStream<SoulRegistryServerNotification>
    private let notificationContinuation: AsyncStream<SoulRegistryServerNotification>.Continuation

    nonisolated var notifications: AsyncStream<SoulRegistryServerNotification> {
        notificationStream
    }

    init(socketPath: String = SoulRegistryServerClient.defaultSocketPath()) {
        self.socketPath = socketPath
        var continuation: AsyncStream<SoulRegistryServerNotification>.Continuation!
        notificationStream = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    deinit {
        readTask?.cancel()
        try? handle?.close()
        notificationContinuation.finish()
    }

    func connectAndInitialize() async throws {
        if handle == nil {
            handle = try Self.connectUnixSocket(path: socketPath)
            startReader()
        }
        _ = try await call(
            method: "initialize",
            params: .object([
                "client_name": .string("Soul-Desktop"),
                "client_version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"),
                "client_capabilities": .object([:])
            ])
        )
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
        return try decode(SoulWorkProjection.self, from: result)
    }

    func decodeNotificationParams<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else { throw SoulRegistryServerClientError.decodeFailed }
        return try decode(type, from: value)
    }

    private func call(method: String, params: JSONValue, timeoutSeconds: UInt64 = 5) async throws -> JSONValue {
        guard let handle else { throw SoulRegistryServerClientError.notConnected }
        let id = JSONRPCID.int(nextID)
        nextID += 1
        let envelope = JSONRPCEnvelope(jsonrpc: nil, id: id, method: method, params: params)
        let data = try encoder.encode(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self?.resolvePending(id: id, result: .failure(SoulRegistryServerClientError.requestTimedOut(method: method)))
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
            throw SoulRegistryServerClientError.decodeFailed
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
                        throw SoulRegistryServerClientError.connectFailed(String(cString: strerror(errno)))
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
            await self?.failAll(SoulRegistryServerClientError.connectionClosed)
        }
    }

    private func handleLine(_ data: Data) {
        guard let envelope = try? decoder.decode(JSONRPCEnvelope.self, from: data) else { return }
        if let id = envelope.id {
            if let error = envelope.error {
                resolvePending(id: id, result: .failure(SoulRegistryServerClientError.rpcError(error)))
            } else {
                resolvePending(id: id, result: .success(envelope.result ?? .null))
            }
            return
        }
        guard let method = envelope.method else { return }
        notificationContinuation.yield(SoulRegistryServerNotification(method: method, params: envelope.params))
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

    private static func connectUnixSocket(path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SoulRegistryServerClientError.connectFailed(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw SoulRegistryServerClientError.socketPathTooLong(path)
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
            throw SoulRegistryServerClientError.connectFailed(detail)
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

typealias SoulAppServerClientError = SoulRegistryServerClientError
typealias SoulAppServerNotification = SoulRegistryServerNotification
typealias SoulAppServerClient = SoulRegistryServerClient
