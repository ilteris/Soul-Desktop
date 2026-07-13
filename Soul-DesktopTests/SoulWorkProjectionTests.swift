import Foundation
import Darwin
import CryptoKit
import Testing
@testable import Soul_Desktop

struct SoulWorkProjectionTests {
    @Test func endpointSelectionPrefersTCPAuthorityURLAndRequiresURLInRequiredMode() throws {
        #expect(SoulAppServerEndpoint.fromEnvironment([
            "SOUL_REGISTRY_AUTHORITY": "required",
            "SOUL_REGISTRY_AUTHORITY_URL": "tcp://100.123.210.64:4720"
        ]) == .tcp(host: "100.123.210.64", port: 4720))

        if case .invalid(let message) = SoulAppServerEndpoint.fromEnvironment([
            "SOUL_REGISTRY_AUTHORITY": "required"
        ]) {
            #expect(message.contains("SOUL_REGISTRY_AUTHORITY_URL"))
        } else {
            Issue.record("required authority without URL should be invalid")
        }

        if case .unixSocket(let path) = SoulAppServerEndpoint.fromEnvironment([
            "SOUL_REGISTRY": "/tmp/soul-registry"
        ]) {
            #expect(path == "/tmp/soul-registry/run/app-server.sock")
        } else {
            Issue.record("default mode should use the local Unix socket")
        }
    }

    @Test func appServerClientReadsUnixSocketResponses() async throws {
        let server = try UnixJSONRPCFixture()
        server.start()
        defer { server.stop() }

        let client = SoulAppServerClient(socketPath: server.socketPath)
        try await client.connectAndInitialize()
        try await client.subscribe(projectKey: "soul-desktop")

        let status = try await client.orchestrationStatus(projectKey: "soul-desktop")
        #expect(status.projectKey == "soul-desktop")
        #expect(status.snapshot.projectBinding?.declaredPath == "~/Code/Soul-Desktop")

        let projection = try await client.workProjection(projectKey: "soul-desktop")
        #expect(projection.schema == "soul-work-projection/v1")
        #expect(projection.nextStep == "Compile semantic trajectory.")
    }

    @Test func appServerClientReadsTCPAuthorityResponsesAfterHMACAuth() async throws {
        let server = try TCPJSONRPCFixture(apiKey: "test-secret")
        server.start()
        defer { server.stop() }

        let client = SoulAppServerClient(
            endpoint: .tcp(host: "127.0.0.1", port: server.port),
            apiKey: "test-secret",
            allowsLocalFallback: false
        )
        try await client.connectAndInitialize()
        try await client.subscribe(projectKey: "soul-desktop")

        let projection = try await client.workProjection(projectKey: "soul-desktop")
        #expect(projection.authority?.mode == "central")
        #expect(projection.authority?.transport == "app-server")
        #expect(projection.authority?.writes == "local_only")
        #expect(projection.authority?.readOnly == true)
    }

    @Test func appServerClientRejectsBadTCPAuthorityHMACWithoutFallback() async throws {
        let server = try TCPJSONRPCFixture(apiKey: "test-secret")
        server.start()
        defer { server.stop() }

        let client = SoulAppServerClient(
            endpoint: .tcp(host: "127.0.0.1", port: server.port),
            apiKey: "wrong-secret",
            allowsLocalFallback: false
        )
        do {
            try await client.connectAndInitialize()
            Issue.record("bad HMAC should fail")
        } catch let error as SoulAppServerClientError {
            if case .authorityRequiredUnavailable(let detail) = error {
                #expect(detail.contains("invalid auth challenge response"))
            } else {
                Issue.record("expected required authority failure, got \(error)")
            }
        }
    }

    @Test func workProjectionPayloadDecodesContinuitySnapshot() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection/v1",
          "project_key": "soul",
          "session_id": "simple-session",
          "generated_at": "2026-07-04T16:00:00Z",
          "projection_fingerprint": "sha256:abc123",
          "authority": {
            "mode": "central",
            "read_only": true,
            "registry_fingerprint": "sha256:central",
            "transport": "app-server",
            "writes": "local_only"
          },
          "active_task": {
            "task_id": "SOUL-SOUL-307",
            "id": "SOUL-SOUL-307",
            "project": "soul",
            "subject": "Build semantic projection",
            "status": "in_progress",
            "done_criteria": ["projection works"],
            "completed_criteria": []
          },
          "active_run": {
            "run_id": "run_projection",
            "project": "soul",
            "task_id": "SOUL-SOUL-307",
            "session_id": "simple-session",
            "objective": "Read projection",
            "status": "running",
            "updated_at": "2026-07-04T15:59:00Z"
          },
          "trajectory_status": {
            "schema": "soul-trajectory-status/v1",
            "project_key": "soul",
            "session_id": "simple-session",
            "exists": true,
            "stale": false,
            "trajectory_status": "compiled",
            "compiled_at": "2026-07-04T15:58:00Z"
          },
          "trajectory": {
            "status": "compiled",
            "primary_intent": "Continue central registry work.",
            "compiled_at": "2026-07-04T15:58:00Z",
            "compiler_version": "semantic-trajectory/v1",
            "turn_count": 4,
            "decision_count": 1,
            "verification": {
              "run": ["verify-run"],
              "passed": ["verify-pass"],
              "failed": []
            },
            "eval_candidate_refs": ["eval-1"]
          },
          "semantic_timeline_tail": [
            {
              "semantic_event_id": "sem-1",
              "semantic_seq": 1,
              "checkpoint": "PlanCommitted",
              "timestamp": "2026-07-04T15:57:00Z",
              "actor": "user",
              "summary": "Pull work_projection.get.",
              "confidence": 0.8,
              "refs": ["hooks:1"]
            }
          ],
          "next_step": "Pull work_projection.get."
        }
        """.utf8)

        let projection = try JSONDecoder().decode(SoulWorkProjection.self, from: data)

        #expect(projection.schema == "soul-work-projection/v1")
        #expect(projection.projectKey == "soul")
        #expect(projection.sessionID == "simple-session")
        #expect(projection.projectionFingerprint == "sha256:abc123")
        #expect(projection.authority?.mode == "central")
        #expect(projection.authority?.transport == "app-server")
        #expect(projection.authority?.writes == "local_only")
        #expect(projection.authority?.readOnly == true)
        #expect(projection.activeTask?.id == "SOUL-SOUL-307")
        #expect(projection.activeRun?.runID == "run_projection")
        #expect(projection.trajectoryStatus?.stale == false)
        #expect(projection.trajectory?.primaryIntent == "Continue central registry work.")
        #expect(projection.trajectory?.verification?.run == ["verify-run"])
        #expect(projection.trajectory?.verification?.passed == ["verify-pass"])
        #expect(projection.trajectory?.verification?.failed == [])
        #expect(projection.semanticTimelineTail.first?.checkpoint == "PlanCommitted")
        #expect(projection.nextStep == "Pull work_projection.get.")
    }

    @Test func workProjectionUpdatedParamsDriveTargetedRefresh() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection-update/v1",
          "project_key": "soul-desktop",
          "session_id": "session-123",
          "source": "session.finalize",
          "status": "finalized",
          "updated_at": "2026-07-04T16:04:00Z",
          "projection_fingerprint": "sha256:new",
          "trajectory_status": {
            "schema": "soul-trajectory-status/v1",
            "project_key": "soul-desktop",
            "session_id": "session-123",
            "exists": true,
            "stale": true,
            "reason": "hooks_changed"
          },
          "next_step": "Recompile the semantic trajectory before continuing from central projection."
        }
        """.utf8)

        let params = try JSONDecoder().decode(SoulWorkProjectionUpdatedParams.self, from: data)
        let request = try #require(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:old"
        ))

        #expect(params.schema == "soul-work-projection-update/v1")
        #expect(params.source == "session.finalize")
        #expect(params.trajectoryStatus?.stale == true)
        #expect(request.sessionID == "session-123")
        #expect(request.projectionFingerprint == "sha256:new")
        #expect(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:new"
        ) == nil)
        #expect(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "other-project",
            lastFingerprint: "sha256:old"
        ) == nil)
    }

    @Test func workProjectionUpdatedParamsRefreshMissingFingerprintAndPreserveProjectionError() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection-update/v1",
          "project_key": "soul-desktop",
          "session_id": "session-123",
          "source": "registry.watch",
          "status": "changed",
          "updated_at": "2026-07-04T16:05:00Z",
          "projection_fingerprint": "",
          "projection_error": {
            "code": "unsafe_path_segment",
            "message": "session_id is not safe"
          }
        }
        """.utf8)

        let params = try JSONDecoder().decode(SoulWorkProjectionUpdatedParams.self, from: data)
        let request = try #require(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:old"
        ))

        #expect(request.sessionID == "session-123")
        #expect(request.projectionFingerprint == "")
        #expect(request.projectionError?.code == "unsafe_path_segment")
        #expect(request.projectionError?.message == "session_id is not safe")
    }
}

private final class UnixJSONRPCFixture {
    let socketPath: String
    private let listenFD: Int32
    private var task: Task<Void, Never>?

    init() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("app-server.sock").path
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            guard pathBytes.count < rawBuffer.count else {
                throw SoulAppServerClientError.socketPathTooLong(socketPath)
            }
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: pathBytes)
        }

        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(listenFD, sockaddrPointer, length)
            }
        }
        guard bound == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard listen(listenFD, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func start() {
        let fd = listenFD
        task = Task.detached(priority: .utility) {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &chunk, chunk.count)
                if count <= 0 { return }
                buffer.append(contentsOf: chunk.prefix(count))
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let response = Self.response(for: Data(line))
                    else { continue }
                    Self.write(response, to: clientFD)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        close(listenFD)
        try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
    }

    private static func response(for data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"],
              let method = object["method"] as? String
        else { return nil }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocol_version": "0.1.0",
                "server_name": "fixture",
                "server_version": "1",
                "capabilities": ["methods": [], "notifications": [], "features": [:]]
            ]
        case "project.subscribe":
            result = ["project": ["key": "soul-desktop"], "snapshot": ["version": "fixture"]]
        case "project.orchestrationStatus":
            result = orchestrationStatus
        case "work_projection.get":
            result = workProjection
        default:
            return try? JSONSerialization.data(withJSONObject: [
                "id": id,
                "error": ["code": -32601, "message": "method not found"]
            ])
        }
        return try? JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }

    private static func write(_ data: Data, to fd: Int32) {
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(fd, base, rawBuffer.count)
        }
    }

    fileprivate static let orchestrationStatus: [String: Any] = [
        "project_key": "soul-desktop",
        "snapshot": [
            "schema": "soul-orchestration-snapshot/v1",
            "project": "soul-desktop",
            "project_key": "soul-desktop",
            "version": "fixture-version",
            "updated_at": "2026-07-05T03:25:00Z",
            "project_binding": [
                "schema_version": "project-binding/v1",
                "project_key": "soul-desktop",
                "name": "Soul Desktop",
                "declared_path": "~/Code/Soul-Desktop",
                "resolved_path": "/Users/adele/Code/Soul-Desktop",
                "resolution": "tilde_home",
                "exists": true,
                "portable": true,
                "suggested_path": NSNull(),
                "companion_paths": [],
                "source": ["manifest": "~/soul-cli/soul/config/PROJECTS.json"]
            ],
            "work_status": ["project": "soul-desktop", "task": NSNull(), "runs": []],
            "run_review": [
                "schema": "soul-run-review/v1",
                "project": "soul-desktop",
                "summary": [
                    "total_runs": 0,
                    "completed_runs": 0,
                    "failed_runs": 0,
                    "retry_count": 0,
                    "failure_reasons": [:],
                    "verifier_outcomes": [:]
                ],
                "runs": []
            ],
            "subagent_list": ["project": "soul-desktop", "subagents": []],
            "active_task": NSNull(),
            "runs": [],
            "subagents": []
        ]
    ]

    private static let workProjection: [String: Any] = [
        "schema": "soul-work-projection/v1",
        "project_key": "soul-desktop",
        "session_id": NSNull(),
        "generated_at": "2026-07-05T03:25:00Z",
        "projection_fingerprint": "sha256:fixture",
        "authority": [
            "mode": "local",
            "read_only": false,
            "transport": "unix-socket",
            "writes": "local"
        ],
        "active_task": NSNull(),
        "active_run": NSNull(),
        "trajectory_status": NSNull(),
        "trajectory": NSNull(),
        "semantic_timeline_tail": [],
        "next_step": "Compile semantic trajectory."
    ]
}

private final class TCPJSONRPCFixture {
    private(set) var port: UInt16 = 0
    private let apiKey: String
    private let listenFD: Int32
    private var task: Task<Void, Never>?

    init(apiKey: String) throws {
        self.apiKey = apiKey
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(listenFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard listen(listenFD, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(listenFD, sockaddrPointer, &actualLength)
            }
        }
        guard named == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        port = UInt16(bigEndian: actual.sin_port)
    }

    func start() {
        let fd = listenFD
        let apiKey = apiKey
        task = Task.detached(priority: .utility) {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            var authenticated = false
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &chunk, chunk.count)
                if count <= 0 { return }
                buffer.append(contentsOf: chunk.prefix(count))
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let response = Self.response(
                            for: Data(line),
                            apiKey: apiKey,
                            authenticated: &authenticated
                          )
                    else { continue }
                    Self.write(response, to: clientFD)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        close(listenFD)
    }

    private static func response(
        for data: Data,
        apiKey: String,
        authenticated: inout Bool
    ) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"],
              let method = object["method"] as? String
        else { return nil }

        switch method {
        case "initialize":
            return result(id: id, [
                "protocol_version": "0.1.0",
                "server_name": "fixture",
                "server_version": "1",
                "capabilities": [
                    "methods": [],
                    "notifications": [],
                    "features": [
                        "transport": "tcp",
                        "auth": [
                            "required": true,
                            "authenticated": authenticated,
                            "mode": "hmac-challenge-session"
                        ]
                    ]
                ]
            ])
        case "auth.challenge":
            return result(id: id, [
                "required": true,
                "mode": "hmac-challenge-session",
                "challenge": [
                    "challenge_id": "challenge-1",
                    "nonce": "nonce-1"
                ]
            ])
        case "auth.complete":
            guard let params = object["params"] as? [String: Any],
                  let response = params["response"] as? String,
                  let clientID = params["client_id"] as? String,
                  let challengeID = params["challenge_id"] as? String
            else {
                return error(id: id, code: -32602, message: "challenge_id, client_id, and response are required")
            }
            let expected = hmac(apiKey: apiKey, challengeID: challengeID, nonce: "nonce-1", clientID: clientID)
            guard response == expected else {
                return error(id: id, code: -32602, message: "invalid auth challenge response")
            }
            authenticated = true
            return result(id: id, ["authenticated": true, "session": "fixture-session"])
        default:
            guard authenticated else {
                return error(id: id, code: -32600, message: "unauthorized: missing session_token; call auth.challenge/auth.complete first")
            }
            switch method {
            case "project.subscribe":
                return result(id: id, ["project": ["key": "soul-desktop"], "snapshot": ["version": "fixture"]])
            case "project.orchestrationStatus":
                return result(id: id, UnixJSONRPCFixture.orchestrationStatus)
            case "work_projection.get":
                return result(id: id, [
                    "project_key": "soul-desktop",
                    "work_projection": centralWorkProjection
                ])
            default:
                return error(id: id, code: -32601, message: "method not found")
            }
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": ["code": code, "message": message]
        ])
    }

    private static func hmac(apiKey: String, challengeID: String, nonce: String, clientID: String) -> String {
        let message = Data("\(challengeID):\(nonce):\(clientID)".utf8)
        let key = SymmetricKey(data: Data(apiKey.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, to fd: Int32) {
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(fd, base, rawBuffer.count)
        }
    }

    private static let centralWorkProjection: [String: Any] = [
        "schema": "soul-work-projection/v1",
        "project_key": "soul-desktop",
        "session_id": NSNull(),
        "generated_at": "2026-07-05T03:25:00Z",
        "projection_fingerprint": "sha256:central-fixture",
        "authority": [
            "mode": "central",
            "read_only": true,
            "registry_fingerprint": "sha256:central",
            "transport": "app-server",
            "writes": "local_only"
        ],
        "active_task": NSNull(),
        "active_run": NSNull(),
        "trajectory_status": NSNull(),
        "trajectory": NSNull(),
        "semantic_timeline_tail": [],
        "next_step": "Use central projection."
    ]
}
