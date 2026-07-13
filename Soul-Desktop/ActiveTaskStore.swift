import Foundation
import SwiftUI
import Combine

/// SOUL-SOUL_DESKTOP-055: surface the active Soul-OS task's Definition of
/// Done as a checklist in the canvas overlay.
///
/// Data flows entirely through the unified `soul task status -p <project> --json`
/// CLI (kernel-side: SOUL-SOUL_DESKTOP-260). No direct `.soul_task` / `<id>.json`
/// reads remain — the kernel is the source of truth, and any schema change
/// inside the registry JSON propagates to the desktop automatically.
///
/// Refreshes on bind and on registry file changes so the overlay stays current
/// without periodic CLI polling.
@MainActor
final class ActiveTaskStore: ObservableObject {
    struct Criterion: Hashable {
        var text: String
        var done: Bool
    }

    @Published private(set) var taskId: String? = nil
    @Published private(set) var subject: String? = nil
    @Published private(set) var status: String? = nil
    @Published private(set) var criteria: [Criterion] = []

    private var boundProject: String? = nil
    private var activeTaskFile: String? = nil
    private var registryMonitor: SoulRegistryMonitor? = nil
    private var pendingRefreshTask: Task<Void, Never>? = nil
    private var boundEnvironment: [String: String] = [:]
    private var isRefreshing: Bool = false
    private var needsRefreshAfterCurrent: Bool = false

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        boundEnvironment = ProcessInfo.processInfo.environment
        taskId = nil
        subject = nil
        status = nil
        criteria = []
        activeTaskFile = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        registryMonitor = nil
        guard let key = projectKey, !key.isEmpty else { return }
        if !Self.shouldUseCentralAuthority(env: boundEnvironment) {
            registryMonitor = SoulRegistryMonitor { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRegistryRefresh()
                }
            }
            configureRegistryMonitor(project: key)
        }
        Task { await refresh() }
    }

    deinit {
        pendingRefreshTask?.cancel()
        registryMonitor = nil
    }

    private func scheduleRegistryRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            await self?.refresh()
        }
    }

    private struct Payload: Decodable {
        var task_id: String?
        var subject: String?
        var status: String?
        var done_criteria: [String]?
        var completed_criteria: [String]?
        var file: String?
        var error: String?
    }

    private func refresh() async {
        guard let key = boundProject else { return }
        if isRefreshing {
            needsRefreshAfterCurrent = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let env = boundEnvironment.isEmpty ? ProcessInfo.processInfo.environment : boundEnvironment
        let snap = await Self.load(projectKey: key, env: env)
        guard boundProject == key else { return }
        if taskId != snap.taskId { taskId = snap.taskId }
        if subject != snap.subject { subject = snap.subject }
        if status != snap.status { status = snap.status }
        if criteria != snap.criteria { criteria = snap.criteria }
        activeTaskFile = snap.file
        if Self.shouldUseCentralAuthority(env: boundEnvironment) {
            registryMonitor = nil
        } else {
            configureRegistryMonitor(project: key)
        }
        if needsRefreshAfterCurrent {
            needsRefreshAfterCurrent = false
            Task { await refresh() }
        }
    }

    private struct Snap {
        var taskId: String? = nil
        var subject: String? = nil
        var status: String? = nil
        var criteria: [Criterion] = []
        var file: String? = nil
    }

    nonisolated private static func load(projectKey: String, env: [String: String]) async -> Snap {
        if shouldUseCentralAuthority(env: env) {
            return await loadFromCentralAuthority(projectKey: projectKey, env: env)
        }

        let payload: Payload
        do {
            payload = try await SoulCLI.runJSON(
                ["task", "status", "-p", projectKey, "--json"],
                as: Payload.self
            )
        } catch {
            // CLI unavailable or decode failure — render empty rather than
            // stale. The next registry event or manual refresh can recover.
            return Snap()
        }
        if payload.error != nil {
            return Snap(taskId: payload.task_id, file: payload.file)
        }
        let dod = payload.done_criteria ?? []
        let done = Set(payload.completed_criteria ?? [])
        let normalizedStatus = payload.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let criteria = dod.map { Criterion(text: $0, done: done.contains($0)) }
        return Snap(
            taskId: payload.task_id,
            subject: payload.subject,
            status: normalizedStatus,
            criteria: criteria,
            file: payload.file
        )
    }

    nonisolated private static func loadFromCentralAuthority(projectKey: String, env: [String: String]) async -> Snap {
        let client = SoulAppServerClient(
            endpoint: SoulAppServerEndpoint.fromEnvironment(env),
            apiKey: SoulAppServerClient.defaultAPIKey(env: env),
            allowsLocalFallback: false
        )
        do {
            try await client.connectAndInitialize()
            let result = try await client.taskList(projectKey: projectKey, limit: 500)
            let activePayload = result.tasks.first { payload in
                let id = payload.id ?? payload.taskID
                return id == result.activeTask
            } ?? result.tasks.first { payload in
                SoulTaskPayload.normalized(payload.status, fallback: "pending") == "in_progress"
            }
            guard let activePayload else { return Snap(taskId: result.activeTask) }
            let record = activePayload.record(defaultProject: projectKey)
            let completed = Set(activePayload.completedCriteria ?? [])
            let criteria = record.doneCriteria.map { Criterion(text: $0, done: completed.contains($0)) }
            return Snap(
                taskId: record.id,
                subject: record.subject,
                status: record.status,
                criteria: criteria
            )
        } catch {
            return Snap()
        }
    }

    private func configureRegistryMonitor(project: String) {
        let root = Self.registryRootURL()
        var urls: [URL] = [
            root.appendingPathComponent("tasks"),
            root.appendingPathComponent("tasks").appendingPathComponent(project)
        ]
        if let activeTaskFile {
            urls.append(Self.fileURL(from: activeTaskFile))
        }
        registryMonitor?.update(paths: urls)
    }

    private static func registryRootURL() -> URL {
        let raw = ProcessInfo.processInfo.environment["SOUL_REGISTRY"] ?? "\(NSHomeDirectory())/soul_registry"
        return fileURL(from: raw)
    }

    nonisolated static func shouldUseCentralAuthority(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        (env["SOUL_REGISTRY_AUTHORITY"] ?? "").lowercased() == "required"
    }

    private static func fileURL(from raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }
}
