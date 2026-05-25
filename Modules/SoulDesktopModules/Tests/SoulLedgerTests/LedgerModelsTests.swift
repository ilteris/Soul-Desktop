import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger models")
struct LedgerModelsTests {
    @Test("live external sessions are not safely resumable until stale")
    func liveExternalResumeGate() {
        let fresh = LedgerSession(
            id: "s1",
            project: "soul-desktop",
            timestamp: Date(timeIntervalSince1970: 1),
            isLive: true,
            writer: .external,
            isStale: false
        )
        let stale = LedgerSession(
            id: "s1",
            project: "soul-desktop",
            timestamp: Date(timeIntervalSince1970: 1),
            isLive: true,
            writer: .external,
            isStale: true
        )

        #expect(fresh.canSafelyResume == false)
        #expect(stale.canSafelyResume == true)
    }

    @Test("ledger models codable round trip")
    func codableRoundTrip() throws {
        let session = LedgerSession(
            id: "s2",
            project: "soul-desktop",
            timestamp: Date(timeIntervalSince1970: 42),
            intent: "Migrate ledger",
            writer: .soulDesktop,
            worktreePath: "/tmp/worktree",
            replayable: true
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(LedgerSession.self, from: data)

        #expect(decoded == session)
        #expect(decoded.canSafelyResume)
    }
}
