import Foundation
import Testing
import SoulCore
import SoulLedger

/// SOUL-SOUL_DESKTOP-360: the hooks+transcript timeline merge moved into
/// SoulLedger as `LedgerReplayMerge.merge`. These exercise it directly against
/// on-disk fixtures — the bug-prone parts (timestamp ordering, agent-chunk
/// recovery + dedup, duplicate-bubble collapse) that were previously only
/// reachable through the app target.
@Suite("SoulLedger replay merge")
struct ReplayMergeTests {

    /// Writes lines to a fresh temp dir and returns (hooksPath, sessionDir).
    private func fixture(hooks: [String], chunks: [String]? = nil) throws -> (hooksPath: String, sessionDir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hooksURL = dir.appendingPathComponent("hooks.jsonl")
        try hooks.joined(separator: "\n").write(to: hooksURL, atomically: true, encoding: .utf8)
        if let chunks {
            let chunkURL = dir.appendingPathComponent("agent_chunks.jsonl")
            try chunks.joined(separator: "\n").write(to: chunkURL, atomically: true, encoding: .utf8)
        }
        return (hooksURL.path, dir.path)
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func merge(_ f: (hooksPath: String, sessionDir: String)) -> [ReplayEvent] {
        // projectKey/projectPath are dummies: the Claude/Gemini transcript
        // readers resolve ~/.claude and ~/.gemini paths that don't exist for a
        // temp session, so they return empty and don't perturb the timeline.
        LedgerReplayMerge.merge(
            sessionId: "sess",
            projectKey: "proj",
            projectPath: "/tmp/nonexistent-\(UUID().uuidString)",
            hooksPath: f.hooksPath,
            sessionDir: f.sessionDir
        )
    }

    @Test("merges hooks records and sorts by timestamp")
    func mergesAndSortsByTimestamp() throws {
        // Written out of chronological order on purpose.
        let f = try fixture(hooks: [
            #"{"event":"AfterAgent","timestamp":"2026-05-25T15:00:03Z","content":"the answer"}"#,
            #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"the question"}"#,
            #"{"event":"AfterTool","timestamp":"2026-05-25T15:00:02Z","tool":"Read","target":"/tmp/x.swift"}"#,
        ])

        let events = merge(f)

        #expect(events.count == 3)
        // Sorted: user(01) → tool(02) → agent(03).
        guard case .userMessage(_, let q, _) = events[0].item else { Issue.record("0 not user"); return }
        #expect(q == "the question")
        guard case .toolCall(_, let kind, _, _, _, _) = events[1].item else { Issue.record("1 not tool"); return }
        #expect(kind == "read")
        guard case .agentMessage(_, let a, _, _) = events[2].item else { Issue.record("2 not agent"); return }
        #expect(a == "the answer")
    }

    @Test("replays trace missing hook as status row")
    func replaysTraceMissingStatus() throws {
        let f = try fixture(hooks: [
            #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"please edit"}"#,
            #"{"event":"AfterTool","timestamp":"2026-05-25T15:00:02Z","tool":"Edit","target":"/tmp/x.swift"}"#,
            #"{"event":"AfterAgent","timestamp":"2026-05-25T15:00:03Z","content":"I will summarize the changes."}"#,
            #"{"event":"TraceMissing","timestamp":"2026-05-25T15:00:04Z","provider":"geminiCLI","reply_characters":29}"#,
        ])

        let events = merge(f)

        #expect(events.count == 4)
        guard case .status(_, let text) = events[3].item else { Issue.record("3 not status"); return }
        #expect(text.contains("trace missing"))
        #expect(text.contains("complete <soul_trace> block"))
        #expect(text.contains("Gemini"))
    }

    @Test("recovers an agent_chunks bubble that has no AfterAgent")
    func recoversOrphanAgentChunk() throws {
        let f = try fixture(
            hooks: [
                #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"hi"}"#,
            ],
            chunks: [
                #"{"bubble_id":"b1","ts":"2026-05-25T15:00:02Z","chunk":"recovered "}"#,
                #"{"bubble_id":"b1","ts":"2026-05-25T15:00:02Z","chunk":"reply"}"#,
            ]
        )

        let events = merge(f)

        // user prompt + the reconstructed agent reply (chunks concatenated).
        #expect(events.count == 2)
        guard case .agentMessage(_, let text, _, _) = events[1].item else { Issue.record("no recovered reply"); return }
        #expect(text == "recovered reply")
    }

    @Test("skips an agent_chunk already present as an AfterAgent")
    func skipsAgentChunkAlreadyInHooks() throws {
        let f = try fixture(
            hooks: [
                #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"hi"}"#,
                #"{"event":"AfterAgent","timestamp":"2026-05-25T15:00:02Z","content":"already here"}"#,
            ],
            chunks: [
                #"{"bubble_id":"b1","ts":"2026-05-25T15:00:02Z","chunk":"already here"}"#,
            ]
        )

        let events = merge(f)

        // The chunk duplicates the AfterAgent prefix → suppressed. Only 2 rows.
        #expect(events.count == 2)
        let agentCount = events.filter { if case .agentMessage = $0.item { return true } else { return false } }.count
        #expect(agentCount == 1)
    }

    @Test("collapses duplicate transcript bubbles within the dedupe window")
    func dedupesDuplicateBubblesWithinWindow() throws {
        let f = try fixture(hooks: [
            #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"same prompt"}"#,
            #"{"event":"UserPrompt","timestamp":"2026-05-25T15:00:01Z","text":"same prompt"}"#,
        ])

        let events = merge(f)

        #expect(events.count == 1)
    }

    @Test("renders delegation records as subagent card and strips duplicated progress prelude")
    func stripsDelegationProgressPrelude() throws {
        let noisyAgent = """
        I will invoke our specialized `@adversarial_judge` subagent to perform an exhaustive audit.
        I will search the session registry for any delegated subagent outputs to retrieve the judge's full audit envelope.
        I will read the newly generated subagent delegation report `/tmp/del_adversarial_judge.json`.
        Our `@adversarial_judge` subagent has completed a deep architectural and security audit.

        The useful summary stays visible.
        """
        let cleanAgent = """
        Our `@adversarial_judge` subagent has completed a deep architectural and security audit.

        The useful summary stays visible.
        """
        let f = try fixture(hooks: [
            try jsonLine([
                "event": "UserPrompt",
                "timestamp": "2026-05-25T15:00:00Z",
                "text": "delegate to subagent"
            ]),
            try jsonLine([
                "event": "DelegationStarted",
                "timestamp": "2026-05-25T15:00:01Z",
                "delegation_id": "invoke_agent__abc123",
                "specialist": "adversarial_judge",
                "objective": "Audit the sandbox spec",
                "color": "#8E8E93",
                "live_log": "/tmp/live.log"
            ]),
            try jsonLine([
                "event": "DelegationCompleted",
                "timestamp": "2026-05-25T15:00:02Z",
                "delegation_id": "invoke_agent__abc123",
                "specialist": "adversarial_judge",
                "status": "completed",
                "finding_path": "/tmp/del_adversarial_judge.json",
                "color": "#8E8E93"
            ]),
            try jsonLine([
                "event": "AfterAgent",
                "timestamp": "2026-05-25T15:00:03Z",
                "content": noisyAgent
            ]),
            try jsonLine([
                "event": "AfterAgent",
                "timestamp": "2026-05-25T15:00:04Z",
                "content": cleanAgent
            ])
        ])

        let events = merge(f)

        #expect(events.count == 3)
        guard case .toolCall(_, let kind, let title, let status, _, let details) = events[1].item else {
            Issue.record("delegation did not render as tool call")
            return
        }
        #expect(kind == "delegate")
        #expect(title == "@adversarial_judge")
        #expect(status == "completed")
        guard case .subagent(let specialist, let objective, let subagentId, _, let findingPath) = details?.kind else {
            Issue.record("delegation did not carry subagent details")
            return
        }
        #expect(specialist == "adversarial_judge")
        #expect(objective == "Audit the sandbox spec")
        #expect(subagentId == "invoke_agent__abc123")
        #expect(findingPath == "/tmp/del_adversarial_judge.json")

        guard case .agentMessage(_, let text, _, _) = events[2].item else {
            Issue.record("final event did not preserve useful summary")
            return
        }
        #expect(text == cleanAgent)
        #expect(!text.contains("I will search the session registry"))
        #expect(!text.contains("subagent delegation report"))
    }

    @Test("suppresses status-only delegation assistant prose")
    func suppressesStatusOnlyDelegationProse() throws {
        let f = try fixture(hooks: [
            try jsonLine([
                "event": "DelegationStarted",
                "timestamp": "2026-05-25T15:00:01Z",
                "delegation_id": "invoke_agent__abc123",
                "specialist": "adversarial_judge",
                "objective": "Audit the sandbox spec"
            ]),
            try jsonLine([
                "event": "AfterAgent",
                "timestamp": "2026-05-25T15:00:02Z",
                "content": "Routing Gemini native delegation through soul delegate.Started @adversarial_judge on geminiRunning tool: read_fileCompleted tool: read_fileSoul delegate still running (30s elapsed)."
            ])
        ])

        let events = merge(f)

        #expect(events.count == 1)
        guard case .toolCall(_, _, _, _, _, let details) = events[0].item else {
            Issue.record("delegation card missing")
            return
        }
        guard case .subagent = details?.kind else {
            Issue.record("delegation card missing subagent details")
            return
        }
    }

    @Test("does not sanitize unrelated later turns after delegation")
    func keepsUnrelatedLaterDelegationMentions() throws {
        let laterText = "A later subagent design note can mention Running tool: examples without being hidden."
        let f = try fixture(hooks: [
            try jsonLine([
                "event": "UserPrompt",
                "timestamp": "2026-05-25T15:00:00Z",
                "text": "delegate to subagent"
            ]),
            try jsonLine([
                "event": "DelegationStarted",
                "timestamp": "2026-05-25T15:00:01Z",
                "delegation_id": "invoke_agent__abc123",
                "specialist": "adversarial_judge",
                "objective": "Audit the sandbox spec"
            ]),
            try jsonLine([
                "event": "AfterAgent",
                "timestamp": "2026-05-25T15:00:02Z",
                "content": "Routing Gemini native delegation through soul delegate.Started @adversarial_judge on geminiRunning tool: read_fileCompleted tool: read_fileSoul delegate still running (30s elapsed)."
            ]),
            try jsonLine([
                "event": "UserPrompt",
                "timestamp": "2026-05-25T15:01:00Z",
                "text": "now talk about architecture"
            ]),
            try jsonLine([
                "event": "AfterAgent",
                "timestamp": "2026-05-25T15:01:01Z",
                "content": laterText
            ])
        ])

        let events = merge(f)

        #expect(events.count == 4)
        guard case .agentMessage(_, let text, _, _) = events[3].item else {
            Issue.record("later assistant text missing")
            return
        }
        #expect(text == laterText)
    }
}
