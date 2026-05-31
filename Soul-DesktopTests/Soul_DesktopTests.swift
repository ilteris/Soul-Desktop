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
        // wedge against waitUntilExit() if the drain regressed. No `soul` binary / registry
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
