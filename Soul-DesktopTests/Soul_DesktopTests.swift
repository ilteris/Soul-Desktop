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

}
