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
        // has begun its JSON body (`{` after optional whitespace). Anything else
        // following the opener is prose — leave it intact.
        if let openerPattern = try? NSRegularExpression(
            pattern: #"<\s*soul[_-]trace\b[^>]*>"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            if let match = openerPattern.firstMatch(in: working, options: [], range: range),
               let r = Range(match.range, in: working) {
                let after = working[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if after.isEmpty || after.hasPrefix("{") {
                    working.removeSubrange(r.lowerBound..<working.endIndex)
                }
            }
        }

        return (working.trimmingCharacters(in: .whitespacesAndNewlines), lastParsed)
    }
}
