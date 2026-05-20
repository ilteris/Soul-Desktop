import Foundation

/// "How full is the model's context window?" — per-provider best-effort.
///
/// Claude: precise. Reads `~/.claude/projects/<encoded>/<sid>.jsonl` and pulls
/// `usage.{input,cache_creation,cache_read}_tokens` off the most recent
/// assistant entry. That's the actual prompt size sent on the last turn.
///
/// Gemini / Pi: estimated. We sum the message-text bytes from the session's
/// own chat JSON (or, failing that, the kernel's hooks.jsonl) and divide by
/// 4 chars-per-token. Coarse but useful — at least the chip moves and shows
/// you when a session is getting fat.
///
/// `isEstimate` flags which mode produced the number so the chip can render
/// a "~" prefix and the tooltip can say so.
struct ContextUsage {
    let tokens: Int
    let max: Int
    let isEstimate: Bool

    var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1, Double(tokens) / Double(max))
    }

    var shortLabel: String {
        let prefix = isEstimate ? "~" : ""
        if tokens >= 1_000_000 { return prefix + String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000     { return "\(prefix)\(tokens / 1_000)k" }
        return "\(prefix)\(tokens)"
    }

    /// Dispatch on provider. Falls back to nil only if no transcript file
    /// can be located — providers we know how to estimate always return a
    /// value, even if coarse.
    static func compute(provider: Provider, sessionId: String, cwd: String) -> ContextUsage? {
        switch provider {
        case .claude:    return computeClaude(sessionId: sessionId, cwd: cwd)
        case .geminiCLI: return computeGemini(sessionId: sessionId, cwd: cwd)
        case .pi:        return computePi(sessionId: sessionId, cwd: cwd)
        case .codex:     return nil  // Phase 1 stub: token usage not wired yet
        }
    }

    /// Coarse running estimate from the items revealed so far in a Replay.
    /// Sums message text bytes and divides by 4 (the same chars-per-token
    /// heuristic the gemini/pi paths use). Lets the context-usage chip
    /// animate from 0% → final-fill as the replay scrubs through events,
    /// instead of pinning to the static end-of-session value.
    static func estimateFromReplayItems(_ items: [ThreadItem], max: Int = 1_000_000) -> ContextUsage {
        var bytes = 0
        for item in items {
            switch item {
            case .userMessage(_, let text, _),
                 .branchSummary(_, let text, _, _, _),
                 .agentMessage(_, let text, _, _),
                 .agentThought(_, let text, _, _):
                bytes += text.utf8.count
            case .toolCall(_, _, let title, _, let loc, _):
                bytes += title.utf8.count
                if let loc { bytes += loc.utf8.count }
            case .toolCallGroup(_, _, let title, let loc, let inner):
                bytes += title.utf8.count
                if let loc { bytes += loc.utf8.count }
                // Recurse — grouped tool calls have their own titles/locations.
                bytes += Int(estimateFromReplayItems(inner, max: max).tokens) * 4
            case .status(_, let text), .error(_, let text):
                bytes += text.utf8.count
            case .plan, .finalize:
                continue
            }
        }
        return ContextUsage(tokens: bytes / 4, max: max, isEstimate: true)
    }

    // MARK: - Claude (precise)

    private static func computeClaude(sessionId: String, cwd: String) -> ContextUsage? {
        // Claude encodes cwd by replacing "/" → "-". For an absolute path
        // starting with "/" the result already begins with "-"; do NOT
        // prepend another or the lookup hits a phantom "--Users-…" path,
        // returns nil, and the chip silently falls back to the Pi
        // byte-estimate (which overcounts because hooks.jsonl is fatter
        // than the agent transcript per real token).
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let path = ("~/.claude/projects/\(encoded)/\(sessionId).jsonl" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        var lastUsage: (input: Int, cacheCreate: Int, cacheRead: Int)? = nil
        var lastModel: String? = nil
        for line in data.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "assistant" else { continue }
            if let usage = findUsage(in: obj) {
                lastUsage = usage
            }
            if let msg = obj["message"] as? [String: Any],
               let model = msg["model"] as? String {
                lastModel = model
            }
        }

        guard let u = lastUsage else { return nil }
        return ContextUsage(
            tokens: u.input + u.cacheCreate + u.cacheRead,
            max: claudeBudget(for: lastModel),
            isEstimate: false
        )
    }

    /// Claude budget by model ID. The `[1m]` suffix on `claude-opus-4-7[1m]`
    /// signals the 1M-context variant. Other models (sonnet/haiku, and opus
    /// without the suffix) use the standard 200k window. Anthropic doesn't
    /// expose this on every model in a structured field — the bracket marker
    /// in the model id is the most reliable client-side signal.
    private static func claudeBudget(for model: String?) -> Int {
        guard let m = model?.lowercased() else { return 1_000_000 }
        if m.contains("[1m]") { return 1_000_000 }
        if m.contains("opus-4-7") || m.contains("opus-4.7") { return 1_000_000 }
        return 200_000
    }

    // MARK: - Gemini (precise — reads per-turn `tokens` field)

    private static func computeGemini(sessionId: String, cwd: String, max: Int = 1_000_000) -> ContextUsage? {
        // gemini-cli writes precise token counts per turn into the chat
        // JSONL: each model-side entry carries `tokens.{input,output,
        // cached,thoughts,tool,total}`. The "what's in the model's context
        // right now" signal is the most recent entry's `tokens.total` — same
        // pattern as Claude's last-assistant-entry usage block.
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let needle = String(sessionId.prefix(8))
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: chatsDir) else {
            return estimateFromHooks(sessionId: sessionId, max: max)
        }
        let matches = entries.filter { $0.contains(needle) }
        let resolved = matches.max(by: { a, b in
            let aPath = "\(chatsDir)/\(a)"
            let bPath = "\(chatsDir)/\(b)"
            let aTime = (try? FileManager.default.attributesOfItem(atPath: aPath)[.modificationDate] as? Date) ?? .distantPast
            let bTime = (try? FileManager.default.attributesOfItem(atPath: bPath)[.modificationDate] as? Date) ?? .distantPast
            return aTime < bTime
        })
        guard let match = resolved,
              let blob = try? String(contentsOfFile: "\(chatsDir)/\(match)", encoding: .utf8)
        else {
            return estimateFromHooks(sessionId: sessionId, max: max)
        }

        var lastTotal: Int? = nil
        for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any]
            else { continue }
            if let total = tokens["total"] as? Int {
                lastTotal = total
            } else if let inp = tokens["input"] as? Int {
                // Fallback for older entries that lack `total`: sum the
                // component counts we know about.
                let cached = (tokens["cached"] as? Int) ?? 0
                let thoughts = (tokens["thoughts"] as? Int) ?? 0
                lastTotal = inp + cached + thoughts
            }
        }

        if let t = lastTotal {
            return ContextUsage(tokens: t, max: max, isEstimate: false)
        }
        // No tokens field anywhere — fall through to the coarse byte estimate.
        return estimateBytesAtPath("\(chatsDir)/\(match)", max: max)
            ?? estimateFromHooks(sessionId: sessionId, max: max)
    }

    // MARK: - Pi (estimated from hooks)

    private static func computePi(sessionId: String, cwd: String, max: Int = 1_000_000) -> ContextUsage? {
        // Pi sessions write through Soul's hooks.jsonl. That's the most
        // reliable signal we have without poking into Pi-internal storage.
        // Budget is 1M: Pi runs on Gemini under the hood (gemini-2.5-pro
        // family, 1M context). This path is also the fallback when a Claude
        // replay's transcript can't be located — Claude Opus 4.7 [1m] also
        // runs in a 1M window, so 1M is the right ceiling either way.
        return estimateFromHooks(sessionId: sessionId, max: max)
    }

    // MARK: - Shared helpers

    /// Coarse estimate: file bytes / 4 ≈ tokens. Works for any JSON/JSONL
    /// transcript where the bulk of the content is the conversation text.
    private static func estimateBytesAtPath(_ path: String, max: Int) -> ContextUsage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 0
        else { return nil }
        return ContextUsage(tokens: size / 4, max: max, isEstimate: true)
    }

    private static func estimateFromHooks(sessionId: String, max: Int) -> ContextUsage? {
        let registry = (ProcessInfo.processInfo.environment["SOUL_REGISTRY"]
            ?? "~/soul_registry") as NSString
        let base = registry.expandingTildeInPath
        // Hooks live under <registry>/sessions/<project>/<session>/hooks.jsonl.
        // We don't know the project key here — walk the sessions tree and pick
        // the matching session dir. Cheap because we stop at first hit.
        let sessionsRoot = "\(base)/sessions"
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot) else {
            return nil
        }
        for projKey in projects {
            let candidate = "\(sessionsRoot)/\(projKey)/\(sessionId)/hooks.jsonl"
            if FileManager.default.fileExists(atPath: candidate) {
                return estimateBytesAtPath(candidate, max: max)
            }
        }
        return nil
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
