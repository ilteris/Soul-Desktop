import SwiftUI
import Combine

final class SoulControlPanelModel: ObservableObject {
    @Published var operations: [SoulOperation] = []
    @Published var lastVerifySummary: String = "unknown"
    @Published var delegateSpecialist: String = "systems_architect"
    @Published var delegateTask: String = ""
    @Published var delegateStream: Bool = true
    @Published var assistantInput: String = ""
    @Published var assistantMessages: [SoulAssistantMessage] = []

    var runningOperationCount: Int {
        operations.filter { $0.status == .running }.count
    }

    func latestLaunchOperation(for taskID: String) -> SoulOperation? {
        operations.first { $0.title == "Launch \(taskID)" }
    }

    func answerControlPanelQuestion(
        project: SoulProject,
        activeTaskId: String?,
        recommendedTask: SoulTaskRecord?,
        openTasks: [SoulTaskRecord],
        recentSessions: [SoulSession],
        provider: Provider,
        specialist: String
    ) {
        let question = assistantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        assistantInput = ""
        assistantMessages.append(SoulAssistantMessage(isUser: true, text: question))
        assistantMessages.append(SoulAssistantMessage(
            isUser: false,
            text: Self.controlPanelAnswer(
                question: question,
                project: project,
                activeTaskId: activeTaskId,
                recommendedTask: recommendedTask,
                openTasks: openTasks,
                recentSessions: recentSessions,
                provider: provider,
                specialist: specialist
            )
        ))
    }

    func run(
        kind: SoulOperation.Kind,
        title: String,
        args: [String],
        project: String?,
        provider: Provider? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let operationID = startOperation(kind: kind, title: title, project: project, provider: provider)
        Task {
            do {
                let text = try await SoulCLI.runText(args)
                finishOperation(operationID, status: .succeeded, summary: Self.summary(from: text, fallback: "Completed."), logs: text)
                if kind == .verify {
                    lastVerifySummary = text.lowercased().contains("fail") ? "needs attention" : "ok"
                }
                onComplete?()
            } catch {
                finishOperation(operationID, status: .failed, summary: error.localizedDescription, logs: error.localizedDescription)
                if kind == .verify { lastVerifySummary = "failed" }
            }
        }
    }

    func runDelegate(project: String, provider: Provider, dryRun: Bool) {
        let specialist = delegateSpecialist.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = delegateTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !specialist.isEmpty, !task.isEmpty else {
            let operationID = startOperation(kind: .delegate, title: "Delegate", project: project, provider: provider)
            finishOperation(operationID, status: .failed, summary: "Delegate requires a specialist and task.", logs: "")
            return
        }

        var args = [
            "delegate",
            "--project", project,
            "--provider", Self.delegateProviderName(provider),
            "--mode", "async",
            specialist,
            task
        ]
        if dryRun { args.insert("--dry-run", at: 1) }
        if delegateStream && !dryRun { args.insert("--stream", at: 1) }
        if delegateStream && !dryRun {
            runStream(args, title: "Delegate", project: project, provider: provider)
        } else {
            run(kind: .delegate, title: dryRun ? "Delegate Dry Run" : "Delegate", args: args, project: project, provider: provider)
        }
    }

    func runTaskDelegate(_ record: SoulTaskRecord, provider: Provider) {
        let specialist = delegateSpecialist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !specialist.isEmpty else {
            let operationID = startOperation(kind: .delegate, title: "Launch Task", project: record.project, provider: provider)
            finishOperation(operationID, status: .failed, summary: "Launch requires a specialist.", logs: "")
            return
        }

        let brief = Self.taskBrief(from: record)
        var args = [
            "delegate",
            "--project", record.project,
            "--provider", Self.delegateProviderName(provider),
            "--mode", "async",
            specialist,
            brief
        ]
        if delegateStream {
            args.insert("--stream", at: 1)
            runStream(
                args,
                title: "Launch \(record.id)",
                project: record.project,
                provider: provider,
                initialLog: Self.commandLine(args: args)
            )
        } else {
            run(kind: .delegate, title: "Launch \(record.id)", args: args, project: record.project, provider: provider)
        }
    }

    private static func delegateProviderName(_ provider: Provider) -> String {
        switch provider {
        case .geminiCLI: return "gemini"
        case .claude:    return "claude"
        case .pi:        return "pi"
        case .codex:     return "codex"
        }
    }

    private static func taskBrief(from record: SoulTaskRecord) -> String {
        var lines = [
            "Work this Soul task.",
            "",
            "Task ID: \(record.id)",
            "Project: \(record.project)",
            "Status: \(record.status)",
            "Priority: \(record.priority)",
            "Subject: \(record.subject)"
        ]

        if !record.doneCriteria.isEmpty {
            lines.append("")
            lines.append("Definition of Done:")
            for criterion in record.doneCriteria {
                lines.append("- \(criterion)")
            }
        }

        lines.append("")
        lines.append("Return a concise finding with blockers, changed files, and the next concrete action.")
        return lines.joined(separator: "\n")
    }

    private static func controlPanelAnswer(
        question: String,
        project: SoulProject,
        activeTaskId: String?,
        recommendedTask: SoulTaskRecord?,
        openTasks: [SoulTaskRecord],
        recentSessions: [SoulSession],
        provider: Provider,
        specialist: String
    ) -> String {
        let lower = question.lowercased()
        let active = activeTaskId ?? "none"
        let highCount = openTasks.filter { $0.priority == "high" }.count
        let inProgressCount = openTasks.filter { $0.status == "in_progress" }.count
        let top = recommendedTask

        if lower.contains("what") && (lower.contains("next") || lower.contains("do")) {
            if let top {
                return "For \(project.name), I would work \(top.id) next: \(top.subject). It is \(top.status), \(top.priority) priority, with \(top.operatorSummary) Use \(specialist) on \(provider.label) if you want to launch help."
            }
            return "\(project.name) has no open task loaded here. Run Pulse or refresh the queue, then I can point at the next action."
        }

        if lower.contains("project") || lower.contains("where") || lower.contains("context") {
            return "You are operating on \(project.name) (`\(project.id)`) at \(project.path). Active task: \(active). Open tasks: \(openTasks.count), high priority: \(highCount), in progress: \(inProgressCount). Recent sessions loaded: \(recentSessions.count)."
        }

        if lower.contains("task") || lower.contains("queue") || lower.contains("active") {
            guard let top else {
                return "I do not see an open recommended task for \(project.name). The queue may be empty or still loading."
            }
            return "Active task is \(active). The recommended task is \(top.id): \(top.subject). Status \(top.status), priority \(top.priority). \(top.operatorSummary)"
        }

        if lower.contains("agent") || lower.contains("specialist") || lower.contains("provider") {
            return "Current launch defaults are \(specialist) via \(provider.label). For design/product ambiguity use product_shaper or systems_architect; for codebase excavation use code_archaeologist; for registry/data health use registry_guardian."
        }

        if lower.contains("recent") || lower.contains("session") || lower.contains("history") {
            let names = recentSessions.prefix(3).map { $0.intent ?? $0.id }.joined(separator: ", ")
            return names.isEmpty
                ? "No recent sessions are loaded for \(project.name) in this panel."
                : "Recent work for \(project.name): \(names). Use this to decide whether to continue a thread or launch a focused specialist."
        }

        if let top {
            return "I know you are in \(project.name). The control panel is showing \(openTasks.count) open tasks and recommends \(top.id): \(top.subject). Ask me about next action, task queue, recent work, or which specialist to use."
        }
        return "I know you are in \(project.name). Ask me about next action, task queue, recent work, or which specialist to use."
    }

    private func runStream(_ args: [String], title: String, project: String, provider: Provider, initialLog: String? = nil) {
        let operationID = startOperation(kind: .delegate, title: title, project: project, provider: provider)
        if let initialLog {
            appendLog(initialLog + "\n", to: operationID)
        }
        Task {
            do {
                _ = try await SoulCLI.runStream(
                    args,
                    onStart: { pid in
                        Task { @MainActor in
                            self.setOperationProcessID(operationID, pid: pid)
                        }
                    }
                ) { event in
                    let text: String
                    switch event {
                    case .stdout(let chunk): text = chunk
                    case .stderr(let chunk): text = chunk
                    }
                    Task { @MainActor in
                        self.appendLog(text, to: operationID)
                    }
                }
                if operationStatus(operationID) != .cancelled {
                    let logs = operationLogs(operationID)
                    if let failure = Self.streamFailureSummary(from: logs) {
                        finishOperation(operationID, status: .failed, summary: failure, logs: nil)
                    } else {
                        finishOperation(operationID, status: .succeeded, summary: Self.summary(from: logs, fallback: "Delegate completed."), logs: nil)
                    }
                }
            } catch {
                if operationStatus(operationID) != .cancelled {
                    appendLog("\n\(error.localizedDescription)", to: operationID)
                    let logs = operationLogs(operationID)
                    finishOperation(operationID, status: .failed, summary: Self.streamFailureSummary(from: logs) ?? error.localizedDescription, logs: nil)
                }
            }
        }
    }

    private func startOperation(kind: SoulOperation.Kind, title: String, project: String?, provider: Provider?) -> UUID {
        let operation = SoulOperation(
            kind: kind,
            title: title,
            project: project,
            provider: provider,
            status: .running,
            startedAt: Date(),
            lastUpdatedAt: Date(),
            processID: nil,
            endedAt: nil,
            summary: "Running...",
            logs: ""
        )
        operations.insert(operation, at: 0)
        return operation.id
    }

    private func appendLog(_ text: String, to id: UUID) {
        updateOperation(id) { operation in
            operation.logs += text
            operation.lastUpdatedAt = Date()
            operation.summary = Self.summary(from: operation.logs, fallback: "Running...")
        }
    }

    private func finishOperation(_ id: UUID, status: SoulOperation.Status, summary: String, logs: String?) {
        updateOperation(id) { operation in
            operation.status = status
            operation.endedAt = Date()
            operation.lastUpdatedAt = Date()
            operation.summary = summary
            if let logs {
                operation.logs = logs
            }
        }
    }

    func cancelOperation(_ id: UUID) {
        let pid = operations.first { $0.id == id }?.processID
        if let pid {
            SoulCLI.terminateProcessTree(pid: pid)
        }
        updateOperation(id) { operation in
            operation.status = .cancelled
            operation.endedAt = Date()
            operation.lastUpdatedAt = Date()
            operation.summary = "Stopped by user."
            operation.logs += "\n{\"event\":\"cancelled\",\"status\":\"stopped_by_user\"}\n"
        }
    }

    private func operationLogs(_ id: UUID) -> String {
        operations.first { $0.id == id }?.logs ?? ""
    }

    private func operationStatus(_ id: UUID) -> SoulOperation.Status? {
        operations.first { $0.id == id }?.status
    }

    private func setOperationProcessID(_ id: UUID, pid: Int32) {
        updateOperation(id) { operation in
            operation.processID = pid
        }
    }

    private func updateOperation(_ id: UUID, _ body: (inout SoulOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        body(&operations[index])
    }

    private static func summary(from text: String, fallback: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return fallback }
        if first.count <= 180 { return first }
        return String(first.prefix(177)) + "..."
    }

    private static func streamFailureSummary(from text: String) -> String? {
        var latestFailure: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = object["event"] as? String
            else { continue }

            switch event {
            case "subagent_timeout":
                latestFailure = object["reason"] as? String ?? "Delegate timed out waiting for provider output."
            case "subagent_failed":
                latestFailure = object["error"] as? String ?? object["reason"] as? String ?? "Delegate failed."
            default:
                continue
            }
        }
        return latestFailure
    }

    private static func commandLine(args: [String]) -> String {
        let escaped = args.map { arg in
            if arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "$ soul " + escaped.joined(separator: " ")
    }
}
