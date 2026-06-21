import Foundation

struct HydrationResult {
    var env: [String: String] = [:]
    var log: [String] = []
}

enum SoulHydration {
    static let defaultSoulPath = NSHomeDirectory() + "/soul-cli/soul"

    static func prepare(provider: Provider,
                        projectKey: String,
                        projectPath: String,
                        sessionId: String,
                        soulPath: String = defaultSoulPath) async -> HydrationResult {
        switch provider {
        case .geminiCLI:
            return await hydrateGemini(
                projectKey: projectKey,
                projectPath: projectPath,
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
        case .codex:
            return await hydrateCodex(
                projectKey: projectKey,
                projectPath: projectPath,
                soulPath: soulPath
            )
        }
    }

    private static func hydrateGemini(projectKey: String,
                                      projectPath: String,
                                      sessionId: String,
                                      soulPath: String) async -> HydrationResult {
        // Unified hydration path: same generator that produces CLAUDE.md
        // (generate_harness in soul_claude_harness.py), thin wrapper writes
        // GEMINI.md to the project root. gemini-cli auto-discovers GEMINI.md
        // by walking from cwd to root — no env var needed.
        let outPath = "\(projectPath)/GEMINI.md"
        let script  = "\(soulPath)/kernel/soul_gemini_harness.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return HydrationResult(log: ["✗ soul_gemini_harness.py not found at \(script)"])
        }
        let result = await runPythonAsync(
            script: script,
            args: ["--project", projectKey, "--output", outPath],
            extraEnv: [:]
        )
        if result.status != 0 {
            return HydrationResult(log: [
                "✗ soul_gemini_harness.py exit=\(result.status)",
                "  stderr: \(result.stderr.prefix(400))"
            ])
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int ?? 0
        return HydrationResult(log: ["✓ Gemini: regenerated \(outPath) (\(bytes)B)"])
    }

    private static func hydrateClaude(projectKey: String,
                                      projectPath: String,
                                      soulPath: String) async -> HydrationResult {
        let outPath = "\(projectPath)/CLAUDE.md"
        let script  = "\(soulPath)/kernel/soul_claude_harness.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return HydrationResult(log: ["✗ soul_claude_harness.py not found at \(script)"])
        }
        let result = await runPythonAsync(
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

    private static func hydrateCodex(projectKey: String,
                                     projectPath: String,
                                     soulPath: String) async -> HydrationResult {
        let outPath = "\(projectPath)/AGENTS.md"
        let script = "\(soulPath)/kernel/soul_hydrate.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return HydrationResult(log: ["✗ soul_hydrate.py not found at \(script)"])
        }
        let result = await runPythonAsync(
            script: script,
            args: [projectKey, "--target", "codex", "--output", outPath],
            extraEnv: [:]
        )
        if result.status != 0 {
            return HydrationResult(log: [
                "✗ soul_hydrate.py --target codex exit=\(result.status)",
                "  stderr: \(result.stderr.prefix(400))"
            ])
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int ?? 0
        return HydrationResult(log: ["✓ Codex: regenerated \(outPath) (\(bytes)B)"])
    }

    /// Async wrapper that pushes the synchronous subprocess call off whatever
    /// actor called us. The Python harness can run for multiple seconds, so keep
    /// it detached from @MainActor and bound it through `SafeProcessRunner`.
    private static func runPythonAsync(script: String,
                                       args: [String],
                                       extraEnv: [String: String]) async -> RunResult {
        await Task.detached(priority: .userInitiated) {
            runPython(script: script, args: args, extraEnv: extraEnv)
        }.value
    }

    // MARK: - subprocess helper

    private struct RunResult { var status: Int32; var stdout: String; var stderr: String }

    private static func runPython(script: String,
                                  args: [String],
                                  extraEnv: [String: String]) -> RunResult {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        do {
            let result = try SafeProcessRunner.runSync(
                executable: pythonPath(),
                arguments: [script] + args,
                environment: env,
                timeoutSeconds: 30
            )
            return RunResult(
                status: result.status,
                stdout: String(data: result.stdout, encoding: .utf8) ?? "",
                stderr: result.timedOut
                    ? "python command timed out"
                    : String(data: result.stderr, encoding: .utf8) ?? ""
            )
        } catch {
            return RunResult(status: -1, stdout: "", stderr: "spawn failed: \(error.localizedDescription)")
        }
    }

    private static func pythonPath() -> String {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/env"
    }
}
