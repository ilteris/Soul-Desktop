import Foundation

struct ACPProviderSpawn {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]?
    var scrubEnvKeys: [String] = []
    var cwd: String? = nil

    static func resolve(_ provider: Provider) -> ACPProviderSpawn? {
        let env = enrichedEnvironment()
        switch provider {
        case .geminiCLI:
            guard let path = which("gemini") else { return nil }
            return .init(executablePath: path, arguments: ["--acp"], environment: env)
        case .pi:
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
        }
    }
}

private func enrichedEnvironment() -> [String: String] {
    let home = NSHomeDirectory()
    let extras = [
        "\(home)/bin",
        "\(home)/.local/bin",
        "\(home)/.bun/bin",
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
    return ["PATH": dirs.joined(separator: ":")]
}

private func which(_ tool: String) -> String? {
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
