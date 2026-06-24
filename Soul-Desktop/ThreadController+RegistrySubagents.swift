import Foundation
import SoulCore

/// Registry-backed subagent visibility for Gemini.
///
/// Gemini's ACP stream can be quiet for minutes while the Soul kernel has
/// already created `sessions/<project>/subagents/<id>/live.log`. This monitor
/// bridges that gap by inserting the same SubagentCard-backed ThreadItem that
/// an ACP `delegate_to_specialist` update would eventually create.
extension ThreadController {
    private static let registrySubagentPollIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let registrySubagentStartGrace: TimeInterval = 15

    func startRegistrySubagentMonitorIfNeeded() {
        guard provider == .geminiCLI else { return }
        guard registrySubagentMonitorTask == nil else { return }
        guard sessionId?.isEmpty == false else { return }
        let startedAt = turnStartedAt ?? Date()
        registrySubagentMonitorStartedAt = startedAt

        registrySubagentMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRegistrySubagentCards()
                do {
                    try await Task.sleep(nanoseconds: Self.registrySubagentPollIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stopRegistrySubagentMonitor() {
        registrySubagentMonitorTask?.cancel()
        registrySubagentMonitorTask = nil
        registrySubagentMonitorStartedAt = nil
        registryInjectedSubagentIDs.removeAll()
    }

    private func refreshRegistrySubagentCards() async {
        guard isWorking, provider == .geminiCLI else { return }
        guard let sessionId, !sessionId.isEmpty else { return }
        let projectKey = project.id
        async let records = Self.loadRegistrySubagents(projectKey: projectKey)
        async let allowedIDs = Self.loadSessionDelegationIDs(projectKey: projectKey, sessionId: sessionId)
        let loaded = await records
        let allowed = await allowedIDs
        guard !Task.isCancelled, isWorking, provider == .geminiCLI else { return }
        applyRegistrySubagentRecords(
            loaded,
            monitorStartedAt: registrySubagentMonitorStartedAt,
            allowedSubagentIDs: allowed,
            sessionId: sessionId
        )
    }

    nonisolated private static func loadRegistrySubagents(projectKey: String) async -> [SoulSubagentRecord] {
        guard let payload = try? await SoulCLI.runJSON(
            ["subagent", "list", "-p", projectKey, "--json"],
            as: SoulSubagentListPayload.self
        ) else {
            return []
        }
        return payload.subagents
    }

    func applyRegistrySubagentRecords(_ records: [SoulSubagentRecord], monitorStartedAt: Date?) {
        applyRegistrySubagentRecords(
            records,
            monitorStartedAt: monitorStartedAt,
            allowedSubagentIDs: nil,
            sessionId: nil
        )
    }

    func applyRegistrySubagentRecords(
        _ records: [SoulSubagentRecord],
        monitorStartedAt: Date?,
        allowedSubagentIDs: Set<String>?,
        sessionId: String?
    ) {
        let cutoff = (monitorStartedAt ?? registrySubagentMonitorStartedAt ?? Date())
            .addingTimeInterval(-Self.registrySubagentStartGrace)

        for record in records {
            if let sessionId, !sessionId.isEmpty {
                let parentSessionID = record.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parentSessionID, !parentSessionID.isEmpty {
                    guard parentSessionID == sessionId else { continue }
                } else if let allowedSubagentIDs, !allowedSubagentIDs.contains(record.subagentID) {
                    continue
                }
            }

            let alreadyInjected = registryInjectedSubagentIDs.contains(record.subagentID)
            let startedAt = record.startedAt.map { Date(timeIntervalSince1970: $0) } ?? record.timestamp
            let recentActive = record.isActive && (startedAt == nil || startedAt! >= cutoff)
            guard alreadyInjected || recentActive else { continue }

            upsertRegistrySubagentRecord(record)
            registryInjectedSubagentIDs.insert(record.subagentID)
        }
    }

    nonisolated private static func loadSessionDelegationIDs(projectKey: String, sessionId: String) -> Set<String> {
        let path = "\(SoulRegistry.primarySessionsRoot)/\(projectKey)/\(sessionId)/hooks.jsonl"
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return []
        }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String,
                  event == "DelegationStarted" || event == "DelegationCompleted" || event == "DelegationFailed"
            else {
                return nil
            }
            return (object["delegation_id"] as? String) ?? (object["subagent_id"] as? String)
        })
    }

    @discardableResult
    func upsertSubagentToolCallIfAlreadyRendered(
        toolId: String,
        kind: String,
        title: String,
        status: String,
        location: String?,
        details: ToolCallDetails
    ) -> Bool {
        guard case .subagent(let specialist, let objective, let subagentId, let colorHex, let findingPath) = details.kind,
              !subagentId.isEmpty
        else {
            return false
        }

        let exactIndex = firstSubagentItemIndex(subagentId: subagentId)
        let fallbackIndex = exactIndex ?? firstRegistryInjectedSubagentItemIndex(
            specialist: specialist,
            excludingSubagentId: subagentId
        )
        guard let idx = fallbackIndex,
              case .toolCall(let existingItemId, let oldKind, let oldTitle, _, let oldLocation, let oldDetails) = items[idx]
        else {
            return false
        }

        let mergedDetails: ToolCallDetails
        if exactIndex == nil,
           case .subagent(_, _, let existingSubagentId, let existingColorHex, let existingFindingPath) = oldDetails?.kind {
            mergedDetails = ToolCallDetails(
                kind: .subagent(
                    specialist: specialist,
                    objective: objective,
                    subagentId: existingSubagentId,
                    colorHex: colorHex ?? existingColorHex,
                    findingPath: findingPath ?? existingFindingPath
                ),
                startLine: details.startLine,
                previousLineCount: details.previousLineCount
            )
        } else {
            mergedDetails = details
        }

        let mergedTitle = (title.isEmpty || title == "delegate_to_specialist") ? oldTitle : title
        items[idx] = .toolCall(
            id: existingItemId,
            kind: kind.isEmpty ? oldKind : kind,
            title: mergedTitle,
            status: status,
            locationHint: location ?? oldLocation,
            details: mergedDetails
        )
        seenToolCallIds[toolId] = existingItemId
        return true
    }

    private func upsertRegistrySubagentRecord(_ record: SoulSubagentRecord) {
        let details = registrySubagentDetails(from: record)
        let status = registrySubagentStatus(from: record)
        let specialist = registrySubagentSpecialist(from: record)
        let title = specialist.isEmpty ? record.subagentID : "@\(specialist)"
        let objective = registrySubagentObjective(from: record)

        if let idx = firstSubagentItemIndex(subagentId: record.subagentID),
           case .toolCall(let existingItemId, let oldKind, let oldTitle, _, let oldLocation, _) = items[idx] {
            items[idx] = .toolCall(
                id: existingItemId,
                kind: oldKind,
                title: oldTitle.isEmpty ? title : oldTitle,
                status: status,
                locationHint: objective.isEmpty ? oldLocation : objective,
                details: details
            )
            return
        }

        items.append(.toolCall(
            id: UUID(),
            kind: "delegate",
            title: title,
            status: status,
            locationHint: objective.isEmpty ? nil : objective,
            details: details
        ))
    }

    private func registrySubagentDetails(from record: SoulSubagentRecord) -> ToolCallDetails {
        ToolCallDetails(
            kind: .subagent(
                specialist: registrySubagentSpecialist(from: record),
                objective: registrySubagentObjective(from: record),
                subagentId: record.subagentID,
                colorHex: nil,
                findingPath: record.findingPath
            )
        )
    }

    private func registrySubagentStatus(from record: SoulSubagentRecord) -> String {
        let raw = record.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["completed", "failed", "error", "stopped"].contains(raw) {
            return raw
        }
        return record.isActive ? "in_progress" : (raw.isEmpty ? "in_progress" : raw)
    }

    private func registrySubagentSpecialist(from record: SoulSubagentRecord) -> String {
        if let specialist = record.specialist ?? record.finding?.specialist,
           !specialist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SpecialistPalette.normalizedSpecialistName(specialist)
        }
        if let specialist = Self.specialistFromLiveLogHeader(path: record.liveLog) {
            return SpecialistPalette.normalizedSpecialistName(specialist)
        }
        return record.subagentID
    }

    private func registrySubagentObjective(from record: SoulSubagentRecord) -> String {
        let candidates = [
            record.task,
            record.finding?.task,
            record.finding?.objective,
            record.summary,
            record.finding?.summary
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private func firstSubagentItemIndex(subagentId: String) -> Int? {
        items.firstIndex { item in
            guard case .toolCall(_, _, _, _, _, let details) = item,
                  case .subagent(_, _, let existingId, _, _) = details?.kind
            else {
                return false
            }
            return existingId == subagentId
        }
    }

    private func firstRegistryInjectedSubagentItemIndex(
        specialist: String,
        excludingSubagentId: String
    ) -> Int? {
        let normalized = SpecialistPalette.normalizedSpecialistName(specialist)
        let matches = items.indices.filter { idx in
            guard case .toolCall(_, _, _, let status, _, let details) = items[idx],
                  status == "in_progress" || status == "pending",
                  case .subagent(let existingSpecialist, _, let existingId, _, _) = details?.kind,
                  existingId != excludingSubagentId,
                  registryInjectedSubagentIDs.contains(existingId)
            else {
                return false
            }
            return SpecialistPalette.normalizedSpecialistName(existingSpecialist) == normalized
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func specialistFromLiveLogHeader(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let prefix = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        guard let line = prefix.split(separator: "\n", maxSplits: 1).first else { return nil }
        let text = String(line)
        guard let at = text.range(of: "@") else { return nil }
        let tail = text[at.upperBound...]
        let name = tail.prefix { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
        return name.isEmpty ? nil : String(name)
    }
}
