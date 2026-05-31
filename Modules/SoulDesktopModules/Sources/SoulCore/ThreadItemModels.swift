import Foundation

/// Foundation-only domain models shared by the app's `ThreadItem` view model
/// and the packageable ledger/runtime code. These intentionally carry no
/// SwiftUI or app-singleton dependencies so the reader/merge layer can compile
/// and be tested outside the app target (SOUL-SOUL_DESKTOP-360).

public struct PlanEntry: Hashable {
    public let content: String
    public let priority: String?
    public let status: String?

    public init(content: String, priority: String?, status: String?) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// Optional structured payload attached to a tool call. Today this carries
/// the before/after content for Edit/Write operations so the card can show
/// an inline diff on expand. Other tools (Read, Bash, Grep) leave this nil.
public struct ToolCallDetails: Hashable {
    public enum Kind: Hashable {
        case edit(oldString: String, newString: String)
        case write(content: String)
        case output(text: String)
        /// SOUL-SOUL_DESKTOP-111: structured payload for delegate_to_specialist
        /// tool calls so ThreadView can render a SubagentCard instead of the
        /// generic ToolCallRow. `subagentId` keys into the live.log tailer;
        /// `colorHex` is the kernel-resolved badge color (nil → palette fallback);
        /// `findingPath` is set when the agent script writes its final JSON.
        case subagent(specialist: String, objective: String, subagentId: String, colorHex: UInt32?, findingPath: String?)
        /// Claude Code's `Agent` tool (a.k.a. `Task`) — distinct from Soul's
        /// `delegate_to_specialist`. Carries the subagent type pulled from the
        /// tool-call `subagent_type` param plus a parsed result trailer
        /// (`agentId: …` + `<usage>…</usage>`) so the card can show the
        /// specialist name and token/duration stats instead of leaking the
        /// raw trailer into the bubble text.
        case claudeAgent(
            subagentType: String,
            description: String,
            agentId: String?,
            body: String,
            totalTokens: Int?,
            toolUses: Int?,
            durationMs: Int?
        )

        public var isOutput: Bool {
            if case .output = self { return true }
            return false
        }

        public var isSubagent: Bool {
            if case .subagent = self { return true }
            return false
        }

        public var isClaudeAgent: Bool {
            if case .claudeAgent = self { return true }
            return false
        }
    }
    public var kind: Kind
    /// First line of the edit in the source file when known (from ACP's
    /// `locations[0].line`). Used to label diff lines with their real
    /// in-file line numbers instead of starting at 1.
    public var startLine: Int? = nil
    /// For `.write` only: line count of the file at the moment the tool
    /// call was first observed, captured before disk gets overwritten.
    /// Lets the row render `+N -M` instead of additions-only. nil when the
    /// path is unknown or the file didn't exist (fresh write).
    public var previousLineCount: Int? = nil

    public init(kind: Kind, startLine: Int? = nil, previousLineCount: Int? = nil) {
        self.kind = kind
        self.startLine = startLine
        self.previousLineCount = previousLineCount
    }

    public var isSubagent: Bool { kind.isSubagent }
}
