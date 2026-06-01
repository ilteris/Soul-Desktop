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
}
