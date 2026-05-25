import Foundation
import Testing
@testable import SoulACP

@Suite("ACP session update decoding")
struct SessionUpdateTests {
    private let decoder = JSONDecoder()

    @Test("agent message text chunks decode")
    func agentMessageTextChunkDecodes() throws {
        let update = try decodeSessionUpdate("""
        {
          "sessionUpdate": "agent_message_chunk",
          "content": {
            "type": "text",
            "text": "hello from provider"
          }
        }
        """)

        guard case .agentMessageChunk(.text(let text)) = update else {
            Issue.record("Expected agent message text chunk, got \(update)")
            return
        }
        #expect(text == "hello from provider")
    }

    @Test("tool call payloads are preserved")
    func toolCallPayloadPreserved() throws {
        let update = try decodeSessionUpdate("""
        {
          "sessionUpdate": "tool_call",
          "toolCallId": "tool-1",
          "title": "Read file",
          "rawInput": {
            "path": "/tmp/example.txt"
          }
        }
        """)

        guard case .toolCall(.object(let payload)) = update else {
            Issue.record("Expected tool call payload, got \(update)")
            return
        }
        #expect(payload["sessionUpdate"]?.stringValue == "tool_call")
        #expect(payload["toolCallId"]?.stringValue == "tool-1")
        #expect(payload["title"]?.stringValue == "Read file")
        #expect(payload["rawInput"]?["path"]?.stringValue == "/tmp/example.txt")
    }

    @Test("unknown update payloads are preserved")
    func unknownPayloadPreserved() throws {
        let update = try decodeSessionUpdate("""
        {
          "sessionUpdate": "provider_specific_update",
          "answer": 42
        }
        """)

        guard case .unknown(let kind, .object(let payload)) = update else {
            Issue.record("Expected unknown payload, got \(update)")
            return
        }
        #expect(kind == "provider_specific_update")
        guard case .int(let answer)? = payload["answer"] else {
            Issue.record("Expected integer answer payload, got \(String(describing: payload["answer"]))")
            return
        }
        #expect(answer == 42)
    }

    private func decodeSessionUpdate(_ json: String) throws -> SessionUpdate {
        let data = try #require(json.data(using: .utf8))
        return try decoder.decode(SessionUpdate.self, from: data)
    }
}
