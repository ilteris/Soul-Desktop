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

enum ThreadItem: Identifiable, Hashable {
    case userMessage(id: UUID, text: String, timestamp: Date)
    case agentMessage(id: UUID, text: String, complete: Bool, timestamp: Date)
    case toolCall(id: UUID, kind: String, title: String, status: String, locationHint: String?)
    case plan(id: UUID, entries: [PlanEntry])
    case status(id: UUID, text: String)
    case error(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .userMessage(let id, _, _): return id
        case .agentMessage(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _): return id
        case .plan(let id, _): return id
        case .status(let id, _): return id
        case .error(let id, _): return id
        }
    }
}

@MainActor
@Observable
final class ThreadController {
    let id: String = UUID().uuidString.lowercased()
    let provider: Provider
    let project: SoulProject

    var items: [ThreadItem] = []
    var historicalIDs: Set<UUID> = []
    var isWorking: Bool = false
    var lastError: String?
    var availableCommands: [SlashCommand] = []
    var customTitle: String? = nil

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
            case .toolCall(_, let kind, let title, let status, let loc):
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        items.append(.userMessage(id: UUID(), text: trimmed, timestamp: Date()))
        openAgentMessageId = nil
        isWorking = true
        defer { isWorking = false }

        do {
            try await ensureSession()
            guard let client, let sid = sessionId else { return }
            _ = try await client.prompt(sessionId: sid, text: trimmed)
        } catch {
            let msg = "\(error)"
            items.append(.error(id: UUID(), text: msg))
            lastError = msg
        }
    }

    func cancel() async {
        guard let client, let sid = sessionId else { return }
        try? await client.cancel(sessionId: sid)
        items.append(.status(id: UUID(), text: "■ cancel sent"))
    }

    func loadSession(id sid: String) async {
        guard !hasInitialized else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await spawnAndInitialize(skipNewSession: true)
            guard let client else { return }

            let canLoad = supportsLoadSession && Self.looksLikeUUID(sid)
            if !canLoad {
                let reason = supportsLoadSession
                    ? "session ID is not a UUID (\(provider.label) requires UUIDs)"
                    : "\(provider.label) does not persist sessions"
                renderHistoryIfAvailable(sid: sid)
                items.append(.status(id: UUID(), text: "ℹ \(reason) — starting fresh"))
                let newSid = try await client.newSession(cwd: project.path)
                sessionId = newSid
                hasInitialized = true
                items.append(.status(id: UUID(), text: "✓ session/new: \(newSid.prefix(8))…"))
                return
            }

            do {
                try await client.loadSession(sessionId: sid, cwd: project.path)
                sessionId = sid
                hasInitialized = true
                items.append(.status(id: UUID(), text: "✓ session/load: \(sid.prefix(8))…"))
            } catch ACPClientError.rpcError {
                renderHistoryIfAvailable(sid: sid)
                items.append(.status(id: UUID(), text: "ℹ session could not be resumed — starting fresh"))
                let newSid = try await client.newSession(cwd: project.path)
                sessionId = newSid
                hasInitialized = true
                items.append(.status(id: UUID(), text: "✓ session/new: \(newSid.prefix(8))…"))
            }
        } catch {
            items.append(.error(id: UUID(), text: "load failed: \(error)"))
        }
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
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
        items.append(.status(id: UUID(), text: "✓ session/new: \(sid.prefix(8))…"))
    }

    private func spawnAndInitialize(skipNewSession: Bool) async throws {
        if client != nil { return }

        guard var spawn = ACPProviderSpawn.resolve(provider) else {
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

    private func handle(_ event: ACPClient.Event) {
        switch event {
        case .sessionUpdate(let note):
            apply(note.update)
        case .stderr:
            // Suppress noisy stderr in the conversation pane; smoke view is for debugging.
            break
        case .unknownNotification:
            break
        }
    }

    private func apply(_ update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(let block):
            if case .text(let chunk) = block { appendAgentChunk(chunk) }
        case .agentThoughtChunk:
            break
        case .toolCall(let payload):
            insertToolCall(payload, isUpdate: false)
        case .toolCallUpdate(let payload):
            insertToolCall(payload, isUpdate: true)
        case .plan(let payload):
            insertPlan(payload)
        case .availableCommandsUpdate(let payload):
            updateCommands(payload)
        case .currentModeUpdate, .userMessageChunk:
            break
        case .unknown:
            break
        }
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

        if let existingId = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == existingId }),
           case .toolCall(let id, let oldKind, let oldTitle, _, let oldLoc) = items[idx] {
            items[idx] = .toolCall(
                id: id,
                kind: oldKind,
                title: title.isEmpty ? oldTitle : title,
                status: status,
                locationHint: location ?? oldLoc
            )
            return
        }

        // Closing the open agent message when a tool call arrives keeps subsequent
        // chunks in a fresh bubble after the call returns.
        openAgentMessageId = nil

        let uuid = UUID()
        seenToolCallIds[toolId] = uuid
        items.append(.toolCall(
            id: uuid,
            kind: kind,
            title: title.isEmpty ? kind : title,
            status: status,
            locationHint: location
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
