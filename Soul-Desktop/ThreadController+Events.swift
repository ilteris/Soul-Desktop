import Foundation

/// Generic ACP event dispatch + the auto-titling subsystem, lifted out
/// of ThreadController. `handle(_:)` is the per-event router consumed by
/// the spawn-time event task in `spawnAndInitialize`; it forks ACP
/// session updates into `apply(_:)`, ACP requests into `handleACPRequest`,
/// and stderr/termination into status rows. The title cluster
/// (`sendSilent` + `generateTitle` + `runClaudePrint`) drives the
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
        guard let client, let sid = sessionId else { return nil }
        let nid = nativeSessionId ?? sid
        silentCapture = ""
        defer { silentCapture = nil }
        do {
            _ = try await client.prompt(sessionId: nid, text: text)
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

        // Snapshot the first user + first agent turn from items. Reading
        // @MainActor state from inside an actor-isolated method is free; the
        // detached subprocess work below uses only the captured strings.
        var firstUser: String?
        var firstAgent: String?
        for item in items {
            switch item {
            case .userMessage(_, let text, _) where firstUser == nil:
                firstUser = text
            case .agentMessage(_, let text, _, _) where firstAgent == nil:
                firstAgent = text
            default: break
            }
            if firstUser != nil && firstAgent != nil { break }
        }
        guard let user = firstUser, !user.isEmpty else { return }

        let raw: String?
        if let claude = which("claude") {
            raw = await Self.runClaudePrint(executable: claude, user: user, agent: firstAgent)
        } else {
            // Fallback: no `claude` on PATH. Use the active ACP session so the
            // feature still works, at the cost of polluting context with one
            // meta-turn. Same prompt shape as the subprocess path.
            raw = await sendSilent(
                "Summarize our conversation so far into a concise 3-5 word title. Respond with ONLY the title, no quotes, no prefix, no trailing punctuation."
            )
        }

        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        // Strip the quotes / trailing punctuation the agent sometimes adds
        // despite the instruction. Cap length so the sidebar row doesn't
        // truncate mid-word.
        let strip = CharacterSet(charactersIn: "\"'`.")
        title = title.trimmingCharacters(in: strip)
        if title.count > 60 { title = String(title.prefix(60)) }
        await MainActor.run { self.customTitle = title }
        // Persist so the disk-driven sidebar surfaces it on the next scan,
        // and so finalize/replay anchor on the same title the canvas shows.
        // `source: "llm"` so a future user-rename path can win on precedence.
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "Title",
            "text": title,
            "source": "llm",
        ])
    }

    /// Run `claude -p` with a title-generation prompt that embeds the first
    /// user turn (and, when present, the first agent reply) as context.
    /// Returns trimmed stdout on success, nil on spawn/exit failure.
    private static func runClaudePrint(executable: String, user: String, agent: String?) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            var prompt = "Produce a concise 3-5 word title for the following chat. Respond with ONLY the title — no quotes, no prefix, no trailing punctuation.\n\nUser: \(user)"
            if let agent, !agent.isEmpty {
                prompt += "\n\nAssistant: \(agent)"
            }

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

    func handle(_ event: ACPClient.Event) {
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
