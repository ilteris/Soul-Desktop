import Testing
import SoulCore
@testable import SoulRuntime

@Suite("SoulRuntime adapter dependencies")
struct RuntimeAdapterDependencyTests {
    @Test("ACP runtime stays idle and reports missing spawn without app types")
    func acpRuntimeMissingSpawn() async {
        let runtime = ACPProviderRuntimeAdapter(
            provider: .claude,
            projectKey: "project",
            provisionalSessionID: "kernel",
            spawnResolver: { _, _ in nil },
            hydrationPreparer: { _, _, _, _ in RuntimeHydrationResult() }
        )

        await #expect(runtime.isStarted == false)
        await #expect(throws: (any Error).self) {
            _ = try await runtime.start(ProviderRuntimeStartRequest(
                session: ProviderRuntimeSession(
                    provider: .claude,
                    projectPath: "/tmp/project",
                    kernelSessionID: "kernel"
                )
            ))
        }
        await runtime.stop()
        await #expect(runtime.isStarted == false)
    }

    @Test("Codex runtime stays idle and reports missing spawn without app types")
    func codexRuntimeMissingSpawn() async {
        let runtime = CodexProviderRuntimeAdapter(
            projectKey: "project",
            spawnResolver: { _, _ in nil },
            hydrationPreparer: { _, _, _, _ in RuntimeHydrationResult() }
        )

        await #expect(runtime.isStarted == false)
        await #expect(throws: (any Error).self) {
            _ = try await runtime.start(ProviderRuntimeStartRequest(
                session: ProviderRuntimeSession(
                    provider: .codex,
                    projectPath: "/tmp/project",
                    kernelSessionID: "kernel"
                )
            ))
        }
        await runtime.stop()
        await #expect(runtime.isStarted == false)
    }

    @Test("Codex runtime hydrates before launching app server")
    func codexRuntimeHydratesBeforeLaunch() async {
        let probe = HydrationProbe()
        let runtime = CodexProviderRuntimeAdapter(
            projectKey: "project",
            spawnResolver: { _, _ in
                ACPProviderSpawn(executablePath: "/usr/bin/false", arguments: [])
            },
            hydrationPreparer: { provider, projectKey, projectPath, sessionID in
                await probe.record(
                    provider: provider,
                    projectKey: projectKey,
                    projectPath: projectPath,
                    sessionID: sessionID
                )
                return RuntimeHydrationResult()
            }
        )

        await #expect(throws: (any Error).self) {
            _ = try await runtime.start(ProviderRuntimeStartRequest(
                session: ProviderRuntimeSession(
                    provider: .codex,
                    projectPath: "/tmp/project",
                    kernelSessionID: "kernel"
                )
            ))
        }

        let calls = await probe.calls
        #expect(calls.count == 1)
        #expect(calls.first?.provider == .codex)
        #expect(calls.first?.projectKey == "project")
        #expect(calls.first?.projectPath == "/tmp/project")
        #expect(calls.first?.sessionID == "kernel")
    }

    @Test("hydration result is UI-free data")
    func hydrationResultShape() {
        let result = RuntimeHydrationResult(
            env: ["SOUL": "1"],
            log: ["hydrated"]
        )

        #expect(result.env["SOUL"] == "1")
        #expect(result.log == ["hydrated"])
    }

    @Test("ACP runtime exports resolved workspace environment")
    func acpRuntimeWorkspaceEnvironment() {
        let workspace = "/tmp/SOUL-JOB_HUNT-052"
        let env = ACPProviderRuntimeAdapter.applyWorkspaceEnvironment(
            ["PWD": "/tmp/wrong", "CODER_AGENT_WORKSPACE_PATH": "/tmp/wrong"],
            projectKey: "job-hunt",
            workspacePath: workspace,
            kernelSessionID: "kernel-123"
        )

        #expect(env["SOUL_PROJECT"] == "job-hunt")
        #expect(env["SOUL_PROJECT_PATH"] == workspace)
        #expect(env["SOUL_WORKSPACE_PATH"] == workspace)
        #expect(env["SOUL_DESKTOP_WORKSPACE_PATH"] == workspace)
        #expect(env["CODER_AGENT_WORKSPACE_PATH"] == workspace)
        #expect(env["PWD"] == workspace)
        #expect(env["SOUL_SESSION_ID"] == "kernel-123")
    }
}

private actor HydrationProbe {
    struct Call: Equatable {
        var provider: AgentProvider
        var projectKey: String
        var projectPath: String
        var sessionID: String
    }

    private(set) var calls: [Call] = []

    func record(provider: AgentProvider, projectKey: String, projectPath: String, sessionID: String) {
        calls.append(Call(provider: provider, projectKey: projectKey, projectPath: projectPath, sessionID: sessionID))
    }
}
