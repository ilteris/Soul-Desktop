import Foundation
import SoulCore
import SoulLedger

/// What happens when an isolated worktree can't be created for a new session
/// (SOUL-364). Default is `.block`: never let a session silently run in the
/// shared checkout, where it would collide with other concurrent sessions on
/// the same project.
enum WorktreeFallbackPolicy: String {
    case block          // refuse to spawn in the shared checkout; surface an error
    case ask            // reserved for a future prompt; treated as .block until the UI lands
    case fallbackToMain // legacy behavior: run in the main checkout
}

/// Provisions a per-session Git worktree so two agents working the same
/// repository never share a working tree (SOUL-364). Centralizes branch
/// naming, path generation, ledger recording, and fallback policy.
///
/// Invoked from `AppShell.startThread` AFTER `acceptUserPrompt` (so the kernel
/// `sessionId` — adopted from `controller.id` — is set) and BEFORE
/// `dispatchPending` (so the agent spawns with its cwd already pointed at the
/// worktree, and the kernel stamps `SESSION_START.worktree_path` for resume).
enum SessionWorktreeProvisioner {
    static let autoProvisionKey = "soul.worktree.autoProvisionNewSessions"
    static let fallbackPolicyKey = "soul.worktree.fallbackPolicy"

    /// Default ON. Absence of the key reads as enabled.
    static var autoProvisionEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoProvisionKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoProvisionKey)
    }

    /// Default `.block`. Only an explicit, recognized value changes it.
    static var fallbackPolicy: WorktreeFallbackPolicy {
        guard let raw = UserDefaults.standard.string(forKey: fallbackPolicyKey),
              let policy = WorktreeFallbackPolicy(rawValue: raw) else { return .block }
        return policy
    }

    /// Provision an isolated worktree for `controller`'s fresh session.
    /// On success: mutates `controller.project.path` to the worktree, records a
    /// `WorktreeCreated` hook, and sets `worktreeProvisionState = .provisioned`.
    /// On failure: applies `fallbackPolicy` and surfaces a status/error row.
    @MainActor
    static func provision(controller: ThreadController) async {
        guard autoProvisionEnabled else {
            controller.worktreeProvisionState = .skipped(reason: "auto-provision disabled")
            return
        }
        guard let sid = controller.sessionId else {
            controller.worktreeProvisionState = .skipped(reason: "no session id")
            return
        }
        let projectKey = controller.project.id
        let mainPath = controller.project.path

        // Non-git project roots can't host worktrees; isolation is moot.
        guard await GitWorktreeService.isGitRepository(path: mainPath) else {
            controller.worktreeProvisionState = .skipped(reason: "not a git repository")
            return
        }

        let branch = branchName(
            projectKey: projectKey,
            sessionId: sid,
            title: controller.customTitle ?? controller.displayTitle
        )
        let worktreePath = GitWorktreeService.expectedPath(projectKey: projectKey, sessionId: sid)

        // Idempotency: adopt an existing worktree rather than re-creating it.
        if GitWorktreeService.worktreeExists(projectKey: projectKey, sessionId: sid) {
            controller.adoptWorktree(worktreePath, primaryCheckout: mainPath)
            controller.worktreeProvisionState = .provisioned(path: worktreePath, branch: branch)
            return
        }

        controller.items.append(.status(
            id: UUID(),
            text: "Creating isolated worktree for this session…"
        ))

        do {
            // git creates the leaf dir, but the keyed parent may not exist yet.
            let parent = (worktreePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true
            )

            try await GitWorktreeService.addWorktree(
                projectPath: mainPath,
                worktreePath: worktreePath,
                branchName: branch
            )
            controller.adoptWorktree(worktreePath, primaryCheckout: mainPath)
            controller.worktreeProvisionState = .provisioned(path: worktreePath, branch: branch)

            SoulRegistry.appendHook(
                projectKey: projectKey,
                sessionId: sid,
                event: LedgerHookEvent.worktreeCreated(
                    path: worktreePath, branchName: branch
                ).hookDictionary
            )
            controller.items.append(.status(id: UUID(), text: "↗ Isolated on branch \(branch)"))
        } catch {
            applyFailure(controller: controller, projectKey: projectKey, sessionId: sid, error: error)
        }
    }

    @MainActor
    private static func applyFailure(
        controller: ThreadController,
        projectKey: String,
        sessionId: String,
        error: Error
    ) {
        let msg = error.localizedDescription
        switch fallbackPolicy {
        case .fallbackToMain:
            controller.worktreeProvisionState = .fellBackToMain(error: msg)
            SoulRegistry.appendHook(
                projectKey: projectKey, sessionId: sessionId,
                event: ["event": "WorktreeFallback", "error": msg, "policy": "fallbackToMain"]
            )
            controller.items.append(.status(
                id: UUID(),
                text: "⚠︎ Worktree unavailable (\(msg)). Running in the main checkout."
            ))
        case .block, .ask:
            controller.worktreeProvisionState = .blocked(error: msg)
            SoulRegistry.appendHook(
                projectKey: projectKey, sessionId: sessionId,
                event: ["event": "WorktreeFallback", "error": msg, "policy": "block"]
            )
            controller.items.append(.error(
                id: UUID(),
                text: "Could not create an isolated worktree: \(msg). This session is blocked "
                    + "from running in the shared checkout to avoid colliding with other sessions. "
                    + "Resolve the git error and start a new chat, or enable fallback in settings."
            ))
        }
    }

    /// Stable, hierarchical branch name: `soul/session/<projectKey>/<shortSid>-<slug>`.
    static func branchName(projectKey: String, sessionId: String, title: String) -> String {
        let shortSid = String(sessionId.prefix(8))
        return "soul/session/\(projectKey)/\(shortSid)-\(slugify(title))"
    }

    static func slugify(_ raw: String) -> String {
        let clean = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return clean.isEmpty ? "session" : String(clean.prefix(40))
    }
}
