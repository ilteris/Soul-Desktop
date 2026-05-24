import Foundation

/// SOUL-SOUL_DESKTOP-082 Phase 1: unified title resolution.
///
/// Single source of truth for "what string represents this session in the
/// sidebar / toolbar / window title". Called from both:
///   - `ThreadController.displayTitle` (live sessions, full ordered prompts)
///   - `SoulRegistry+Sessions.allSessions` (disk sessions, kernel CLI gives
///     us a single `first_user_prompt`)
///
/// Both call sites previously had independent ad-hoc title logic. The live
/// path stripped bare slash commands; the disk path didn't. That's the
/// drift class this resolver eliminates.
///
/// Priority order (highest to lowest):
///   1. `customTitle` — explicit user-set or post-first-turn LLM-generated
///   2. `finalizeIntent` — LLM-generated finalize.intent if the session has
///      been finalized AND the intent is itself prose (not a copy of the
///      first user prompt)
///   3. First prose user prompt — walks the first 3, returns the first that
///      passes the structural classifier
///   4. Branch-summary or first-agent-message fallback — when all user
///      prompts are skill expansions, lean on whatever signal is left
///   5. Synthesized `<skill> · <date>` — e.g. `/pulse · Apr 28` when all
///      we have is repeated skill expansions
///
/// CLASSIFIER IS STRUCTURAL, NOT LEXICAL. Per adversarial_judge 2026-05-24:
/// matching prose templates ("starts with 'You are Teddy'") couples the
/// desktop to dotfiles content — renaming the persona or editing a skill
/// silently re-titles historical sessions. Detection signals here are
/// content-agnostic: bare slash, harness XML tag, length+markdown+list.
enum SessionTitleResolver {

    struct Inputs {
        var customTitle: String?
        var finalizeIntent: String?
        /// Ordered user prompts. Sidebar gets up to 3 (SOUL-SOUL-090);
        /// live thread has N.
        var prompts: [String]
        /// First agent text (only first meaningful line is used). Optional
        /// fallback when all user prompts are skill expansions.
        var firstAgentLine: String?
        /// Optional branch-summary text from a branchSummary item. Used as
        /// a higher-priority fallback than firstAgentLine.
        var branchSummary: String?
        /// Skill name extracted from a bare-slash first prompt, when known.
        /// Optional — if nil, the resolver derives it from the first
        /// classified `.bareSlash` prompt.
        var skillHint: String?
    }

    enum PromptKind: Equatable {
        case empty
        /// `/pulse` alone — single token starting with `/`, no body.
        case bareSlash(String)
        /// Long structured text matching a known wrapper shape: harness
        /// `<command-name>` tag, OR ≥500 chars with markdown bold + numbered
        /// list. Treated as "the wrapper around an empty user input".
        case skillExpansion
        /// Anything else — actual prose the user typed.
        case prose
    }

    // MARK: - Public API

    static func resolve(_ inputs: Inputs) -> String {
        // 1. Explicit customTitle wins.
        if let t = inputs.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return truncate(t)
        }

        // 2. finalize.intent if it's prose (skill-expansion intents are noise).
        if let intent = inputs.finalizeIntent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty {
            if case .prose = classify(intent) {
                return truncate(intent)
            }
        }

        // 3. First prose user prompt (look at up to 3).
        for prompt in inputs.prompts.prefix(3) {
            if case .prose = classify(prompt) {
                return truncate(prompt)
            }
        }

        // 4. Branch summary, then first agent line, before synthesizing.
        if let summary = inputs.branchSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return truncate(summary)
        }
        if let agent = inputs.firstAgentLine?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
            return truncate(agent)
        }

        // 5. Synthesized fallback: just the skill stub. No date suffix —
        // sidebar row's subtitle (Phase 2) carries date/turn-count for
        // disambiguation between same-stub sessions. Title stays clean.
        if let skill = inputs.skillHint ?? derivedSkillName(from: inputs.prompts) {
            return skill
        }
        return "New chat"
    }

    // MARK: - Classifier

    static func classify(_ prompt: String) -> PromptKind {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // Bare /cmd: single token starting with `/`, no internal whitespace.
        if trimmed.hasPrefix("/") {
            let body = trimmed.dropFirst()
            if !body.isEmpty && !body.contains(where: { $0.isWhitespace }) {
                return .bareSlash("/" + String(body))
            }
        }

        // Harness-injected XML tag. The slash-command harness wraps a
        // skill invocation with `<command-name>foo</command-name>` plus
        // ancillary tags. Format is harness-controlled and stable across
        // skill edits — a structural signal, not a prose match.
        if trimmed.contains("<command-name>") {
            return .skillExpansion
        }

        // Structural skill expansion. Two signals, either qualifies:
        //
        // (a) Obvious: long structured doc (≥500 chars) with markdown bold
        //     and a numbered list. Catches verbose templates conservatively.
        //
        // (b) Dense markup: 2+ bold spans (4+ `**` occurrences) AND 2+
        //     numbered items, ANY length. User prose almost never combines
        //     both at density. Catches /pulse-style short skill expansions
        //     (~380 chars, "**Execution**:" + "**Report**:" + 2 steps).
        //
        // Both rules avoid lexical templates — no string is matched, only
        // structural counts. Renaming a persona in the skill file does
        // not change these signals.
        let boldMarkerCount = trimmed.components(separatedBy: "**").count - 1
        let numberedItemCount: Int = {
            guard let regex = try? NSRegularExpression(pattern: #"(^|\n)\s*\d+\.\s"#) else { return 0 }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            return regex.numberOfMatches(in: trimmed, range: range)
        }()

        if trimmed.count >= 500 && boldMarkerCount >= 2 && numberedItemCount >= 1 {
            return .skillExpansion  // rule (a)
        }
        if boldMarkerCount >= 4 && numberedItemCount >= 2 {
            return .skillExpansion  // rule (b) — density signal, any length
        }

        return .prose
    }

    // MARK: - Helpers

    private static let titleMaxChars = 60

    private static func truncate(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= titleMaxChars { return oneLine }
        return String(oneLine.prefix(titleMaxChars)) + "…"
    }

    /// Try to lift a short descriptor from the first prompt that classifies
    /// as bareSlash or skillExpansion. For bareSlash the name is the slash
    /// command itself. For skillExpansion we return the shortest non-trivial
    /// sentence in the first paragraph — empirically that's the imperative
    /// directive ("Perform a Registry Pulse."), while longer sentences are
    /// persona-setup boilerplate. Pure structural, no lexical match.
    private static func derivedSkillName(from prompts: [String]) -> String? {
        for prompt in prompts {
            switch classify(prompt) {
            case .bareSlash(let name):
                return name
            case .skillExpansion:
                if let stub = shortestSentenceInFirstParagraph(prompt) {
                    return stub
                }
                // Fall through: try next prompt if this one yielded nothing.
                continue
            case .prose, .empty:
                continue
            }
        }
        return nil
    }

    /// Shortest sentence between 9 and 60 characters in the first paragraph
    /// of `text`. First paragraph = text up to the first blank line. Returns
    /// nil if no sentence fits the window.
    private static func shortestSentenceInFirstParagraph(_ text: String) -> String? {
        // First paragraph: everything up to the first \n\n (or end).
        let firstParagraph: String
        if let blankRange = text.range(of: "\n\n") {
            firstParagraph = String(text[..<blankRange.lowerBound])
        } else {
            firstParagraph = text
        }
        // Split on ". " — keeps sentence-ish chunks without over-fragmenting
        // on every period (URLs, ellipses, etc. survive intact).
        let sentences = firstParagraph
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidates = sentences.filter { (9...60).contains($0.count) }
        guard let shortest = candidates.min(by: { $0.count < $1.count }) else {
            return nil
        }
        // Strip a trailing period if present — the synthesized title already
        // adds " · <date>", trailing period reads as a typo.
        return shortest.hasSuffix(".") ? String(shortest.dropLast()) : shortest
    }

}
