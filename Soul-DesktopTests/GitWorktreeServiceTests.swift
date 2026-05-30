import Testing
import Foundation
@testable import Soul_Desktop

@Suite("GitWorktreeService Tests")
struct GitWorktreeServiceTests {
    
    private func runCommand(_ executable: String, _ arguments: [String], currentDirectoryPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryPath = currentDirectoryPath
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
}
