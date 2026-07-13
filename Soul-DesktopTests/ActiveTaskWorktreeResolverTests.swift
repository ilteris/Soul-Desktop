import Foundation
import Testing
@testable import Soul_Desktop

@Suite("ActiveTaskWorktreeResolver")
struct ActiveTaskWorktreeResolverTests {
    @Test func resolvesActiveTaskWorkspaceRecord() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        let worktree = root.base.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeActiveTask("SOUL-JOB_HUNT-052", projectKey: "job-hunt", registryRoot: root.registry)
        try writeWorkspace(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            path: worktree.path,
            parentRepo: parent.path,
            branch: "codex/job-hunt/soul-job_hunt-052",
            registryRoot: root.registry
        )

        let adoption = try #require(ActiveTaskWorktreeResolver.adoption(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            currentProjectPath: parent.path,
            registryRoot: root.registry
        ))

        #expect(adoption.path == worktree.standardizedFileURL.path)
        #expect(adoption.branch == "codex/job-hunt/soul-job_hunt-052")
    }

    @Test func ignoresWorkspaceRecordFromDifferentParentCheckout() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        let other = root.base.appendingPathComponent("other-worktree", isDirectory: true)
        let worktree = root.base.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeWorkspace(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            path: worktree.path,
            parentRepo: parent.path,
            branch: nil,
            registryRoot: root.registry
        )

        let adoption = ActiveTaskWorktreeResolver.adoption(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            currentProjectPath: other.path,
            registryRoot: root.registry
        )

        #expect(adoption == nil)
    }

    @Test func ignoresWorkspaceRecordWhenCurrentPathEqualsWorktreeButParentDiffers() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        let worktree = root.base.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeWorkspace(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            path: worktree.path,
            parentRepo: parent.path,
            branch: nil,
            registryRoot: root.registry
        )

        let adoption = ActiveTaskWorktreeResolver.adoption(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            currentProjectPath: worktree.path,
            registryRoot: root.registry
        )

        #expect(adoption == nil)
    }

    @Test func ignoresWorkspaceRecordWithoutParentRepo() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        let worktree = root.base.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeWorkspace(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            path: worktree.path,
            parentRepo: nil,
            branch: nil,
            registryRoot: root.registry
        )

        let adoption = ActiveTaskWorktreeResolver.adoption(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            currentProjectPath: parent.path,
            registryRoot: root.registry
        )

        #expect(adoption == nil)
    }

    @Test func doesNotGuessWorktreePathWithoutWorkspaceRecord() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try writeActiveTask("SOUL-JOB_HUNT-052", projectKey: "job-hunt", registryRoot: root.registry)

        let adoption = ActiveTaskWorktreeResolver.adoption(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            currentProjectPath: parent.path,
            registryRoot: root.registry
        )

        #expect(adoption == nil)
    }

    @Test func activeProjectAdoptionReadsSoulTaskPointer() throws {
        let root = try makeRegistryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }

        let parent = root.base.appendingPathComponent("job-hunt", isDirectory: true)
        let worktree = root.base.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeActiveTask("SOUL-JOB_HUNT-052", projectKey: "job-hunt", registryRoot: root.registry)
        try writeWorkspace(
            projectKey: "job-hunt",
            taskId: "SOUL-JOB_HUNT-052",
            path: worktree.path,
            parentRepo: parent.path,
            branch: nil,
            registryRoot: root.registry
        )
        let project = SoulProject(id: "job-hunt", name: "Job Hunt 2026", path: parent.path)

        let adoption = try #require(ActiveTaskWorktreeResolver.adoption(
            for: project,
            registryRoot: root.registry
        ))

        #expect(adoption.taskId == "SOUL-JOB_HUNT-052")
        #expect(adoption.path == worktree.standardizedFileURL.path)
    }

    private func makeRegistryFixture() throws -> (base: URL, registry: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-active-task-worktree-\(UUID().uuidString)", isDirectory: true)
        let registry = base.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        return (base, registry)
    }

    private func writeActiveTask(
        _ taskId: String,
        projectKey: String,
        registryRoot: URL
    ) throws {
        let taskDir = registryRoot
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        try "\(taskId)\n".write(
            to: taskDir.appendingPathComponent(".soul_task"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeWorkspace(
        projectKey: String,
        taskId: String,
        path: String,
        parentRepo: String?,
        branch: String?,
        registryRoot: URL
    ) throws {
        let workspaceDir = registryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "schema_version": "soul-workspace/v1",
            "workspace_id": taskId,
            "project": projectKey,
            "task_id": taskId,
            "status": "active",
            "path": path
        ]
        if let parentRepo {
            obj["parent_repo"] = parentRepo
        }
        if let branch {
            obj["branch"] = branch
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: workspaceDir.appendingPathComponent("\(taskId).json"), options: .atomic)
    }
}
