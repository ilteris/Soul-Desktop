import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger raw record readers")
struct LedgerRecordsTests {
    @Test("parses ISO and local ledger timestamps")
    func parseTimestamps() throws {
        let iso = try #require(parseLedgerTimestamp("2026-05-25T15:10:11.123Z"))
        #expect(iso.timeIntervalSince1970 > 0)

        let local = try #require(parseLedgerTimestamp("2026-05-25T15:10:11.123456"))
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: local) == 2026)
        #expect(parseLedgerTimestamp(nil) == nil)
    }

    @Test("reads timestamped hooks records")
    func readsTimestampedHookRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-hooks-\(UUID().uuidString).jsonl")
        let contents = [
            #"{"event":"UserPrompt","timestamp":"2026-05-25T15:10:11Z","text":"hello"}"#,
            #"{"event":"AfterAgent","timestamp":"2026-05-25T15:10:12Z","content":"world"}"#,
            #"{"event":"MissingTimestamp","text":"skip"}"#
        ].joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = readHookRecords(atPath: url.path)

        #expect(records.map(\.event) == ["UserPrompt", "AfterAgent"])
        guard case .userPrompt(let userPrompt)? = records.first?.payload else {
            Issue.record("Expected UserPrompt payload")
            return
        }
        #expect(userPrompt.text == "hello")
        guard case .afterAgent(let afterAgent)? = records.dropFirst().first?.payload else {
            Issue.record("Expected AfterAgent payload")
            return
        }
        #expect(afterAgent.content == "world")
    }

    @Test("typed hook payloads cover replay events and unknown fallback")
    func typedHookPayloads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-typed-hooks-\(UUID().uuidString).jsonl")
        let contents = [
            #"{"event":"AfterTool","timestamp":"2026-05-25T15:10:11Z","tool":"Bash","target":"swift test","rationale":"run tests","reward":0.5}"#,
            #"{"event":"BranchSummary","timestamp":"2026-05-25T15:10:12Z","summary":"handoff","from_provider":"claude","to_provider":"geminiCLI"}"#,
            #"{"event":"DelegationStarted","timestamp":"2026-05-25T15:10:13Z","delegation_id":"d1","specialist":"verifier","objective":"check","color":"ff00aa"}"#,
            #"{"event":"DelegationCompleted","timestamp":"2026-05-25T15:10:14Z","delegation_id":"d1","finding_path":"/tmp/finding.md"}"#,
            #"{"event":"CodexApproval","timestamp":"2026-05-25T15:10:15Z","op":"APPROVAL","intent":"allow command"}"#,
            #"{"event":"CustomDecision","timestamp":"2026-05-25T15:10:16Z","op":"NOTE","intent":"custom"}"#,
            #"{"event":"SESSION_START","timestamp":"2026-05-25T15:10:17Z"}"#,
            #"{"event":"Unrecognized","timestamp":"2026-05-25T15:10:18Z","value":1}"#
        ].joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = readHookRecords(atPath: url.path)

        guard case .afterTool(let tool) = records[0].payload else {
            Issue.record("Expected AfterTool payload")
            return
        }
        #expect(tool.tool == "Bash")
        #expect(tool.target == "swift test")
        #expect(tool.rationale == "run tests")
        #expect(tool.reward == 0.5)

        guard case .branchSummary(let branch) = records[1].payload else {
            Issue.record("Expected BranchSummary payload")
            return
        }
        #expect(branch.summary == "handoff")
        #expect(branch.fromProvider == "claude")
        #expect(branch.toProvider == "geminiCLI")

        guard case .delegationStarted(let started) = records[2].payload else {
            Issue.record("Expected DelegationStarted payload")
            return
        }
        #expect(started.delegationId == "d1")
        #expect(started.specialist == "verifier")
        #expect(started.objective == "check")
        #expect(started.color == "ff00aa")

        guard case .delegationCompleted(let completed) = records[3].payload else {
            Issue.record("Expected DelegationCompleted payload")
            return
        }
        #expect(completed.delegationId == "d1")
        #expect(completed.findingPath == "/tmp/finding.md")

        guard case .codexApproval(let approval) = records[4].payload else {
            Issue.record("Expected CodexApproval payload")
            return
        }
        #expect(approval.op == "APPROVAL")
        #expect(approval.intent == "allow command")

        guard case .decision(let decision) = records[5].payload else {
            Issue.record("Expected generic decision payload")
            return
        }
        #expect(decision.event == "CustomDecision")
        #expect(decision.op == "NOTE")
        #expect(decision.intent == "custom")

        guard case .metadata(let metadataEvent) = records[6].payload else {
            Issue.record("Expected metadata payload")
            return
        }
        #expect(metadataEvent == "SESSION_START")

        guard case .unknown(let unknownEvent) = records[7].payload else {
            Issue.record("Expected unknown payload")
            return
        }
        #expect(unknownEvent == "Unrecognized")
    }

    @Test("reads agent chunk records")
    func readsAgentChunkRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-agent-chunks-\(UUID().uuidString).jsonl")
        let contents = [
            #"{"bubble_id":"b1","chunk":"hel","ts":"2026-05-25T15:10:11Z"}"#,
            #"{"bubble_id":"b1","chunk":"lo","ts":"2026-05-25T15:10:12Z"}"#,
            #"{"bubble_id":"missing-chunk"}"#
        ].joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = readAgentChunkRecords(atPath: url.path)

        #expect(records.count == 2)
        #expect(records.map(\.chunk) == ["hel", "lo"])
        #expect(records.allSatisfy { $0.bubbleId == "b1" })
        #expect(records.allSatisfy { $0.timestamp != nil })
    }
}
