import Foundation

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
    static func runMutation(_ args: [String], stdin: Data? = nil) async throws {
        _ = try await run(args, stdin: stdin)
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

            guard process.terminationStatus == 0 else {
                let message = String(data: err, encoding: .utf8) ?? ""
                throw SoulCLIError.nonZeroExit(code: process.terminationStatus, stderr: message)
            }
            return out
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
