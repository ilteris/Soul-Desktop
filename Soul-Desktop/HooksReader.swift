import Foundation
import SoulCore
import SoulLedger

/// App-side adapter over the packageable `LedgerReplayMerge` (SoulLedger).
/// Resolves the kernel registry's on-disk paths and the finalize fallback —
/// the two things that depend on registry layout / env — and delegates the
/// heavy hooks+transcript timeline merge to the module (SOUL-360).
enum HooksReader {
    static func events(forSession sid: String, project: SoulProject) -> [ReplayEvent] {
        let hooksPath = SoulRegistry.hooksPath(projectKey: project.id, sessionId: sid)
        let sessionDir = SoulRegistry.sessionDir(projectKey: project.id, sessionId: sid)

        var merged = LedgerReplayMerge.merge(
            sessionId: sid,
            projectKey: project.id,
            projectPath: project.path,
            hooksPath: hooksPath,
            sessionDir: sessionDir
        )

        // Empty-merge fallback: a session whose only artifact is a finalize
        // record still renders something useful in Replay. Owns the registry's
        // finalize lookup so the module stays registry-free.
        if merged.isEmpty,
           let finalize = SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid) {
            let ts = finalize.timestamp ?? Date()
            merged.append(ReplayEvent(
                id: UUID(),
                timestamp: ts,
                item: .finalize(
                    id: UUID(),
                    intent: finalize.intent,
                    summary: finalize.summary,
                    rationale: finalize.rationale,
                    fixed: finalize.fixed,
                    nextStep: finalize.nextStep,
                    timestamp: ts
                )
            ))
        }
        return merged
    }
}
