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
        durable: Bool = true,
        durableStepID: String? = nil,
        durableDirectDelegate: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        let operationID = startOperation(kind: kind, title: title, project: project, provider: provider)
        Task {
            let stepOwnedByDesktop = !durableDirectDelegate
            let contextResult = durable
                ? await createDurableContext(
                    kind: kind,
                    title: title,
                    project: project,
                    stepID: durableStepID ?? Self.durableStepID(kind: kind)
                )
                : .skipped
            let context: DurableRunContext?
            switch contextResult {
            case .created(let created):
                context = created
                attachDurableContext(created, to: operationID, stepOwnedByDesktop: stepOwnedByDesktop)
                if operationStatus(operationID) == .cancelled {
                    await finishDurableContext(
                        created,
                        kind: kind,
                        status: .cancelled,
                        summary: "Stopped by user.",
                        createsStep: stepOwnedByDesktop
                    )
                    return
                }
            case .failed(let message):
                context = nil
                appendLog("\n{\"event\":\"durable_run_create_failed\",\"error\":\"\(Self.jsonSafe(message))\"}\n", to: operationID)
                if operationStatus(operationID) == .cancelled {
                    return
                }
            case .skipped:
                context = nil
                if operationStatus(operationID) == .cancelled {
                    return
                }
            }
            let commandArgs = durableDirectDelegate && context != nil
                ? Self.delegateArgs(args, context: context!)
                : args
            do {
                let text = try await SoulCLI.runText(commandArgs)
                if operationStatus(operationID) == .cancelled {
                    return
                }
                let summary = Self.summary(from: text, fallback: "Completed.")
                if let context {
                    await finishDurableContext(
                        context,
                        kind: kind,
                        status: .succeeded,
                        summary: summary,
                        createsStep: stepOwnedByDesktop
                    )
                }
                finishOperation(operationID, status: .succeeded, summary: summary, logs: operationLogs(operationID) + Self.commandLine(args: commandArgs) + "\n" + text)
                if kind == .verify {
                    lastVerifySummary = text.lowercased().contains("fail") ? "needs attention" : "ok"
                }
                onComplete?()
            } catch {
                if operationStatus(operationID) == .cancelled {
                    return
                }
                if let context {
                    await finishDurableContext(
                        context,
                        kind: kind,
                        status: .failed,
                        summary: error.localizedDescription,
                        createsStep: stepOwnedByDesktop
                    )
                }
                finishOperation(operationID, status: .failed, summary: error.localizedDescription, logs: operationLogs(operationID) + Self.commandLine(args: commandArgs) + "\n" + error.localizedDescription)
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
            runStream(
                args,
                title: "Delegate",
                project: project,
                provider: provider,
                stepID: Self.durableDelegateStepID(specialist: specialist)
            )
        } else {
            run(
                kind: .delegate,
                title: dryRun ? "Delegate Dry Run" : "Delegate",
                args: args,
                project: project,
                provider: provider,
                durable: !dryRun,
                durableStepID: dryRun ? nil : Self.durableDelegateStepID(specialist: specialist),
                durableDirectDelegate: !dryRun
            )
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
                stepID: Self.durableDelegateStepID(specialist: specialist, taskID: record.id)
            )
        } else {
            run(
                kind: .delegate,
                title: "Launch \(record.id)",
                args: args,
                project: record.project,
                provider: provider,
                durableStepID: Self.durableDelegateStepID(specialist: specialist, taskID: record.id),
                durableDirectDelegate: true
            )
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

    private func runStream(_ args: [String], title: String, project: String, provider: Provider, stepID: String) {
        let operationID = startOperation(kind: .delegate, title: title, project: project, provider: provider)
        Task {
            let contextResult = await createDurableContext(
                kind: .delegate,
                title: title,
                project: project,
                stepID: stepID
            )
            let commandArgs: [String]
            let context: DurableRunContext?
            switch contextResult {
            case .created(let created):
                context = created
                attachDurableContext(created, to: operationID, stepOwnedByDesktop: false)
                if operationStatus(operationID) == .cancelled {
                    await finishDurableContext(created, kind: .delegate, status: .cancelled, summary: "Stopped by user.", createsStep: false)
                    return
                }
            case .failed(let message):
                context = nil
                appendLog("\n{\"event\":\"durable_run_create_failed\",\"error\":\"\(Self.jsonSafe(message))\"}\n", to: operationID)
                if operationStatus(operationID) == .cancelled {
                    return
                }
            case .skipped:
                context = nil
                if operationStatus(operationID) == .cancelled {
                    return
                }
            }
            if let context {
                commandArgs = Self.delegateArgs(args, context: context)
            } else {
                commandArgs = args
            }
            appendLog(Self.commandLine(args: commandArgs) + "\n", to: operationID)
            do {
                _ = try await SoulCLI.runStream(
                    commandArgs,
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
                        if let context {
                            await finishDurableContext(context, kind: .delegate, status: .failed, summary: failure, createsStep: false)
                        }
                        finishOperation(operationID, status: .failed, summary: failure, logs: nil)
                    } else {
                        let summary = Self.summary(from: logs, fallback: "Delegate completed.")
                        if let context {
                            await finishDurableContext(context, kind: .delegate, status: .succeeded, summary: summary, createsStep: false)
                        }
                        finishOperation(operationID, status: .succeeded, summary: summary, logs: nil)
                    }
                }
            } catch {
                if operationStatus(operationID) != .cancelled {
                    appendLog("\n\(error.localizedDescription)", to: operationID)
                    let logs = operationLogs(operationID)
                    let summary = Self.streamFailureSummary(from: logs) ?? error.localizedDescription
                    if let context {
                        await finishDurableContext(context, kind: .delegate, status: .failed, summary: summary, createsStep: false)
                    }
                    finishOperation(operationID, status: .failed, summary: summary, logs: nil)
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
            durableRunID: nil,
            durableStepID: nil,
            durableStepOwnedByDesktop: false,
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
        let operation = operations.first { $0.id == id }
        let pid = operation?.processID
        let durableContext = operation.flatMap(Self.durableContext(from:))
        let createsStep = operation?.durableStepOwnedByDesktop == true
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
        if let durableContext {
            Task {
                await finishDurableContext(
                    durableContext,
                    kind: operation?.kind ?? .delegate,
                    status: .cancelled,
                    summary: "Stopped by user.",
                    createsStep: createsStep
                )
            }
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

    private func attachDurableContext(_ context: DurableRunContext, to id: UUID, stepOwnedByDesktop: Bool) {
        updateOperation(id) { operation in
            operation.durableRunID = context.runID
            operation.durableStepID = context.stepID
            operation.durableStepOwnedByDesktop = stepOwnedByDesktop
            operation.logs += "{\"event\":\"durable_run_started\",\"run_id\":\"\(context.runID)\",\"step_id\":\"\(context.stepID)\"}\n"
            operation.lastUpdatedAt = Date()
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

    private struct DurableRunContext: Hashable {
        var project: String
        var runID: String
        var stepID: String
    }

    private enum DurableContextResult {
        case created(DurableRunContext)
        case failed(String)
        case skipped
    }

    private struct DurableRunCreatePayload: Decodable {
        var runID: String
        var project: String

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case project
        }
    }

    private func createDurableContext(kind: SoulOperation.Kind, title: String, project: String?, stepID: String) async -> DurableContextResult {
        guard let project, !project.isEmpty else { return .skipped }
        do {
            let payload = try await SoulCLI.runJSON(
                [
                    "run", "create",
                    "-p", project,
                    "--objective", title,
                    "--status", "running",
                    "--summary", "Started from Soul Desktop.",
                    "--json"
                ],
                as: DurableRunCreatePayload.self
            )
            return .created(DurableRunContext(project: payload.project, runID: payload.runID, stepID: stepID))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finishDurableContext(
        _ context: DurableRunContext,
        kind: SoulOperation.Kind,
        status: SoulOperation.Status,
        summary: String,
        createsStep: Bool
    ) async {
        if createsStep {
            await createDurableStep(context, kind: kind, status: status, summary: summary)
        }
        await updateDurableRun(context, status: status, summary: summary)
    }

    private func createDurableStep(
        _ context: DurableRunContext,
        kind: SoulOperation.Kind,
        status: SoulOperation.Status,
        summary: String
    ) async {
        do {
            _ = try await SoulCLI.runText([
                "run", "step", "create",
                "-p", context.project,
                context.runID,
                "--step-id", context.stepID,
                "--kind", Self.durableStepKind(for: kind),
                "--objective", Self.durableStepObjective(for: kind),
                "--status", Self.durableStepStatus(for: status),
                "--summary", summary,
                "--allow-existing",
                "--json"
            ])
        } catch {
            appendLog("\n{\"event\":\"durable_step_failed\",\"error\":\"\(Self.jsonSafe(error.localizedDescription))\"}\n", to: operationID(for: context))
        }
    }

    private func updateDurableRun(_ context: DurableRunContext, status: SoulOperation.Status, summary: String) async {
        do {
            _ = try await SoulCLI.runText([
                "run", "update",
                "-p", context.project,
                context.runID,
                "--status", Self.durableRunStatus(for: status),
                "--summary", summary,
                "--json"
            ])
        } catch {
            appendLog("\n{\"event\":\"durable_run_update_failed\",\"error\":\"\(Self.jsonSafe(error.localizedDescription))\"}\n", to: operationID(for: context))
        }
    }

    private func operationID(for context: DurableRunContext) -> UUID {
        operations.first { $0.durableRunID == context.runID }?.id ?? UUID()
    }

    private static func durableContext(from operation: SoulOperation) -> DurableRunContext? {
        guard let project = operation.project,
              let runID = operation.durableRunID,
              let stepID = operation.durableStepID
        else { return nil }
        return DurableRunContext(project: project, runID: runID, stepID: stepID)
    }

    private static func durableRunStatus(for status: SoulOperation.Status) -> String {
        switch status {
        case .running: return "running"
        case .succeeded: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private static func durableStepStatus(for status: SoulOperation.Status) -> String {
        switch status {
        case .running: return "running"
        case .succeeded: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private static func durableStepKind(for kind: SoulOperation.Kind) -> String {
        kind == .verify ? "verifier" : "shell"
    }

    private static func durableStepObjective(for kind: SoulOperation.Kind) -> String {
        switch kind {
        case .pulse: return "Run Soul pulse"
        case .verify: return "Verify project"
        case .delegate: return "Delegate specialist work"
        case .task: return "Update task state"
        case .finalize: return "Finalize session"
        case .compact: return "Compact session context"
        case .appServerDoctor: return "Run app-server doctor"
        }
    }

    private static func durableStepID(kind: SoulOperation.Kind) -> String {
        "desktop_\(kind.rawValue)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func durableDelegateStepID(specialist: String, taskID: String? = nil) -> String {
        let prefix = ["delegate", sanitizeID(specialist), taskID.map(sanitizeID)].compactMap { $0 }.joined(separator: "_")
        return "\(prefix)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func delegateArgs(_ args: [String], context: DurableRunContext) -> [String] {
        guard args.first == "delegate", args.count >= 3 else { return args }
        var next = args
        next.insert(contentsOf: ["--run-id", context.runID, "--step-id", context.stepID], at: max(1, next.count - 2))
        return next
    }

    private static func sanitizeID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let text = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return text.isEmpty ? "step" : text
    }

    private static func jsonSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
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
