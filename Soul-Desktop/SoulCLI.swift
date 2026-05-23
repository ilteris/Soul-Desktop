import Foundation
import Darwin

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
            return "Could not find the soul CLI at ~/dotfiles/soul/bin/soul."
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

            process.waitUntilExit()
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

            let status = process.terminationStatus
            if status != 0 {
                throw SoulCLIError.nonZeroExit(
                    code: status,
                    stderr: String(data: remainingErr, encoding: .utf8) ?? ""
                )
            }
            return status
        }.value
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

    @discardableResult
    private static func run(_ args: [String], stdin: Data?) async throws -> Data {
        let result = try await runCapture(args, stdin: stdin)
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? ""
            throw SoulCLIError.nonZeroExit(code: result.status, stderr: message)
        }
        return result.stdout
    }

    private struct Capture: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } catch {
            return []
        }
    }

    private static func runCapture(_ args: [String], stdin: Data?) async throws -> Capture {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = soulExecutablePath() else {
                throw SoulCLIError.executableNotFound
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = cliEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(stdin)
                try? input.fileHandleForWriting.close()
            } else {
                try process.run()
            }

            process.waitUntilExit()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()

            return Capture(status: process.terminationStatus, stdout: out, stderr: err)
        }.value
    }

    private static func soulExecutablePath() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/dotfiles/soul/bin/soul",
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
            "\(home)/dotfiles/soul/bin",
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
        env["SOUL_PATH"] = "\(home)/dotfiles/soul"
        return env
    }
}
