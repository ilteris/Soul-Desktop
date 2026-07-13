import Foundation
import Darwin
import SoulCore

private let _wireTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func wireTimestamp() -> String {
    _wireTimeFormatter.string(from: Date())
}

/// Why the child went away. Distinguishes deliberate teardown from a crash so
/// ACPClient can decide whether to surface a user-facing error.
enum ACPTransportTermination: Sendable {
    case eof                   // stdout closed (child exited or detached its stdout)
    case processExit(Int32)    // process.terminationHandler fired with this status
    case explicit              // ACPClient.stop() called terminate()
}

actor ACPTransport {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private var lineContinuation: AsyncStream<String>.Continuation?
    private var stderrContinuation: AsyncStream<String>.Continuation?
    private var terminationContinuation: AsyncStream<ACPTransportTermination>.Continuation?
    private var buffer = Data()
    private var didTerminate = false

    let incomingLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>
    /// Yields exactly once when the child process goes away (EOF on stdout,
    /// terminationHandler firing, or explicit teardown — whichever happens
    /// first), then finishes. Subscribers can `for await` it to resume any
    /// outstanding waiters with a typed error instead of hanging forever.
    let terminationEvents: AsyncStream<ACPTransportTermination>

    init(executableURL: URL,
         arguments: [String],
         environment: [String: String]? = nil,
         scrubEnvKeys: [String] = [],
         cwd: String? = nil) {
        var inCont: AsyncStream<String>.Continuation!
        self.incomingLines = AsyncStream { inCont = $0 }
        var errCont: AsyncStream<String>.Continuation!
        self.stderrLines = AsyncStream { errCont = $0 }
        var termCont: AsyncStream<ACPTransportTermination>.Continuation!
        self.terminationEvents = AsyncStream { termCont = $0 }

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
        process.environment = SoulAuthorityEnvironment.applyingFinalizePromotion(env)

        // Capture self weakly inside the C-callback-style terminationHandler
        // so the actor doesn't keep the Process alive past its useful life.
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.handleTermination(.processExit(status)) }
        }

        Task { await self.bind(linesContinuation: inCont, stderrContinuation: errCont, terminationContinuation: termCont) }
    }

    private func bind(linesContinuation: AsyncStream<String>.Continuation,
                      stderrContinuation: AsyncStream<String>.Continuation,
                      terminationContinuation: AsyncStream<ACPTransportTermination>.Continuation) {
        self.lineContinuation = linesContinuation
        self.stderrContinuation = stderrContinuation
        self.terminationContinuation = terminationContinuation

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF on stdout. Child has closed its writer end — either
                // exited cleanly, crashed, or detached. Surface it so any
                // awaiting JSON-RPC continuations don't hang.
                Task { await self?.handleTermination(.eof) }
                return
            }
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

    /// Idempotent: the same child can trigger EOF and terminationHandler in
    /// quick succession; we want exactly one termination event.
    private func handleTermination(_ cause: ACPTransportTermination) {
        guard !didTerminate else { return }
        didTerminate = true
        // Drop readability handlers so we don't fire EOF a second time on
        // the now-closed file descriptors during process teardown.
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        terminationContinuation?.yield(cause)
        terminationContinuation?.finish()
        lineContinuation?.finish()
        stderrContinuation?.finish()
    }

    func start() throws {
        try process.run()
        // SOUL-SOUL_DESKTOP-194: put the child in its own process group so
        // a later `terminate()` can SIGKILL the whole tree. Providers
        // launch via `npx`, which forks a `node` child that does the real
        // work. SIGTERM to npx does NOT propagate to its node child, so
        // the agent kept running after Stop. With pid as its own pgid we
        // can `killpg(pid, SIGKILL)` and take down npx + node + helpers
        // atomically.
        //
        // Best-effort: there's an inherent race where the child may have
        // already called setpgid itself, in which case our call returns
        // EPERM and we fall back to plain `process.terminate()`. For node
        // children this is fine — node doesn't change pgid.
        let pid = process.processIdentifier
        if pid > 0 {
            _ = Darwin.setpgid(pid, pid)
        }
    }

    /// Throws on broken pipe (child exited mid-write). Callers should treat
    /// the throw as a terminal signal — the continuation they registered will
    /// also be drained via the termination stream.
    func send(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }

    func terminate() {
        if process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                // SIGTERM the whole process group first so npx + node + any
                // helpers all get a chance to flush. Escalate to SIGKILL
                // after 400ms if anything is still alive.
                _ = Darwin.killpg(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    _ = Darwin.killpg(pid, SIGKILL)
                }
            } else {
                process.terminate()
            }
        }
        handleTermination(.explicit)
    }
}
