//
//  Soul_DesktopTests.swift
//  Soul-DesktopTests
//
//  Created by ilteris kaplan on 5/9/26.
//

import Testing
@testable import Soul_Desktop

struct Soul_DesktopTests {

    @Test func testRunCaptureLargeOutputDoesNotDeadlock() async throws {
        // Running 'soul session list --json --include-machine --full' produces a very large JSON output,
        // which exercises SoulCLI's concurrent draining logic.
        let output = try await SoulCLI.runText(["session", "list", "--json", "--include-machine", "--full"])
        #expect(!output.isEmpty)
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
