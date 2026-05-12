import Foundation

/// Shell commands that don't return on their own. The agent will issue one,
/// the tool call sits in_progress forever, and the ACP turn can't resolve
/// because `client.prompt` is awaiting a `stopReason` that never arrives.
///
/// SOUL-SOUL_DESKTOP-034: at tool-call insert time, match the command and
/// surface a visible warning row above the card so the user knows to hit
/// Recover. Pure detection — we do not rewrite or cancel here. The
/// per-tool-call timeout (-033) is the quantitative backstop; this is the
/// qualitative one.
enum StuckCommandPatterns {
    /// Match the command and return a short human-readable reason, or nil
    /// when the command looks safe. Reason is shown to the user verbatim.
    static func reason(forExecuteCommand raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // tail -f / tail --follow follows the file forever.
        if lower.range(of: #"(^|\s|\|\s*)tail\s+(-[a-z]*f|--follow)"#, options: .regularExpression) != nil {
            return "tail -f never returns — it follows the file indefinitely."
        }

        // watch loops every N seconds, by design.
        if lower.range(of: #"(^|\s|\|\s*)watch\s"#, options: .regularExpression) != nil {
            return "watch loops forever by design."
        }

        // top without -b is interactive and never exits.
        if let r = lower.range(of: #"(^|\s|\|\s*)top(\s|$)"#, options: .regularExpression) {
            let tail = String(lower[r.upperBound...])
            if !tail.contains("-b") {
                return "top runs interactively — pass `-b -n1` for a one-shot snapshot."
            }
        }

        // less / more on stdin block waiting for keypresses; without a pipe
        // they expect a TTY we don't have.
        if lower.range(of: #"(^|\s)(less|more)(\s|$)"#, options: .regularExpression) != nil,
           !trimmed.contains("|") {
            return "less / more block on a TTY — pipe through `cat` or redirect to a file."
        }

        // sleep N where N > 60 — agent rarely needs to actually wait that
        // long; usually a chained-after-& race. Doesn't apply to backgrounded
        // sleeps; this catches `sleep 600 && do_thing`.
        if let m = lower.range(of: #"(?:^|\s|;|&&)sleep\s+(\d+)"#, options: .regularExpression) {
            let numStr = lower[m].split(separator: " ").last ?? ""
            if let n = Int(numStr), n > 60 {
                return "sleep \(n)s is long — confirm this isn't a hang."
            }
        }

        // Backgrounded long-runners: foo &  (trailing &, not && or |&)
        // We catch the obvious "command & sleep N" race the agent loves;
        // the watchdog should still cancel these, but a heads-up helps.
        if lower.range(of: #"&\s*(sleep\s+\d+)?\s*$"#, options: .regularExpression) != nil,
           !lower.contains("&&") {
            return "command backgrounded with `&` — the foreground may return before the work completes."
        }

        // ssh without ConnectTimeout can hang on unreachable hosts.
        if lower.range(of: #"(^|\s)ssh\s"#, options: .regularExpression) != nil,
           !lower.contains("connecttimeout") {
            return "ssh without `-o ConnectTimeout=N` can hang on unreachable hosts."
        }

        return nil
    }
}
