import Testing
import Foundation
@testable import Soul_Desktop

@Suite("GitWorktreeService Tests")
struct GitWorktreeServiceTests {
    
    private func runCommand(_ executable: String, _ arguments: [String], currentDirectoryPath: String) -> Bool {
        do {
            let result = try SafeProcessRunner.runSync(
                executable: executable,
                arguments: arguments,
                currentDirectoryPath: currentDirectoryPath,
                timeoutSeconds: 10
            )
            return result.status == 0
        } catch {
            return false
        }
    }

    private func gitOutput(_ arguments: [String], currentDirectoryPath: String) throws -> String {
        let result = try SafeProcessRunner.runSync(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            timeoutSeconds: 10
        )
        #expect(result.status == 0)
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    @Test
    func testWorktreeLifecycle() async throws {
        // Create a unique temporary directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mainRepoDir = tempDir.appendingPathComponent("main_repo")
        let worktreeDir = tempDir.appendingPathComponent("worktrees/my_fork")
        
        try FileManager.default.createDirectory(at: mainRepoDir, withIntermediateDirectories: true)
        
        let gitPath = "/usr/bin/git"
        
        // 1. Initialize empty git repository
        try #require(runCommand(gitPath, ["init", "-b", "main"], currentDirectoryPath: mainRepoDir.path))
        
        // Git worktrees require at least one commit in the repository to work.
        // Configure git dummy user and make an initial commit.
        try #require(runCommand(gitPath, ["config", "user.name", "Test User"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand(gitPath, ["config", "user.email", "test@example.com"], currentDirectoryPath: mainRepoDir.path))
        
        let testFile = mainRepoDir.appendingPathComponent("README.md")
        try "Initial commit".write(to: testFile, atomically: true, encoding: .utf8)
        
        try #require(runCommand(gitPath, ["add", "README.md"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand(gitPath, ["commit", "-m", "Initial commit"], currentDirectoryPath: mainRepoDir.path))
        
        // 2. Add worktree
        let branchName = "test/fork-branch"
        try await GitWorktreeService.addWorktree(
            projectPath: mainRepoDir.path,
            worktreePath: worktreeDir.path,
            branchName: branchName
        )
        
        // Verify worktree folder exists and is a git repository (contains .git file linking to main repo)
        let dotGitFile = worktreeDir.appendingPathComponent(".git")
        #expect(FileManager.default.fileExists(atPath: dotGitFile.path))
        
        // 3. List worktrees
        let listOutput = try await GitWorktreeService.listWorktrees(projectPath: mainRepoDir.path)
        #expect(listOutput.contains("my_fork"))
        
        // 4. Remove worktree
        try await GitWorktreeService.removeWorktree(
            projectPath: mainRepoDir.path,
            worktreePath: worktreeDir.path,
            force: true
        )
        
        // Verify folder is gone or untracked
        #expect(!FileManager.default.fileExists(atPath: dotGitFile.path))
        
        // 5. Prune worktrees
        try await GitWorktreeService.pruneWorktrees(projectPath: mainRepoDir.path)
        
        // Cleanup temp directory
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test
    func landFastForwardSealsTrackedChangesAndRetiresWorktree() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mainRepoDir = tempDir.appendingPathComponent("repo")
        let worktreeDir = tempDir.appendingPathComponent("worktrees/session")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: mainRepoDir, withIntermediateDirectories: true)
        try #require(runCommand("/usr/bin/git", ["init", "-b", "main"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["config", "user.name", "Test User"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["config", "user.email", "test@example.com"], currentDirectoryPath: mainRepoDir.path))
        try "one\n".write(to: mainRepoDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try #require(runCommand("/usr/bin/git", ["add", "README.md"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["commit", "-m", "Initial"], currentDirectoryPath: mainRepoDir.path))

        try await GitWorktreeService.addWorktree(
            projectPath: mainRepoDir.path,
            worktreePath: worktreeDir.path,
            branchName: "soul/session/test/session-1"
        )
        try "two\n".write(to: worktreeDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try await GitWorktreeService.landFastForward(
            projectPath: mainRepoDir.path,
            worktreePath: worktreeDir.path,
            sessionId: "session-1",
            projectKey: "test",
            title: "Land test"
        )

        #expect(result.branchName == "soul/session/test/session-1")
        #expect(result.sealedCommit == true)
        #expect(!FileManager.default.fileExists(atPath: worktreeDir.path))
        let deletedBranch = try gitOutput(
            ["branch", "--list", "soul/session/test/session-1"],
            currentDirectoryPath: mainRepoDir.path
        )
        #expect(deletedBranch.isEmpty)
        #expect(try String(contentsOf: mainRepoDir.appendingPathComponent("README.md"), encoding: .utf8) == "two\n")
        let backupSha = try gitOutput(["rev-parse", result.backupRef], currentDirectoryPath: mainRepoDir.path)
        #expect(backupSha == result.priorTargetSha)
        let author = try gitOutput(
            ["log", "-1", "--format=%an <%ae>"],
            currentDirectoryPath: mainRepoDir.path
        )
        #expect(author == "Soul Desktop <soul-desktop@local>")
    }

    @Test
    func landFastForwardBlocksUntrackedFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mainRepoDir = tempDir.appendingPathComponent("repo")
        let worktreeDir = tempDir.appendingPathComponent("worktrees/session")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: mainRepoDir, withIntermediateDirectories: true)
        try #require(runCommand("/usr/bin/git", ["init", "-b", "main"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["config", "user.name", "Test User"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["config", "user.email", "test@example.com"], currentDirectoryPath: mainRepoDir.path))
        try "one\n".write(to: mainRepoDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try #require(runCommand("/usr/bin/git", ["add", "README.md"], currentDirectoryPath: mainRepoDir.path))
        try #require(runCommand("/usr/bin/git", ["commit", "-m", "Initial"], currentDirectoryPath: mainRepoDir.path))

        try await GitWorktreeService.addWorktree(
            projectPath: mainRepoDir.path,
            worktreePath: worktreeDir.path,
            branchName: "soul/session/test/session-2"
        )
        try "secret\n".write(to: worktreeDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        do {
            _ = try await GitWorktreeService.landFastForward(
                projectPath: mainRepoDir.path,
                worktreePath: worktreeDir.path,
                sessionId: "session-2",
                projectKey: "test"
            )
            Issue.record("Expected untracked file to block landing")
        } catch {
            #expect(error.localizedDescription.contains("untracked files"))
        }

        #expect(FileManager.default.fileExists(atPath: worktreeDir.path))
        let branch = try gitOutput(
            ["branch", "--list", "soul/session/test/session-2"],
            currentDirectoryPath: mainRepoDir.path
        )
        #expect(!branch.isEmpty)
    }
}
