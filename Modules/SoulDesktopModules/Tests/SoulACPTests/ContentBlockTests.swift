import Foundation
import Testing
@testable import SoulACP

@Suite("ACP content block encoding")
struct ContentBlockTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("text blocks round trip")
    func textBlockRoundTrip() throws {
        let data = try encoder.encode(ContentBlock.text("hello ACP"))
        let object = try decodeObject(data)

        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "hello ACP")

        let decoded = try decoder.decode(ContentBlock.self, from: data)
        #expect(decoded == .text("hello ACP"))
    }

    @Test("image blocks round trip")
    func imageBlockRoundTrip() throws {
        let block = ContentBlock.image(mimeType: "image/png", base64: "aW1hZ2U=")
        let data = try encoder.encode(block)
        let object = try decodeObject(data)

        #expect(object["type"] as? String == "image")
        #expect(object["mimeType"] as? String == "image/png")
        #expect(object["data"] as? String == "aW1hZ2U=")

        let decoded = try decoder.decode(ContentBlock.self, from: data)
        #expect(decoded == block)
    }

    private func decodeObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }
}
