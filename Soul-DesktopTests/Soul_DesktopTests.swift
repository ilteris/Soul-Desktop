//
//  Soul_DesktopTests.swift
//  Soul-DesktopTests
//
//  Created by ilteris kaplan on 5/9/26.
//

import Testing
import Foundation
import SoulCore
@testable import Soul_Desktop

struct Soul_DesktopTests {

    @Test func testRunCaptureLargeOutputDoesNotDeadlock() async throws {
        // Exercises SoulCLI's concurrent stdout/stderr draining against a deterministic
        // large-output source. Drives `/bin/cat` over a generated temp file far larger than
        // a single pipe buffer (64KB on macOS), so a child that out-writes the buffer would
        // wedge if the drain regressed. No `soul` binary / registry
        // dependency, so it can't fast-fail under parallel test contention — the prior flake.
        let bytes = 8 * 1024 * 1024  // 8 MB ≫ 64KB pipe buffer
        let payload = Data(repeating: 0x41 /* 'A' */, count: bytes)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soulcli-drain-\(UUID().uuidString).bin")
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let capture = try await SoulCLI.captureProcess(
            executable: "/bin/cat",
            arguments: [tmp.path]
        )

        #expect(capture.status == 0)
        #expect(capture.stdout.count == bytes)  // byte-exact: nothing dropped or truncated by the drain
        #expect(capture.stderr.isEmpty)
    }

    @Test func safeProcessRunnerCapturesStdinAndStderr() async throws {
        let input = Data("hello runner".utf8)
        let result = try await SafeProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "cat; printf 'warn' >&2"],
            stdin: input,
            timeoutSeconds: 5
        )

        #expect(result.status == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello runner")
        #expect(String(data: result.stderr, encoding: .utf8) == "warn")
        #expect(result.timedOut == false)
    }

    @Test func safeProcessRunnerTimesOutHungChild() async throws {
        let result = try await SafeProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeoutSeconds: 0.2
        )

        #expect(result.status == SafeProcessRunner.timeoutStatus)
        #expect(result.timedOut == true)
    }

    @Test func registryWatcherFloorsFullRescanCadence() throws {
        let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
        let lastFire = DispatchTime(uptimeNanoseconds: 9_000_000_000)

        let deadline = RegistryWatcher.nextFireDeadline(
            now: now,
            lastFireAt: lastFire,
            debounceInterval: 0.25,
            minimumFireInterval: 5
        )

        #expect(deadline.uptimeNanoseconds == 14_000_000_000)
    }

    @Test func registryWatcherUsesDebounceWhenMinimumCadenceElapsed() throws {
        let now = DispatchTime(uptimeNanoseconds: 20_000_000_000)
        let lastFire = DispatchTime(uptimeNanoseconds: 10_000_000_000)

        let deadline = RegistryWatcher.nextFireDeadline(
            now: now,
            lastFireAt: lastFire,
            debounceInterval: 0.25,
            minimumFireInterval: 5
        )

        #expect(deadline.uptimeNanoseconds == 20_250_000_000)
    }

    @Test func testCompactSlashCommandIsRecognized() throws {
        // SOUL-SOUL_DESKTOP-359: /compact must parse as a slash command and
        // be classified as a Soul command so the composer intercepts it
        // (routes to forceCompact) rather than shipping it to the agent.
        #expect(SlashCommandParse.parse("/compact").commandName == "compact")
        #expect(SlashCommandParse.parse("/compact ").commandName == "compact")
        #expect(SlashCommand.compact.isSoulSlashCommand)
        #expect(SlashCommand.compact.name == "compact")
        // A bare prompt is not mistaken for the command.
        #expect(SlashCommandParse.parse("compact the code please").commandName == nil)
    }

    @Test func testNativeCompactDirectiveParsing() throws {
        let jsonStr = """
        {
            "action": "native_compact",
            "method": "thread/compact/start",
            "banner": "Compacting Codex context…",
            "provider": "codex"
        }
        """
        guard let data = jsonStr.data(using: .utf8),
              let directive = AutoCompactController.Directive.parse(data)
        else {
            Issue.record("Failed to parse native_compact directive")
            return
        }
        if case .nativeCompact(let method, let banner) = directive {
            #expect(method == "thread/compact/start")
            #expect(banner == "Compacting Codex context…")
        } else {
            Issue.record("Parsed directive was not .nativeCompact")
        }
    }

    @Test func testContextUsageFractionIsLinear() throws {
        // The donut ring draws straight off `fraction` — spent/budget, no
        // nonlinear curve. 79k / 1M must read as ~8% of the ring, not the
        // inflated 60%-knee value the old visualFraction produced.
        let small = ContextUsage(tokens: 79_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(abs(small.fraction - 0.079) < 1e-9)

        let half = ContextUsage(tokens: 100_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(half.fraction == 0.5)

        let full = ContextUsage(tokens: 200_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(full.fraction == 1.0)

        // Clamps at 1.0 even when tokens exceed the budget.
        let over = ContextUsage(tokens: 1_200_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(over.fraction == 1.0)

        let zero = ContextUsage(tokens: 0, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(zero.fraction == 0.0)
    }

    // MARK: - SOUL-379 Codex stream-coalescing contract
    //
    // Pins the drain-ordering invariant the adversarial audit of 2b8f1b2
    // flagged as untested: a future edit that breaks coalescing or the
    // finalize guard now fails a red test instead of silently regressing.

    private static func codexTestProject() -> SoulProject {
        SoulProject(id: "test", name: "Test", path: "/tmp/soul-test",
                    pillar: nil, tier: nil, status: nil,
                    primaryHost: nil, devCommand: nil, devURL: nil)
    }

    @MainActor
    @Test func codexCoalesceBuffersDeltasOffGraphThenFlushesOnce() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let uuid = UUID()
        controller.codexItemMap = ["c1": uuid]
        controller.agentStreamBuffer.registerCodexItem(itemId: "c1", id: uuid, kind: .message, initialText: "")

        controller.enqueueCodexDelta(itemId: "c1", delta: "Hel", kind: .agentText)
        controller.enqueueCodexDelta(itemId: "c1", delta: "lo", kind: .agentText)

        // Pre-flush: the observed transcript is untouched; deltas live in buffers.
        #expect(controller.items.isEmpty)
        #expect(controller.pendingCodexOrder == ["c1"])

        controller.flushPendingCodexDeltas()

        // Post-flush: deltas have moved into the stream buffer, not the
        // observed transcript. Materialization is the explicit UI boundary.
        #expect(controller.items.isEmpty)
        controller.materializeBufferedAgentStreams()
        guard case .agentMessage(_, let post, let complete, _) = controller.items[0] else {
            Issue.record("expected agentMessage"); return
        }
        #expect(post == "Hello")
        #expect(complete == true)
        #expect(controller.pendingCodexOrder.isEmpty)
        #expect(controller.codexFlushScheduled == false)
    }

    @MainActor
    @Test func codexCoalesceKeepsPerItemTextAndIsIdempotent() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let a = UUID(); let b = UUID()
        controller.codexItemMap = ["a": a, "b": b]
        controller.agentStreamBuffer.registerCodexItem(itemId: "a", id: a, kind: .message, initialText: "")
        controller.agentStreamBuffer.registerCodexItem(itemId: "b", id: b, kind: .thought, initialText: "")

        // Interleaved deltas for two items accumulate independently.
        controller.enqueueCodexDelta(itemId: "a", delta: "ans", kind: .agentText)
        controller.enqueueCodexDelta(itemId: "b", delta: "rea", kind: .reasoning)
        controller.enqueueCodexDelta(itemId: "a", delta: "wer", kind: .agentText)
        controller.flushPendingCodexDeltas()
        #expect(controller.items.isEmpty)
        controller.materializeBufferedAgentStreams()

        guard case .agentMessage(_, let aText, _, _) = controller.items[0],
              case .agentThought(_, let bText, _, _) = controller.items[1] else {
            Issue.record("unexpected item shapes"); return
        }
        #expect(aText == "answer")
        #expect(bText == "rea")

        // A second flush with an empty buffer is a no-op (text unchanged).
        controller.flushPendingCodexDeltas()
        guard case .agentMessage(_, let aText2, _, _) = controller.items[0] else {
            Issue.record("unexpected"); return
        }
        #expect(aText2 == "answer")
    }

    @MainActor
    @Test func codexCoalesceLateDeltaDoesNotReopenCompletedBubble() throws {
        // The finalize-guard hardening: a stray delta arriving after the bubble
        // finalized must not flip complete:true back to false or append text.
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let uuid = UUID()
        controller.items = [.agentMessage(id: uuid, text: "done", complete: true, timestamp: Date())]
        controller.codexItemMap = ["c1": uuid]

        controller.enqueueCodexDelta(itemId: "c1", delta: " extra", kind: .agentText)
        controller.flushPendingCodexDeltas()

        guard case .agentMessage(_, let text, let complete, _) = controller.items[0] else {
            Issue.record("expected agentMessage"); return
        }
        #expect(text == "done")   // late delta dropped
        #expect(complete == true) // bubble stays finalized
    }

    @Test func codexContextWindowResolvesConfiguredModelMaxFromProviderCache() throws {
        let dir = try Self.makeTemporaryDirectory()
        let config = dir.appendingPathComponent("config.toml")
        let cache = dir.appendingPathComponent("models_cache.json")

        try """
        model = "gpt-5.4"
        model_reasoning_effort = "low"

        [projects."/tmp/project"]
        trust_level = "trusted"
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        {
          "models": [
            {
              "slug": "gpt-5.4",
              "context_window": 272000,
              "max_context_window": 1000000
            }
          ]
        }
        """.write(to: cache, atomically: true, encoding: .utf8)

        #expect(CodexContextWindowResolver.resolve(
            configPath: config.path,
            modelsCachePath: cache.path
        ) == 1_000_000)
    }

    @Test func codexConfiguredModelIgnoresProjectSections() throws {
        let dir = try Self.makeTemporaryDirectory()
        let config = dir.appendingPathComponent("config.toml")

        try """
        model = "gpt-5.4"

        [projects."/tmp/project"]
        model = "gpt-5.4-mini"
        """.write(to: config, atomically: true, encoding: .utf8)

        #expect(CodexContextWindowResolver.configuredModel(in: config.path) == "gpt-5.4")
    }

    @MainActor
    @Test func codexTokenUsagePrefersProviderContextWindow() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())

        controller.applyCodexTokenUsage(
            lastTotalTokens: 123_456,
            modelContextWindow: 258_000,
            providerContextWindow: 1_000_000
        )

        #expect(controller.codexTokensUsed == 123_456)
        #expect(controller.codexContextWindow == 1_000_000)
    }

    @MainActor
    @Test func codexTokenUsageFallsBackToLiveEventWindow() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        controller.didResolveCodexProviderContextWindow = true
        controller.codexProviderContextWindow = nil

        controller.applyCodexTokenUsage(
            lastTotalTokens: 1_200_000,
            modelContextWindow: 272_000,
            providerContextWindow: nil
        )

        #expect(controller.codexTokensUsed == 1_200_000)
        #expect(controller.codexContextWindow == 272_000)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoulDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}
