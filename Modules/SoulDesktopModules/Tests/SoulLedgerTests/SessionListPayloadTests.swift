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

    @Test("decodes kernel session row contract fields")
    func decodesKernelSessionRowContractFields() throws {
        let data = Data("""
        {
          "session_id":"s",
          "raw_title":"<environment_context>",
          "title":"Fix sidebar contract",
          "session_visibility":"human",
          "session_kind":"conversation",
          "visibility_reason":"conversation",
          "provider":"gemini",
          "origin":"terminal",
          "writer":"terminal",
          "title_source":"first_prompt",
          "title_status":"provisional",
          "assistant_turn_count":3,
          "tool_call_count":4,
          "visible_turn_count":7,
          "has_conversation":true,
          "loadable":false,
          "replayable":true,
          "resume_strategy":"replay_only",
          "resume_target":"/tmp/session",
          "loadability_reason":"missing_provider_cache",
          "health":"partial",
          "health_reasons":["prompt_without_agent"],
          "lifecycle":"trashed",
          "trashed_at":"2026-05-25T20:10:00Z",
          "slash_semantics":{
            "clear":{
              "local_only":true,
              "conversation_worthy":false,
              "task_affecting":false,
              "title_worthy":false,
              "expansion_strategy":false
            },
            "pulse":{
              "local_only":false,
              "conversation_worthy":true,
              "task_affecting":true,
              "title_worthy":true,
              "expansion_strategy":"skill"
            }
          },
          "task_id":"SOUL-123",
          "task_status":"in_progress",
          "task_subject":"Lift sidebar contracts"
        }
        """.utf8)

        let record = try decodeLedgerSessionListRecord(from: data)

        #expect(record.raw_title == "<environment_context>")
        #expect(record.session_visibility == "human")
        #expect(record.session_kind == "conversation")
        #expect(record.visibility_reason == "conversation")
        #expect(record.provider == "gemini")
        #expect(record.origin == "terminal")
        #expect(record.writer == "terminal")
        #expect(record.title_source == "first_prompt")
        #expect(record.title_status == "provisional")
        #expect(record.assistant_turn_count == 3)
        #expect(record.tool_call_count == 4)
        #expect(record.visible_turn_count == 7)
        #expect(record.has_conversation == true)
        #expect(record.loadable == false)
        #expect(record.replayable == true)
        #expect(record.resume_strategy == "replay_only")
        #expect(record.resume_target == "/tmp/session")
        #expect(record.loadability_reason == "missing_provider_cache")
        #expect(record.health == "partial")
        #expect(record.health_reasons == ["prompt_without_agent"])
        #expect(record.lifecycle == "trashed")
        #expect(record.trashed_at == "2026-05-25T20:10:00Z")
        #expect(record.slash_semantics?["clear"]?.local_only == true)
        #expect(record.slash_semantics?["clear"]?.conversation_worthy == false)
        #expect(record.slash_semantics?["clear"]?.title_worthy == false)
        #expect(record.slash_semantics?["clear"]?.expansion_strategy == nil)
        #expect(record.slash_semantics?["pulse"]?.expansion_strategy == "skill")
        #expect(record.task_id == "SOUL-123")
        #expect(record.task_status == "in_progress")
        #expect(record.task_subject == "Lift sidebar contracts")
    }
}
