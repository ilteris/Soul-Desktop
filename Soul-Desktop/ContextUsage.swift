import Foundation

/// Approximate "how full is the model's context window" for a Claude session.
///
/// We read the harness's own JSONL transcript (~/.claude/projects/<encoded>/<sid>.jsonl)
/// and pull `usage` off the most recent `assistant` entry. That number reflects
/// the actual prompt size sent on the last turn — a much better signal than
/// summing every turn's usage (which would double-count the system prompt).
///
/// Gemini and Pi don't write equivalent usage metadata, so this returns nil
/// for non-Claude sessions.
struct ContextUsage {
    let tokens: Int
    let max: Int

    var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1, Double(tokens) / Double(max))
    }

    /// "23k" — short form for chip display.
    var shortLabel: String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000     { return "\(tokens / 1_000)k" }
        return "\(tokens)"
    }

    static func compute(forSession sid: String, cwd: String, max: Int = 200_000) -> ContextUsage? {
        let encoded = "-" + cwd.replacingOccurrences(of: "/", with: "-")
        let path = ("~/.claude/projects/\(encoded)/\(sid).jsonl" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        var lastUsage: (input: Int, cacheCreate: Int, cacheRead: Int)? = nil
        for line in data.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "assistant" else { continue }
            if let usage = findUsage(in: obj) {
                lastUsage = usage
            }
        }

        guard let u = lastUsage else { return nil }
        return ContextUsage(tokens: u.input + u.cacheCreate + u.cacheRead, max: max)
    }

    private static func findUsage(in obj: Any) -> (input: Int, cacheCreate: Int, cacheRead: Int)? {
        if let dict = obj as? [String: Any] {
            if let usage = dict["usage"] as? [String: Any] {
                let inp = (usage["input_tokens"] as? Int) ?? 0
                let cc  = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cr  = (usage["cache_read_input_tokens"] as? Int) ?? 0
                return (inp, cc, cr)
            }
            for v in dict.values {
                if let found = findUsage(in: v) { return found }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if let found = findUsage(in: v) { return found }
            }
        }
        return nil
    }
}
