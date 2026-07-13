import SwiftUI

extension AppShellV2 {
    var activeTaskCard: some View {
        controlCard(title: "Active Work", icon: "scope") {
            VStack(alignment: .leading, spacing: 12) {
                if let taskId = activeTask.taskId {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activeTask.subject ?? "Untitled task")
                                .font(SoulFont.ui(15, weight: .semibold))
                                .foregroundStyle(SoulColor.fg)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(taskId)
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer()
                        if let status = activeTask.status {
                            Text(status)
                                .font(SoulFont.code(10))
                                .foregroundStyle(SoulColor.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(SoulColor.accent.opacity(0.1), in: Capsule())
                        }
                    }

                    if activeTask.criteria.isEmpty {
                        emptyLine("No done criteria recorded.")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(activeTask.criteria, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(item.done ? SoulColor.accent : SoulColor.fgMuted)
                                        .padding(.top, 1)
                                    Text(item.text)
                                        .font(SoulFont.ui(12))
                                        .foregroundStyle(item.done ? SoulColor.fgSubtle : SoulColor.fg)
                                        .strikethrough(item.done)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    emptyLine("No active task selected for this project.")
                }

                HStack(spacing: 8) {
                    actionButton("Pulse", icon: "waveform.path.ecg") { runPulse() }
                    actionButton("Finalize", icon: "seal") { runFinalCommand("finalize") }
                    actionButton("Compact", icon: "rectangle.compress.vertical") { runFinalCommand("compact") }
                }
            }
        }
    }

    var taskWorkSurface: some View {
        let recommended = taskQueue.recommendedTask
        let visibleTasks = showAllTasks ? taskQueue.openTasks : Array(taskQueue.openTasks.prefix(6))

        return controlCard(title: "Next Task", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                if let error = taskQueue.loadError {
                    emptyLine(error)
                } else if taskQueue.openTasks.isEmpty {
                    emptyLine(taskQueue.isLoading ? "Loading tasks..." : "No open tasks in this project.")
                } else {
                    if let recommended {
                        recommendedTaskPanel(recommended)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Backlog")
                                .font(SoulFont.ui(11, weight: .medium))
                                .foregroundStyle(SoulColor.fgSubtle)
                                .textCase(.uppercase)
                            Text("\(taskQueue.openTasks.count) open · \(taskQueue.highPriorityCount) high · \(taskQueue.inProgressCount) running")
                                .font(SoulFont.ui(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                            Spacer()
                            if taskQueue.openTasks.count > 6 {
                                Button(showAllTasks ? "Show less" : "Show all \(taskQueue.openTasks.count)") {
                                    showAllTasks.toggle()
                                }
                                .font(SoulFont.ui(11, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(SoulColor.accent)
                            }
                        }

                        ForEach(visibleTasks) { task in
                            taskQueueRow(task, isRecommended: task.id == recommended?.id)
                        }
                    }
                }
            }
        }
    }

    func recommendedTaskPanel(_ task: SoulTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        taskStatusChip(task.priority)
                        taskStatusChip(task.status)
                        Text(task.id)
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    Text(task.subject)
                        .font(SoulFont.ui(19, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(task.operatorSummary)
                        .font(SoulFont.ui(12))
                        .foregroundStyle(SoulColor.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                specialistMenu

                Menu {
                    ForEach(Provider.allCases) { provider in
                        Button(provider.label) { selectedProvider = provider }
                    }
                } label: {
                    HStack(spacing: 6) {
                        CompactProviderGlyph(provider: selectedProvider)
                        Text(selectedProvider.label)
                            .font(SoulFont.ui(11, weight: .medium))
                    }
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(SoulColor.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                Toggle("Stream", isOn: $pulseModel.delegateStream)
                    .toggleStyle(.switch)
                    .font(SoulFont.ui(11))

                Spacer(minLength: 0)
                actionButton("Focus", icon: "scope") { selectTask(task) }
                actionButton("Start", icon: "play.fill") { startTask(task) }
                Button {
                    launchTask(task)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Launch Agent")
                            .font(SoulFont.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(SoulColor.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }

            if let launch = pulseModel.latestLaunchOperation(for: task.id) {
                Divider()
                    .overlay(SoulColor.border.opacity(0.35))
                HStack(alignment: .top, spacing: 8) {
                    statusBadge(launch.status)
                    Text(launch.summary)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(SoulColor.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.accent.opacity(0.24), lineWidth: 0.75))
    }

    var specialistMenu: some View {
        Menu {
            ForEach(specialistStore.specialists, id: \.self) { specialist in
                Button {
                    pulseModel.delegateSpecialist = specialist
                } label: {
                    HStack {
                        Text(specialist)
                        if specialist == pulseModel.delegateSpecialist {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .medium))
                Text(pulseModel.delegateSpecialist)
                    .font(SoulFont.code(12))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Choose specialist")
    }

    var providerMenu: some View {
        Menu {
            ForEach(Provider.allCases) { provider in
                Button {
                    selectedProvider = provider
                } label: {
                    HStack {
                        Text(provider.label)
                        if provider == selectedProvider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                CompactProviderGlyph(provider: selectedProvider)
                Text(selectedProvider.label)
                    .font(SoulFont.ui(12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .foregroundStyle(SoulColor.fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SoulColor.bgElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.35), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Choose provider")
    }

    func taskQueueRow(_ task: SoulTaskRecord, isRecommended: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.id == taskQueue.activeTaskId ? "scope" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(task.id == taskQueue.activeTaskId ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 20)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(task.id)
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    taskStatusChip(task.status)
                    taskStatusChip(task.priority)
                }
                Text(task.subject)
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(task.operatorSummary)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    selectTask(task)
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Set active task")

                Button {
                    startTask(task)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.soulHover)
                .help("Mark in progress")

                Button {
                    launchTask(task)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("Launch")
                            .font(SoulFont.ui(11, weight: .medium))
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.soulHover)
                .help("Launch selected agent on this task")
            }
        }
        .padding(12)
        .background(task.id == taskQueue.activeTaskId ? SoulColor.accent.opacity(0.1) : SoulColor.bgElevated.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.28), lineWidth: 0.5))
    }

    func queueMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SoulFont.ui(10, weight: .medium))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
            Text(value)
                .font(SoulFont.ui(12, weight: .semibold))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SoulColor.bgElevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    func taskStatusChip(_ text: String) -> some View {
        Text(text.isEmpty ? "unknown" : text)
            .font(SoulFont.code(10))
            .foregroundStyle(SoulColor.fgSubtle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SoulColor.fg.opacity(0.06), in: Capsule())
    }
}
