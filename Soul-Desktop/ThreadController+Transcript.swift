import Foundation
import SoulLedger

extension ThreadController {
    /// Lazily create the transcript watcher for Claude sessions. Other
    /// providers don't rotate their transcript filename mid-conversation,
    /// so they don't need this. Called from session-creation paths
    /// (spawnAndInitialize + handleResume) right after `nativeSessionId`
    /// is assigned.
    ///
    /// On rotation, the watcher writes a `ProviderTranscriptID` event
    /// to the kernel ledger so downstream readers (ContextUsage chip,
    /// ClaudeTranscriptReader, SessionLoadability) pick up the new
    /// filename via `SoulRegistry.findProviderTranscriptID`.
    func ensureTranscriptWatcher() {
        guard provider == .claude else { return }
        guard transcriptWatcher == nil else { return }
        guard let kernelSid = sessionId else { return }

        let cwd = activeProjectPath.hasSuffix("/")
            ? String(activeProjectPath.dropLast()) : activeProjectPath
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\(encoded)")

        // Seed `currentId` with the most reliable existing pointer so we
        // don't fire on the first mtime touch of a file we already knew
        // about. Priority: persisted ProviderTranscriptID > NativeSessionID
        // > nativeSessionId in memory > kernel sid.
        let seedId = SoulRegistry.findProviderTranscriptID(projectKey: project.id, sessionId: kernelSid, provider: "claude")
            ?? SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: kernelSid, provider: "claude")
            ?? nativeSessionId
            ?? kernelSid
        providerTranscriptId = seedId

        guard let watcher = ProviderTranscriptWatcher(encodedDir: dir, initialId: seedId) else {
            NSLog("[transcript-watcher] could not start watcher for \(dir)")
            return
        }
        let projectKey = project.id
        watcher.onRotation = { [weak self] newId in
            // We're already back on MainActor inside the watcher's hop.
            self?.persistTranscriptRotation(newId: newId, projectKey: projectKey, kernelSid: kernelSid)
        }
        transcriptWatcher = watcher
    }

    /// Called from the prompt-send paths right before / after invoking
    /// `client.prompt(sessionId:text:)`. Opens the 5-second window inside
    /// which a `.jsonl` modification is interpreted as our turn landing.
    func armTranscriptWatcher() {
        transcriptWatcher?.arm()
    }

    /// Update `providerTranscriptId`, append the audit event to the
    /// kernel ledger, and tell the watcher about the new baseline so it
    /// doesn't re-fire on the same id.
    private func persistTranscriptRotation(newId: String, projectKey: String, kernelSid: String) {
        let oldId = providerTranscriptId
        guard newId != oldId else { return }
        providerTranscriptId = newId
        transcriptWatcher?.setCurrentId(newId)
        SoulRegistry.appendHook(
            projectKey: projectKey,
            sessionId: kernelSid,
            event: LedgerHookEvent.providerTranscriptID(
                transcriptID: newId,
                previousTranscriptID: oldId ?? "",
                provider: "claude",
                timestamp: ISO8601DateFormatter().string(from: Date())
            ).hookDictionary
        )
        logLifecycle("transcript.rotation", note: "old=\(oldId ?? "nil") new=\(newId)")
    }
}
