import Foundation

/// SOUL-SOUL_DESKTOP-245 (Phase B — bypass-first resume).
///
/// Renders a hydrated thread's prior items into a single text block that
/// gets prefixed to the user's first prompt after a resume. The agent
/// reads it as inline context and continues naturally; the canvas still
/// shows the full transcript above. This replaces the old
/// `session/load`-based resume that was re-feeding the entire history
/// back to the agent (and blowing the context window — see the 1.7M-token
/// screenshot bug that motivated -245).
///
/// Phase A will replace `build(...)` with a summarizer when `byteCount`
/// exceeds the safe threshold. Today we either inject verbatim (small
/// session) or skip and start fresh (with a status row explaining why).
/// SPEC-245-K step 4. Where in the provider's session/new wire format
/// the preamble lands. Raw values match the kernel's channel strings
/// (see `~/dotfiles/soul/kernel/preamble/providers.py`).
enum PreambleChannel: String {
    /// Claude (claude-agent-acp): pack into `_meta.systemPrompt` on
    /// session/new. Agent consumes as native system prompt.
    case claudeSystemMeta = "claude_system_meta"
    /// Gemini-CLI / Pi / unknown: provider doesn't expose a system
    /// slot, so we degrade to prefixing the user-channel prompt.
    case userPromptPrefix = "user_prompt_prefix"
}

/// SPEC-245-K Phase A step 2. JSON payload returned by
/// `soul preamble --format json`. Mirrored from
/// `~/dotfiles/soul/kernel/commands/soul_preamble.py::_emit`.
struct PreamblePayload: Decodable {
    let preamble: String
    let channel: String
    let cacheHit: Bool
    let mode: String              // "verbatim" | "summary"
    let charCount: Int
    let turnCount: Int
    let truncated: Bool
    let summarized: Bool

    enum CodingKeys: String, CodingKey {
        case preamble, channel, mode, truncated, summarized
        case cacheHit = "cache_hit"
        case charCount = "char_count"
        case turnCount = "turn_count"
    }

    var resolvedChannel: PreambleChannel {
        PreambleChannel(rawValue: channel) ?? .userPromptPrefix
    }
}

enum LedgerPreamble {

    /// Anything larger than this gets dropped instead of injected. 300K
    /// chars ≈ 75K tokens. Sized for Claude Sonnet's 200K window minus
    /// system prompt + tool schemas + the new user turn + headroom for
    /// the reply (~50K reserved). Gemini and Pi have larger windows so
    /// this is conservative for them; Codex (GPT-5 class, varies) is
    /// roughly comparable to Sonnet. Phase A will make this per-provider
    /// keyed; for Phase B one floor is fine and the audit caught the
    /// previous 500K value as too aggressive for Claude.
    static let maxChars = 300_000

    struct Built {
        var text: String
        var turnCount: Int
        var truncated: Bool
    }

    /// Returns nil when there's nothing worth injecting (empty / only
    /// status rows / errors).
    static func build(from items: [ThreadItem]) -> Built? {
        var lines: [String] = []
        var turns = 0

        for item in items {
            switch item {
            case .userMessage(_, let text, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append("User: \(trimmed)")
                turns += 1

            case .agentMessage(_, let text, _, _):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append("You: \(trimmed)")

            case .branchSummary(_, let summary, let from, let to, _):
                lines.append("[branched from \(from.label) to \(to.label)]")
                lines.append("Summary: \(summary)")

            case .toolCall(_, let kind, let title, let status, let hint, _):
                let hintPart = hint.map { " (\($0))" } ?? ""
                lines.append("[tool: \(kind) \(title)\(hintPart) — \(status)]")

            case .toolCallGroup(_, let kind, let title, let hint, let inner):
                let hintPart = hint.map { " (\($0))" } ?? ""
                lines.append("[tool group: \(kind) \(title)\(hintPart) — \(inner.count) calls]")

            case .finalize(_, let intent, let summary, _, _, let next, _):
                var bits: [String] = ["[prior session finalized]"]
                if let intent, !intent.isEmpty { bits.append("Intent: \(intent)") }
                if let summary, !summary.isEmpty { bits.append("Summary: \(summary)") }
                if let next, !next.isEmpty { bits.append("Next: \(next)") }
                lines.append(bits.joined(separator: " "))

            case .agentThought, .plan, .status, .error:
                continue
            }
        }

        guard turns > 0 else { return nil }

        let body = lines.joined(separator: "\n\n")
        let wrapped = """
        <prior_session_context>
        You're resuming an existing conversation. The user can see the full
        prior transcript in their UI above your reply — do NOT recap it.
        Below is that conversation so you have context. Continue naturally
        from the new user message that follows.

        ---
        \(body)
        ---
        </prior_session_context>

        """

        if wrapped.count > maxChars {
            return Built(text: "", turnCount: turns, truncated: true)
        }
        return Built(text: wrapped, turnCount: turns, truncated: false)
    }

    /// Prefix the preamble to the agent-channel text for the first send.
    /// Leaves `display` untouched — the canvas already shows the prior items.
    static func prefix(_ preamble: String, to agent: String) -> String {
        guard !preamble.isEmpty else { return agent }
        return preamble + "\nNew user message:\n" + agent
    }
}
