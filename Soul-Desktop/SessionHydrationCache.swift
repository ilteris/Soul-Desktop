import Foundation
import SoulCore
import SoulLedger

struct HydratedSessionSnapshot {
    let projectId: String
    let sessionId: String
    let provider: Provider
    let items: [ThreadItem]
    let historicalIDs: Set<UUID>
    let title: String?
    let nativeSessionId: String?
    let lastFinalizeInjectedAt: Date?
    let fingerprint: SessionHydrationFingerprint
}

struct SessionHydrationFingerprint: Hashable {
    struct FileStamp: Hashable {
        let path: String
        let modified: Date?
        let size: UInt64?
    }

    let hooks: FileStamp
    let agentChunks: FileStamp
    let finalize: FileStamp?
    let providerTranscript: FileStamp?

    static func current(projectKey: String, sessionId: String, projectPath: String, provider: Provider, nativeSessionId: String?) -> SessionHydrationFingerprint {
        let hooks = stamp(SoulRegistry.hooksPath(projectKey: projectKey, sessionId: sessionId))
        let agentChunks = stamp("\(SoulRegistry.sessionDir(projectKey: projectKey, sessionId: sessionId))/agent_chunks.jsonl")
        let transcriptId = nativeSessionId ?? sessionId
        return SessionHydrationFingerprint(
            hooks: hooks,
            agentChunks: agentChunks,
            finalize: latestFinalizeStamp(projectKey: projectKey, sessionId: sessionId),
            providerTranscript: providerTranscriptStamp(
                projectKey: projectKey,
                projectPath: projectPath,
                sessionId: transcriptId,
                provider: provider
            )
        )
    }

    private static func latestFinalizeStamp(projectKey: String, sessionId: String) -> FileStamp? {
        // Ledger-backed finalize events live inside hooks.jsonl, already
        // covered by the `hooks` stamp in this fingerprint. Only look for
        // legacy sidecar finalize JSON here so cache validation never scans
        // hooks on the main actor during a sidebar click.
        let fm = FileManager.default
        var candidates: [String] = []
        for dir in SoulRegistry.projectSessionDirs(projectKey) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where name.hasSuffix(".json") {
                let stem = String(name.dropLast(5))
                if stem == sessionId || stem.hasSuffix("_\(sessionId)") {
                    candidates.append("\(dir)/\(name)")
                }
            }
        }
        guard let path = candidates.sorted().last else { return nil }
        return stamp(path)
    }

    private static func stamp(_ path: String) -> FileStamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return FileStamp(
            path: path,
            modified: attrs?[.modificationDate] as? Date,
            size: (attrs?[.size] as? NSNumber)?.uint64Value
        )
    }

    private static func providerTranscriptStamp(projectKey: String, projectPath: String, sessionId sid: String, provider: Provider) -> FileStamp? {
        switch provider {
        case .claude:
            let encoded = projectPath.replacingOccurrences(of: "/", with: "-")
            let path = "\(NSHomeDirectory())/.claude/projects/\(encoded)/\(sid).jsonl"
            return FileManager.default.fileExists(atPath: path) ? stamp(path) : nil
        case .geminiCLI:
            return locateGeminiTranscript(projectKey: projectKey, sessionId: sid).map { stamp($0) }
        case .pi:
            return locatePiTranscript(projectPath: projectPath, sessionId: sid).map { stamp($0) }
        case .codex:
            return nil
        }
    }

    private static func locateGeminiTranscript(projectKey: String, sessionId sid: String) -> String? {
        let geminiBase = ("~/.gemini/tmp" as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        guard let topEntries = try? fileManager.contentsOfDirectory(atPath: geminiBase) else { return nil }
        let candidateDirs = topEntries.filter { $0 == projectKey || $0.hasPrefix("\(projectKey)-") }

        var candidates: [String] = []
        for dir in candidateDirs {
            let chatsDir = "\(geminiBase)/\(dir)/chats"
            guard let entries = try? fileManager.contentsOfDirectory(atPath: chatsDir) else { continue }
            for name in entries where name.hasSuffix(".jsonl") || name.hasSuffix(".json") {
                candidates.append("\(chatsDir)/\(name)")
            }
        }

        let shortId = String(sid.prefix(8))
        let prefixMatches = candidates.filter { ($0 as NSString).lastPathComponent.contains(shortId) }
        if let hit = prefixMatches.max(by: { size($0) < size($1) }), firstLineSessionId(atPath: hit) == sid {
            return hit
        }
        return candidates.first { firstLineSessionId(atPath: $0) == sid }
    }

    private static func locatePiTranscript(projectPath: String, sessionId sid: String) -> String? {
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        let encoded = "--" + parts.joined(separator: "-") + "--"
        let dir = "\(NSHomeDirectory())/.pi/agent/sessions/\(encoded)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return entries.first(where: { $0.hasSuffix("_\(sid).jsonl") }).map { "\(dir)/\($0)" }
    }

    private static func firstLineSessionId(atPath path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 512)
        guard let string = String(data: data, encoding: .utf8),
              let newline = string.range(of: "\n")
        else { return nil }
        let firstLine = String(string[..<newline.lowerBound])
        guard let lineData = firstLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return nil }
        return object["sessionId"] as? String
    }

    private static func size(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value) ?? 0
    }
}

enum HydratedSessionSnapshotBuilder {
    static func build(sessionId sid: String, project: SoulProject, provider: Provider) -> HydratedSessionSnapshot {
        let metadata = SoulRegistry.hooksMetadata(projectKey: project.id, sessionId: sid, provider: provider.rawValue)
        let nativeId = metadata.nativeSessionId
        let lookupId = nativeId ?? sid
        let baseItems = history(sessionId: sid, lookupId: lookupId, project: project, provider: provider)
        let built = buildItems(
            baseItems: baseItems,
            slashPrompts: metadata.slashPrompts,
            sessionId: sid,
            project: project,
            includeFinalize: true,
            finalizeRecord: metadata.latestFinalize,
            statusTail: statusTail(for: baseItems, project: project, sessionId: sid)
        )
        return HydratedSessionSnapshot(
            projectId: project.id,
            sessionId: sid,
            provider: provider,
            items: built.items,
            historicalIDs: built.historicalIDs,
            title: metadata.title,
            nativeSessionId: nativeId,
            lastFinalizeInjectedAt: built.lastFinalizeInjectedAt,
            fingerprint: .current(
                projectKey: project.id,
                sessionId: sid,
                projectPath: project.path,
                provider: provider,
                nativeSessionId: nativeId
            )
        )
    }

    private static func history(sessionId sid: String, lookupId: String, project: SoulProject, provider: Provider) -> [ThreadItem] {
        switch provider {
        case .claude:
            let ledger = HooksReader.events(forSession: sid, project: project).map(\.item)
            if hasUserAndAgent(ledger) { return ledger }
            return ClaudeTranscriptReader.transcript(forSession: lookupId, cwd: project.path) ?? ledger
        case .geminiCLI:
            let ledger = HooksReader.events(forSession: sid, project: project).map(\.item)
            if hasUserAndAgent(ledger) { return ledger }
            return GeminiTranscriptReader.transcript(forSession: lookupId, projectKey: project.id) ?? ledger
        case .pi:
            let ledger = HooksReader.events(forSession: sid, project: project).map(\.item)
            if hasUserAndAgent(ledger) { return ledger }
            return PiTranscriptReader.transcript(forSession: lookupId, cwd: project.path) ?? ledger
        case .codex:
            return HooksReader.events(forSession: sid, project: project).map(\.item)
        }
    }

    private static func hasUserAndAgent(_ items: [ThreadItem]) -> Bool {
        let hasUser = items.contains { if case .userMessage = $0 { return true } else { return false } }
        let hasAgent = items.contains { if case .agentMessage = $0 { return true } else { return false } }
        return hasUser && hasAgent
    }

    private static func statusTail(for baseItems: [ThreadItem], project: SoulProject, sessionId sid: String) -> String? {
        guard baseItems.isEmpty else { return nil }
        let hooksPath = SoulRegistry.hooksPath(projectKey: project.id, sessionId: sid)
        if FileManager.default.fileExists(atPath: hooksPath) {
            return "ℹ session ledger present but turn content was dropped at write-time — finalize summary above; new turns start fresh"
        }
        return "ℹ this session has no offline transcript on this machine — type to start a fresh chat"
    }

    private static func buildItems(
        baseItems: [ThreadItem],
        slashPrompts: [(text: String, timestamp: Date)],
        sessionId sid: String,
        project: SoulProject,
        includeFinalize: Bool,
        finalizeRecord: SoulRegistry.FinalizeRecord?,
        statusTail: String?
    ) -> (items: [ThreadItem], historicalIDs: Set<UUID>, lastFinalizeInjectedAt: Date?) {
        var hydrated = baseItems
        var hydratedIDs = Set(baseItems.map(\.id))
        insertSlashCommandPrompts(slashPrompts, into: &hydrated, historicalIDs: &hydratedIDs)

        var finalizeTs: Date? = nil
        if includeFinalize {
            finalizeTs = insertFinalizeSummary(finalizeRecord, sessionId: sid, into: &hydrated, historicalIDs: &hydratedIDs)
        }

        if let statusTail {
            let id = UUID()
            hydrated.append(.status(id: id, text: statusTail))
            hydratedIDs.insert(id)
        }

        return (hydrated, hydratedIDs, finalizeTs)
    }

    private static func insertFinalizeSummary(
        _ rec: SoulRegistry.FinalizeRecord?,
        sessionId sid: String,
        into hydrated: inout [ThreadItem],
        historicalIDs hydratedIDs: inout Set<UUID>
    ) -> Date? {
        guard let rec else { return nil }
        let hasContent = (rec.intent?.isEmpty == false)
            || (rec.summary?.isEmpty == false)
            || (rec.rationale?.isEmpty == false)
            || (rec.fixed?.isEmpty == false)
            || (rec.nextStep?.isEmpty == false)
        guard hasContent else { return nil }

        let finalizeTs = rec.timestamp ?? Date()
        if hydrated.contains(where: { item in
            guard case .finalize(_, _, _, _, _, _, let existingTs) = item else { return false }
            return abs(existingTs.timeIntervalSince(finalizeTs)) < 1
        }) {
            return finalizeTs
        }

        let id = UUID()
        let card = ThreadItem.finalize(
            id: id,
            intent: rec.intent,
            summary: rec.summary,
            rationale: rec.rationale,
            fixed: rec.fixed,
            nextStep: rec.nextStep,
            timestamp: finalizeTs
        )
        let insertAt = hydrated.firstIndex(where: { item in
            guard let ts = itemTimestamp(item) else { return false }
            return ts > finalizeTs
        }) ?? hydrated.endIndex
        hydrated.insert(card, at: insertAt)
        hydratedIDs.insert(id)
        return finalizeTs
    }

    private static func itemTimestamp(_ item: ThreadItem) -> Date? {
        switch item {
        case .userMessage(_, _, let ts): return ts
        case .branchSummary(_, _, _, _, let ts): return ts
        case .agentMessage(_, _, _, let ts): return ts
        case .agentThought(_, _, _, let ts): return ts
        case .agentProgress(_, _, _, let ts): return ts
        case .finalize(_, _, _, _, _, _, let ts): return ts
        case .toolCall, .plan, .status, .error, .toolCallGroup: return nil
        }
    }

    private static func insertSlashCommandPrompts(
        _ prompts: [(text: String, timestamp: Date)],
        into hydrated: inout [ThreadItem],
        historicalIDs hydratedIDs: inout Set<UUID>
    ) {
        guard !prompts.isEmpty else { return }

        for prompt in prompts {
            let dedupWindow: TimeInterval = 2
            let alreadyPresent = hydrated.contains { item in
                if case .userMessage(_, let text, let ts) = item,
                   text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.text,
                   abs(ts.timeIntervalSince(prompt.timestamp)) <= dedupWindow {
                    return true
                }
                return false
            }
            if alreadyPresent { continue }

            let id = UUID()
            let inserted: ThreadItem = .userMessage(id: id, text: prompt.text, timestamp: prompt.timestamp)
            let insertAt = hydrated.firstIndex { item in
                let ts: Date? = {
                    if case .userMessage(_, _, let t) = item { return t }
                    if case .agentMessage(_, _, _, let t) = item { return t }
                    return nil
                }()
                return ts.map { $0 > prompt.timestamp } ?? false
            } ?? hydrated.endIndex
            hydrated.insert(inserted, at: insertAt)
            hydratedIDs.insert(id)
        }
    }
}

@MainActor
final class SessionHydrationCache {
    private var snapshots: [String: HydratedSessionSnapshot] = [:]
    private var inFlight: [String: Task<HydratedSessionSnapshot, Never>] = [:]
    private var prewarmTask: Task<Void, Never>?

    func snapshot(project: SoulProject, sessionId: String, provider: Provider) -> HydratedSessionSnapshot? {
        let key = cacheKey(project: project, sessionId: sessionId, provider: provider)
        guard let cached = snapshots[key],
              cached.fingerprint == .current(
                projectKey: project.id,
                sessionId: sessionId,
                projectPath: project.path,
                provider: provider,
                nativeSessionId: cached.nativeSessionId
              )
        else {
            snapshots.removeValue(forKey: key)
            return nil
        }
        return cached
    }

    func buildOrReuse(project: SoulProject, sessionId: String, provider: Provider) async -> HydratedSessionSnapshot {
        let key = cacheKey(project: project, sessionId: sessionId, provider: provider)
        if let cached = snapshot(project: project, sessionId: sessionId, provider: provider) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task.detached(priority: .userInitiated) {
            HydratedSessionSnapshotBuilder.build(sessionId: sessionId, project: project, provider: provider)
        }
        inFlight[key] = task
        let snapshot = await task.value
        inFlight.removeValue(forKey: key)
        if !snapshot.items.isEmpty || snapshots[key]?.items.isEmpty != false {
            snapshots[key] = snapshot
        }
        return snapshot
    }

    func prewarm(sessions: [SoulSession], projects: [SoulProject], providerForSession: @escaping @MainActor (SoulSession) -> Provider) {
        prewarmTask?.cancel()
        let projectById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let candidates = Array(sessions.prefix(20))
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            for batch in candidates.chunked(into: 3) {
                if Task.isCancelled { return }
                await withTaskGroup(of: Void.self) { group in
                    for session in batch {
                        guard let project = projectById[session.project] else { continue }
                        let provider = providerForSession(session)
                        group.addTask { [weak self] in
                            _ = await self?.buildOrReuse(project: project, sessionId: session.id, provider: provider)
                        }
                    }
                }
            }
        }
    }

    func invalidate(projectId: String) {
        snapshots = snapshots.filter { !$0.key.hasPrefix("\(projectId)|") }
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func cacheKey(project: SoulProject, sessionId: String, provider: Provider) -> String {
        "\(project.id)|\(provider.rawValue)|\(project.path)|\(sessionId)"
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = Swift.min(index + size, endIndex)
            chunks.append(Array(self[index..<next]))
            index = next
        }
        return chunks
    }
}
