import Foundation

public enum LedgerHookValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
}

public struct LedgerHookEvent: Equatable, Sendable {
    public var name: String
    public var fields: [String: LedgerHookValue]

    public init(name: String, fields: [String: LedgerHookValue] = [:]) {
        self.name = name
        self.fields = fields
    }

    public static func userPrompt(text: String) -> LedgerHookEvent {
        LedgerHookEvent(name: "UserPrompt", fields: ["text": .string(text)])
    }

    public static func title(text: String, source: String) -> LedgerHookEvent {
        LedgerHookEvent(name: "Title", fields: [
            "text": .string(text),
            "source": .string(source),
        ])
    }

    public static func sessionOwner(
        writer: String,
        pid: Int,
        provider: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "SessionOwner", fields: [
            "writer": .string(writer),
            "pid": .int(pid),
            "provider": .string(provider),
        ])
    }

    public static func acpRequestIgnored(
        method: String,
        provider: String,
        params: String? = nil
    ) -> LedgerHookEvent {
        var fields: [String: LedgerHookValue] = [
            "method": .string(method),
            "provider": .string(provider),
        ]
        if let params { fields["params"] = .string(params) }
        return LedgerHookEvent(name: "ACPRequestIgnored", fields: fields)
    }

    public static func branchSummary(
        summary: String,
        sourceProvider: String?,
        targetProvider: String?
    ) -> LedgerHookEvent {
        var fields: [String: LedgerHookValue] = ["summary": .string(summary)]
        if let sourceProvider { fields["from_provider"] = .string(sourceProvider) }
        if let targetProvider { fields["to_provider"] = .string(targetProvider) }
        return LedgerHookEvent(name: "BranchSummary", fields: fields)
    }

    public static func afterAgent(content: String, provider: String) -> LedgerHookEvent {
        LedgerHookEvent(name: "AfterAgent", fields: [
            "content": .string(content),
            "provider": .string(provider),
        ])
    }

    public static func nativeSessionID(
        provider: String,
        nativeID: String,
        cwd: String? = nil
    ) -> LedgerHookEvent {
        var fields: [String: LedgerHookValue] = [
            "provider": .string(provider),
            "nativeId": .string(nativeID),
        ]
        if let cwd { fields["cwd"] = .string(cwd) }
        return LedgerHookEvent(name: "NativeSessionID", fields: fields)
    }

    public static func nativeSessionIDRecovery(
        provider: String,
        nativeSessionID: String,
        timestamp: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "NativeSessionID", fields: [
            "native_session_id": .string(nativeSessionID),
            "provider": .string(provider),
            "timestamp": .string(timestamp),
        ])
    }

    public static func providerTranscriptID(
        transcriptID: String,
        previousTranscriptID: String,
        provider: String,
        timestamp: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "ProviderTranscriptID", fields: [
            "transcript_id": .string(transcriptID),
            "previous_transcript_id": .string(previousTranscriptID),
            "provider": .string(provider),
            "timestamp": .string(timestamp),
        ])
    }

    public static func turnSteered(provider: String, queuedCount: Int) -> LedgerHookEvent {
        LedgerHookEvent(name: "TurnSteered", fields: [
            "provider": .string(provider),
            "queued_count": .int(queuedCount),
        ])
    }

    public static func stallRecovered(
        provider: String,
        toolKind: String,
        stalledSeconds: Int,
        recoverySource: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "StallRecovered", fields: [
            "provider": .string(provider),
            "tool_kind": .string(toolKind),
            "stalled_seconds": .int(stalledSeconds),
            "recovery_source": .string(recoverySource),
        ])
    }

    public static func stallDetected(
        provider: String,
        toolKind: String,
        stalledSeconds: Int,
        threshold: Int
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "StallDetected", fields: [
            "provider": .string(provider),
            "tool_kind": .string(toolKind),
            "stalled_seconds": .int(stalledSeconds),
            "threshold": .int(threshold),
        ])
    }

    public static func toolCallSignpost(
        provider: String,
        toolCallID: String,
        quietSeconds: Int,
        threshold: Int
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "ToolCallSignpost", fields: [
            "provider": .string(provider),
            "tool_call_id": .string(toolCallID),
            "quiet_seconds": .int(quietSeconds),
            "threshold": .int(threshold),
        ])
    }

    public static func subagentLongRunning(
        provider: String,
        toolCallID: String,
        quietSeconds: Int
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "SubagentLongRunning", fields: [
            "provider": .string(provider),
            "tool_call_id": .string(toolCallID),
            "quiet_seconds": .int(quietSeconds),
        ])
    }

    public static func traceMissing(provider: String, replyCharacters: Int) -> LedgerHookEvent {
        LedgerHookEvent(name: "TraceMissing", fields: [
            "provider": .string(provider),
            "reply_characters": .int(replyCharacters),
        ])
    }

    public static func toolCallTimeout(
        provider: String,
        toolCallID: String,
        toolKind: String,
        toolTitle: String,
        elapsedSeconds: Int,
        threshold: Int,
        afterToolInLedger: Bool
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "ToolCallTimeout", fields: [
            "provider": .string(provider),
            "tool_call_id": .string(toolCallID),
            "tool_kind": .string(toolKind),
            "tool_title": .string(toolTitle),
            "elapsed_seconds": .int(elapsedSeconds),
            "threshold": .int(threshold),
            "afterTool_in_ledger": .bool(afterToolInLedger),
        ])
    }

    public static func afterTool(
        tool: String,
        target: String,
        rationale: String,
        provider: String,
        codexItemType: String,
        status: String,
        cwd: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "AfterTool", fields: [
            "tool": .string(tool),
            "target": .string(target),
            "rationale": .string(rationale),
            "provider": .string(provider),
            "codex_item_type": .string(codexItemType),
            "status": .string(status),
            "cwd": .string(cwd),
        ])
    }

    public static func codexApproval(
        op: String,
        intent: String,
        provider: String,
        method: String,
        decision: String,
        command: String,
        permissionMode: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "CodexApproval", fields: [
            "op": .string(op),
            "intent": .string(intent),
            "provider": .string(provider),
            "method": .string(method),
            "decision": .string(decision),
            "command": .string(command),
            "permission_mode": .string(permissionMode),
        ])
    }

    public static func worktreeCreated(
        path: String,
        branchName: String
    ) -> LedgerHookEvent {
        LedgerHookEvent(name: "WorktreeCreated", fields: [
            "path": .string(path),
            "branchName": .string(branchName),
        ])
    }
}
