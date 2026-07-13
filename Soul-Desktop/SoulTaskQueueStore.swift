import Foundation
import SwiftUI
import Combine

@MainActor
final class SoulTaskQueueStore: ObservableObject {
    @Published private(set) var openTasks: [SoulTaskRecord] = []
    @Published private(set) var activeTaskId: String? = nil
    @Published private(set) var loadError: String? = nil
    @Published private(set) var isLoading: Bool = false

    private var boundProject: String? = nil

    var recommendedTask: SoulTaskRecord? {
        openTasks.first { $0.id == activeTaskId }
            ?? openTasks.first { $0.status == "in_progress" }
            ?? openTasks.first { $0.priority == "high" }
            ?? openTasks.first
    }

    var highPriorityCount: Int {
        openTasks.filter { $0.priority == "high" }.count
    }

    var inProgressCount: Int {
        openTasks.filter { $0.status == "in_progress" }.count
    }

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        openTasks = []
        activeTaskId = nil
        loadError = nil
        refresh()
    }

    func refresh() {
        guard let project = boundProject, !project.isEmpty else { return }
        isLoading = true
        Task {
            let snapshot = await Self.load(projectKey: project)
            openTasks = snapshot.tasks
            activeTaskId = snapshot.activeTaskId
            loadError = snapshot.error
            isLoading = false
        }
    }

    private struct Snapshot: Sendable {
        var tasks: [SoulTaskRecord]
        var activeTaskId: String?
        var error: String? = nil
    }

    nonisolated private static func load(projectKey: String) async -> Snapshot {
        if shouldUseCentralAuthority() {
            return await loadFromCentralAuthority(projectKey: projectKey)
        }

        return await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("soul_registry")
                .appendingPathComponent("tasks")
                .appendingPathComponent(projectKey)
            let activeURL = root.appendingPathComponent(".soul_task")
            let active = (try? String(contentsOf: activeURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let tasks = loadOpenTasks(projectKey: projectKey, from: urls)
            return Snapshot(tasks: tasks, activeTaskId: active?.isEmpty == false ? active : nil)
        }.value
    }

    nonisolated static func shouldUseCentralAuthority(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let mode = (env["SOUL_REGISTRY_AUTHORITY"] ?? "").lowercased()
        return mode == "required"
    }

    nonisolated private static func loadFromCentralAuthority(projectKey: String) async -> Snapshot {
        let client = SoulAppServerClient()
        do {
            try await client.connectAndInitialize()
            let result = try await client.taskList(projectKey: projectKey, limit: 500)
            return Snapshot(
                tasks: sorted(result.taskRecords(defaultProject: projectKey)),
                activeTaskId: result.activeTask
            )
        } catch {
            return Snapshot(
                tasks: [],
                activeTaskId: nil,
                error: "Required central task authority unavailable: \(error.localizedDescription)"
            )
        }
    }

    nonisolated static func loadOpenTasks(
        projectKey: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SoulTaskRecord] {
        guard !shouldUseCentralAuthority(env: env) else { return [] }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("soul_registry")
            .appendingPathComponent("tasks")
            .appendingPathComponent(projectKey)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return loadOpenTasks(projectKey: projectKey, from: urls)
    }

    nonisolated private static func loadOpenTasks(projectKey: String, from urls: [URL]) -> [SoulTaskRecord] {
        var tasks: [SoulTaskRecord] = []
        for url in urls where url.pathExtension == "json" {
            guard let task = readTask(url, projectKey: projectKey) else { continue }
            if task.status == "completed" || task.status == "wont_fix" || task.status == "archive" {
                continue
            }
            tasks.append(task)
        }

        return sorted(tasks)
    }

    nonisolated static func sorted(_ tasks: [SoulTaskRecord]) -> [SoulTaskRecord] {
        tasks.sorted { lhs, rhs in
            let rank: [String: Int] = ["in_progress": 0, "pending": 1, "freezer": 2]
            let lhsRank = rank[lhs.status] ?? 9
            let rhsRank = rank[rhs.status] ?? 9
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    nonisolated private static func readTask(_ url: URL, projectKey: String) -> SoulTaskRecord? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = (obj["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let subject = (obj["subject"] as? String) ?? (obj["title"] as? String) ?? "Untitled task"
        let project = (obj["project"] as? String) ?? projectKey
        let status = ((obj["status"] as? String) ?? "pending")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let priority = ((obj["priority"] as? String) ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let doneCriteria = (obj["done_criteria"] as? [String]) ?? (obj["definition_of_done"] as? [String]) ?? []
        let completed = (obj["completed_criteria"] as? [String]) ?? []

        return SoulTaskRecord(
            id: id,
            project: project,
            subject: subject,
            status: status,
            priority: priority,
            updatedAt: obj["updated_at"] as? String,
            doneCriteria: doneCriteria,
            completedCriteriaCount: completed.count
        )
    }
}
