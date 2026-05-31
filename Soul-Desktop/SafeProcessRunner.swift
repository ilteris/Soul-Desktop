import Foundation

struct SafeProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

enum SafeProcessRunner {
    static let timeoutStatus: Int32 = -2

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryPath: String? = nil,
        stdin: Data? = nil,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> SafeProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectoryPath: currentDirectoryPath,
                stdin: stdin,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }

    static func runSync(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryPath: String? = nil,
        stdin: Data? = nil,
        timeoutSeconds: TimeInterval = 30
    ) throws -> SafeProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectoryPath {
            process.currentDirectoryPath = currentDirectoryPath
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        let stdoutBox = NSMutableData()
        let stderrBox = NSMutableData()
        let stdoutLock = NSLock()
        let stderrLock = NSLock()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stdout.fileHandleForReading, into: stdoutBox, lock: stdoutLock)
            drainGroup.leave()
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stderr.fileHandleForReading, into: stderrBox, lock: stderrLock)
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            throw error
        }

        if let stdin {
            stdinPipe?.fileHandleForWriting.write(stdin)
        }
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeoutSeconds
        var timedOut = false
        if termination.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                process.interrupt()
            }
        }

        _ = drainGroup.wait(timeout: .now() + 1)

        let status = timedOut ? timeoutStatus : process.terminationStatus
        return SafeProcessResult(
            status: status,
            stdout: stdoutBox as Data,
            stderr: stderrBox as Data,
            timedOut: timedOut
        )
    }

    private static func drain(_ handle: FileHandle, into box: NSMutableData, lock: NSLock) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lock.lock()
            box.append(chunk)
            lock.unlock()
        }
    }
}
