import Testing
import Foundation
@testable import Soul_Desktop

/// SOUL-364: per-session worktree provisioning. Covers the pure logic
/// (branch naming, slug normalization, policy/setting defaults) and the new
/// `isGitRepository` gate that decides whether a project root can be isolated.
@Suite("SessionWorktreeProvisioner Tests", .serialized)
struct SessionWorktreeProvisionerTests {

    private func run(_ args: [String], cwd: String) -> Bool {
        do {
            let result = try SafeProcessRunner.runSync(
                executable: "/usr/bin/git",
                arguments: args,
                currentDirectoryPath: cwd,
                timeoutSeconds: 10
            )
            return result.status == 0
        }
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
    func autoProvisionDefaultsOffWhenUnset() {
        UserDefaults.standard.removeObject(forKey: SessionWorktreeProvisioner.autoProvisionKey)
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled == false)
    }

    @Test
    func autoProvisionResolutionChain() {
        // 1. Explicit per-session policy in PROJECTS.json
        let pSession = SoulProject(id: "soul", name: "Soul OS", path: "~/soul-cli/soul", worktreePolicy: "per-session")
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled(for: pSession) == true)

        // 2. Explicit off policy in PROJECTS.json
        let pOff = SoulProject(id: "soul-desktop", name: "Soul Desktop", path: "~/Code/Soul-Desktop", worktreePolicy: "off")
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled(for: pOff) == false)

        // 3. Fallback to global setting (e.g. false when global unset)
        UserDefaults.standard.removeObject(forKey: SessionWorktreeProvisioner.autoProvisionKey)
        let pFallback = SoulProject(id: "some-other", name: "Some Other", path: "~/Code/Some-Other", worktreePolicy: nil)
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled(for: pFallback) == false)

        // 4. Fallback to global setting when true
        UserDefaults.standard.set(true, forKey: SessionWorktreeProvisioner.autoProvisionKey)
        #expect(SessionWorktreeProvisioner.autoProvisionEnabled(for: pFallback) == true)

        // Clean up
        UserDefaults.standard.removeObject(forKey: SessionWorktreeProvisioner.autoProvisionKey)
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
