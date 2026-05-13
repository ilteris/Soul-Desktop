import Foundation

/// Single source of truth for the `/<kebab-case-name> [args]` shape used by
/// chip rendering in the canvas. Every surface that destructures a user
/// message and wants to differentiate slash invocations from plain prose
/// should route through this helper instead of re-implementing the regex.
///
/// SOUL-SOUL_DESKTOP-039: previously UserMessageRow had its own parse;
/// ReplayView's ChapterHeader did its own substring-and-truncate. Consolidated
/// so the recognition rule is consistent across paths.
enum SlashCommandParse {
    struct Parsed {
        /// Command name without the leading slash, e.g. `"decision"`. Nil
        /// when the text isn't a slash invocation.
        let commandName: String?
        /// The remainder after the command name, trimmed. Empty for a bare
        /// `/decision` with no args.
        let rest: String
    }

    static func parse(_ text: String) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return Parsed(commandName: nil, rest: text) }
        let body = trimmed.dropFirst()
        // Pick the first whitespace or newline boundary as the name terminator.
        let boundary: String.Index? = {
            if let sp = body.firstIndex(of: " ") { return sp }
            if let nl = body.firstIndex(of: "\n") { return nl }
            return nil
        }()
        let name: Substring
        let rest: String
        if let b = boundary {
            name = body[..<b]
            rest = String(body[body.index(after: b)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = body
            rest = ""
        }
        let isKebabish = !name.isEmpty && name.allSatisfy { c in
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }
        return isKebabish
            ? Parsed(commandName: String(name), rest: rest)
            : Parsed(commandName: nil, rest: text)
    }
}
