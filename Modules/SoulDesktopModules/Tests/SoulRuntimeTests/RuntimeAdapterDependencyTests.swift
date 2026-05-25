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
            spawnResolver: { _, _ in nil }
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

    @Test("hydration result is UI-free data")
    func hydrationResultShape() {
        let result = RuntimeHydrationResult(
            env: ["SOUL": "1"],
            log: ["hydrated"]
        )

        #expect(result.env["SOUL"] == "1")
        #expect(result.log == ["hydrated"])
    }
}
