import Testing
import Foundation
@testable import Soul_Desktop

/// SOUL-365: the mergeability probe. Recreates the parallel-session scenario
/// validated by the shell prototype — three worktrees off main, one editing a
/// disjoint file, one colliding on the same lines — and asserts the readout.
@Suite("WorktreeMergeProbe Tests")
struct WorktreeMergeProbeTests {

    @discardableResult
    private func git(_ args: [String], cwd: String, env: [String: String] = [:]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryPath = cwd
        if !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    @Test
    func parsesGitVersion() {
        #expect(WorktreeMergeProbe.parseVersion("git version 2.50.1 (Apple Git-155)")! == (2, 50))
        #expect(WorktreeMergeProbe.parseVersion("git version 2.38.0")! == (2, 38))
        #expect(WorktreeMergeProbe.parseVersion("garbage") == nil)
    }

    @Test
    func parsesConflictMessageFallback() {
        let out = "abc123\n\nCONFLICT (content): Merge conflict in Sources/Foo.swift\n"
        #expect(WorktreeMergeProbe.parseConflictFiles(out) == ["Sources/Foo.swift"])
    }

    @Test
    func probeReadoutMatchesParallelSessionScenario() async throws {
        let probe = WorktreeMergeProbe(gitPath: "/usr/bin/git")
        try await #require(probe.supportsInMemoryMerge())

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-probe-" + UUID().uuidString)
        let repo = root.appendingPathComponent("repo")
        let wts = root.appendingPathComponent("wts")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed a repo with two files and one commit on main.
        try #require(git(["init", "-b", "main"], cwd: repo.path))
        try #require(git(["config", "user.name", "Test"], cwd: repo.path))
        try #require(git(["config", "user.email", "t@e.st"], cwd: repo.path))
        try "let foo = 1\n".write(to: repo.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        try "let bar = 1\n".write(to: repo.appendingPathComponent("Bar.swift"), atomically: true, encoding: .utf8)
        try #require(git(["add", "-A"], cwd: repo.path))
        try #require(git(["commit", "-m", "init"], cwd: repo.path))

        // Three sessions branched off main, like the provisioner creates.
        let a = wts.appendingPathComponent("session-a").path
        let b = wts.appendingPathComponent("session-b").path
        let c = wts.appendingPathComponent("session-c").path
        try #require(git(["worktree", "add", "-b", "probe/a", a, "main"], cwd: repo.path))
        try #require(git(["worktree", "add", "-b", "probe/b", b, "main"], cwd: repo.path))
        try #require(git(["worktree", "add", "-b", "probe/c", c, "main"], cwd: repo.path))

        // Live, UNCOMMITTED edits (never sealed):
        try "let foo = 2 // session-a\n".write(to: URL(fileURLWithPath: a).appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        try "let bar = 2 // session-b\n".write(to: URL(fileURLWithPath: b).appendingPathComponent("Bar.swift"), atomically: true, encoding: .utf8)
        try "let foo = 3 // session-c\n".write(to: URL(fileURLWithPath: c).appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)

        // Each lands clean vs main individually.
        #expect(await probe.mergeability(ofWorktree: a, into: "main", repo: repo.path) == .clean)
        #expect(await probe.mergeability(ofWorktree: b, into: "main", repo: repo.path) == .clean)
        #expect(await probe.mergeability(ofWorktree: c, into: "main", repo: repo.path) == .clean)

        // Sibling divergence: a⇄b disjoint files clean; a⇄c collide on Foo.swift.
        let ca = try #require(await probe.probeCommit(worktree: a))
        let cb = try #require(await probe.probeCommit(worktree: b))
        let cc = try #require(await probe.probeCommit(worktree: c))
        #expect(await probe.merge(base: ca, candidate: cb, repo: repo.path) == .clean)
        #expect(await probe.merge(base: cb, candidate: cc, repo: repo.path) == .clean)
        #expect(await probe.merge(base: ca, candidate: cc, repo: repo.path) == .conflict(files: ["Foo.swift"]))

        // Index-untouched invariant: probing must not stage anything in the
        // real worktree index (spec §3.2 — agent-race safety).
        for wt in [a, b, c] {
            let staged = Process()
            staged.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            staged.arguments = ["-C", wt, "diff", "--cached", "--name-only"]
            let pipe = Pipe(); staged.standardOutput = pipe
            try staged.run(); staged.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
