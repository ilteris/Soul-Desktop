import Foundation
import SoulACP
import SoulCore
import SoulLedger
import SoulRuntime

/// Generic ACP event dispatch + the auto-titling subsystem, lifted out
/// of ThreadController. `handle(_:)` is the per-event router consumed by
/// the spawn-time event task in `spawnAndInitialize`; it forks ACP
/// session updates into `apply(_:)`, ACP requests into `handleACPRequest`,
/// and stderr/termination into status rows. The title cluster
/// (`sendSilent` + `generateTitle` + `runGeminiPrint`) drives the
/// post-turn synthetic prompt that asks the agent for a short title and
/// captures the reply silently (no canvas render).
///
/// Pure file shuffle, no behavior change. Refactor 10/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
extension ThreadController {

    /// Silent ACP round-trip: send `text` over the same session, capture the
    /// agent's reply chunks into a buffer instead of rendering them, return
    /// the accumulated string once the prompt resolves. Streaming routing is
    /// gated by `silentCapture` over in `apply(_:)`.
    private func sendSilent(_ text: String) async -> String? {
        guard sessionId != nil else { return nil }
        silentCapture = ""
        defer { silentCapture = nil }
        do {
            try await runtimes.acp?.prompt(ProviderRuntimePromptRequest<ContentBlock>(
                session: runtimeSessionSnapshot(),
                text: text
            ))
        } catch {
            print("[silent-prompt] failed: \(error)")
            return nil
        }
        let captured = silentCapture?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured, !captured.isEmpty else { return nil }
        return captured
    }

    func generateTitle() async {
        guard let sid = sessionId else { return }

        // Snapshot the first real user prompts + first agent turn from items.
        // Harness scaffolds can be ledgered as user messages; passing those
        // to the title LLM is how raw XML/path output becomes a persisted
        // Title hook.
        var userPrompts: [String] = []
        var firstAgent: String?
        for item in items {
            switch item {
            case .userMessage(_, let text, _):
                let cleaned = SoulRegistry.stripCommandTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if case .prose = SessionTitleResolver.classify(cleaned), !SessionTitleResolver.isPlaceholderTitle(cleaned) {
                    userPrompts.append(cleaned)
                }
            case .agentMessage(_, let text, _, _) where firstAgent == nil:
                firstAgent = text
            default: break
            }
            if userPrompts.count >= 3 && firstAgent != nil { break }
        }
        guard !userPrompts.isEmpty else { return }

        let raw: String?
        if let bundled = Self.bundledGeminiPrintSpawn() {
            raw = await Self.runGeminiPrint(
                executable: bundled.executable,
                argumentsPrefix: bundled.argumentsPrefix,
                users: userPrompts,
                agent: firstAgent
            )
        } else if let gemini = which("gemini") {
            raw = await Self.runGeminiPrint(
                executable: gemini,
                argumentsPrefix: [],
                users: userPrompts,
                agent: firstAgent
            )
        } else {
            // Fallback: no `gemini` on PATH. Use the active ACP session so the
            // feature still works, at the cost of polluting context with one
            // meta-turn. Same prompt shape as the subprocess path.
            raw = await sendSilent(Self.titleGenerationPrompt(users: userPrompts, agent: firstAgent))
        }

        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        // Strip the quotes / trailing punctuation the agent sometimes adds
        // despite the instruction. Cap length so the sidebar row doesn't
        // truncate mid-word.
        let strip = CharacterSet(charactersIn: "\"'`.")
        title = title.trimmingCharacters(in: strip)
        // LLMs sometimes hallucinate `<command-name>` / `<local-command-*>`
        // wrappers around the title text because they see these tags in the
        // prompt context and reflect them back. Strip before persisting so a
        // bad title can't get cached into the Title hook and re-loaded as
        // customTitle on every subsequent session open.
        title = SoulRegistry.stripCommandTags(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if title.count > 60 { title = String(title.prefix(60)) }
        await MainActor.run { self.customTitle = title }
        // Persist so the disk-driven sidebar surfaces it on the next scan,
        // and so finalize/replay anchor on the same title the canvas shows.
        // `source: "llm"` so a future user-rename path can win on precedence.
        SoulRegistry.appendHook(
            projectKey: project.id,
            sessionId: sid,
            event: LedgerHookEvent.title(text: title, source: "llm").hookDictionary
        )
    }

    /// Run `gemini -p` with a title-generation prompt that embeds the first
    /// few substantive user turns (and, when present, the first agent reply)
    /// as context.
    /// Returns trimmed stdout on success, nil on spawn/exit failure.
    private static func runGeminiPrint(
        executable: String,
        argumentsPrefix: [String],
        users: [String],
        agent: String?
    ) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let prompt = titleGenerationPrompt(users: users, agent: agent)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = argumentsPrefix + ["-p", prompt, "--output-format", "text"]
            var env = ProcessInfo.processInfo.environment
            env["SOUL_SESSION_VISIBILITY"] = "machine"
            env["SOUL_SESSION_KIND"] = "title_generation"
            p.environment = env
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

    private nonisolated static func bundledGeminiPrintSpawn() -> (executable: String, argumentsPrefix: [String])? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let entry = resources
            .appendingPathComponent("GeminiCLI")
            .appendingPathComponent("bundle")
            .appendingPathComponent("gemini.js")
            .path
        guard FileManager.default.fileExists(atPath: entry),
              let node = which("node") else {
            return nil
        }
        return (node, [entry])
    }

    private nonisolated static func titleGenerationPrompt(users: [String], agent: String?) -> String {
        let userContext = users.prefix(3).enumerated().map { idx, text in
            "User \(idx + 1):\n\(text)"
        }.joined(separator: "\n\n")

        var prompt = """
        Generate a title for this chat session.

        Title copy should be glanceable and specific.
        - Title: what this thread now is (state + object).
        - Aim for 4-8 words.
        - Explain what was built, fixed, decided, investigated, or requested.
        - Prefer concrete nouns + verbs.
        - Include a crisp status cue when helpful: blocked, needs decision, ready for review, fixed, verified.
        - Avoid generic titles like "Update", "Done", "FYI", "Following up", "Chat", "Question", "Help", or "Untitled".
        - Do not copy a long user prompt verbatim.

        Respond with ONLY the title. No quotes, no prefix, no trailing punctuation.

        Chat context:

        \(userContext)
        """

        if let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nAssistant:\n\(agent)"
        }
        return prompt
    }

    func handle(_ event: ACPClient.Event) {
        // SOUL-210: while a Stop is mid-flight, drop session/update
        // notifications so the agent can't stream more rows after the
        // user clicked Stop. The .terminated event MUST still pass so
        // the controller knows the child has actually exited.
        if isCancelling {
            if case .terminated = event { /* allow */ } else { return }
        }
        // Don't bump activity during the agent's replay-transcript stream.
        // session/load streams every historical user/agent chunk back to us;
        // counting those as "activity" makes the sidebar row jump to the top
        // with an "in 0 sec." timestamp even though the user only clicked to
        // open. Real user activity (send, fresh assistant turn) bumps via
        // send() and the post-replay handler.
        if !isReplayingLoad {
            lastActivityAt = Date()
        }
        // Activity arrived — clear the stall flag so the next stall episode
        // gets its own StallDetected hook instead of being silently suppressed
        // by the prior turn's debounce.
        stallHookEmittedAt = nil
        switch event {
        case .sessionUpdate(let note):
            apply(note.update)
        case .stderr(let line):
            appendAgentLog(line)
        case .request(let id, let method, let params):
            Task { [weak self] in
                await self?.handleACPRequest(id: id, method: method, params: params)
            }
        case .unknownNotification(let method, let params):
            // Diagnostic: any JSON-RPC notification whose method we don't
            // recognize. pi-acp may stream progress via custom methods that
            // bypass session/update entirely. Log so we can see them in the
            // agent log instead of silently dropping.
            let preview = params.map { String(describing: $0).prefix(240) } ?? "<nil>"
            appendAgentLog("[unknown notif] method=\(method) params=\(preview)")
        case .terminated(let cause):
            // Child agent went away. Surface a status row so the user
            // notices instead of staring at a working spinner that will
            // never resolve. Pending continuations are already drained by
            // ACPClient; the rpcError / writeFailed / childTerminated
            // throws land in whichever send path was awaiting.
            appendAgentLog("[child terminated] \(cause)")
            if isWorking {
                isWorking = false
            }
            items.append(.status(id: UUID(), text: "■ agent process ended: \(cause)"))
        }
    }

}
