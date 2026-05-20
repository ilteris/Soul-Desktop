import Foundation

enum SoulCLIError: LocalizedError {
    case nonZeroExit(code: Int32, stderr: String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(_, let stderr):
            return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["soul"] + args

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
}
