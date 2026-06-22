import Foundation
import Testing
@testable import SoulACP

@Suite("Codex app-server envelope encoding")
struct CodexClientEnvelopeTests {
    @Test("calls omit jsonrpc")
    func callEnvelopeOmitsJSONRPC() throws {
        let data = try CodexClient.makeCodexEnvelope(
            id: .int(1),
            method: "thread/start",
            params: .object(["cwd": .string("/tmp")])
        )
        let object = try decodeObject(data)

        #expect(object["jsonrpc"] == nil)
        #expect(object["id"] as? Int == 1)
        #expect(object["method"] as? String == "thread/start")
    }

    @Test("notifications omit jsonrpc")
    func notificationEnvelopeOmitsJSONRPC() throws {
        let data = try CodexClient.makeCodexEnvelope(
            id: nil,
            method: "initialized",
            params: .object([:])
        )
        let object = try decodeObject(data)

        #expect(object["jsonrpc"] == nil)
        #expect(object["id"] == nil)
        #expect(object["method"] as? String == "initialized")
    }

    @Test("responses omit jsonrpc")
    func responseEnvelopeOmitsJSONRPC() throws {
        let data = try CodexClient.makeCodexResponseEnvelope(
            id: .string("approval-1"),
            result: .object(["decision": .string("approved")])
        )
        let object = try decodeObject(data)

        #expect(object["jsonrpc"] == nil)
        #expect(object["id"] as? String == "approval-1")
        #expect(object["method"] == nil)
        #expect(object["result"] != nil)
    }

    @Test("requests decode when jsonrpc is omitted")
    func requestDecodesWithoutJSONRPCHeader() throws {
        let data = try #require("""
        {
          "id": 7,
          "method": "session/prompt",
          "params": {
            "sessionId": "session-1"
          }
        }
        """.data(using: .utf8))

        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)

        #expect(envelope.jsonrpc == nil)
        #expect(envelope.id == .int(7))
        #expect(envelope.method == "session/prompt")
        #expect(envelope.params?["sessionId"]?.stringValue == "session-1")
    }

    @Test("responses decode when jsonrpc is omitted")
    func responseDecodesWithoutJSONRPCHeader() throws {
        let data = try #require("""
        {
          "id": "approval-1",
          "result": {
            "decision": "approved"
          }
        }
        """.data(using: .utf8))

        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)

        #expect(envelope.jsonrpc == nil)
        #expect(envelope.id == .string("approval-1"))
        #expect(envelope.method == nil)
        #expect(envelope.result?["decision"]?.stringValue == "approved")
    }

    @Test("turn input preserves image attachments")
    func turnInputPreservesImageAttachments() throws {
        let input = CodexClient.codexTurnInput(
            text: "inspect this",
            attachments: [.image(mimeType: "image/png", base64: "abc123")]
        )

        #expect(input.count == 2)
        guard case .object(let text)? = input.first,
              case .object(let image)? = input.last else {
            Issue.record("Expected text and image input objects")
            return
        }
        #expect(text["type"]?.stringValue == "text")
        #expect(text["text"]?.stringValue == "inspect this")
        #expect(text["text_elements"] == .array([]))
        #expect(image["type"]?.stringValue == "image")
        #expect(image["url"]?.stringValue == "data:image/png;base64,abc123")
    }

    @Test("request timeout error is user readable")
    func requestTimeoutErrorIsUserReadable() throws {
        let error = CodexClientError.requestTimedOut(method: "turn/start", timeoutSeconds: 30)

        #expect(error.localizedDescription == "Codex request timed out: turn/start after 30s")
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }
}
