import Foundation
import SoulCore

/// Background LLM helper that turns an in-progress conversation into a
/// concise opening message the user can edit/send when continuing in
/// another provider ("Branch to Claude" / "Branch to Gemini" / etc).
///
/// Why a background LLM instead of a deterministic synthesis: the user's
/// own one-line bridge prompt ("we're trying to make truss-cli wrap
/// gemini-stock; hit a ModuleNotFoundError") was empirically what made
/// cross-provider handoff work for them. A model is better at producing
/// that one-line bridge than a static "first user prompt + last reply"
/// concat — it can read intent + current state and write the summary
/// the user would write themselves.
///
/// Same subprocess pattern as `ThreadController+Events.runClaudePrint`
/// (used by title generation) — invokes `claude -p` if available, returns
/// empty string on failure so the composer just stays empty (user can
/// type their own opener — no worse than today).
enum ComposeBranchSeed {

    /// Produce a 1-3 sentence opener from `items`. Returns "" on any
    /// failure path - caller treats empty as "no seed, user types fresh."
    static func run(
        items: [ThreadItem],
        sourceProvider: Provider,
        targetProvider: Provider
    ) async -> String {
        let transcript = composeCompactTranscript(items: items)
        guard !transcript.isEmpty else { return "" }
        guard let claudeExec = Self.which("claude") else { return "" }
        let prompt = """
        You are helping a user continue a conversation in a fresh chat with a different AI assistant. Below is the recent transcript of their conversation with \(sourceProvider.label). They are about to switch to \(targetProvider.label) and need a single concise opening message they can edit/send to pick up where they left off.

        Rules:
        - Write in first person, from the user's perspective ("we're working on…", "I'm trying to…")
        - Mention the goal and the current state or blocker
        - Output ONLY the message text — no quotes, no preamble, no "here's your message", no markdown formatting
        - Aim for 200-500 characters

        CONVERSATION:
        \(transcript)
        """
        let raw = await runClaudeSubprocess(executable: claudeExec, prompt: prompt)
        return sanitizeSeed(raw)
    }

    static func fallbackSeed(
        sourceTitle: String,
        sourceProvider: Provider,
        targetProvider: Provider
    ) -> String {
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPlaceholder(title), title != "New chat" else { return "" }
        return "Continue the \(sourceProvider.label) session in \(targetProvider.label): \(title). First inspect the current repo state, then pick up the work from there."
    }

    /// Pack items into a compact transcript: first user prompt (gives the
    /// original intent) plus the last few exchanges (gives current state).
    /// Skips tool calls, status rows, soul_trace blocks — those are noise
    /// for the summarization model.
    private static func composeCompactTranscript(items: [ThreadItem]) -> String {
        var firstUser: String? = nil
        var tail: [(role: String, text: String)] = []
        let tailBudget = 6  // last N user+agent items
        let perTurnCap = 800

        for item in items {
            switch item {
            case .userMessage(_, let text, _):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                if firstUser == nil { firstUser = String(clean.prefix(perTurnCap)) }
                tail.append((role: "User", text: String(clean.prefix(perTurnCap))))
            case .agentMessage(_, let text, _, _):
                let visible = SoulTrace.extract(from: text).visible
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !visible.isEmpty, !isPlaceholder(visible) else { continue }
                tail.append((role: "Assistant", text: String(visible.prefix(perTurnCap))))
            default:
                continue
            }
        }

        if tail.isEmpty { return "" }
        let trimmed = Array(tail.suffix(tailBudget))
        var lines: [String] = []
        // Echo the first user prompt up top if it's not already in the tail
        // window — important when the conversation has drifted far from
        // where it started.
        if let first = firstUser,
           let firstTail = trimmed.first,
           !(firstTail.role == "User" && firstTail.text == first) {
            lines.append("Original goal — User: \(first)")
            lines.append("")
            lines.append("--- recent turns ---")
        }
        for entry in trimmed {
            lines.append("\(entry.role): \(entry.text)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Invoke `claude -p <prompt>` off-main and return stdout. nil on any
    /// spawn/exit failure (caller treats as empty seed).
    private static func runClaudeSubprocess(executable: String, prompt: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-p", prompt]
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                return nil
            }
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    private static func sanitizeSeed(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stripped = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlaceholder(stripped) ? "" : stripped
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "(no response)"
            || normalized == "no response"
            || normalized == "(empty)"
            || normalized == "empty"
            || normalized == "new chat"
    }

    /// Resolve a binary from $PATH. Mirrors `ThreadController.which` (private
    /// there) so this file is self-contained — branch seed shouldn't reach
    /// across the controller for a utility helper.
    private static func which(_ binary: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let homeBin = NSHomeDirectory() + "/bin"
        let candidates = [homeBin] + paths
        let fm = FileManager.default
        for dir in candidates {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
