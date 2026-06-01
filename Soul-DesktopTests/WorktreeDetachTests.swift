import Foundation
import Testing
import SoulCore
@testable import Soul_Desktop

/// After a session worktree is landed and removed, the live controller must
/// repoint to the primary checkout so its bottom-bar branch label (driven by
/// ComposerView's `.task(id: projectPath)`) and its working root follow main
/// instead of a now-deleted worktree directory.
@MainActor
@Suite("Worktree detach repoints controller to primary checkout")
struct WorktreeDetachTests {

    private static func testProject(path: String) -> SoulProject {
        SoulProject(
            id: "soul-desktop",
            name: "Soul Desktop",
            path: path,
            pillar: "Platform",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
    }

    private static func hasLandedStatus(_ controller: ThreadController) -> Bool {
        controller.items.contains { item in
            if case .status(_, let text) = item { return text.contains("Worktree landed") }
            return false
        }
    }

    @Test("detach repoints project.path to primary and notes the move")
    func detachRepointsProjectPath() {
        let worktree = "/Users/x/.soul/worktrees/soul-desktop/abc"
        let primary = "/Users/x/Code/Soul-Desktop"
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject(path: worktree))
        #expect(controller.project.path == worktree)

        controller.detachFromWorktree(toPrimaryPath: primary)

        #expect(controller.project.path == primary)
        #expect(Self.hasLandedStatus(controller))
    }

    @Test("detach is a no-op when already rooted at the primary checkout")
    func detachNoOpWhenAlreadyPrimary() {
        let primary = "/Users/x/Code/Soul-Desktop"
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject(path: primary))

        controller.detachFromWorktree(toPrimaryPath: primary)

        #expect(controller.project.path == primary)
        #expect(!Self.hasLandedStatus(controller))
    }

    @Test("adopt points the controller at the worktree")
    func adoptSetsWorktreePath() {
        let primary = "/Users/x/Code/Soul-Desktop"
        let worktree = "/Users/x/.soul/worktrees/soul-desktop/abc"
        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject(path: primary))

        controller.adoptWorktree(worktree, primaryCheckout: primary)

        #expect(controller.project.path == worktree)
    }

    /// End-to-end: an out-of-band `git worktree remove` deletes the worktree's
    /// `.git` link. The armed vnode watch must fire and repoint the controller
    /// to the primary checkout with no in-app action involved.
    @Test("out-of-band .git removal repoints the controller to primary")
    func outOfBandRemovalRepoints() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("soul-wt-\(UUID().uuidString)")
        let worktree = base.appendingPathComponent("wt")
        let primary = base.appendingPathComponent("primary").path
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        let gitLink = worktree.appendingPathComponent(".git")
        try "gitdir: /tmp/primary/.git/worktrees/wt\n".write(to: gitLink, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: base) }

        let controller = ThreadController(provider: .geminiCLI, project: Self.testProject(path: primary))
        controller.adoptWorktree(worktree.path, primaryCheckout: primary)
        #expect(controller.project.path == worktree.path)

        // Simulate `git worktree remove` deleting the .git link.
        try fm.removeItem(at: gitLink)

        // The vnode source fires on the main queue then hops to the actor; poll
        // the main runloop until the repoint lands (≤3s).
        var flipped = false
        for _ in 0..<60 {
            if controller.project.path == primary { flipped = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(flipped)
        #expect(controller.project.path == primary)
    }
}
