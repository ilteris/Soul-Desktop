import Testing
import Foundation
@testable import Soul_Desktop

/// SOUL-364: per-session worktree provisioning. Covers the pure logic
/// (branch naming, slug normalization, policy/setting defaults) and the new
/// `isGitRepository` gate that decides whether a project root can be isolated.
@Suite("SessionWorktreeProvisioner Tests")
struct SessionWorktreeProvisionerTests {

    private func run(_ args: [String], cwd: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryPath = cwd
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    @Test
    func branchNameIsStableAndHierarchical() {
        let branch = SessionWorktreeProvisioner.branchName(
            projectKey: "SOUL_DESKTOP",
            sessionId: "abcdef1234567890",
            title: "Fix the sidebar crash!"
        )
        #expect(branch == "soul/session/SOUL_DESKTOP/abcdef12-fix-the-sidebar-crash")
    }

    @Test
    func slugifyEmptyFallsBackToSession() {
        #expect(SessionWorktreeProvisioner.slugify("") == "session")
        #expect(SessionWorktreeProvisioner.slugify("!!! ??? ...") == "session")
    }

    @Test
    func slugifyTruncatesAndLowercases() {
        let long = String(repeating: "A", count: 100)
        let slug = SessionWorktreeProvisioner.slugify(long)
        #expect(slug.count == 40)
        #expect(slug == slug.lowercased())
    }

    @Test
    func fallbackPolicyDefaultsToBlock() {
        UserDefaults.standard.removeObject(forKey: SessionWorktreeProvisioner.fallbackPolicyKey)
        #expect(SessionWorktreeProvisioner.fallbackPolicy == .block)
    }

    @Test
    func autoProvisionDefaultsOnWhenUnset() {
        UserDefaults.standard.removeObject(forKey: SessionWorktreeProvisioner.autoProvisionKey)
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled == true)
    }

    @Test
    func isGitRepositoryTrueForInitializedRepoFalseForPlainDir() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let repo = tempDir.appendingPathComponent("repo")
        let plain = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try #require(run(["init", "-b", "main"], cwd: repo.path))

        let isRepo = await GitWorktreeService.isGitRepository(path: repo.path)
        let isPlain = await GitWorktreeService.isGitRepository(path: plain.path)
        let isMissing = await GitWorktreeService.isGitRepository(path: tempDir.appendingPathComponent("nope").path)

        #expect(isRepo == true)
        #expect(isPlain == false)
        #expect(isMissing == false)
    }
}
