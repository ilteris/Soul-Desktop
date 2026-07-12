import Foundation

struct ActiveTaskWorktreeAdoption: Equatable {
    var taskId: String
    var path: String
    var branch: String?
}

enum ActiveTaskWorktreeResolver {
    static func adoption(
        for project: SoulProject,
        registryRoot: URL = defaultRegistryRoot(),
        fileManager: FileManager = .default
    ) -> ActiveTaskWorktreeAdoption? {
        guard let taskId = activeTaskId(projectKey: project.id, registryRoot: registryRoot) else {
            return nil
        }
        return adoption(
            projectKey: project.id,
            taskId: taskId,
            currentProjectPath: project.path,
            registryRoot: registryRoot,
            fileManager: fileManager
        )
    }

    static func adoption(
        projectKey: String,
        taskId: String,
        currentProjectPath: String,
        registryRoot: URL = defaultRegistryRoot(),
        fileManager: FileManager = .default
    ) -> ActiveTaskWorktreeAdoption? {
        guard let record = workspaceRecord(
            projectKey: projectKey,
            taskId: taskId,
            registryRoot: registryRoot
        ),
              record.isUsable(forCurrentProjectPath: currentProjectPath),
              directoryExists(record.path, fileManager: fileManager)
        else { return nil }
        return ActiveTaskWorktreeAdoption(
            taskId: taskId,
            path: normalized(record.path),
            branch: record.branch
        )
    }

    static func activeTaskId(projectKey: String, registryRoot: URL = defaultRegistryRoot()) -> String? {
        let url = registryRoot
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
            .appendingPathComponent(".soul_task")
        let raw = try? String(contentsOf: url, encoding: .utf8)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func defaultRegistryRoot() -> URL {
        let raw = ProcessInfo.processInfo.environment["SOUL_REGISTRY"]
            ?? "\(NSHomeDirectory())/soul_registry"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    private struct WorkspaceRecord {
        var project: String?
        var taskId: String?
        var status: String?
        var path: String
        var parentRepo: String?
        var branch: String?

        func isUsable(forCurrentProjectPath current: String) -> Bool {
            if let status, ["removed", "closed", "archived"].contains(status.lowercased()) {
                return false
            }
            guard let parentRepo, !parentRepo.isEmpty else { return false }
            let currentPath = ActiveTaskWorktreeResolver.normalized(current)
            return currentPath == ActiveTaskWorktreeResolver.normalized(parentRepo)
        }
    }

    private static func workspaceRecord(
        projectKey: String,
        taskId: String,
        registryRoot: URL
    ) -> WorkspaceRecord? {
        let url = registryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
            .appendingPathComponent("\(taskId).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let recordProject = obj["project"] as? String
        let recordTask = obj["task_id"] as? String
        if let recordProject, recordProject != projectKey { return nil }
        if let recordTask, recordTask != taskId { return nil }

        return WorkspaceRecord(
            project: recordProject,
            taskId: recordTask,
            status: obj["status"] as? String,
            path: path,
            parentRepo: obj["parent_repo"] as? String,
            branch: obj["branch"] as? String
        )
    }

    private static func directoryExists(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        return fileManager.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}
