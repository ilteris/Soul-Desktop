import Foundation

actor ACPTransport {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private var lineContinuation: AsyncStream<String>.Continuation?
    private var stderrContinuation: AsyncStream<String>.Continuation?
    private var buffer = Data()

    let incomingLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>

    init(executableURL: URL,
         arguments: [String],
         environment: [String: String]? = nil,
         scrubEnvKeys: [String] = [],
         cwd: String? = nil) {
        var inCont: AsyncStream<String>.Continuation!
        self.incomingLines = AsyncStream { inCont = $0 }
        var errCont: AsyncStream<String>.Continuation!
        self.stderrLines = AsyncStream { errCont = $0 }

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        for key in scrubEnvKeys { env.removeValue(forKey: key) }
        if let environment {
            for (k, v) in environment { env[k] = v }
        }
        process.environment = env

        Task { await self.bind(linesContinuation: inCont, stderrContinuation: errCont) }
    }

    private func bind(linesContinuation: AsyncStream<String>.Continuation,
                      stderrContinuation: AsyncStream<String>.Continuation) {
        self.lineContinuation = linesContinuation
        self.stderrContinuation = stderrContinuation

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.append(data: data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let s = String(data: data, encoding: .utf8) else { return }
            Task { await self?.emitStderr(s) }
        }
    }

    private func append(data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0..<(nl + 1))
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                lineContinuation?.yield(s)
            }
        }
    }

    private func emitStderr(_ s: String) {
        for line in s.split(separator: "\n") {
            stderrContinuation?.yield(String(line))
        }
    }

    func start() throws {
        try process.run()
    }

    func send(_ data: Data) {
        var payload = data
        payload.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: payload)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        lineContinuation?.finish()
        stderrContinuation?.finish()
    }
}
