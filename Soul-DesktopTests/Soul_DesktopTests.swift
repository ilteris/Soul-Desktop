//
//  Soul_DesktopTests.swift
//  Soul-DesktopTests
//
//  Created by ilteris kaplan on 5/9/26.
//

import Testing
import Foundation
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

}
