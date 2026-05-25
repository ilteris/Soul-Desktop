import Testing
@testable import SoulLedger

@Suite("Ledger hook events")
struct LedgerHookEventsTests {
    @Test("user prompt event preserves hook shape")
    func userPromptShape() {
        let event = LedgerHookEvent.userPrompt(text: "hello")

        #expect(event.name == "UserPrompt")
        #expect(event.fields["text"] == .string("hello"))
    }

    @Test("metadata audit events preserve hook keys")
    func metadataAuditShapes() {
        let title = LedgerHookEvent.title(text: "Runtime Split", source: "llm")
        let owner = LedgerHookEvent.sessionOwner(
            writer: "soul-desktop",
            pid: 123,
            provider: "claude"
        )
        let ignored = LedgerHookEvent.acpRequestIgnored(
            method: "session/unknown",
            provider: "geminiCLI",
            params: #"{"id":1}"#
        )

        #expect(title.name == "Title")
        #expect(title.fields["text"] == .string("Runtime Split"))
        #expect(title.fields["source"] == .string("llm"))
        #expect(owner.name == "SessionOwner")
        #expect(owner.fields["writer"] == .string("soul-desktop"))
        #expect(owner.fields["pid"] == .int(123))
        #expect(ignored.name == "ACPRequestIgnored")
        #expect(ignored.fields["method"] == .string("session/unknown"))
        #expect(ignored.fields["params"] == .string(#"{"id":1}"#))
    }

    @Test("after agent event preserves provider and content")
    func afterAgentShape() {
        let event = LedgerHookEvent.afterAgent(content: "done", provider: "codex")

        #expect(event.name == "AfterAgent")
        #expect(event.fields["content"] == .string("done"))
        #expect(event.fields["provider"] == .string("codex"))
    }

    @Test("native session recovery preserves legacy key spelling")
    func nativeSessionRecoveryShape() {
        let event = LedgerHookEvent.nativeSessionIDRecovery(
            provider: "geminiCLI",
            nativeSessionID: "native-1",
            timestamp: "2026-05-25T00:00:00Z"
        )

        #expect(event.name == "NativeSessionID")
        #expect(event.fields["native_session_id"] == .string("native-1"))
        #expect(event.fields["provider"] == .string("geminiCLI"))
        #expect(event.fields["timestamp"] == .string("2026-05-25T00:00:00Z"))
    }

    @Test("native session event preserves nativeId key spelling")
    func nativeSessionIDShape() {
        let event = LedgerHookEvent.nativeSessionID(
            provider: "claude",
            nativeID: "native-2",
            cwd: "/tmp/project"
        )

        #expect(event.name == "NativeSessionID")
        #expect(event.fields["nativeId"] == .string("native-2"))
        #expect(event.fields["provider"] == .string("claude"))
        #expect(event.fields["cwd"] == .string("/tmp/project"))
    }

    @Test("provider transcript id event preserves rotation keys")
    func providerTranscriptIDShape() {
        let event = LedgerHookEvent.providerTranscriptID(
            transcriptID: "new",
            previousTranscriptID: "old",
            provider: "claude",
            timestamp: "2026-05-25T00:00:00Z"
        )

        #expect(event.name == "ProviderTranscriptID")
        #expect(event.fields["transcript_id"] == .string("new"))
        #expect(event.fields["previous_transcript_id"] == .string("old"))
        #expect(event.fields["provider"] == .string("claude"))
        #expect(event.fields["timestamp"] == .string("2026-05-25T00:00:00Z"))
    }

    @Test("turn steered event preserves queued count")
    func turnSteeredShape() {
        let event = LedgerHookEvent.turnSteered(provider: "geminiCLI", queuedCount: 2)

        #expect(event.name == "TurnSteered")
        #expect(event.fields["provider"] == .string("geminiCLI"))
        #expect(event.fields["queued_count"] == .int(2))
    }

    @Test("stall recovered event preserves integer duration")
    func stallRecoveredShape() {
        let event = LedgerHookEvent.stallRecovered(
            provider: "claude",
            toolKind: "execute",
            stalledSeconds: 90,
            recoverySource: "auto"
        )

        #expect(event.name == "StallRecovered")
        #expect(event.fields["stalled_seconds"] == .int(90))
        #expect(event.fields["recovery_source"] == .string("auto"))
    }

    @Test("watchdog events preserve timeout and signpost keys")
    func watchdogShapes() {
        let stall = LedgerHookEvent.stallDetected(
            provider: "geminiCLI",
            toolKind: "execute",
            stalledSeconds: 120,
            threshold: 90
        )
        let signpost = LedgerHookEvent.toolCallSignpost(
            provider: "geminiCLI",
            toolCallID: "tool-1",
            quietSeconds: 45,
            threshold: 90
        )
        let subagent = LedgerHookEvent.subagentLongRunning(
            provider: "claude",
            toolCallID: "tool-2",
            quietSeconds: 300
        )
        let timeout = LedgerHookEvent.toolCallTimeout(
            provider: "codex",
            toolCallID: "tool-3",
            toolKind: "shell",
            toolTitle: "swift test",
            elapsedSeconds: 600,
            threshold: 300,
            afterToolInLedger: true
        )

        #expect(stall.name == "StallDetected")
        #expect(stall.fields["tool_kind"] == .string("execute"))
        #expect(stall.fields["stalled_seconds"] == .int(120))
        #expect(stall.fields["threshold"] == .int(90))
        #expect(signpost.name == "ToolCallSignpost")
        #expect(signpost.fields["tool_call_id"] == .string("tool-1"))
        #expect(signpost.fields["quiet_seconds"] == .int(45))
        #expect(subagent.name == "SubagentLongRunning")
        #expect(subagent.fields["tool_call_id"] == .string("tool-2"))
        #expect(timeout.name == "ToolCallTimeout")
        #expect(timeout.fields["tool_kind"] == .string("shell"))
        #expect(timeout.fields["tool_title"] == .string("swift test"))
        #expect(timeout.fields["afterTool_in_ledger"] == .bool(true))
    }

    @Test("codex approval event preserves approval keys")
    func codexApprovalShape() {
        let event = LedgerHookEvent.codexApproval(
            op: "APPROVAL",
            intent: "Codex command approval handled: swift test",
            provider: "codex",
            method: "exec",
            decision: #"{"decision":"approve"}"#,
            command: "swift test",
            permissionMode: "standard"
        )

        #expect(event.name == "CodexApproval")
        #expect(event.fields["op"] == .string("APPROVAL"))
        #expect(event.fields["intent"] == .string("Codex command approval handled: swift test"))
        #expect(event.fields["provider"] == .string("codex"))
        #expect(event.fields["method"] == .string("exec"))
        #expect(event.fields["decision"] == .string(#"{"decision":"approve"}"#))
        #expect(event.fields["command"] == .string("swift test"))
        #expect(event.fields["permission_mode"] == .string("standard"))
    }

    @Test("codex after tool event preserves tool keys")
    func codexAfterToolShape() {
        let event = LedgerHookEvent.afterTool(
            tool: "Bash",
            target: "swift test",
            rationale: "Run tests",
            provider: "codex",
            codexItemType: "command",
            status: "completed",
            cwd: "/tmp/project"
        )

        #expect(event.name == "AfterTool")
        #expect(event.fields["tool"] == .string("Bash"))
        #expect(event.fields["target"] == .string("swift test"))
        #expect(event.fields["rationale"] == .string("Run tests"))
        #expect(event.fields["provider"] == .string("codex"))
        #expect(event.fields["codex_item_type"] == .string("command"))
        #expect(event.fields["status"] == .string("completed"))
        #expect(event.fields["cwd"] == .string("/tmp/project"))
    }
}
