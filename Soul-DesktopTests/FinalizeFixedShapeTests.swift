import Testing
import Foundation
import SoulLedger
@testable import Soul_Desktop

/// Regression lock for the SOUL-093-class bug where the kernel's Finalize
/// event's `fixed` field drifted from `String` to `[String]`. The old strict
/// `String?` decode threw `typeMismatch` on the first array-shaped row and
/// — because `loadSessionListPayload` uses `try?` — silently nuked the
/// whole project's payload, leaving the sidebar empty for any project that
/// contained a single new-shape Finalize event.
///
/// If `fixed` drifts again (e.g. to an array of objects) this suite fails
/// loudly instead of producing the same "rows just disappear" symptom.
@Suite
struct FinalizeFixedShapeTests {

    private func decode(_ json: String) throws -> SessionListPayload {
        try JSONDecoder().decode(SessionListPayload.self, from: Data(json.utf8))
    }

    @Test
    func acceptsFixedAsString() throws {
        let json = """
        {"project":"p","sessions":[{
          "session_id":"00000000-0000-0000-0000-000000000001",
          "project":"p",
          "session_dir":"/tmp/p/s",
          "hooks_path":"/tmp/p/s/hooks.jsonl",
          "event_count":1,
          "finalize":{"fixed":"SOUL-001 SOUL-002"}
        }]}
        """
        let p = try decode(json)
        #expect(p.sessions.first?.finalize?.fixed == "SOUL-001 SOUL-002")
    }

    @Test
    func acceptsFixedAsArray() throws {
        let json = """
        {"project":"p","sessions":[{
          "session_id":"00000000-0000-0000-0000-000000000002",
          "project":"p",
          "session_dir":"/tmp/p/s",
          "hooks_path":"/tmp/p/s/hooks.jsonl",
          "event_count":1,
          "finalize":{"fixed":["SOUL-001","SOUL-002"]}
        }]}
        """
        let p = try decode(json)
        #expect(p.sessions.first?.finalize?.fixed == "SOUL-001\nSOUL-002")
    }

    @Test
    func acceptsFixedAsEmptyArray() throws {
        let json = """
        {"project":"p","sessions":[{
          "session_id":"00000000-0000-0000-0000-000000000003",
          "project":"p",
          "session_dir":"/tmp/p/s",
          "hooks_path":"/tmp/p/s/hooks.jsonl",
          "event_count":1,
          "finalize":{"fixed":[]}
        }]}
        """
        let p = try decode(json)
        #expect(p.sessions.first?.finalize?.fixed == nil)
    }

    @Test
    func acceptsFixedAbsent() throws {
        let json = """
        {"project":"p","sessions":[{
          "session_id":"00000000-0000-0000-0000-000000000004",
          "project":"p",
          "session_dir":"/tmp/p/s",
          "hooks_path":"/tmp/p/s/hooks.jsonl",
          "event_count":1,
          "finalize":{"intent":"ship it"}
        }]}
        """
        let p = try decode(json)
        #expect(p.sessions.first?.finalize?.fixed == nil)
        #expect(p.sessions.first?.finalize?.intent == "ship it")
    }

    /// The actual SOUL-093 failure mode: a payload with mixed shapes. The
    /// old decode threw on the first array row and lost ALL sessions
    /// including the well-formed ones. New decode must keep every session.
    @Test
    func mixedShapesDoNotPoisonWholePayload() throws {
        let json = """
        {"project":"p","sessions":[
          {"session_id":"00000000-0000-0000-0000-000000000005",
           "project":"p","session_dir":"/tmp/p/a","hooks_path":"/tmp/p/a/hooks.jsonl",
           "event_count":1,
           "finalize":{"fixed":"legacy string"}},
          {"session_id":"00000000-0000-0000-0000-000000000006",
           "project":"p","session_dir":"/tmp/p/b","hooks_path":"/tmp/p/b/hooks.jsonl",
           "event_count":1,
           "finalize":{"fixed":["SOUL-100","SOUL-101"]}},
          {"session_id":"00000000-0000-0000-0000-000000000007",
           "project":"p","session_dir":"/tmp/p/c","hooks_path":"/tmp/p/c/hooks.jsonl",
           "event_count":1,
           "finalize":null}
        ]}
        """
        let p = try decode(json)
        #expect(p.sessions.count == 3)
        #expect(p.sessions[0].finalize?.fixed == "legacy string")
        #expect(p.sessions[1].finalize?.fixed == "SOUL-100\nSOUL-101")
        #expect(p.sessions[2].finalize == nil)
    }
}
