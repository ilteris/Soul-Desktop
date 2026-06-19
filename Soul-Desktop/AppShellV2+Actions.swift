import SwiftUI
import AppKit

extension AppShellV2 {
    func refreshProjects() {
        LiveSoulRegistryStore.shared.refresh()
        projects = registryStore.activeProjects()
        if selectedProject == nil || !projects.contains(where: { $0.id == selectedProject }) {
            selectedProject = projects.first?.id
        }
        refreshProjectCounts()
    }

    func refreshProjectState() {
        guard let project else { return }
        activeTask.bind(projectKey: project.id)
        taskQueue.bind(projectKey: project.id)
        specialistStore.bind(projectKey: project.id, selected: pulseModel.delegateSpecialist) { specialist in
            pulseModel.delegateSpecialist = specialist
        }
        if let cached = registryStore.cachedSessions(forProject: project.id) {
            recentSessions = Array(cached.prefix(12))
        } else {
            recentSessions = []
        }
        let projectId = project.id
        let projectPath = project.path
        Task {
            let sessions = await Task.detached(priority: .userInitiated) {
                SoulRegistry.allSessions(forProject: projectId, limit: 12, projectPath: projectPath)
            }.value
            guard self.project?.id == projectId else { return }
            recentSessions = sessions
        }
    }

    func refreshProjectCounts() {
        let ids = projects.map(\.id)
        Task {
            let counts = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, SoulRegistry.sessionCount(forProject: id))
                })
            }.value
            projectCounts = counts
        }
    }

    func runPulse() {
        guard let project else { return }
        pulseModel.run(kind: .pulse, title: "Pulse", args: ["pulse", "--output", "text", project.path], project: project.id)
    }

    func runVerify() {
        guard let project else { return }
        pulseModel.run(kind: .verify, title: "Verify Project", args: ["verify", "--project", project.id], project: project.id) {
            refreshProjectState()
        }
    }

    func runFinalCommand(_ command: String) {
        guard let project else { return }
        let kind: SoulOperation.Kind = command == "compact" ? .compact : .finalize
        pulseModel.run(kind: kind, title: command.capitalized, args: [command, "--project", project.id], project: project.id) {
            refreshProjectState()
        }
    }

    func runAppServerDoctor() {
        pulseModel.run(kind: .appServerDoctor, title: "App-server Doctor", args: ["app-server", "doctor"], project: project?.id)
    }

    func runDelegate(dryRun: Bool) {
        guard let project else { return }
        pulseModel.runDelegate(project: project.id, provider: selectedProvider, dryRun: dryRun)
    }

    func askControlPanelAssistant() {
        guard let project else { return }
        pulseModel.answerControlPanelQuestion(
            project: project,
            activeTaskId: activeTask.taskId,
            recommendedTask: taskQueue.recommendedTask,
            openTasks: taskQueue.openTasks,
            recentSessions: recentSessions,
            provider: selectedProvider,
            specialist: pulseModel.delegateSpecialist
        )
    }

    func selectTask(_ task: SoulTaskRecord) {
        pulseModel.run(kind: .task, title: "Focus Task", args: ["task", "select", task.id, "--project", task.project], project: task.project) {
            taskQueue.refresh()
            activeTask.bind(projectKey: task.project)
        }
    }

    func startTask(_ task: SoulTaskRecord) {
        pulseModel.run(kind: .task, title: "Start Task", args: ["task", "status", "in_progress", "--task_id", task.id, "--project", task.project], project: task.project) {
            refreshTaskQueue()
        }
    }

    func launchTask(_ task: SoulTaskRecord) {
        pulseModel.runTaskDelegate(task, provider: selectedProvider)
    }

    func refreshTaskQueue() {
        taskQueue.refresh()
        activeTask.bind(projectKey: project?.id)
    }

    func openActiveTaskRecord() {
        guard let project else { return }
        let taskId = activeTask.taskId ?? taskQueue.recommendedTask?.id
        guard let taskId else { return }
        openTaskRecord(project: project.id, taskId: taskId)
    }

    func openPressureTask() {
        guard let project else { return }
        let taskId = taskQueue.openTasks.first(where: { $0.priority == "high" })?.id ?? taskQueue.openTasks.first?.id
        guard let taskId else { return }
        openTaskRecord(project: project.id, taskId: taskId)
    }

    func openTaskRecord(project: String, taskId: String) {
        let url = SoulTaskRecord.fileURL(project: project, id: taskId)
        NSWorkspace.shared.open(url)
    }

    func inspectLatestOperation() {
        let latest = pulseModel.operations.first(where: { $0.status == .running }) ?? pulseModel.operations.first
        inspectedOperationID = latest?.id
    }

    func openTimelineEntry(_ entry: SoulTimelineEntry) {
        if let operationID = entry.operationID {
            inspectedOperationID = operationID
            return
        }
        if let taskID = entry.taskID, let project {
            openTaskRecord(project: project.id, taskId: taskID)
            return
        }
        if entry.kind == .session {
            inspectLatestOperation()
        }
    }

    func openOperationLog(_ operation: SoulOperation) {
        let body = """
        \(operation.title)
        status: \(operation.status.label)
        started: \(operation.startedAt.formatted(date: .abbreviated, time: .standard))

        \(operation.summary)

        \(operation.logs)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-operation-\(operation.id.uuidString.prefix(8)).log")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
}
