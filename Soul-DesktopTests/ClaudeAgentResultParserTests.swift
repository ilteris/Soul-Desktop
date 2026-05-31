import Foundation
import Testing
@testable import Soul_Desktop

/// `ClaudeAgentResultParser.parse` lifts the Claude Agent-tool result trailers
/// (`agentId: …`, `<usage>…</usage>`) out of a reply body into structured
/// fields. The cards (`SubagentCard`/`ClaudeAgentCard`) run it; so does the
/// plain assistant bubble (`AgentMessageRow`) now that a subagent reply can
/// surface as the parent's `AfterAgent` message with those trailers attached.
///
/// The regression these lock: a subagent reply rendered as a plain bubble used
/// to leak the raw `<usage>subagent_tokens: …</usage>` block and the `agentId:`
/// line into the transcript (drag.png leak class).
@Suite("ClaudeAgentResultParser.parse")
struct ClaudeAgentResultParserTests {

    /// The exact trailer layout observed in the leaking screenshot: an
    /// `agentId:` line, then a `<usage>` block whose fields are separated by
    /// blank lines, using the kernel's `subagent_tokens` key.
    @Test("strips the subagent trailer layout from the screenshot")
    func stripsSubagentTrailer() {
        let raw = """
        Ship A, not B. That's the actual silent-spin cause.

        agentId: acb588bdbd5f990eb (use SendMessage with to: 'acb588bdbd5f990eb' to continue this agent)

        <usage>subagent_tokens: 68919

        tool_uses: 11

        duration_ms: 73856</usage>
        """
        let parsed = ClaudeAgentResultParser.parse(raw)
        #expect(parsed.body == "Ship A, not B. That's the actual silent-spin cause.")
        #expect(parsed.agentId == "acb588bdbd5f990eb")
        #expect(parsed.totalTokens == 68919)
        #expect(parsed.toolUses == 11)
        #expect(parsed.durationMs == 73856)
    }

    /// Claude's own Agent tool emits `total_tokens` rather than the kernel's
    /// `subagent_tokens`; both must fill the token field.
    @Test("accepts the total_tokens key variant")
    func acceptsTotalTokensKey() {
        let raw = """
        Done.

        agentId: deadbeef
        <usage>total_tokens: 1234
        tool_uses: 2
        duration_ms: 500</usage>
        """
        let parsed = ClaudeAgentResultParser.parse(raw)
        #expect(parsed.body == "Done.")
        #expect(parsed.totalTokens == 1234)
    }

    /// An ordinary reply with no trailers passes through untouched — the parse
    /// is a no-op, so wiring it into every assistant bubble is safe.
    @Test("ordinary reply is a no-op")
    func ordinaryReplyUntouched() {
        let raw = "Here is a normal answer with no trailers.\n\nSecond paragraph."
        let parsed = ClaudeAgentResultParser.parse(raw)
        #expect(parsed.body == raw)
        #expect(parsed.agentId == nil)
        #expect(parsed.totalTokens == nil)
        #expect(parsed.toolUses == nil)
        #expect(parsed.durationMs == nil)
    }

    /// The full pipeline `AgentMessageRow` runs: parse the usage/agentId
    /// trailers, then `SoulTrace.extract` the trajectory block. None of the
    /// three envelopes may survive into the visible text.
    @Test("parse then SoulTrace.extract clears every trailer")
    func combinedPipelineClearsAllTrailers() {
        let raw = """
        The recommendation stands.

        <soul_trace>{"intent":"x","next_step":"y","rationale":"z"}</soul_trace>

        agentId: cafe1234 (use SendMessage with to: 'cafe1234' to continue this agent)

        <usage>subagent_tokens: 42
        tool_uses: 1
        duration_ms: 10</usage>
        """
        let stats = ClaudeAgentResultParser.parse(raw)
        let (visible, trace) = SoulTrace.extract(from: stats.body)
        #expect(visible == "The recommendation stands.")
        #expect(!visible.contains("<usage>"))
        #expect(!visible.contains("agentId:"))
        #expect(!visible.contains("<soul_trace>"))
        #expect(trace?.intent == "x")
        #expect(stats.totalTokens == 42)
        #expect(stats.toolUses == 1)
        #expect(stats.durationMs == 10)
    }
}
