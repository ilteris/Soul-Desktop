import Foundation
import Darwin
import SoulCore

enum SoulCLIError: LocalizedError {
    case nonZeroExit(code: Int32, stderr: String)
    case executableNotFound
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(_, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "soul CLI failed." : message
        case .executableNotFound:
            return "Could not find the soul CLI at ~/soul-cli/soul/bin/soul."
        case .decodeFailed:
            return "Could not decode soul CLI output."
        }
    }
}

enum SoulCLI {
    enum Stream: Sendable {
        case stdout(String)
        case stderr(String)
    }

    static func runMutation(_ args: [String], stdin: Data? = nil) async throws {
        _ = try await run(args, stdin: stdin)
    }

    static func runText(_ args: [String], stdin: Data? = nil, includeStderr: Bool = true) async throws -> String {
        let result = try await runCapture(args, stdin: stdin)
        let outText = String(data: result.stdout, encoding: .utf8) ?? ""
        let errText = String(data: result.stderr, encoding: .utf8) ?? ""
        guard result.status == 0 else {
            throw SoulCLIError.nonZeroExit(code: result.status, stderr: errText)
        }
        guard includeStderr else { return outText }
        if errText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outText
        }
        return outText.isEmpty ? errText : outText + "\n" + errText
    }

    static func runStream(
        _ args: [String],
        stdin: Data? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil,
        onEvent: @escaping @Sendable (Stream) -> Void
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = soulExecutablePath() else {
                throw SoulCLIError.executableNotFound
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = cliEnvironment()

            let termination = ProcessTerminationSignal()
            process.terminationHandler = { _ in
                termination.signal(process.terminationStatus)
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                onEvent(.stdout(text))
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                onEvent(.stderr(text))
            }

            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(stdin)
                try? input.fileHandleForWriting.close()
            } else {
                try process.run()
            }
            onStart?(process.processIdentifier)

            let status: Int32
            if let terminatedStatus = await termination.wait(timeoutSeconds: 120) {
                status = terminatedStatus
            } else {
                process.terminate()
                status = await termination.wait(timeoutSeconds: 1) ?? SafeProcessRunner.timeoutStatus
            }
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let remainingOut = stdoutHandle.readDataToEndOfFile()
            if !remainingOut.isEmpty, let text = String(data: remainingOut, encoding: .utf8) {
                onEvent(.stdout(text))
            }
            let remainingErr = stderrHandle.readDataToEndOfFile()
            if !remainingErr.isEmpty, let text = String(data: remainingErr, encoding: .utf8) {
                onEvent(.stderr(text))
            }

            if status != 0 {
                throw SoulCLIError.nonZeroExit(
                    code: status,
                    stderr: String(data: remainingErr, encoding: .utf8) ?? ""
                )
            }
            return status
        }.value
    }

    private final class ProcessTerminationSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuations: [CheckedContinuation<Int32, Never>] = []

        func signal(_ status: Int32) {
            let pending: [CheckedContinuation<Int32, Never>]
            lock.lock()
            guard self.status == nil else {
                lock.unlock()
                return
            }
            self.status = status
            pending = continuations
            continuations.removeAll()
            lock.unlock()

            for continuation in pending {
                continuation.resume(returning: status)
            }
        }

        func wait(timeoutSeconds: TimeInterval) async -> Int32? {
            await withTaskGroup(of: Int32?.self) { group in
                group.addTask { await self.wait() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return nil
                }

                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }

        private func wait() async -> Int32 {
            if let status = currentStatus() {
                return status
            }

            return await withCheckedContinuation { continuation in
                if let status = appendContinuationOrStatus(continuation) {
                    continuation.resume(returning: status)
                }
            }
        }

        private func currentStatus() -> Int32? {
            lock.lock()
            let value = status
            lock.unlock()
            return value
        }

        private func appendContinuationOrStatus(_ continuation: CheckedContinuation<Int32, Never>) -> Int32? {
            lock.lock()
            if let status {
                lock.unlock()
                return status
            }
            continuations.append(continuation)
            lock.unlock()
            return nil
        }
    }

    static func terminateProcessTree(pid: Int32) {
        let children = childPIDs(of: pid)
        for child in children {
            terminateProcessTree(pid: child)
        }
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            Darwin.kill(pid, SIGKILL)
        }
    }

    static func runJSON<T: Decodable>(_ args: [String], stdin: Data? = nil, as type: T.Type) async throws -> T {
        let data = try await run(args, stdin: stdin)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw SoulCLIError.decodeFailed
        }
        return decoded
    }

    /// Synchronous escape hatch for sync call sites that need a CLI result
    /// without async plumbing — e.g. `SoulRegistry.projects()`,
    /// `AppShellV2.projectTeam(...)`, and the session-show helpers.
    /// Blocks the calling thread until the CLI returns. Returns stdout
    /// bytes on success or nil on any failure (executable missing,
    /// non-zero exit, I/O error) — the caller decides how to degrade.
    ///
    /// Uses `SafeProcessRunner` so stdout/stderr drain while the process runs
    /// and timeout/termination handling stays bounded.
    static func runSync(_ args: [String]) -> Data? {
        guard let executable = soulExecutablePath() else { return nil }
        do {
            let result = try SafeProcessRunner.runSync(
                executable: executable,
                arguments: args,
                environment: cliEnvironment(),
                timeoutSeconds: 30
            )
            guard result.status == 0 else { return nil }
            return result.stdout
        } catch {
            return nil
        }
    }

    @discardableResult
    private static func run(_ args: [String], stdin: Data?) async throws -> Data {
        let result = try await runCapture(args, stdin: stdin)
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? ""
            throw SoulCLIError.nonZeroExit(code: result.status, stderr: message)
        }
        return result.stdout
    }

    struct Capture: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        do {
            let result = try SafeProcessRunner.runSync(
                executable: "/usr/bin/pgrep",
                arguments: ["-P", "\(pid)"],
                timeoutSeconds: 2
            )
            let text = String(data: result.stdout, encoding: .utf8) ?? ""
            return text
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } catch {
            return []
        }
    }

    private static func runCapture(_ args: [String], stdin: Data?) async throws -> Capture {
        guard let executable = soulExecutablePath() else {
            throw SoulCLIError.executableNotFound
        }
        return try await captureProcess(
            executable: executable,
            arguments: args,
            environment: cliEnvironment(),
            stdin: stdin
        )
    }

    /// Core concurrent-drain capture: runs `executable` with `arguments`,
    /// draining stdout/stderr while the child runs and bounding termination.
    ///
    /// Exposed internally (not tied to the `soul` binary) so the drain path can be exercised
    /// deterministically against a known large-output source — see
    /// `testRunCaptureLargeOutputDoesNotDeadlock`. Production callers go through `runCapture`.
    static func captureProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) async throws -> Capture {
        let result = try await SafeProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stdin: stdin,
            timeoutSeconds: 120
        )
        return Capture(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    private static func soulExecutablePath() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/soul-cli/soul/bin/soul",
            "\(home)/.local/bin/soul",
            "\(home)/bin/soul",
            "/opt/homebrew/bin/soul",
            "/usr/local/bin/soul"
        ]

        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = "\(dir)/soul"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func cliEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        let extras = [
            "\(home)/soul-cli/soul/bin",
            "\(home)/dotfiles/bin",
            "\(home)/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var seen = Set<String>()
        // Extras BEFORE inherited PATH so brew tools (python3 3.14, gemini,
        // soul) win over system shims when both exist. macOS app processes
        // inherit a minimal PATH (/usr/bin first), which used to resolve
        // `env python3` to system Python 3.9 and crash any PEP-604 typing
        // in kernel scripts. See SPEC-245-K hotfix.
        let dirs = (extras + current.split(separator: ":").map(String.init)).filter { seen.insert($0).inserted }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")
        env["HOME"] = home
        env["SOUL_PATH"] = "\(home)/soul-cli/soul"
        // ProcessInfo.environment is a launch-time snapshot. Tests and some
        // embedding paths swizzle these with setenv() before invoking the
        // kernel CLI, so read the live process environment explicitly.
        for key in [
            "SOUL_HOME",
            "SOUL_REGISTRY",
            "SOUL_PATH",
            "SOUL_REGISTRY_AUTHORITY",
            "SOUL_REGISTRY_AUTHORITY_URL",
            "SOUL_API_KEY",
            "SOUL_AUTHORITY_API_KEY",
            "SOUL_FINALIZE_PROMOTE_AUTHORITY",
        ] {
            if let value = getenv(key).map({ String(cString: $0) }), !value.isEmpty {
                env[key] = value
            }
        }
        return SoulAuthorityEnvironment.applyingFinalizePromotion(env)
    }
}
