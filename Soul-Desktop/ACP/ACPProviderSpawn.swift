import Foundation

struct ACPProviderSpawn {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]?
    var scrubEnvKeys: [String] = []
    var cwd: String? = nil

    /// Resolve a spawn for a provider. When `resumeSessionId` is non-nil, we
    /// add provider-specific CLI flags so the agent comes up already loaded
    /// on that session — bypassing ACP `loadSession`, which gemini-cli and
    /// pi don't really support over RPC. Claude resumes via ACP, so its
    /// spawn shape doesn't change.
    static func resolve(_ provider: Provider, resumeSessionId: String? = nil) -> ACPProviderSpawn? {
        let env = enrichedEnvironment()
        switch provider {
        case .geminiCLI:
            if let bundled = bundledGeminiSpawn(env: env) {
                return bundled
            }
            // SOUL_GEMINI_LOCAL=1 (or a path) swaps the global gemini install
            // for a local checkout under ~/Code/gemini-cli — used while
            // iterating on patches to gemini-cli itself (e.g. nested-subagent
            // ACP notifications). Defaults to the standard `gemini` binary on
            // PATH when the env var is unset or empty.
            if let local = localGeminiSpawn(env: env) {
                return local
            }
            guard let path = which("gemini") else { return nil }
            // No `--resume` flag: gemini-cli fully supports ACP `session/load`
            // (verified via `agentCapabilities.loadSession: true` in its
            // initialize response). The CLI-flag resume path is redundant and
            // skips the protocol's history replay through user/agent message
            // chunks, so the canvas comes up empty. Route resume through
            // session/load like Claude.
            return .init(executablePath: path, arguments: geminiACPArguments(), environment: env)
        case .pi:
            // pi-acp 0.0.27 only parses `--terminal-login` from argv —
            // anything else (including the `--resume <sid>` we used to
            // pass) is silently ignored. Resume now goes through ACP
            // `session/load`, which pi-acp does implement and advertises
            // via `agentCapabilities.loadSession: true`.
            guard let path = which("npx") else { return nil }
            return .init(executablePath: path, arguments: ["-y", "pi-acp"], environment: env)
        case .claude:
            guard let path = which("npx") else { return nil }
            return .init(
                executablePath: path,
                arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
                environment: env,
                scrubEnvKeys: ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"]
            )
        case .codex:
            // Codex app-server speaks JSON-RPC 2.0 over stdio (newline-delimited).
            // Default `codex app-server` (no flags) uses stdio mode — same
            // framing model as ACPTransport, so we reuse the transport actor
            // verbatim from CodexClient. Resume is not modeled at the CLI
            // level (codex manages threads server-side); the resume flow runs
            // through the `thread/resume` JSON-RPC method instead.
            guard let path = which("codex") else { return nil }
            return .init(
                executablePath: path,
                arguments: ["app-server"],
                environment: env
            )
        }
    }
}

/// Resolve the Gemini CLI runtime bundled inside the app. The bundle is
/// produced by `scripts/vendor_gemini_cli.sh` from the pinned gemini-cli
/// checkout and copied into Contents/Resources at build time.
private func bundledGeminiSpawn(env: [String: String]) -> ACPProviderSpawn? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let entry = resources
        .appendingPathComponent("GeminiCLI")
        .appendingPathComponent("bundle")
        .appendingPathComponent("gemini.js")
        .path
    guard FileManager.default.fileExists(atPath: entry) else { return nil }
    guard let node = which("node") else { return nil }
    return .init(executablePath: node, arguments: [entry] + geminiACPArguments(), environment: env)
}

/// Resolve a local gemini-cli spawn when the user has opted in via
/// `SOUL_GEMINI_LOCAL`. Accepted values:
///   "1" / "true"  → use the default ~/Code/gemini-cli/packages/cli/dist/index.js
///   "<abs path>"  → use that path verbatim as the JS entry point
/// Returns nil when the env var is unset, empty, "0", or points at a file that
/// doesn't exist (caller falls back to the global `gemini` binary).
private func localGeminiSpawn(env: [String: String]) -> ACPProviderSpawn? {
    guard let raw = ProcessInfo.processInfo.environment["SOUL_GEMINI_LOCAL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty, raw != "0" else {
        return nil
    }
    let home = NSHomeDirectory()
    let entry: String
    if raw == "1" || raw.lowercased() == "true" {
        entry = "\(home)/Code/gemini-cli/packages/cli/dist/index.js"
    } else {
        entry = (raw as NSString).expandingTildeInPath
    }
    guard FileManager.default.fileExists(atPath: entry) else { return nil }
    guard let node = which("node") else { return nil }
    return .init(executablePath: node, arguments: [entry] + geminiACPArguments(), environment: env)
}

private func geminiACPArguments() -> [String] {
    let home = NSHomeDirectory()
    let includeDirs = [
        // Agents are routinely instructed to inspect Soul kernel scripts from
        // project sessions. Without these include dirs Gemini's read/edit
        // tools reject paths like ~/dotfiles/soul/bin/soul as out-of-workspace.
        "\(home)/dotfiles/soul",
        "\(home)/dotfiles",
    ].filter { FileManager.default.fileExists(atPath: $0) }

    guard !includeDirs.isEmpty else { return ["--acp"] }
    return ["--acp", "--include-directories", includeDirs.joined(separator: ",")]
}

private func enrichedEnvironment() -> [String: String] {
    let home = NSHomeDirectory()
    let extras = [
        "\(home)/bin",
        "\(home)/.local/bin",
        "\(home)/.bun/bin",
        // Soul OS kernel CLI — lets spawned agents call `soul pulse`,
        // `soul task ...`, and friends without a PATH miss.
        "\(home)/dotfiles/soul/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var seen = Set<String>()
    var dirs: [String] = []
    for d in (current.split(separator: ":").map(String.init) + extras) {
        if seen.insert(d).inserted { dirs.append(d) }
    }
    var env: [String: String] = ["PATH": dirs.joined(separator: ":")]
    // Forward Soul runtime roots so spawned agents resolve state the same
    // way the host process does. SOUL_REGISTRY remains for legacy scripts;
    // SOUL_HOME is the primary runtime home for new session/cache writes.
    env["SOUL_HOME"] = SoulRegistry.soulHomePath
    env["SOUL_REGISTRY"] = SoulRegistry.registryPath
    if let reg = ProcessInfo.processInfo.environment["SOUL_REGISTRY"], !reg.isEmpty {
        env["SOUL_REGISTRY"] = reg
    }
    // Also forward HOME so `~` expansion inside spawned kernel scripts
    // (pulse.py, soul_log_decision.py, soul_claude_finalize.py) resolves to
    // the same user the desktop app is running as.
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
        env["HOME"] = h
    }
    // Opt the spawned claude-agent-acp into Anthropic's 1M-context beta so
    // Opus 4.7 / Sonnet 4.x sessions get the full window instead of the
    // default 200k cap. The Anthropic SDK reads ANTHROPIC_BETAS as a
    // comma-separated list and forwards each entry as the `anthropic-beta`
    // header on every API call.
    if let existing = ProcessInfo.processInfo.environment["ANTHROPIC_BETAS"], !existing.isEmpty {
        env["ANTHROPIC_BETAS"] = existing.contains("context-1m") ? existing : "\(existing),context-1m-2025-08-07"
    } else {
        env["ANTHROPIC_BETAS"] = "context-1m-2025-08-07"
    }
    return env
}

/// Process-wide cache for resolved binary paths. The login-shell fallback
/// (`/bin/zsh -l -c 'command -v <tool>'`) takes 200-500ms because of `-l`
/// running .zshrc; clicking multiple sessions in quick succession used to
/// stack those calls on the @MainActor and beachball. Binary paths don't
/// change during a process lifetime, so cache the first result (positive
/// AND negative) and short-circuit thereafter.
private nonisolated(unsafe) var whichCache: [String: String?] = [:]
private let whichCacheLock = NSLock()

func which(_ tool: String) -> String? {
    whichCacheLock.lock()
    if let cached = whichCache[tool] {
        whichCacheLock.unlock()
        return cached
    }
    whichCacheLock.unlock()

    let resolved = whichUncached(tool)

    whichCacheLock.lock()
    whichCache[tool] = resolved
    whichCacheLock.unlock()
    return resolved
}

private func whichUncached(_ tool: String) -> String? {
    let home = NSHomeDirectory()
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var dirs = pathEnv.split(separator: ":").map(String.init)
    dirs.append(contentsOf: [
        "\(home)/bin",
        "\(home)/.local/bin",
        "\(home)/.nvm/versions/node/current/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ])
    for dir in dirs {
        let candidate = "\(dir)/\(tool)"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    if let shellPath = loginShellPath(),
       let resolved = runLoginShell(command: "command -v \(tool)", shell: shellPath)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !resolved.isEmpty,
       FileManager.default.isExecutableFile(atPath: resolved) {
        return resolved
    }
    return nil
}

private func loginShellPath() -> String? {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
}

private func runLoginShell(command: String, shell: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-l", "-c", command]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}
