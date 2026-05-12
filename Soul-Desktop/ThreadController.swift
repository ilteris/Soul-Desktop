import Foundation
import SwiftUI

struct PlanEntry: Hashable {
    let content: String
    let priority: String?
    let status: String?
}

struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String?
    let inputHint: String?
    var id: String { name }
}

/// Optional structured payload attached to a tool call. Today this carries
/// the before/after content for Edit/Write operations so the card can show
/// an inline diff on expand. Other tools (Read, Bash, Grep) leave this nil.
struct ToolCallDetails: Hashable {
    enum Kind: Hashable {
        case edit(oldString: String, newString: String)
        case write(content: String)
    }
    var kind: Kind
    /// First line of the edit in the source file when known (from ACP's
    /// `locations[0].line`). Used to label diff lines with their real
    /// in-file line numbers instead of starting at 1.
    var startLine: Int? = nil
}

enum ThreadItem: Identifiable, Hashable {
    case userMessage(id: UUID, text: String, timestamp: Date)
    case agentMessage(id: UUID, text: String, complete: Bool, timestamp: Date)
    case toolCall(id: UUID, kind: String, title: String, status: String, locationHint: String?, details: ToolCallDetails?)
    case plan(id: UUID, entries: [PlanEntry])
    case status(id: UUID, text: String)
    case error(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .userMessage(let id, _, _): return id
        case .agentMessage(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _): return id
        case .plan(let id, _): return id
        case .status(let id, _): return id
        case .error(let id, _): return id
        }
    }
}

/// Owns the live state of a single chat thread: the ordered ThreadItem list,
/// streaming agent message coalescing, tool-call lifecycle, and the bridge to
/// ACPClient for send/cancel/load. One instance per active thread.
@MainActor
@Observable
final class ThreadController {
    let id: String = UUID().uuidString.lowercased()
    let provider: Provider
    let project: SoulProject
    /// Best-effort wall-clock moment the underlying *session* started. For a
    /// fresh thread this is the instantiation time; AppShell overwrites it on
    /// session-load with the first hooks.jsonl event timestamp so the
    /// session-length chip reflects total session age, not "ms since this view
    /// opened."
    var startedAt: Date = Date()

    var items: [ThreadItem] = []
    var historicalIDs: Set<UUID> = []
    var isWorking: Bool = false
    var lastError: String?
    var availableCommands: [SlashCommand] = []
    var customTitle: String? = nil
    /// Per-thread permission policy. Default mirrors the previous behavior so
    /// existing flows don't regress; user can dial down via the composer chip.
    var permissionMode: PermissionMode = .fullAccess {
        didSet {
            let mode = permissionMode
            let c = client
            Task { await c?.setPermissionMode(mode) }
        }
    }
    /// Rolling capture of the agent's stderr + protocol-level errors. Bounded
    /// so a chatty agent can't bloat memory. Surfaced via the inactivity
    /// popover so the user has somewhere to look when the agent stalls.
    var agentLog: [String] = []
    /// Last time we received any event from the agent. Used to compute
    /// "quiet for Ns" once `isWorking` is true and nothing's streaming.
    var lastActivityAt: Date = Date()

    /// Sends issued while a turn is already running get parked here and
    /// drained in order once the current `client.prompt` resolves. Each
    /// entry carries both halves of the two-channel send so slash-expanded
    /// agent text and the bare-`/cmd` display bubble stay paired.
    struct QueuedPrompt: Hashable {
        let itemId: UUID
        let display: String
        let agent: String
    }
    var queuedPrompts: [QueuedPrompt] = []

    /// The set of `userMessage` item IDs that have been appended to `items`
    /// but not yet dispatched. ThreadView styles these bubbles with a
    /// "pending" look so the user can tell which prompts are queued vs. the
    /// one the agent is actively chewing on.
    var queuedItemIDs: Set<UUID> { Set(queuedPrompts.map(\.itemId)) }

    /// Per-thread scroll anchor. ThreadView records the top-most visible item
    /// as the user scrolls and restores it on re-appear so switching threads
    /// (multiplexer) doesn't snap each view back to the top.
    var scrollAnchorItemId: UUID? = nil
    /// True iff the anchor is the synthetic "__bottom__" sentinel. We store a
    /// separate bool because the sentinel isn't a UUID.
    var scrollAnchorAtBottom: Bool = true

    /// True while a `session/load` is in flight. The agent replays the prior
    /// transcript through `user_message_chunk` / `agent_message_chunk`
    /// notifications during the load — we still paint them, but flag the
    /// items as historical so they don't accidentally trigger one-shot
    /// behaviors like first-turn title generation.
    private var isReplayingLoad: Bool = false

    /// When non-nil, the next agent reply stream is captured into this buffer
    /// instead of being rendered in the canvas. Used for out-of-band prompts
    /// like title generation — same ACP session, same agent, no second model
    /// spawn, but the user never sees the round-trip. Tool calls during a
    /// silent prompt are also suppressed; title prompts shouldn't need tools,
    /// and if the agent calls one anyway, surfacing it would be more confusing
    /// than helpful.
    private var silentCapture: String? = nil

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }

        let firstUser: String? = items.lazy.compactMap {
            if case .userMessage(_, let t, _) = $0 { return t } else { return nil }
        }.first

        if let user = firstUser, !isBareSlashCommand(user) {
            return truncateForTitle(user)
        }

        let firstAgent: String? = items.lazy.compactMap {
            if case .agentMessage(_, let t, _, _) = $0 { return t } else { return nil }
        }.first

        if let agent = firstAgent, let line = firstMeaningfulLine(agent) {
            return truncateForTitle(line)
        }

        if let user = firstUser {
            return truncateForTitle(user)
        }
        return "New chat"
    }

    private func isBareSlashCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let body = trimmed.dropFirst()
        return !body.contains(" ") && !body.contains("\n") && !body.isEmpty
    }

    private func truncateForTitle(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }

    private func firstMeaningfulLine(_ text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Strip leading markdown markers
            while line.hasPrefix("#") || line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            // Strip simple inline markdown
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return line }
        }
        return nil
    }

    func markdownTranscript() -> String {
        var out = "# \(displayTitle)\n\n"
        for item in items {
            switch item {
            case .userMessage(_, let text, _):
                out += "**You:** \(text)\n\n"
            case .agentMessage(_, let text, _, _):
                out += "**\(provider.label):** \(text)\n\n"
            case .toolCall(_, let kind, let title, let status, let loc, _):
                out += "_\(kind): \(title)_ — \(status)\(loc.map { " (\($0))" } ?? "")\n\n"
            case .plan(_, let entries):
                out += "**Plan:**\n"
                for e in entries {
                    let mark = e.status == "completed" ? "x" : " "
                    out += "- [\(mark)] \(e.content)\n"
                }
                out += "\n"
            case .status, .error:
                continue
            }
        }
        return out
    }

    private var client: ACPClient?
    private(set) var sessionId: String?
    private var hasInitialized = false
    private var supportsLoadSession = false
    private var openAgentMessageId: UUID?
    private var seenToolCallIds: [String: UUID] = [:]
    private var eventTask: Task<Void, Never>?

    init(provider: Provider, project: SoulProject) {
        self.provider = provider
        self.project = project
    }

    func send(_ text: String) async {
        await send(display: text, agent: text)
    }

    /// Two-channel send: `display` is what the user sees in their own bubble;
    /// `agent` is what we actually ship over ACP. They diverge when a slash
    /// command expands client-side — the bubble keeps the bare `/cmd` chip
    /// while the agent receives the skill's full instructions + any args.
    ///
    /// While a turn is already in flight, additional sends queue rather than
    /// step on the live prompt. They paint as user bubbles immediately so the
    /// canvas reads chronologically, and dispatch to the agent in order once
    /// the current turn resolves. The behavior switch (queue vs steer-via-
    /// cancel) is the future home for a user setting; the queue side is the
    /// safe default.
    func send(display: String, agent: String) async {
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else { return }

        let messageId = UUID()
        items.append(.userMessage(id: messageId, text: trimmedDisplay, timestamp: Date()))
        openAgentMessageId = nil
        lastActivityAt = Date()
        // User just sent — they want to follow the response. Reset the scroll
        // anchor to "stick to bottom" so ThreadView's items.count auto-scroll
        // pins to the latest content regardless of where the view was before.
        scrollAnchorAtBottom = true
        scrollAnchorItemId = nil

        if isWorking {
            // Already running a turn; stash this for the dispatch loop to
            // pick up. UserPrompt is logged here so the hooks ledger
            // reflects the order the user sent things, not the order the
            // agent processed them.
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId ?? id, event: [
                "event": "UserPrompt",
                "text": trimmedDisplay,
            ])
            queuedPrompts.append(QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent))
            return
        }

        isWorking = true
        defer { isWorking = false }

        // First turn dispatches immediately; subsequent queued turns are
        // drained from `queuedPrompts` while we still hold `isWorking`.
        var current: QueuedPrompt? = QueuedPrompt(itemId: messageId, display: trimmedDisplay, agent: trimmedAgent)
        do {
            try await ensureSession()
            guard let client, let sid = sessionId else { return }

            while let turn = current {
                SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                    "event": "UserPrompt",
                    "text": turn.display,
                ])
                _ = try await client.prompt(sessionId: sid, text: turn.agent)

                // Post-turn title generation only on the very first user turn
                // of a fresh chat. Skip when draining queued prompts.
                let userPrompts = items.filter { if case .userMessage = $0 { return true } else { return false } }.count
                if userPrompts == 1 && customTitle == nil {
                    Task { await generateTitle() }
                }

                current = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
            }
        } catch {
            let msg = "\(error)"
            items.append(.error(id: UUID(), text: msg))
            lastError = msg
        }
    }

    /// Drop any queued-but-not-yet-sent prompts. Wired into `cancel()` and
    /// surfaced via a clear-X on the queue chip in the composer.
    func clearQueue() {
        queuedPrompts.removeAll()
    }

    func cancel() async {
        guard let client, let sid = sessionId else { return }
        // Drop any queued prompts — cancelling means "stop, don't keep going."
        // Letting them dispatch after the cancel would surprise the user.
        queuedPrompts.removeAll()
        try? await client.cancel(sessionId: sid)
        // Flip any still-running tool calls to a terminal "stopped" status so
        // the row stops claiming work is happening. Without this the orange
        // "in_progress" pill lingers indefinitely after the agent acks cancel.
        items = items.map { item in
            if case .toolCall(let id, let kind, let title, let status, let loc, let details) = item,
               status == "in_progress" || status == "pending" {
                return .toolCall(id: id, kind: kind, title: title, status: "stopped", locationHint: loc, details: details)
            }
            return item
        }
        // Guard against duplicate "cancel sent" rows when the user mashes the
        // cancel button — only append if the most recent status isn't already it.
        if case .status(_, let last)? = items.last, last == "■ cancel sent" {
            // already there
        } else {
            items.append(.status(id: UUID(), text: "■ cancel sent"))
        }
        isWorking = false
    }

    func loadSession(id sid: String) async {
        guard !hasInitialized else { return }
        isWorking = true
        defer { isWorking = false }
        guard Self.looksLikeUUID(sid) else {
            items.append(.error(id: UUID(), text: "session id is not a UUID; cannot resume"))
            return
        }

        // Soul kernel UUIDs and native agent session IDs (gemini-cli / Pi)
        // occupy different namespaces. We store the native ID in hooks.jsonl
        // at session start; if present, we use it for --resume. Otherwise the
        // session predates native-ID capture and isn't truly resumable — be
        // honest about that instead of asking the agent to resume a UUID it
        // never minted (gemini-cli would error or silently start fresh).
        let nativeId = SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid)

        // Restore custom title if one was generated/logged previously.
        customTitle = SoulRegistry.findTitle(projectKey: project.id, sessionId: sid)

        do {
            switch provider {
            case .claude, .geminiCLI:
                // Both report `agentCapabilities.loadSession: true` over ACP
                // and stream the prior transcript back as user/agent message
                // chunks during the load.
                try await spawnAndInitialize(skipNewSession: true)
                guard let client else { return }
                let resumeId = nativeId ?? sid

                // SAFETY: snapshot the agent's own chat file before letting
                // it try to load. We hit a regression where gemini-cli's
                // session/new fallback (triggered after a session/load
                // rpcError) reused the same sessionId and overwrote the
                // original 11MB transcript with a 228-byte stub. Copy first,
                // attempt load second; on disaster the user has `.bak-…`
                // sitting next to the file to recover from.
                let backupPath = Self.backupAgentChatIfPresent(
                    provider: provider,
                    sessionId: resumeId,
                    cwd: project.path
                )
                do {
                    isReplayingLoad = true
                    try await client.loadSession(sessionId: resumeId, cwd: project.path)
                    isReplayingLoad = false
                    sessionId = resumeId
                    hasInitialized = true
                    items.append(.status(id: UUID(), text: "✓ session/load: \(resumeId.prefix(8))…"))
                } catch ACPClientError.rpcError(let rpc) {
                    isReplayingLoad = false
                    // SOUL-SOUL_DESKTOP-022: before surfacing the error, try a
                    // content-match backfill. If our hooks ledger's first
                    // prompt matches one of the agent's native transcripts,
                    // we record the mapping and retry session/load once.
                    if let backfilled = SoulRegistry.backfillNativeSessionID(
                        projectKey: project.id,
                        sessionId: sid,
                        provider: provider.rawValue,
                        cwd: project.path
                    ), backfilled != resumeId {
                        items.append(.status(
                            id: UUID(),
                            text: "↻ backfilled native session id \(backfilled.prefix(8))… — retrying"
                        ))
                        do {
                            isReplayingLoad = true
                            try await client.loadSession(sessionId: backfilled, cwd: project.path)
                            isReplayingLoad = false
                            sessionId = backfilled
                            hasInitialized = true
                            items.append(.status(id: UUID(), text: "✓ session/load: \(backfilled.prefix(8))…"))
                            return
                        } catch {
                            isReplayingLoad = false
                            // Fall through to the original error reporting.
                        }
                    }
                    // Surface the full JSON-RPC error so we can diagnose
                    // why gemini's session/load actually failed (parse
                    // error in the transcript? cwd basename mismatch?
                    // capability gating?). Without this the symptom is
                    // opaque and we just route to the fallback blind.
                    let dataStr = Self.describeJSONValue(rpc.data)
                    let suffix = dataStr.isEmpty ? "" : " · data: \(dataStr)"
                    items.append(.error(
                        id: UUID(),
                        text: "session/load rpcError code=\(rpc.code) message=\(rpc.message)\(suffix)"
                    ))
                    if provider == .geminiCLI {
                        // Hard stop. Gemini-cli's session/new fallback under
                        // a same-UUID load failure is destructive (rewrites
                        // the chat file with an empty stub). Refuse the
                        // fallback, surface the backup path, and let the
                        // user decide whether to try again or recover.
                        if let backupPath {
                            items.append(.status(
                                id: UUID(),
                                text: "ℹ original chat file preserved at \(backupPath)"
                            ))
                        }
                        // Keep `hasInitialized` false so the canvas stays in
                        // a clear "not loaded" state instead of pretending a
                        // fresh thread.
                        return
                    }
                    // Claude: existing behavior (transcript file is at a
                    // different path and isn't touched by session/new).
                    renderHistoryIfAvailable(sid: sid)
                    items.append(.status(id: UUID(), text: "ℹ session could not be resumed — starting fresh"))
                    let newSid = try await client.newSession(cwd: project.path)
                    sessionId = newSid
                    hasInitialized = true
                    items.append(.status(id: UUID(), text: "✓ session/new: \(newSid.prefix(8))…"))
                }
            case .pi:
                // Pi-ACP hasn't been verified to support ACP loadSession yet;
                // keep the CLI `--resume` path until we test it the way
                // gemini-cli was tested. If `nativeId` is nil this still
                // attempts the Soul UUID, which fails honestly via the catch.
                if let nativeId {
                    try await spawnAndInitialize(skipNewSession: true, resumeSessionId: nativeId)
                    guard client != nil else { return }
                    sessionId = nativeId
                    hasInitialized = true
                    items.append(.status(id: UUID(), text: "✓ resumed: \(nativeId.prefix(8))… (\(provider.label) --resume)"))
                } else {
                    renderHistoryIfAvailable(sid: sid)
                    items.append(.status(id: UUID(), text: "ℹ this session predates resume support — viewing read-only. Send a message to continue as a fresh chat."))
                    try await spawnAndInitialize(skipNewSession: false)
                    if let newSid = sessionId {
                        items.append(.status(id: UUID(), text: "✓ session/new: \(newSid.prefix(8))… (\(provider.label))"))
                    }
                    hasInitialized = true
                }
            }
        } catch {
            isReplayingLoad = false
            items.append(.error(id: UUID(), text: "load failed: \(error)"))
        }
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Render a JSONValue payload as a compact string for the error row.
    /// We don't try to be cute about it — JSON-encode and truncate so any
    /// shape lands as a single readable line the user can copy back.
    private static func describeJSONValue(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) {
            return s.count > 400 ? String(s.prefix(400)) + "…" : s
        }
        return ""
    }

    /// Best-effort snapshot of the agent's chat file before a resume attempt.
    /// Copies `<chatsDir>/session-…-<first8>.json{,l}` → `<file>.bak-<epoch>`.
    /// Returns the backup path if a copy was made, nil otherwise. Failures
    /// are silent — this is belt-and-suspenders, not a correctness gate.
    private static func backupAgentChatIfPresent(provider: Provider, sessionId: String, cwd: String) -> String? {
        guard provider == .geminiCLI else { return nil }
        let basename = (cwd as NSString).lastPathComponent
        let chatsDir = ("~/.gemini/tmp/\(basename)/chats" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }
        let needle = String(sessionId.prefix(8))
        let candidates = entries.filter {
            ($0.hasSuffix("-\(needle).json") || $0.hasSuffix("-\(needle).jsonl"))
        }
        // Pick the largest matching file — that's the one with real history,
        // not a previous-attempt stub.
        let resolved = candidates.max(by: { a, b in
            let aSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(a)")[.size] as? Int) ?? 0
            let bSize = (try? fm.attributesOfItem(atPath: "\(chatsDir)/\(b)")[.size] as? Int) ?? 0
            return aSize < bSize
        })
        guard let match = resolved else { return nil }
        let src = "\(chatsDir)/\(match)"
        let stamp = Int(Date().timeIntervalSince1970)
        let dst = "\(src).bak-\(stamp)"
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// When ACP resume isn't possible, hydrate the canvas from the harness's own
    /// transcript file so the user at least sees the conversation they clicked on.
    /// New turns will go through session/new — no replay into the agent.
    private func renderHistoryIfAvailable(sid: String) {
        guard provider == .claude,
              let history = ClaudeTranscriptReader.transcript(forSession: sid, cwd: project.path),
              !history.isEmpty
        else { return }

        for it in history { historicalIDs.insert(it.id) }
        items.append(contentsOf: history)
        items.append(.status(id: UUID(), text: "─ history above (read-only) ─"))
    }

    func teardown() async {
        eventTask?.cancel()
        await client?.stop()
        client = nil
    }

    // MARK: - private

    private func ensureSession() async throws {
        if hasInitialized, client != nil, sessionId != nil { return }
        try await spawnAndInitialize(skipNewSession: false)
        guard let client else { return }
        let sid = try await client.newSession(cwd: project.path)
        sessionId = sid
        hasInitialized = true
        
        // Persist the provider's native sessionId alongside the kernel ledger
        // for this session. Identity-mapping for Soul-Desktop spawns (kernel
        // dir == gemini's sessionId), but keeping the explicit record means
        // findNativeSessionID always answers without falling back to `sid`.
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "NativeSessionID",
            "provider": provider.rawValue,
            "nativeId": sid,
            "cwd": project.path,
        ])
        
        items.append(.status(id: UUID(), text: "✓ session/new: \(sid.prefix(8))…"))
    }

    private func spawnAndInitialize(skipNewSession: Bool, resumeSessionId: String? = nil) async throws {
        if client != nil { return }

        guard var spawn = ACPProviderSpawn.resolve(provider, resumeSessionId: resumeSessionId) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no spawn config for \(provider.label)"])
        }

        items.append(.status(id: UUID(), text: "▶ hydrating Soul context for \(provider.label)…"))
        let hydration = await SoulHydration.prepare(
            provider: provider,
            projectKey: project.id,
            projectPath: project.path,
            sessionId: id
        )
        for line in hydration.log { items.append(.status(id: UUID(), text: line)) }

        var env = spawn.environment ?? [:]
        for (k, v) in hydration.env { env[k] = v }
        spawn.environment = env
        spawn.cwd = project.path

        let client = try ACPClient(spawn: spawn)
        self.client = client
        await client.setAutoAllow(true)
        await client.setPermissionMode(permissionMode)
        try await client.start()

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }

        let initResp = try await client.initialize()
        supportsLoadSession = initResp.agentCapabilities?.loadSession ?? false
        items.append(.status(id: UUID(), text: "✓ initialize: \(initResp.agentInfo?.name ?? "?") (proto \(initResp.protocolVersion))"))
    }

    /// Silent ACP round-trip: send `text` over the same session, capture the
    /// agent's reply chunks into a buffer instead of rendering them, return
    /// the accumulated string once the prompt resolves. Streaming routing is
    /// gated by `silentCapture` over in `apply(_:)`.
    private func sendSilent(_ text: String) async -> String? {
        guard let client, let sid = sessionId else { return nil }
        silentCapture = ""
        defer { silentCapture = nil }
        do {
            _ = try await client.prompt(sessionId: sid, text: text)
        } catch {
            print("[silent-prompt] failed: \(error)")
            return nil
        }
        let captured = silentCapture?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured, !captured.isEmpty else { return nil }
        return captured
    }

    private func generateTitle() async {
        guard let sid = sessionId else { return }
        let raw = await sendSilent(
            "Summarize our conversation so far into a concise 3-5 word title. Respond with ONLY the title, no quotes, no prefix, no trailing punctuation."
        )
        guard var title = raw, !title.isEmpty else { return }
        // Strip the quotes / trailing punctuation the agent sometimes adds
        // despite the instruction. Cap length so the sidebar row doesn't
        // truncate mid-word.
        let strip = CharacterSet(charactersIn: "\"'`.")
        title = title.trimmingCharacters(in: strip)
        if title.count > 60 { title = String(title.prefix(60)) }
        await MainActor.run { self.customTitle = title }
        // Persist so the disk-driven sidebar surfaces it on the next scan,
        // and so finalize/replay anchor on the same title the canvas shows.
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "Title",
            "text": title,
        ])
    }

    private func handle(_ event: ACPClient.Event) {
        lastActivityAt = Date()
        switch event {
        case .sessionUpdate(let note):
            apply(note.update)
        case .stderr(let line):
            appendAgentLog(line)
        case .unknownNotification:
            break
        }
    }

    private func appendAgentLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agentLog.append(trimmed)
        // Cap at 400 lines so a hot-streaming agent can't balloon memory.
        if agentLog.count > 400 {
            agentLog.removeFirst(agentLog.count - 400)
        }
    }

    private func apply(_ update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(let block):
            if case .text(let chunk) = block {
                if silentCapture != nil {
                    silentCapture? += chunk
                } else {
                    appendAgentChunk(chunk)
                }
            }
        case .agentThoughtChunk:
            break
        case .toolCall(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: false)
        case .toolCallUpdate(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: true)
        case .plan(let payload):
            insertPlan(payload)
        case .availableCommandsUpdate(let payload):
            updateCommands(payload)
        case .userMessageChunk(let block):
            // The agent replays prior user turns through this stream during
            // `session/load`. Each chunk is the full text of one turn (not a
            // partial stream). Closing the open agent bubble ensures turn
            // boundaries paint cleanly when several turns replay in sequence.
            if case .text(let text) = block,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openAgentMessageId = nil
                // Claude Code wraps locally-executed slash command output in
                // `<local-command-*>` scaffolding tags before injecting them
                // back into the chat stream. Without filtering, those tags
                // would render verbatim as user bubbles. Strip / re-route.
                let classified = classifyLocalCommand(text)
                switch classified {
                case .skip:
                    break
                case .status(let inner):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    items.append(.status(id: id, text: inner))
                case .message(let cleaned):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    items.append(.userMessage(id: id, text: cleaned, timestamp: Date()))
                }
            }
        case .currentModeUpdate:
            break
        case .unknown:
            break
        }
    }

    /// Classification of a user-message-chunk that may contain Claude Code's
    /// `<local-command-*>` scaffolding. The scaffolding is protocol-internal
    /// noise (caveat reminders for the model), command output (stdout/stderr),
    /// or a real user prompt with no tags. We route each shape to the right
    /// item type so the chat history doesn't surface raw XML.
    private enum LocalCommandShape {
        case skip                  // caveat-only / pure scaffolding → drop
        case status(String)        // command stdout/stderr → small status line
        case message(String)       // real user text (possibly with caveat stripped)
    }

    private func classifyLocalCommand(_ raw: String) -> LocalCommandShape {
        var stripped = raw.replacingOccurrences(
            of: "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // <task-notification> blocks come from Claude's background-task
        // tracker (e.g. a long-running Bash that was killed). Collapse to
        // a small status line using the <summary> field if present —
        // otherwise drop the block entirely. Either way the surrounding
        // XML never renders as a user bubble.
        if let regex = try? NSRegularExpression(pattern: "<task-notification>([\\s\\S]*?)</task-notification>") {
            let ns = stripped as NSString
            let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                guard m.numberOfRanges >= 2 else { continue }
                let inner = ns.substring(with: m.range(at: 1))
                let summaryRegex = try? NSRegularExpression(pattern: "<summary>([\\s\\S]*?)</summary>")
                let innerNS = inner as NSString
                let smatch = summaryRegex?.firstMatch(in: inner, range: NSRange(location: 0, length: innerNS.length))
                let summary = smatch.flatMap { sm -> String? in
                    guard sm.numberOfRanges >= 2 else { return nil }
                    return innerNS.substring(with: sm.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
                let replacement = summary.isEmpty ? "" : "[task] \(summary)"
                stripped = (stripped as NSString).replacingCharacters(in: m.range, with: replacement)
            }
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Pull out stdout/stderr inner text if present.
        let streamPattern = "<local-command-(stdout|stderr)>([\\s\\S]*?)</local-command-\\1>"
        if let regex = try? NSRegularExpression(pattern: streamPattern) {
            let ns = stripped as NSString
            let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let parts = matches.compactMap { m -> String? in
                    guard m.numberOfRanges >= 3 else { return nil }
                    return ns.substring(with: m.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return joined.isEmpty ? .skip : .status(joined)
            }
        }

        if stripped.isEmpty { return .skip }
        // If what remains is just our injected "[task] ..." marker(s),
        // route to status instead of user bubble.
        if stripped.split(separator: "\n").allSatisfy({ $0.hasPrefix("[task] ") }) {
            return .status(stripped)
        }
        return .message(stripped)
    }

    private func appendAgentChunk(_ chunk: String) {
        if let openId = openAgentMessageId,
           let idx = items.firstIndex(where: { $0.id == openId }),
           case .agentMessage(let id, let existing, _, let ts) = items[idx] {
            items[idx] = .agentMessage(id: id, text: existing + chunk, complete: false, timestamp: ts)
        } else {
            let id = UUID()
            openAgentMessageId = id
            items.append(.agentMessage(id: id, text: chunk, complete: false, timestamp: Date()))
        }
    }

    private func insertToolCall(_ payload: JSONValue, isUpdate: Bool) {
        let toolId = payload["toolCallId"]?.stringValue ?? UUID().uuidString
        let kind = payload["kind"]?.stringValue ?? "tool"
        let rawTitle = payload["title"]?.stringValue ?? ""
        let status = payload["status"]?.stringValue ?? "pending"

        // Claude (and most ACP agents) attach a human-readable description to
        // every tool call's rawInput — "Search for X", "List dotfiles". For
        // Bash calls especially, the title field is the raw command, which is
        // useless as a chip headline. Prefer description when present, and
        // surface the command underneath as location.
        let rawInput = payload["rawInput"]
        let description = rawInput?["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = rawInput?["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let title: String = {
            if !description.isEmpty { return description }
            return rawTitle
        }()

        let location: String? = {
            if kind == "execute", !command.isEmpty { return command }
            return firstLocation(payload)
        }()

        if status == "failed" {
            ToolFailureLog.dump(payload: payload, provider: provider, sessionId: sessionId)
        }

        // Try structured extraction from rawInput first. ACP `tool_call_update`
        // notifications often re-send the same toolCallId with only the
        // status/output changing, so rawInput is empty on later updates.
        // We must NOT overwrite a previously-captured structured payload
        // with the JSON fallback when an update arrives empty-handed.
        let startLine: Int? = {
            guard case .array(let locs)? = payload["locations"], let first = locs.first,
                  let line = first["line"], case .int(let l) = line else { return nil }
            return l
        }()
        let structuredDetails: ToolCallDetails? = {
            guard let rawInput else { return nil }
            let oldS = rawInput["old_string"]?.stringValue ?? rawInput["oldString"]?.stringValue
            let newS = rawInput["new_string"]?.stringValue ?? rawInput["newString"]?.stringValue
            if let oldS, let newS {
                return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS), startLine: startLine)
            }
            if let content = rawInput["content"]?.stringValue ?? rawInput["new_str"]?.stringValue {
                return ToolCallDetails(kind: .write(content: content), startLine: startLine)
            }
            return nil
        }()

        if let existingId = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == existingId }),
           case .toolCall(let id, let oldKind, let oldTitle, _, let oldLoc, let oldDetails) = items[idx] {
            items[idx] = .toolCall(
                id: id,
                kind: oldKind,
                title: title.isEmpty ? oldTitle : title,
                status: status,
                locationHint: location ?? oldLoc,
                details: structuredDetails ?? oldDetails
            )
            return
        }

        // Closing the open agent message when a tool call arrives keeps subsequent
        // chunks in a fresh bubble after the call returns.
        openAgentMessageId = nil

        // First time we're seeing this toolCallId. Use structured details
        // when we have them. Otherwise only fall back to the JSON-payload
        // dump for tools that *should* carry diff-shaped input (edit /
        // write). For Bash / Read / Grep / etc. there's nothing useful to
        // expand into, so leave details nil and the chevron stays hidden.
        let firstSeenDetails: ToolCallDetails? = {
            if let s = structuredDetails { return s }
            guard kind == "edit" || kind == "write" else { return nil }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? enc.encode(payload),
               let s = String(data: data, encoding: .utf8) {
                return ToolCallDetails(kind: .write(content: s))
            }
            return nil
        }()

        let uuid = UUID()
        seenToolCallIds[toolId] = uuid
        items.append(.toolCall(
            id: uuid,
            kind: kind,
            title: title.isEmpty ? kind : title,
            status: status,
            locationHint: location,
            details: firstSeenDetails
        ))
    }

    private func updateCommands(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["availableCommands"] ?? payload["commands"] else { return }
        let cmds: [SlashCommand] = raw.compactMap { c in
            guard let name = c["name"]?.stringValue else { return nil }
            let hint = c["input"]?["hint"]?.stringValue
            return SlashCommand(
                name: name,
                description: c["description"]?.stringValue,
                inputHint: hint
            )
        }
        availableCommands = cmds.sorted { $0.name < $1.name }
    }

    private func insertPlan(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["entries"] else { return }
        let entries: [PlanEntry] = raw.map { e in
            PlanEntry(
                content: e["content"]?.stringValue ?? "",
                priority: e["priority"]?.stringValue,
                status: e["status"]?.stringValue
            )
        }
        guard !entries.isEmpty else { return }

        if let idx = items.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
            if case .plan(let id, _) = items[idx] {
                items[idx] = .plan(id: id, entries: entries)
                return
            }
        }
        openAgentMessageId = nil
        items.append(.plan(id: UUID(), entries: entries))
    }

    private func firstLocation(_ payload: JSONValue) -> String? {
        guard case .array(let locs)? = payload["locations"], let first = locs.first else { return nil }
        let path = first["path"]?.stringValue ?? ""
        if let line = first["line"], case .int(let l) = line { return "\(path):\(l)" }
        return path.isEmpty ? nil : path
    }
}
