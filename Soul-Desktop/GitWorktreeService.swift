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
}
