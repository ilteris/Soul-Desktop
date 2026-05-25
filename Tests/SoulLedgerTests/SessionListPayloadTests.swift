import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger session list payload decoding")
struct SessionListPayloadTests {
    private func decode(_ json: String) throws -> LedgerSessionListPayload {
        try decodeLedgerSessionListPayload(from: Data(json.utf8))
    }

    @Test("accepts finalize fixed as string")
    func acceptsFixedAsString() throws {
        let payload = try decode("""
        {"project":"p","sessions":[{"session_id":"s","finalize":{"fixed":"SOUL-001 SOUL-002"}}]}
        """)

        #expect(payload.sessions.first?.finalize?.fixed == "SOUL-001 SOUL-002")
    }

    @Test("accepts finalize fixed as array")
    func acceptsFixedAsArray() throws {
        let payload = try decode("""
        {"project":"p","sessions":[{"session_id":"s","finalize":{"fixed":["SOUL-001","SOUL-002"]}}]}
        """)

        #expect(payload.sessions.first?.finalize?.fixed == "SOUL-001\nSOUL-002")
    }

    @Test("accepts finalize fixed as empty array")
    func acceptsFixedAsEmptyArray() throws {
        let payload = try decode("""
        {"project":"p","sessions":[{"session_id":"s","finalize":{"fixed":[]}}]}
        """)

        #expect(payload.sessions.first?.finalize?.fixed == nil)
    }

    @Test("decodes session show record")
    func decodesSessionShowRecord() throws {
        let data = Data("""
        {"session_id":"s","prompt_count":2,"native_session_ids":{"claude":"native"}}
        """.utf8)

        let record = try decodeLedgerSessionListRecord(from: data)

        #expect(record.session_id == "s")
        #expect(record.prompt_count == 2)
        #expect(record.native_session_ids?["claude"] == "native")
    }
}
