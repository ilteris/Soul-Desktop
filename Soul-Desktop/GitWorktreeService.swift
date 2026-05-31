import Foundation

public enum GitWorktreeError: Error, LocalizedError {
    case gitExecutableNotFound
    case commandFailed(status: Int32, stderr: String)
    case custom(String)

    public var errorDescription: String? {
        switch self {
        case .gitExecutableNotFound:
            return "Git executable not found in PATH."
        case .commandFailed(let status, let stderr):
            return "Git command failed with status \(status): \(stderr)"
        case .custom(let message):
            return message
        }
    }
}

public struct WorktreeLandResult: Equatable {
    public var branchName: String
    public var priorTargetSha: String
    public var landedSha: String
    public var backupRef: String
    public var sealedCommit: Bool
}

public struct GitWorktreeService {
    /// Calculate the canonical expected worktree path for a session.
    public static func expectedPath(projectKey: String, sessionId: String) -> String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".soul/worktrees/\(projectKey)/\(sessionId)")
    }

    /// Check if a worktree already exists for a session on disk.
    public static func worktreeExists(projectKey: String, sessionId: String) -> Bool {
        let path = expectedPath(projectKey: projectKey, sessionId: sessionId)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True when `path` is inside a git work tree. Used to gate per-session
    /// worktree provisioning (SOUL-364): non-git project roots can't host
    /// worktrees, so isolation is moot and the session runs in place.
    public static func isGitRepository(path: String) async -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return false }
        do {
            let out = try await runGit(at: expanded, arguments: ["rev-parse", "--is-inside-work-tree"])
            return out == "true"
        } catch {
            return false
        }
    }

    private static func resolveGitPath() -> String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/git") {
            return "/usr/local/bin/git"
        }
        return "git"
    }

    @discardableResult
    private static func runGit(
        at projectPath: String,
        arguments: [String]
    ) async throws -> String {
        let gitPath = resolveGitPath()
        let result: SafeProcessResult
        do {
            result = try await SafeProcessRunner.run(
                executable: gitPath,
                arguments: ["-C", projectPath] + arguments,
                timeoutSeconds: 10
            )
        } catch {
            throw GitWorktreeError.custom("Failed to spawn git process: \(error.localizedDescription)")
        }
        if result.status != 0 {
            let errText = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GitWorktreeError.commandFailed(
                status: result.status,
                stderr: result.timedOut ? "git command timed out" : errText
            )
        }

        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Add a git worktree.
    /// Runs: git worktree add -b branchName worktreePath
    public static func addWorktree(
        projectPath: String,
        worktreePath: String,
        branchName: String
    ) async throws {
        let expandedProjectPath = (projectPath as NSString).expandingTildeInPath
        let expandedWorktreePath = (worktreePath as NSString).expandingTildeInPath
        
        let args = ["worktree", "add", "-b", branchName, expandedWorktreePath]
        try await runGit(at: expandedProjectPath, arguments: args)
    }

    /// Remove a git worktree.
    /// Runs: git worktree remove --force worktreePath
    public static func removeWorktree(
        projectPath: String,
        worktreePath: String,
        force: Bool = true
    ) async throws {
        let expandedProjectPath = (projectPath as NSString).expandingTildeInPath
        let expandedWorktreePath = (worktreePath as NSString).expandingTildeInPath
        
        var args = ["worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append(expandedWorktreePath)
        
        try await runGit(at: expandedProjectPath, arguments: args)
    }

    /// List active git worktrees.
    /// Runs: git worktree list
    public static func listWorktrees(projectPath: String) async throws -> String {
        let expandedProjectPath = (projectPath as NSString).expandingTildeInPath
        return try await runGit(at: expandedProjectPath, arguments: ["worktree", "list"])
    }

    /// Prune untracked worktree metadata.
    /// Runs: git worktree prune
    public static func pruneWorktrees(projectPath: String) async throws {
        let expandedProjectPath = (projectPath as NSString).expandingTildeInPath
        try await runGit(at: expandedProjectPath, arguments: ["worktree", "prune"])
    }

    /// Land an idle session worktree back to `targetBranch` using the
    /// conservative SOUL-370 path:
    /// - refuse untracked files instead of sweeping them into history
    /// - seal tracked worktree changes with a Soul-authored commit
    /// - require targetBranch to be an ancestor of the session branch
    /// - save a prior-ref backup before advancing targetBranch
    /// - remove the session worktree and delete the landed branch
    ///
    /// This intentionally implements only the T1 fast-forward path. Textual
    /// merges and conflict resolution stay human-driven.
    public static func landFastForward(
        projectPath: String,
        worktreePath: String,
        targetBranch: String = "main",
        sessionId: String,
        projectKey: String,
        title: String? = nil
    ) async throws -> WorktreeLandResult {
        let expandedProjectPath = (projectPath as NSString).expandingTildeInPath
        let expandedWorktreePath = (worktreePath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedProjectPath) else {
            throw GitWorktreeError.custom("Project checkout does not exist: \(expandedProjectPath)")
        }
        guard FileManager.default.fileExists(atPath: expandedWorktreePath) else {
            throw GitWorktreeError.custom("Session worktree does not exist: \(expandedWorktreePath)")
        }

        let branch = try await runGit(at: expandedWorktreePath, arguments: ["branch", "--show-current"])
        guard !branch.isEmpty else {
            throw GitWorktreeError.custom("Session worktree is detached; cannot safely land it")
        }
        guard branch != targetBranch else {
            throw GitWorktreeError.custom("Session worktree is already on \(targetBranch)")
        }

        let checkedOutTarget = try await runGit(
            at: expandedProjectPath,
            arguments: ["branch", "--show-current"]
        )
        guard checkedOutTarget == targetBranch else {
            throw GitWorktreeError.custom(
                "Project checkout is on \(checkedOutTarget.isEmpty ? "detached HEAD" : checkedOutTarget), not \(targetBranch)"
            )
        }

        let mainStatus = try await runGit(
            at: expandedProjectPath,
            arguments: ["status", "--porcelain"]
        )
        guard mainStatus.isEmpty else {
            throw GitWorktreeError.custom("Main checkout has local changes; land after it is clean")
        }

        let untracked = try await runGit(
            at: expandedWorktreePath,
            arguments: ["status", "--porcelain", "--untracked-files=normal"]
        )
        let untrackedLines = untracked
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("?? ") }
        guard untrackedLines.isEmpty else {
            let files = untrackedLines
                .map { String($0.dropFirst(3)) }
                .prefix(5)
                .joined(separator: ", ")
            throw GitWorktreeError.custom(
                "Session worktree has untracked files (\(files)); review or gitignore them before landing"
            )
        }

        let trackedStatus = try await runGit(
            at: expandedWorktreePath,
            arguments: ["status", "--porcelain", "--untracked-files=no"]
        )
        var sealedCommit = false
        if !trackedStatus.isEmpty {
            try await runGit(at: expandedWorktreePath, arguments: ["add", "-u"])
            let message = sealCommitMessage(
                sessionId: sessionId,
                projectKey: projectKey,
                title: title
            )
            try await runGit(
                at: expandedWorktreePath,
                arguments: [
                    "-c", "user.name=Soul Desktop",
                    "-c", "user.email=soul-desktop@local",
                    "commit",
                    "--author=Soul Desktop <soul-desktop@local>",
                    "-m", message
                ]
            )
            sealedCommit = true
        }

        let targetSha = try await runGit(
            at: expandedProjectPath,
            arguments: ["rev-parse", targetBranch]
        )
        let branchSha = try await runGit(
            at: expandedProjectPath,
            arguments: ["rev-parse", branch]
        )
        do {
            try await runGit(
                at: expandedProjectPath,
                arguments: ["merge-base", "--is-ancestor", targetSha, branchSha]
            )
        } catch {
            throw GitWorktreeError.custom(
                "\(branch) cannot fast-forward \(targetBranch); resolve divergence manually"
            )
        }

        let backupRef = "refs/soul/land-backups/\(targetBranch)/\(safeRefComponent(sessionId))"
        try await runGit(
            at: expandedProjectPath,
            arguments: ["update-ref", backupRef, targetSha]
        )
        try await runGit(
            at: expandedProjectPath,
            arguments: ["merge", "--ff-only", branch]
        )
        try await removeWorktree(
            projectPath: expandedProjectPath,
            worktreePath: expandedWorktreePath,
            force: false
        )
        try await runGit(
            at: expandedProjectPath,
            arguments: ["branch", "-d", branch]
        )

        return WorktreeLandResult(
            branchName: branch,
            priorTargetSha: targetSha,
            landedSha: branchSha,
            backupRef: backupRef,
            sealedCommit: sealedCommit
        )
    }

    private static func sealCommitMessage(
        sessionId: String,
        projectKey: String,
        title: String?
    ) -> String {
        var lines = ["Seal Soul session worktree"]
        lines.append("")
        lines.append("Session: \(sessionId)")
        lines.append("Project: \(projectKey)")
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Title: \(title)")
        }
        return lines.joined(separator: "\n")
    }

    private static func safeRefComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let clean = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return clean.isEmpty ? UUID().uuidString.lowercased() : clean
    }
}
