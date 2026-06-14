import Foundation
import SoulCore

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
struct ContextUsage: Sendable {
    let tokens: Int
    let max: Int
    let isEstimate: Bool
    /// Optional per-source breakdown surfaced in the chip's tooltip so the
    /// user can sanity-check the number. nil ⇒ no extra detail available
    /// (typically estimated sources). All values in raw token units.
    let breakdown: Breakdown?

    struct Breakdown: Sendable {
        /// Provider-reported model id (e.g. "claude-opus-4-7", "gemini-2.5-pro").
        let model: String?
        /// Fresh prompt tokens — text the model has to read this turn.
        let input: Int?
        /// Cache-creation tokens (Claude only).
        let cacheCreate: Int?
        /// Cache-read tokens — pulled from the provider's prompt cache.
        /// Counts against the window even though it's cheap to fetch.
        let cacheRead: Int?
        /// Source description shown in the tooltip header.
        let source: String
    }

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

    /// Multi-line tooltip body. Pinned at the top: source + model. Below:
    /// a breakdown when the source produced one. Used by ContextUsageChip
    /// instead of the previous one-liner so "is the number correct?" is
    /// answerable from a hover.
    var tooltipText: String {
        var lines: [String] = []
        let formatted = ContextUsage.formatTokens(tokens)
        let maxFormatted = ContextUsage.formatTokens(max)
        lines.append("\(formatted) / \(maxFormatted) (\(Int(fraction * 100))%)")
        if let b = breakdown {
            lines.append(b.source)
            if let model = b.model { lines.append("model: \(model)") }
            if let input = b.input { lines.append("  input: \(ContextUsage.formatTokens(input))") }
            if let cc = b.cacheCreate, cc > 0 { lines.append("  cache-create: \(ContextUsage.formatTokens(cc))") }
            if let cr = b.cacheRead, cr > 0 { lines.append("  cache-read: \(ContextUsage.formatTokens(cr))") }
        } else if isEstimate {
            lines.append("Estimated from transcript bytes — provider doesn't expose precise usage.")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Dispatch on provider. Falls back to nil only if no transcript file
    /// can be located — providers we know how to estimate always return a
    /// value, even if coarse.
    ///
    /// SOUL-SOUL_DESKTOP-234: read from `AppShell.contextUsage`, which is a
    /// computed property hit on every AppShell.body re-eval. Each call used
    /// to open session-sized JSONL files. Cache by the kernel hooks file's
    /// content stamp so clicks/body churn do not reparse stable transcripts,
    /// while active sessions still invalidate when the ledger advances.
    ///
    /// SOUL-IDENTITY-SPLIT: `sessionId` here is the *kernel* UUID. The
    /// on-disk Claude/Gemini transcript filename can differ — either
    /// because the session was repaired/branched and the provider keeps
    /// its own id, or because Claude rotated the transcript on /compact.
    /// Resolution uses the same hooks.jsonl-indexed lookup that
    /// SessionLoadability already relies on (`findProviderTranscriptID`
    /// → `findNativeSessionID` → bare sid).
    static func compute(provider: Provider, sessionId: String, cwd: String, projectKey: String) -> ContextUsage? {
        // SOUL-IDENTITY-SPLIT perf fix: key the memo off the inputs
        // (provider+cwd+kernel sid) — NOT off the resolved transcript id.
        // resolveTranscriptId walks hooks.jsonl, which is multi-MB on
        // active sessions; doing that before the cache lookup beachballs
        // the main thread on every body re-eval.
        let key = "\(provider.rawValue)|\(cwd)|\(sessionId)|\(projectKey)"
        let hooksStamp = fileStamp(atPath: SoulRegistry.hooksPath(projectKey: projectKey, sessionId: sessionId))
        let now = Date()
        memoLock.lock()
        let cached = memo[key]
        memoLock.unlock()
        if let cached,
           cached.hooksStamp == hooksStamp,
           hooksStamp != nil || now.timeIntervalSince(cached.date) < memoTTL {
            return cached.value
        }
        let transcriptId = resolveTranscriptId(
            kernelSid: sessionId, provider: provider, projectKey: projectKey
        )
        let result: ContextUsage?
        switch provider {
        case .claude:    result = computeClaude(sessionId: transcriptId, cwd: cwd)
        case .geminiCLI: result = computeGemini(sessionId: transcriptId, cwd: cwd)
        case .pi:        result = computePi(sessionId: transcriptId, cwd: cwd)
        case .codex:     result = nil  // Phase 1 stub: token usage not wired yet
        }
        memoLock.lock()
        memo[key] = MemoEntry(date: now, hooksStamp: hooksStamp, value: result)
        memoLock.unlock()
        return result
    }

    /// kernelSid → on-disk transcript id, using the same priority order
    /// the rest of the codebase has converged on:
    ///   1. ProviderTranscriptID event (newest; captures /compact rotation)
    ///   2. NativeSessionID event (initial divergence at session/new)
    ///   3. The kernel sid itself (identity-mapped sessions)
    private static func resolveTranscriptId(kernelSid: String, provider: Provider, projectKey: String) -> String {
        let identity = SoulRegistry.transcriptIdentity(
            projectKey: projectKey,
            sessionId: kernelSid,
            provider: provider.rawValue
        )
        return identity.providerTranscriptId ?? identity.nativeSessionId ?? kernelSid
    }

    private struct FileStamp: Equatable {
        let mtime: Date
        let size: UInt64
    }

    private struct MemoEntry {
        let date: Date
        let hooksStamp: FileStamp?
        let value: ContextUsage?
    }

    private static var memo: [String: MemoEntry] = [:]
    private static let memoLock = NSLock()
    private static let memoTTL: TimeInterval = 2.0

    private static func fileStamp(atPath path: String) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mt = attrs[.modificationDate] as? Date
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return FileStamp(mtime: mt, size: size)
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
        return ContextUsage(tokens: bytes / 4, max: max, isEstimate: true, breakdown: nil)
    }

    // MARK: - Claude (precise)

    private static func computeClaude(sessionId: String, cwd: String) -> ContextUsage? {
        // Claude encodes a cwd into its projects-dir name by replacing BOTH
        // "/" and "." with "-". The "." substitution is load-bearing: every
        // Soul worktree lives under `~/.soul/worktrees/…`, so a "/"-only
        // encoding produces `-Users-…-.soul-…` while Claude's real dir is
        // `-Users-…--soul-…` (the dot collapses to a second dash). The miss
        // returned nil and the context chip silently vanished for every
        // worktree-hosted Claude session (SOUL-SOUL_DESKTOP context chip bug).
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = ("~/.claude/projects/\(encoded)" as NSString).expandingTildeInPath
        // Prefer the resolved transcript id, but Claude rotates the transcript
        // on every `/compact` and the kernel's newest NativeSessionID can name
        // a rollout that hasn't been written to disk yet. When the resolved id
        // is missing, fall back to the most-recently-modified `*.jsonl` in the
        // project dir so the chip tracks the live transcript across rotations.
        let preferred = "\(dir)/\(sessionId).jsonl"
        let path: String
        if FileManager.default.fileExists(atPath: preferred) {
            path = preferred
        } else if let newest = newestTranscript(inDir: dir) {
            path = newest
        } else {
            return nil
        }
        guard let data = try? String(contentsOfFile: path, encoding: .utf8)
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
            isEstimate: false,
            breakdown: Breakdown(
                model: lastModel,
                input: u.input,
                cacheCreate: u.cacheCreate,
                cacheRead: u.cacheRead,
                source: "From last-turn `usage` in Claude transcript JSONL."
            )
        )
    }

    /// Claude budget by model ID. The whole Opus 4 family from 4-7 onward
    /// (opus-4-7, opus-4-8, …) ships a 1M-context window; sonnet/haiku and
    /// older opus use the standard 200k.
    ///
    /// Two signals, in order. First the `[1m]` bracket — a Claude Code UI
    /// label that's the explicit 1M marker when present. But that bracket
    /// only rides on the *live* model id; the transcript's `message.model`
    /// is the bare API id (`claude-opus-4-8`), so the bracket never matches
    /// on disk. That's why we also parse the Opus 4 minor version directly:
    /// any `opus-4-N` with N ≥ 7 is 1M. This auto-covers future Opus bumps
    /// (4-9, …) without another edit — the bug we just fixed was 4-8 falling
    /// through because only 4-7 was hardcoded.
    private static func claudeBudget(for model: String?) -> Int {
        guard let m = model?.lowercased() else { return 1_000_000 }
        if m.contains("[1m]") { return 1_000_000 }
        if let minor = opusFourMinor(in: m), minor >= 7 { return 1_000_000 }
        return 200_000
    }

    /// Parse the minor version N out of an `opus-4-N` / `opus-4.N` model id.
    /// Returns nil for non-Opus-4 ids. The N is read as a run of digits, so
    /// date-suffixed ids like `opus-4-8-20260115` resolve to 8, not 820260115.
    private static func opusFourMinor(in model: String) -> Int? {
        for sep in ["opus-4-", "opus-4."] {
            guard let r = model.range(of: sep) else { continue }
            let digits = model[r.upperBound...].prefix { $0.isNumber }
            if let n = Int(digits) { return n }
        }
        return nil
    }

    // MARK: - Gemini (precise — reads per-turn `tokens` field)

    private static func computeGemini(sessionId: String, cwd: String, max: Int = 1_000_000) -> ContextUsage? {
        // gemini-cli writes precise token counts per turn into the chat
        // JSONL: each model-side entry carries `tokens.{input,output,
        // cached,thoughts,tool,total}`. The "what's in the model's context
        // right now" signal is the most recent entry's `tokens.total` — same
        // pattern as Claude's last-assistant-entry usage block.
        //
        // -N collision walk: gemini-cli files chats under
        // `~/.gemini/tmp/<basename>/chats/` — but when two projects share
        // a cwd basename, the second one gets `<basename>-1`, `<basename>-2`
        // siblings. Without walking these, the resolver silently misses
        // and the chip falls back to the coarse hooks byte-estimate. Any
        // /compress auto-fire built on top of that would trigger on the
        // wrong signal. Walk all <basename>* siblings and merge their
        // chats/ contents, then pick the newest match across the union.
        let basename = (cwd as NSString).lastPathComponent
        let tmpDir = ("~/.gemini/tmp" as NSString).expandingTildeInPath
        let siblings: [String]
        if let all = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            let lowerBase = basename.lowercased()
            siblings = all.filter { entry in
                let lower = entry.lowercased()
                return lower == lowerBase || lower.hasPrefix("\(lowerBase)-")
            }
        } else {
            siblings = [basename]
        }
        let needle = String(sessionId.prefix(8))
        // (chatsDir, chatFile) pairs across every sibling.
        var candidates: [(String, String)] = []
        for sib in siblings {
            let chatsDir = "\(tmpDir)/\(sib)/chats"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: chatsDir) else { continue }
            for entry in entries where entry.contains(needle) {
                candidates.append((chatsDir, entry))
            }
        }
        guard !candidates.isEmpty else {
            return estimateFromHooks(sessionId: sessionId, max: max)
        }
        let resolved = candidates.max(by: { lhs, rhs in
            let aTime = (try? FileManager.default.attributesOfItem(atPath: "\(lhs.0)/\(lhs.1)")[.modificationDate] as? Date) ?? .distantPast
            let bTime = (try? FileManager.default.attributesOfItem(atPath: "\(rhs.0)/\(rhs.1)")[.modificationDate] as? Date) ?? .distantPast
            return aTime < bTime
        })
        guard let pick = resolved else {
            return estimateFromHooks(sessionId: sessionId, max: max)
        }
        let chatsDir = pick.0
        let match = pick.1
        let path = "\(chatsDir)/\(match)"

        if let t = lastGeminiTokenTotal(atPath: path) {
            return ContextUsage(
                tokens: t, max: max, isEstimate: false,
                breakdown: Breakdown(
                    model: "gemini",
                    input: t,
                    cacheCreate: nil,
                    cacheRead: nil,
                    source: "From last-turn `tokens.total` in gemini-cli chat JSONL."
                )
            )
        }
        // No tokens field anywhere — fall through to the coarse byte estimate.
        return estimateBytesAtPath(path, max: max)
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
    /// Newest `*.jsonl` transcript in a Claude project dir, by modification
    /// time. Used as the fallback when the resolved native-session id names a
    /// rollout that isn't on disk (post-`/compact` rotation, or a freshly
    /// minted id the agent hasn't written to yet).
    private static func newestTranscript(inDir dir: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }
        let jsonls = entries.filter { $0.hasSuffix(".jsonl") }
        return jsonls
            .map { "\(dir)/\($0)" }
            .max(by: { lhs, rhs in
                let a = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let b = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return a < b
            })
    }

    private static func estimateBytesAtPath(_ path: String, max: Int) -> ContextUsage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 0
        else { return nil }
        return ContextUsage(tokens: size / 4, max: max, isEstimate: true, breakdown: nil)
    }

    private static func lastGeminiTokenTotal(atPath path: String) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 256 * 1024
        let offset = end > tailBytes ? end - tailBytes : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(),
              let blob = String(data: data, encoding: .utf8)
        else { return nil }

        for line in blob.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any],
                  let total = geminiTokenTotal(from: tokens)
            else { continue }
            return total
        }
        return nil
    }

    private static func geminiTokenTotal(from tokens: [String: Any]) -> Int? {
        if let total = tokens["total"] as? Int {
            return total
        }
        if let inp = tokens["input"] as? Int {
            // Fallback for older entries that lack `total`: sum the
            // component counts we know about.
            let cached = (tokens["cached"] as? Int) ?? 0
            let thoughts = (tokens["thoughts"] as? Int) ?? 0
            return inp + cached + thoughts
        }
        return nil
    }

    private static func estimateFromHooks(sessionId: String, max: Int) -> ContextUsage? {
        // Hooks live under <SOUL_HOME>/sessions/<project>/<session>/hooks.jsonl,
        // with a legacy ~/soul_registry fallback during migration.
        // We don't know the project key here — walk the sessions tree and pick
        // the matching session dir. Cheap because we stop at first hit.
        for sessionsRoot in SoulRegistry.sessionRoots() {
            guard let projects = try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot) else {
                continue
            }
            for projKey in projects {
                let candidate = "\(sessionsRoot)/\(projKey)/\(sessionId)/hooks.jsonl"
                if FileManager.default.fileExists(atPath: candidate) {
                    return estimateBytesAtPath(candidate, max: max)
                }
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
