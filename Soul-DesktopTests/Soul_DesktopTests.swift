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

    @Test func testContextUsageVisualFraction() throws {
        // 1. Claude/standard linear scaling (max < 1M)
        let claudeHalf = ContextUsage(tokens: 100_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(claudeHalf.fraction == 0.5)
        #expect(claudeHalf.visualFraction == 0.5)

        let claudeFull = ContextUsage(tokens: 200_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(claudeFull.fraction == 1.0)
        #expect(claudeFull.visualFraction == 1.0)

        // 2. Gemini piece-wise scaling (max >= 1M)
        let geminiZero = ContextUsage(tokens: 0, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(geminiZero.fraction == 0.0)
        #expect(geminiZero.visualFraction == 0.0)

        // 50k is exactly half of the 100k soft threshold, so it should map to 30% visual fraction (0.5 * 0.6)
        let geminiSoftHalf = ContextUsage(tokens: 50_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(geminiSoftHalf.fraction == 0.05)
        #expect(geminiSoftHalf.visualFraction == 0.3)

        // 100k is exactly the soft threshold, so it should map to 60% visual fraction
        let geminiThreshold = ContextUsage(tokens: 100_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(geminiThreshold.fraction == 0.1)
        #expect(geminiThreshold.visualFraction == 0.6)

        // 550k is halfway in the upper range (100k to 1M), so it should map to 80% (0.6 + 0.5 * 0.4)
        let geminiUpperHalf = ContextUsage(tokens: 550_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(geminiUpperHalf.fraction == 0.55)
        #expect(abs(geminiUpperHalf.visualFraction - 0.8) < 1e-9)
    }

}
