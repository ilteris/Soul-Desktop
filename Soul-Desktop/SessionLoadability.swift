import Foundation
import SoulLedger

/// Where on disk a session's transcript actually lives, plus the cwd to
/// spawn the agent in for a successful resume. Returned by the global
/// UUID-keyed lookup so callers can override their assumed project path
/// when a session's transcript lives outside the project bucket the row
/// happened to be filed under.
struct LoadableLocation {
    /// "claude" | "geminiCLI" | "pi" | "codex"
    let provider: String
    /// Absolute cwd to spawn the agent in.
    let cwd: String
    /// For diagnostics / logging.
    let transcriptPath: String
}

/// App bridge over SoulLedger's UI-free loadability readers.
enum SessionLoadability {
    /// True iff *some* provider has a readable transcript for this UUID
    /// reachable from the passed project. Conservative on Pi/Codex: only
    /// returns true when the on-disk file actually exists.
    static func canLoadFromDisk(sessionId sid: String, project: SoulProject) -> Bool {
        let nativeSessionIDs = [
            "claude": SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid, provider: "claude"),
            "geminiCLI": SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid, provider: "geminiCLI"),
        ].compactMapValues { $0 }

        return LedgerSessionLoadability.canLoadFromDisk(
            sessionId: sid,
            project: project.ledgerProject,
            nativeSessionIDs: nativeSessionIDs,
            sessionDir: { projectKey, sessionId in
                SoulRegistry.sessionDir(projectKey: projectKey, sessionId: sessionId)
            }
        )
    }

    /// Walk every known provider dir for a `<sid>` file. Returns the first
    /// match with a usable cwd. Run only on session click — not in the
    /// sidebar hot loop — so the O(dir) cost is acceptable.
    static func discover(sessionId sid: String) -> LoadableLocation? {
        LedgerSessionLoadability.discover(
            sessionId: sid,
            activeProjects: LiveSoulRegistryStore.shared.activeProjects().map(\.ledgerProject),
            sessionRoots: SoulRegistry.sessionRoots()
        ).map { location in
            LoadableLocation(
                provider: location.provider,
                cwd: location.cwd,
                transcriptPath: location.transcriptPath
            )
        }
    }
}

private extension SoulProject {
    var ledgerProject: LedgerProject {
        LedgerProject(
            id: id,
            name: name,
            path: path,
            pillar: pillar,
            tier: tier,
            status: status,
            primaryHost: primaryHost
        )
    }
}
