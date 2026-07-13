import Foundation
import Testing
@testable import SoulACP

@Suite("ACP transport environment")
struct ACPTransportEnvironmentTests {
    @Test("required TCP authority child process receives finalize promotion")
    func requiredTCPAuthorityChildReceivesFinalizePromotion() async throws {
        let transport = ACPTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "env; sleep 0.1"],
            environment: [
                "SOUL_REGISTRY_AUTHORITY": "required",
                "SOUL_REGISTRY_AUTHORITY_URL": "tcp://100.123.210.64:4720",
            ],
            scrubEnvKeys: ["SOUL_FINALIZE_PROMOTE_AUTHORITY"]
        )
        let lines = await transport.incomingLines
        let termination = await transport.terminationEvents
        let output = Task { () -> [String] in
            var result: [String] = []
            for await line in lines {
                result.append(line)
            }
            return result
        }

        try await transport.start()
        for await _ in termination { break }
        let envLines = await output.value

        #expect(envLines.contains("SOUL_FINALIZE_PROMOTE_AUTHORITY=1"))
    }
}
