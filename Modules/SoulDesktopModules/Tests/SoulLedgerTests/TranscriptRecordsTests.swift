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

    @Test("Gemini transcript preserves thoughts and tool preludes separately from final response")
    func geminiTranscriptSeparatesThoughtsAndFinalResponse() throws {
        let projectKey = "soul-ledger-gemini-\(UUID().uuidString.lowercased())"
        let sessionId = UUID().uuidString.lowercased()
        let chats = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/tmp/\(projectKey)/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp/\(projectKey)")
            )
        }

        let transcript = chats.appendingPathComponent("session-\(String(sessionId.prefix(8))).jsonl")
        let lines = [
            #"{"sessionId":"\#(sessionId)","projectHash":"test","startTime":"2026-06-24T20:00:00Z","kind":"main"}"#,
            #"{"id":"u1","timestamp":"2026-06-24T20:00:01Z","type":"user","content":[{"text":"check status"}]}"#,
            #"{"id":"g1","timestamp":"2026-06-24T20:00:02Z","type":"gemini","content":"I will inspect git status.","thoughts":[{"subject":"Plan","description":"Need to inspect before answering.","timestamp":"2026-06-24T20:00:02Z"}],"toolCalls":[{"name":"run_shell_command","args":{"command":"git status"}}]}"#,
            #"{"id":"g2","timestamp":"2026-06-24T20:00:03Z","type":"gemini","content":"Workspace is clean.","thoughts":[]}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let result = try #require(readGeminiTranscriptTurns(sessionId: sessionId, projectKey: projectKey))
        #expect(result.turns.count == 5)

        guard case .message(.user, "check status", _) = result.turns[0].content else {
            Issue.record("Expected user prompt")
            return
        }
        guard case .thought(let thought, _) = result.turns[1].content else {
            Issue.record("Expected structured Gemini thought")
            return
        }
        #expect(thought.contains("Plan"))
        #expect(thought.contains("Need to inspect before answering."))
        guard case .thought("I will inspect git status.", _) = result.turns[2].content else {
            Issue.record("Expected tool prelude as thought")
            return
        }
        guard case .tool(let tool, _) = result.turns[3].content else {
            Issue.record("Expected tool call")
            return
        }
        #expect(tool.name == "run_shell_command")
        guard case .message(.assistant, "Workspace is clean.", _) = result.turns[4].content else {
            Issue.record("Expected final Gemini response")
            return
        }
    }

    @Test("Gemini transcript treats content followed by updateToolCall as progress")
    func geminiTranscriptClassifiesSeparatedToolPreludeAsThought() throws {
        let projectKey = "soul-ledger-gemini-\(UUID().uuidString.lowercased())"
        let sessionId = UUID().uuidString.lowercased()
        let chats = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/tmp/\(projectKey)/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp/\(projectKey)")
            )
        }

        let transcript = chats.appendingPathComponent("session-\(String(sessionId.prefix(8))).jsonl")
        let lines = [
            #"{"sessionId":"\#(sessionId)","projectHash":"test","startTime":"2026-06-24T22:00:00Z","kind":"main"}"#,
            #"{"id":"u1","timestamp":"2026-06-24T22:00:01Z","type":"user","content":[{"text":"write the file"}]}"#,
            #"{"id":"g1","timestamp":"2026-06-24T22:00:02Z","type":"gemini","content":"I will write the complete cover_letter.html file.","thoughts":[]}"#,
            #"{"$updateToolCall":{"messageId":"m1","toolCall":{"id":"write_file__1","name":"write_file","args":{"file_path":"cover_letter.html"},"status":"success"},"status":"success","timestamp":"2026-06-24T22:00:03Z"}}"#,
            #"{"id":"g2","timestamp":"2026-06-24T22:00:04Z","type":"gemini","content":"The cover letter is ready.","thoughts":[]}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let result = try #require(readGeminiTranscriptTurns(sessionId: sessionId, projectKey: projectKey))
        #expect(result.turns.count == 4)

        guard case .message(.user, "write the file", _) = result.turns[0].content else {
            Issue.record("Expected user prompt")
            return
        }
        guard case .thought("I will write the complete cover_letter.html file.", _) = result.turns[1].content else {
            Issue.record("Expected separated tool prelude to become thought")
            return
        }
        guard case .tool(let tool, _) = result.turns[2].content else {
            Issue.record("Expected separated updateToolCall to become tool")
            return
        }
        #expect(tool.name == "write_file")
        #expect(tool.string("file_path") == "cover_letter.html")
        guard case .message(.assistant, "The cover letter is ready.", _) = result.turns[3].content else {
            Issue.record("Expected final Gemini response")
            return
        }
    }
}
