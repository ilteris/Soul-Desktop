import Foundation

struct HydrationResult {
    var env: [String: String] = [:]
    var log: [String] = []
}

enum SoulHydration {
    static let defaultSoulPath = NSHomeDirectory() + "/dotfiles/soul"

    static func prepare(provider: Provider,
                        projectKey: String,
                        projectPath: String,
                        sessionId: String,
                        soulPath: String = defaultSoulPath) async -> HydrationResult {
        switch provider {
        case .geminiCLI:
            return await hydrateGemini(
                projectKey: projectKey,
                sessionId: sessionId,
                soulPath: soulPath
            )
        case .claude:
            return await hydrateClaude(
                projectKey: projectKey,
                projectPath: projectPath,
                soulPath: soulPath
            )
        case .pi:
            return HydrationResult(
                env: [:],
                log: ["✓ Pi: hydration handled by soul-orchestrator extension at runtime"]
            )
        }
    }

    private static func hydrateGemini(projectKey: String,
                                      sessionId: String,
                                      soulPath: String) async -> HydrationResult {
        let outPath = "/tmp/soul_system_\(sessionId).md"
        let script  = "\(soulPath)/kernel/soul_hydrate.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return HydrationResult(log: ["✗ soul_hydrate.py not found at \(script)"])
        }
        let result = runPython(
            script: script,
            args: [projectKey,
                   "--target", "gemini",
                   "--out", outPath,
                   "--session-id", sessionId],
            extraEnv: ["SOUL_PROVIDER": "gemini"]
        )
        if result.status != 0 {
            return HydrationResult(log: [
                "✗ soul_hydrate.py exit=\(result.status)",
                "  stderr: \(result.stderr.prefix(400))"
            ])
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int ?? 0
        return HydrationResult(
            env: ["GEMINI_SYSTEM_MD": outPath],
            log: ["✓ Gemini: hydrated → \(outPath) (\(bytes)B)"]
        )
    }

    private static func hydrateClaude(projectKey: String,
                                      projectPath: String,
                                      soulPath: String) async -> HydrationResult {
        let outPath = "\(projectPath)/CLAUDE.md"
        let script  = "\(soulPath)/kernel/soul_claude_harness.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return HydrationResult(log: ["✗ soul_claude_harness.py not found at \(script)"])
        }
        let result = runPython(
            script: script,
            args: ["--project", projectKey, "--output", outPath],
            extraEnv: [:]
        )
        if result.status != 0 {
            return HydrationResult(log: [
                "✗ soul_claude_harness.py exit=\(result.status)",
                "  stderr: \(result.stderr.prefix(400))"
            ])
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int ?? 0
        return HydrationResult(log: ["✓ Claude: regenerated \(outPath) (\(bytes)B)"])
    }

    // MARK: - subprocess helper

    private struct RunResult { var status: Int32; var stdout: String; var stderr: String }

    private static func runPython(script: String,
                                  args: [String],
                                  extraEnv: [String: String]) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath())
        p.arguments = [script] + args

        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return RunResult(status: -1, stdout: "", stderr: "spawn failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            status: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func pythonPath() -> String {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/env"
    }
}
