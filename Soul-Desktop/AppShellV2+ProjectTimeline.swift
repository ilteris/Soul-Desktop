import SwiftUI

extension AppShellV2 {
    var projectTimelineCard: some View {
        controlCard(title: "Project Story", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            VStack(alignment: .leading, spacing: 12) {
                Text(projectStoryLead)
                    .font(SoulFont.ui(13, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    storyBlock(
                        title: "Now",
                        icon: "scope",
                        value: currentFocusTitle,
                        detail: currentFocusDetail,
                        action: openActiveTaskRecord
                    )
                    storyBlock(
                        title: "In Motion",
                        icon: "dot.radiowaves.left.and.right",
                        value: liveWorkTitle,
                        detail: liveWorkDetail,
                        action: inspectLatestOperation
                    )
                    workProjectionStoryBlock
                    storyBlock(
                        title: "Pressure",
                        icon: "exclamationmark.triangle",
                        value: pressureTitle,
                        detail: pressureDetail,
                        action: openPressureTask
                    )
                    projectBindingStoryBlock
                }

                projectBindingDiagnostics

                let entries = projectTimelineEntries
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Recent signals")
                            .font(SoulFont.ui(10, weight: .medium))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .textCase(.uppercase)
                        ForEach(entries.prefix(4)) { entry in
                            timelineRow(entry)
                        }
                    }
                }
            }
        }
    }

    var projectStoryLead: String {
        let open = taskQueue.openTasks.count
        let high = taskQueue.highPriorityCount
        let running = taskQueue.inProgressCount
        if let recommended = taskQueue.recommendedTask {
            return "\(project?.name ?? "This project") is currently centered on \(recommended.id): \(recommended.subject). The queue has \(open) open task\(open == 1 ? "" : "s"), \(high) high-priority item\(high == 1 ? "" : "s"), and \(running) marked in progress."
        }
        return "\(project?.name ?? "This project") has \(open) open task\(open == 1 ? "" : "s") and \(recentSessions.count) recent session\(recentSessions.count == 1 ? "" : "s") loaded."
    }

    var currentFocusTitle: String {
        if let activeTaskId = activeTask.taskId { return activeTaskId }
        return taskQueue.recommendedTask?.id ?? "No task selected"
    }

    var currentFocusDetail: String {
        if let subject = activeTask.subject { return subject }
        return taskQueue.recommendedTask?.subject ?? "Choose a task before launching an agent."
    }

    var liveWorkTitle: String {
        let activeRuns = runStore.activeRuns.count
        let activeSubagents = runStore.activeSubagents.count
        let running = pulseModel.runningOperationCount
        let live = recentSessions.filter(\.isLive).count
        if activeRuns > 0 { return "\(activeRuns) durable run\(activeRuns == 1 ? "" : "s")" }
        if activeSubagents > 0 { return "\(activeSubagents) subagent\(activeSubagents == 1 ? "" : "s")" }
        if running > 0 { return "\(running) operation\(running == 1 ? "" : "s") running" }
        if live > 0 { return "\(live) live session\(live == 1 ? "" : "s")" }
        return "No active run"
    }

    var liveWorkDetail: String {
        if let run = runStore.activeRuns.first {
            return "\(run.runID): \(run.displayDetail)"
        }
        if let subagent = runStore.activeSubagents.first {
            return "\(subagent.displayTitle): \(subagent.displayDetail)"
        }
        if let op = pulseModel.operations.first(where: { $0.status == .running }) {
            return "\(op.title): \(op.summary)"
        }
        let live = recentSessions.filter(\.isLive)
        if !live.isEmpty {
            let eventCount = live.reduce(0) { $0 + $1.eventCount }
            return "\(eventCount) live events across current project sessions."
        }
        return "Launch an agent or run pulse to create a fresh operating signal."
    }

    var workProjectionStoryBlock: some View {
        let projection = runStore.workProjection
        let error = runStore.workProjectionError
        let value = error == nil
            ? (projection?.trajectory?.primaryIntent
                ?? projection?.sessionID
                ?? "No work projection")
            : "Projection error"
        let detail = error?.message
            ?? error?.code
            ?? projection?.nextStep
            ?? "Waiting for central work_projection.get."
        return storyBlock(
            title: "Continuity",
            icon: "point.topleft.down.curvedto.point.bottomright.up",
            value: value,
            detail: detail,
            action: runRegistryServerDoctor
        )
    }

    var pressureTitle: String {
        if taskQueue.highPriorityCount > 0 { return "\(taskQueue.highPriorityCount) high priority" }
        if taskQueue.openTasks.isEmpty { return "Clear" }
        return "\(taskQueue.openTasks.count) open"
    }

    var pressureDetail: String {
        if let firstHigh = taskQueue.openTasks.first(where: { $0.priority == "high" }) {
            return firstHigh.subject
        }
        if taskQueue.openTasks.isEmpty {
            return "No open task pressure detected in the registry."
        }
        return taskQueue.openTasks.first?.subject ?? "Backlog loaded."
    }

    var projectBindingStoryBlock: some View {
        let binding = runStore.projectBinding
        return storyBlock(
            title: "Binding",
            icon: binding?.portable == true ? "link.circle" : "link.circle.fill",
            value: binding?.statusLabel ?? "No binding snapshot",
            detail: binding?.locationSummary ?? "Waiting for Registry Server project_binding.",
            action: runRegistryServerDoctor
        )
    }

    @ViewBuilder
    var projectBindingDiagnostics: some View {
        if let binding = runStore.projectBinding {
            VStack(alignment: .leading, spacing: 7) {
                Text("Project binding")
                    .font(SoulFont.ui(10, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textCase(.uppercase)
                diagnosticRow("Declared", binding.declaredPath)
                diagnosticRow("Resolved", binding.resolvedPath)
                diagnosticRow("Resolution", binding.statusLabel)
                diagnosticRow("Health", binding.healthSummary)
                diagnosticRow("Manifest", binding.manifestSummary)
            }
            .padding(10)
            .background(SoulColor.bgElevated.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.22), lineWidth: 0.5))
        }
    }

    func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(SoulFont.code(10))
                .foregroundStyle(SoulColor.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    func storyBlock(title: String, icon: String, value: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .textCase(.uppercase)
                    Text(value)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                    Text(detail)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open details")
    }

    var projectTimelineEntries: [SoulTimelineEntry] {
        var entries: [SoulTimelineEntry] = []

        for run in runStore.recentRuns.prefix(6) {
            entries.append(SoulTimelineEntry(
                kind: .run,
                icon: run.isActive ? "record.circle" : "checkmark.seal",
                tint: run.statusTint,
                title: run.displayTitle,
                detail: run.displayDetail,
                timestamp: run.timestamp,
                badge: run.status,
                runID: run.runID
            ))
        }

        for subagent in runStore.subagents.prefix(4) {
            entries.append(SoulTimelineEntry(
                kind: .operation,
                icon: subagent.isActive ? "person.2.wave.2" : "person.crop.circle.badge.checkmark",
                tint: subagent.isActive ? SoulColor.accent : SoulColor.fgMuted,
                title: subagent.displayTitle,
                detail: subagent.displayDetail,
                timestamp: subagent.timestamp,
                badge: subagent.status ?? "subagent"
            ))
        }

        for operation in pulseModel.operations {
            entries.append(SoulTimelineEntry(
                kind: .operation,
                icon: operation.kind.icon,
                tint: operation.status.tint,
                title: operation.title,
                detail: operation.summary,
                timestamp: operation.startedAt,
                badge: operation.status.label,
                operationID: operation.id
            ))
        }

        if let activeId = activeTask.taskId {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: "scope",
                tint: SoulColor.accent,
                title: activeTask.subject ?? "Active task",
                detail: activeId,
                timestamp: Date(),
                badge: activeTask.status ?? "active",
                taskID: activeId
            ))
        } else if let recommended = taskQueue.recommendedTask {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: "sparkles",
                tint: SoulColor.accent,
                title: recommended.subject,
                detail: recommended.id,
                timestamp: taskTimestamp(recommended) ?? Date(),
                badge: recommended.status,
                taskID: recommended.id
            ))
        }

        for task in taskQueue.openTasks.prefix(4) where task.id != activeTask.taskId && task.id != taskQueue.recommendedTask?.id {
            entries.append(SoulTimelineEntry(
                kind: .task,
                icon: task.status == "in_progress" ? "play.fill" : "circle",
                tint: task.status == "in_progress" ? SoulColor.accent : SoulColor.fgMuted,
                title: task.subject,
                detail: task.id,
                timestamp: taskTimestamp(task),
                badge: task.priority,
                taskID: task.id
            ))
        }

        let liveSessions = recentSessions.filter(\.isLive)
        if !liveSessions.isEmpty {
            let providers = liveSessions
                .map { $0.source ?? $0.liveProvider ?? "unknown" }
                .reduce(into: [String: Int]()) { counts, provider in counts[provider, default: 0] += 1 }
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " · ")
            let latest = liveSessions.compactMap { $0.lastActivityAt ?? $0.timestamp }.max()
            let eventCount = liveSessions.reduce(0) { $0 + $1.eventCount }
            entries.append(SoulTimelineEntry(
                kind: .session,
                icon: "dot.radiowaves.left.and.right",
                tint: SoulColor.accent,
                title: "\(liveSessions.count) live session\(liveSessions.count == 1 ? "" : "s")",
                detail: "\(providers) · \(eventCount) events",
                timestamp: latest,
                badge: "live"
            ))
        }

        for session in recentSessions.filter({ !$0.isLive }).prefix(3) {
            entries.append(SoulTimelineEntry(
                kind: .session,
                icon: "bubble.left.and.bubble.right",
                tint: SoulColor.fgMuted,
                title: session.title ?? session.intent ?? session.summary ?? "Untitled session",
                detail: "\(session.source ?? session.liveProvider ?? "unknown") · \(session.eventCount) events",
                timestamp: session.lastActivityAt ?? session.timestamp,
                badge: "session"
            ))
        }

        return entries.sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
    }

    func timelineRow(_ entry: SoulTimelineEntry) -> some View {
        Button {
            openTimelineEntry(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.tint)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(SoulFont.ui(12, weight: .semibold))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                        timelineBadge(entry.badge)
                        Spacer(minLength: 8)
                        Text(entry.timestamp.map { timelineTime($0) } ?? "unknown")
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    Text(entry.detail)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open signal")
    }

    func timelineBadge(_ text: String) -> some View {
        Text(text)
            .font(SoulFont.code(10))
            .foregroundStyle(SoulColor.fgSubtle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(SoulColor.fg.opacity(0.06), in: Capsule())
    }

    func timelineTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    func taskTimestamp(_ task: SoulTaskRecord) -> Date? {
        guard let updatedAt = task.updatedAt else { return nil }
        return Self.timelineTimestampFormatter.date(from: updatedAt)
            ?? Self.timelineTimestampFormatterWithFractionalSeconds.date(from: updatedAt)
    }

    static let timelineTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let timelineTimestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func statusPill(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SoulColor.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SoulFont.ui(10, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(SoulFont.ui(13, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: SoulMetric.radiusS))
        .overlay(RoundedRectangle(cornerRadius: SoulMetric.radiusS).strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5))
    }
}
