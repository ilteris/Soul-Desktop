import Foundation
import Testing
@testable import Soul_Desktop

@Suite("Preview path target routing")
struct PreviewPathTargetTests {
    @Test func existingDirectoryRoutesToFinder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("applications/fireworks-product-engineer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AppShell.PreviewPathTarget.resolve(directory.path) == .directory(directory.path))
    }

    @Test func existingFileRoutesToPreviewPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try "# Read me\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AppShell.PreviewPathTarget.resolve(file.path) == .file(file.path))
    }

    @Test func missingPathStillRoutesToPreviewPaneForErrorDisplay() {
        let missing = "/tmp/soul-preview-target-\(UUID().uuidString)/missing.md"

        #expect(AppShell.PreviewPathTarget.resolve(missing) == .file(missing))
    }

    @Test func sameFilesystemPathNormalizesDotComponents() {
        let base = "/tmp/soul-preview-target-\(UUID().uuidString)"

        #expect(AppShell.sameFilesystemPath("\(base)/folder/../folder", "\(base)/folder"))
    }

    @Test func relativePreviewPathPrefersSessionWorktreeOverCanonicalProjectPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let canonical = root.appendingPathComponent("job-hunt", isDirectory: true)
        let worktree = root.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let file = worktree.appendingPathComponent("MONDAY_BEN_CALL_PLAYBOOK.md")
        try "# Playbook\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let base = try #require(AppShell.preferredPreviewBasePath(
            sessionWorktreePath: worktree.path,
            projectOverridePath: nil,
            threadProjectPath: canonical.path,
            replayProjectPath: nil,
            currentProjectPath: canonical.path
        ))

        #expect(base == worktree.path)
        #expect(AppShell.resolvePreviewPath("MONDAY_BEN_CALL_PLAYBOOK.md", base: base) == file.path)
    }

    @Test func relativePreviewPathUsesProjectOverrideBeforeCanonicalProjectPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let canonical = root.appendingPathComponent("job-hunt", isDirectory: true)
        let selectedWorktree = root.appendingPathComponent("SOUL-JOB_HUNT-052", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedWorktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let base = try #require(AppShell.preferredPreviewBasePath(
            sessionWorktreePath: nil,
            projectOverridePath: selectedWorktree.path,
            threadProjectPath: canonical.path,
            replayProjectPath: nil,
            currentProjectPath: canonical.path
        ))

        #expect(base == selectedWorktree.path)
    }

    @Test func relativePreviewPathInReplayResolvesToReplayProjectAndIgnoresActiveThread() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let activeThreadPath = root.appendingPathComponent("active-thread-project", isDirectory: true)
        let replayProjectPath = root.appendingPathComponent("replay-project", isDirectory: true)
        try FileManager.default.createDirectory(at: activeThreadPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replayProjectPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Simulated previewBasePath() output for replay, setting threadProjectPath to nil:
        let base = try #require(AppShell.preferredPreviewBasePath(
            sessionWorktreePath: nil,
            projectOverridePath: nil,
            threadProjectPath: nil, // Isolated during replay
            replayProjectPath: replayProjectPath.path,
            currentProjectPath: nil
        ))

        #expect(base == replayProjectPath.path)
    }

    @Test func relativePreviewPathInReplayPrefersReplaySessionWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let replayProjectPath = root.appendingPathComponent("replay-project", isDirectory: true)
        let replayWorktreePath = root.appendingPathComponent("SOUL-REPLAY-101", isDirectory: true)
        try FileManager.default.createDirectory(at: replayProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replayWorktreePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let base = try #require(AppShell.preferredPreviewBasePath(
            sessionWorktreePath: replayWorktreePath.path,
            projectOverridePath: nil,
            threadProjectPath: nil,
            replayProjectPath: replayProjectPath.path,
            currentProjectPath: nil
        ))

        #expect(base == replayWorktreePath.path)
    }

    @Test func bareFilenameFallbackDoesNotEscapeActivePreviewBase() {
        #expect(!AppShell.shouldSearchKnownProjectsForBarePreview(
            currentExists: false,
            stripped: "MONDAY_BEN_CALL_PLAYBOOK.md",
            base: "/Users/example/soul_worktrees/job-hunt/SOUL-JOB_HUNT-052"
        ))
        #expect(AppShell.shouldSearchKnownProjectsForBarePreview(
            currentExists: false,
            stripped: "PROJECTS.json",
            base: nil
        ))
    }
}
