import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger JSONL enumeration")
struct JSONLinesTests {
    @Test("enumerates newline and trailing JSONL records")
    func enumerateJSONLinesIncludesTrailingLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-ledger-\(UUID().uuidString).jsonl")
        let contents = #"{"a":1}"# + "\n" + #"{"b":2}"#
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var lines: [String] = []
        let stats = enumerateJSONLines(atPath: url.path) { data in
            lines.append(String(decoding: data, as: UTF8.self))
        }

        #expect(lines == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(stats.warnedCount == 0)
        #expect(stats.skippedCount == 0)
        #expect(stats.largestLineBytes == #"{"b":2}"#.utf8.count)
    }
}
