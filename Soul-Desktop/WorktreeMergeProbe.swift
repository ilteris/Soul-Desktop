import Foundation

/// SOUL-365: computes per-session worktree mergeability with git's in-memory
/// merge (`merge-tree --write-tree`, git 2.38+) over an ephemeral snapshot of a
/// worktree's *live, uncommitted* files.
///
/// The snapshot is built in a throwaway index (`GIT_INDEX_FILE` pointed at a
/// non-existent path), so this NEVER writes a worktree's real `.git/index` and
/// is safe to run while an agent is using git in that worktree (the race the
/// merge-back spec §3.2 forbids). Nothing is committed to any ref; the probe
/// commit is a dangling object that git GCs.
public struct WorktreeMergeProbe {
    public enum Mergeability: Equatable {
        case clean
        case conflict(files: [String])
        case unknown(reason: String)
    }

    private let gitPath: String

    /// Prefer a modern git (Homebrew) over Apple git for `--write-tree`
    /// coverage on older systems; falls back to whatever's on PATH.
    public init(gitPath: String? = nil) {
        self.gitPath = gitPath ?? Self.resolveGitPath()
    }

    static func resolveGitPath() -> String {
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "git"
    }

    // MARK: - Public API

    /// Whether the resolved git supports the in-memory merge primitive.
    public func supportsInMemoryMerge() async -> Bool {
        let r = await run(["--version"])
        guard r.status == 0, let v = Self.parseVersion(r.stdout) else { return false }
        return v.major > 2 || (v.major == 2 && v.minor >= 38)
    }

    /// Mergeability of a worktree's live state against `target` (e.g. "main"),
    /// computed in `repo` (the main checkout that owns the shared object store).
    public func mergeability(
        ofWorktree worktree: String,
        into target: String,
        repo: String
    ) async -> Mergeability {
        guard await supportsInMemoryMerge() else {
            return .unknown(reason: "git too old for merge-tree --write-tree")
        }
        guard let candidate = await probeCommit(worktree: worktree) else {
            return .unknown(reason: "probe snapshot failed")
        }
        let t = await run(["-C", repo, "rev-parse", target])
        guard t.status == 0 else { return .unknown(reason: "unknown target \(target)") }
        return await merge(base: trimmed(t.stdout), candidate: candidate, repo: repo)
    }

    /// Mergeability of two probe commits against each other — the
    /// sibling-vs-sibling divergence signal. Caller supplies commits from
    /// `probeCommit`.
    public func merge(base: String, candidate: String, repo: String) async -> Mergeability {
        let r = await run(["-C", repo, "merge-tree", "--write-tree", base, candidate])
        switch r.status {
        case 0: return .clean
        case 1: return .conflict(files: Self.parseConflictFiles(r.stdout))
        default: return .unknown(reason: r.stderr.isEmpty ? "rc=\(r.status)" : trimmed(r.stderr))
        }
    }

    /// Snapshot a worktree's live files into a dangling commit parented on its
    /// HEAD (so `merge-tree` has a proper merge base). Returns the commit SHA,
    /// or nil if any step fails. Uses a throwaway index — the real one is never
    /// touched.
    public func probeCommit(worktree: String) async -> String? {
        let tmpIndex = NSTemporaryDirectory()
            + "soul-probe-index-" + UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }
        let env = ["GIT_INDEX_FILE": tmpIndex]

        guard await run(["-C", worktree, "add", "-A"], env: env).status == 0 else { return nil }
        let wt = await run(["-C", worktree, "write-tree"], env: env)
        guard wt.status == 0 else { return nil }
        let tree = trimmed(wt.stdout)

        let head = await run(["-C", worktree, "rev-parse", "HEAD"])
        guard head.status == 0 else { return nil }
        let base = trimmed(head.stdout)

        let commit = await run(
            ["-C", worktree, "commit-tree", tree, "-p", base],
            stdin: "soul probe"
        )
        guard commit.status == 0 else { return nil }
        return trimmed(commit.stdout)
    }

    // MARK: - Parsing

    static func parseVersion(_ s: String) -> (major: Int, minor: Int)? {
        // "git version 2.50.1 (Apple Git-155)"
        let parts = s.split(separator: " ")
        guard let i = parts.firstIndex(of: "version"), i + 1 < parts.count else { return nil }
        let nums = parts[i + 1].split(separator: ".")
            .map { $0.prefix(while: { $0.isNumber }) }
            .compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return (nums[0], nums[1])
    }

    /// Extract conflicted paths from `merge-tree --write-tree` output. Line 0 is
    /// the toplevel tree oid; the "conflicted file info" lines follow until a
    /// blank line, each as `<mode> <object> <stage>\t<path>`. Falls back to
    /// scanning the informational "Merge conflict in <path>" messages, and to
    /// an empty list if neither parses (the rc is the authoritative signal).
    static func parseConflictFiles(_ out: String) -> [String] {
        let lines = out.components(separatedBy: "\n")
        var files: [String] = []
        var i = 1
        while i < lines.count, !lines[i].isEmpty {
            if let tab = lines[i].range(of: "\t") {
                files.append(String(lines[i][tab.upperBound...]))
            }
            i += 1
        }
        if files.isEmpty {
            let marker = "Merge conflict in "
            for l in lines where l.contains(marker) {
                if let r = l.range(of: marker) {
                    files.append(String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return Array(Set(files)).sorted()
    }

    // MARK: - Process runner

    private struct GitResult { let status: Int32; let stdout: String; let stderr: String }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ args: [String], env: [String: String] = [:], stdin: String? = nil) async -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = args
        if !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            proc.environment = merged
        }
        let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        if stdin != nil { proc.standardInput = inPipe }

        // Drain both pipes concurrently before waiting, to avoid a full-buffer
        // deadlock on large diffs.
        async let outData = Task {
            (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value
        async let errData = Task {
            (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        }.value

        do {
            try proc.run()
        } catch {
            return GitResult(status: -1, stdout: "", stderr: "spawn failed: \(error.localizedDescription)")
        }
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()
        // Close the parent's copies of the child's stdout/stderr write ends so
        // readToEnd sees EOF the instant the child exits, not whenever ARC
        // releases the pipes. Without this each call stalls for seconds.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        await Task.detached { proc.waitUntilExit() }.value

        let o = await outData
        let e = await errData
        return GitResult(
            status: proc.terminationStatus,
            stdout: String(data: o, encoding: .utf8) ?? "",
            stderr: String(data: e, encoding: .utf8) ?? ""
        )
    }
}
