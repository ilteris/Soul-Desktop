import Foundation
import SoulCore

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
                lines.append("[branched from \(from.appProvider?.label ?? from.rawValue) to \(to.appProvider?.label ?? to.rawValue)]")
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

    /// Strip any `<prior_session_context>...</prior_session_context>` block
    /// the agent inadvertently echoed back into its reply. Defensive — the
    /// preamble instructs "do NOT recap it" but gemini-3.5-flash and codex
    /// sometimes copy the opening tag plus a user/agent recap before
    /// pivoting to their actual response.
    ///
    /// Boundary detection (in priority order, first match wins):
    ///   1. `</prior_session_context>` close tag — drop through it.
    ///   2. `\n---\n` separator — drop through it (envelope's body delimiter).
    ///   3. First "User: …" / "You: …" recap-line block followed by a markdown
    ///      header — drop through the last consecutive recap line.
    ///   4. First markdown header (`^#+ `) — drop up to it (header is real content).
    ///   5. Two consecutive blank lines — drop up to them (paragraph break).
    /// If none match, strip just the opener line (worst case: we leak a few
    /// lines of recap rather than eat the whole reply).
    static func scrubEchoed(_ text: String) -> String {
        guard text.contains("<prior_session_context>") else { return text }
        var out = text
        // Soul-Desktop's wire prefix marker is deterministic and never appears
        // organically in user input — if present, drop everything up to and
        // including it. Catches the UserPrompt-pollution case (preamble +
        // "New user message:" + actual text) without relying on heuristics.
        let marker = "\nNew user message:\n"
        if let openRange = out.range(of: "<prior_session_context>"),
           let markerRange = out.range(of: marker, range: openRange.upperBound..<out.endIndex) {
            out.removeSubrange(openRange.lowerBound..<markerRange.upperBound)
        }
        // Paired form: drop opener-to-close inclusive.
        while let openRange = out.range(of: "<prior_session_context>"),
              let closeRange = out.range(of: "</prior_session_context>", range: openRange.upperBound..<out.endIndex) {
            out.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        // Unclosed form passes — scan for a boundary in priority order.
        if let openRange = out.range(of: "<prior_session_context>") {
            let scan = openRange.upperBound..<out.endIndex
            if let dashEnd = out.range(of: "\n---\n", range: scan) {
                out.removeSubrange(openRange.lowerBound..<dashEnd.upperBound)
            } else if let headerRange = firstMarkdownHeader(in: out, range: scan) {
                // Drop everything from the opener up to (but not including)
                // the first markdown header — the model's real response.
                out.removeSubrange(openRange.lowerBound..<headerRange.lowerBound)
            } else if let recapEnd = lastRecapLineEnd(in: out, range: scan) {
                out.removeSubrange(openRange.lowerBound..<recapEnd)
            } else if let blank = out.range(of: "\n\n\n", range: scan) {
                out.removeSubrange(openRange.lowerBound..<blank.upperBound)
            } else if let lineEnd = out.range(of: "\n", range: scan) {
                // Worst case: drop the tag line only.
                out.removeSubrange(openRange.lowerBound..<lineEnd.upperBound)
            }
        }
        return out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Range of the first line that starts with one or more `#` followed by a
    /// space (markdown header).
    private static func firstMarkdownHeader(in s: String, range: Range<String.Index>) -> Range<String.Index>? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let lineEnd = s[cursor..<range.upperBound].firstIndex(of: "\n") ?? range.upperBound
            let line = s[cursor..<lineEnd]
            if let firstNonHash = line.firstIndex(where: { $0 != "#" }),
               firstNonHash > line.startIndex,
               line[firstNonHash] == " " {
                return cursor..<lineEnd
            }
            if lineEnd == range.upperBound { break }
            cursor = s.index(after: lineEnd)
        }
        return nil
    }

    /// Index just past the last consecutive `User:` / `You:` recap line. Used
    /// when the agent echoed a recap pair but didn't follow with `---` or a
    /// header — we still want to chop off the recap so the canvas isn't a
    /// reprint of the prior turn.
    private static func lastRecapLineEnd(in s: String, range: Range<String.Index>) -> String.Index? {
        var cursor = range.lowerBound
        var lastMatch: String.Index? = nil
        while cursor < range.upperBound {
            let lineEnd = s[cursor..<range.upperBound].firstIndex(of: "\n") ?? range.upperBound
            let line = s[cursor..<lineEnd]
            if line.hasPrefix("User:") || line.hasPrefix("You:") {
                lastMatch = lineEnd
            }
            if lineEnd == range.upperBound { break }
            cursor = s.index(after: lineEnd)
        }
        return lastMatch
    }
}
