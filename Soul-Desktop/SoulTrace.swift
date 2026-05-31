import Foundation

/// Trajectory signal emitted by agents at the end of substantive turns —
/// `<soul_trace>{"intent": "...", "next_step": "...", "rationale": "..."}</soul_trace>`.
/// The kernel parses this to score predictive alignment; the desktop renders
/// it as a small chip below the assistant bubble.
struct SoulTrace: Hashable {
    let intent: String
    let nextStep: String
    let rationale: String

    /// Pull `<soul_trace>` blocks out of an agent reply. Returns the visible
    /// text (every block stripped) plus the most recent parsed trace when
    /// present and well-formed. Hardened against the leak modes seen in the
    /// wild:
    ///   * Multiple traces in one reply — strip all, surface the last.
    ///   * Case / whitespace variants (`<SOUL_TRACE>`, `< soul_trace >`).
    ///   * Optional attributes on the opener (`<soul_trace v="1">`).
    ///   * Code-fence wrappers — strip the surrounding empty ```…``` fence
    ///     when stripping the block leaves nothing else inside it.
    ///   * Streaming truncation — an opener with no closer yet (still typing)
    ///     hides everything from the opener to end-of-text so the raw JSON
    ///     doesn't flash into the bubble mid-stream.
    /// Malformed JSON inside an otherwise valid block yields a stripped
    /// `visible` with `trace: nil` — the chip silently degrades rather than
    /// the raw envelope leaking through.
    static func extract(from raw: String) -> (visible: String, trace: SoulTrace?) {
        var working = raw
        var lastParsed: SoulTrace? = nil

        // Strip every well-formed block. NSRegularExpression so we can match
        // case-insensitively and tolerate whitespace + attributes inside the
        // opening tag. The body must open with `{` — a genuine trajectory
        // envelope is always `<soul_trace>{…}</soul_trace>`. Without that
        // anchor the opener also matches a prose *mention* of the tag (e.g.
        // ``strips `<soul_trace>` ``), and the lazy `[\s\S]*?` then spans from
        // that mention all the way to a real closer further down, deleting the
        // prose in between (drag.png truncation).
        let pattern = #"(?:`{3,}[a-zA-Z]*\s*\n)?\s*<\s*soul[_-]trace\b[^>]*>\s*(\{[\s\S]*?)<\s*/\s*soul[_-]trace\s*>\s*(?:\n`{3,})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (raw, nil)
        }

        while true {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            guard let match = regex.firstMatch(in: working, options: [], range: range) else { break }
            if let innerRange = Range(match.range(at: 1), in: working) {
                let inner = String(working[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = inner.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lastParsed = SoulTrace(
                        intent:    obj["intent"]    as? String ?? "",
                        nextStep:  obj["next_step"] as? String ?? "",
                        rationale: obj["rationale"] as? String ?? ""
                    )
                }
            }
            guard let fullRange = Range(match.range, in: working) else { break }
            working.replaceSubrange(fullRange, with: "")
        }

        // Streaming guard: an opener with no closer means the model is still
        // typing the JSON body. Hide from the opener to end so the raw `{`
        // doesn't flash into the rendered bubble before the closer lands.
        //
        // But only when it's actually an in-progress trace, not when the reply
        // is *describing* the tag in prose. The false positive seen in the wild
        // (drag.png): a subagent reply explaining `<soul_trace>` inside inline
        // code — `… SoulTrace.extract (strips `<soul_trace>`/agentId)` — tripped
        // this guard, which then deleted everything from the tag to end-of-text
        // and truncated the visible reply at the opening backtick. Distinguish
        // the two by what follows the opener: a genuine streaming trace is
        // either still being typed (nothing but whitespace after the opener) or
        // has begun — but not finished — its JSON body. Anything else following
        // the opener is prose — leave it intact.
        //
        // Two refinements over the naive `firstMatch` + `hasPrefix("{")` check:
        //   * Bug A (leak): scan the *last* opener, not the first. Every
        //     well-formed block was already stripped above, so only a trailing
        //     closer-less opener can be a live stream; earlier openers are prose
        //     mentions. `firstMatch` would inspect the prose mention, decline to
        //     fire, and let a real streaming trace at the end leak its raw JSON.
        //   * Bug D (truncation): a prose `<soul_trace>{…}` with no closer trips
        //     `hasPrefix("{")` and truncates the reply. An in-progress trace has
        //     an *unterminated* body (no closing `}` yet); a complete prose `{…}`
        //     is balanced. Only truncate when the brace body is still open.
        //   * EDGE1 (`}`-in-streaming-body): the open/closed test must be
        //     string-aware. A naive `contains("}")` (or a plain brace-depth
        //     counter) misclassifies a *streaming* body whose string value holds
        //     a brace — `{"rationale":"fixed the } in removeSubrange` — as
        //     complete, and lets its raw partial JSON flash into the bubble.
        //     `jsonObjectIsComplete` walks the body respecting quotes/escapes so
        //     a brace inside a string never closes the object.
        if let openerPattern = try? NSRegularExpression(
            pattern: #"<\s*soul[_-]trace\b[^>]*>"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = openerPattern.matches(in: working, options: [], range: range)
            if let match = matches.last, let r = Range(match.range, in: working) {
                let after = working[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let isStreaming = after.isEmpty || (after.hasPrefix("{") && !jsonObjectIsComplete(after))
                if isStreaming {
                    working.removeSubrange(r.lowerBound..<working.endIndex)
                }
            }
        }

        return (working.trimmingCharacters(in: .whitespacesAndNewlines), lastParsed)
    }

    /// Whether `text` opens with a structurally complete JSON object — i.e. the
    /// `{` started at the head is matched by a `}` at depth zero. String-aware:
    /// braces inside quoted strings (and escaped quotes) are ignored, so a
    /// streaming body still typing `{"rationale":"fixed the }` reads as
    /// incomplete rather than balanced. Returns false if `text` doesn't begin
    /// with `{`.
    private static func jsonObjectIsComplete(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        var sawOpen = false
        for ch in text {
            if escaped { escaped = false; continue }
            if inString {
                switch ch {
                case "\\": escaped = true
                case "\"": inString = false
                default: break
                }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1; sawOpen = true
            case "}":
                depth -= 1
                if depth == 0 { return sawOpen }
                if depth < 0 { return false }
            default: break
            }
        }
        return false
    }
}
