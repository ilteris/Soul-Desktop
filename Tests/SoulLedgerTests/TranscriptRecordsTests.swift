import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger transcript and replay records")
struct TranscriptRecordsTests {
    @Test("replay records pair delegation start with completion")
    func replayRecordsPairDelegations() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-replay-\(UUID().uuidString).jsonl")
        let contents = [
            #"{"event":"DelegationStarted","timestamp":"2026-05-25T15:10:11Z","delegation_id":"d1","specialist":"verifier","objective":"check"}"#,
            #"{"event":"DelegationCompleted","timestamp":"2026-05-25T15:10:12Z","delegation_id":"d1","finding_path":"/tmp/finding.md"}"#,
            #"{"event":"AfterAgent","timestamp":"2026-05-25T15:10:13Z","content":"done"}"#
        ].joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = readLedgerReplayRecords(atPath: url.path)

        #expect(records.count == 2)
        guard case .delegationStarted(let started, let completed)? = records.first?.kind else {
            Issue.record("Expected delegation replay record")
            return
        }
        #expect(started.delegationId == "d1")
        #expect(completed?.findingPath == "/tmp/finding.md")
    }

    @Test("transcript tool records preserve string arguments")
    func toolRecordsPreserveStringArguments() {
        let tool = LedgerToolRecord(
            name: "edit",
            arguments: [
                "file_path": .string("/tmp/file.swift"),
                "count": .number(3)
            ]
        )

        #expect(tool.string("file_path") == "/tmp/file.swift")
        #expect(tool.string("count") == nil)
    }

    @Test("strips Gemini referenced file expansion")
    func stripsGeminiReferencedFileExpansion() {
        let raw = """
        summarize @README.md

        --- Content from referenced files ---
        large file contents
        """

        #expect(stripLedgerGeminiReferencedFileBlock(raw) == "summarize @README.md")
    }
}
