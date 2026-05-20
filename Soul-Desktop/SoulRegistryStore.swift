import Foundation

protocol SoulRegistryStore: Sendable {
    func projects() -> [SoulProject]
    func activeProjects() -> [SoulProject]
    func sessionCount(forProject projectKey: String) -> Int
    func cachedSessions(forProject projectKey: String) -> [SoulSession]?
    func allSessions(forProject projectKey: String, limit: Int?, projectPath: String?) -> [SoulSession]
    func warmCache(forProject projectKey: String, sessions: [SoulSession])
    func invalidateCache(forProject projectKey: String)
    func firstHookTimestamp(projectKey: String, sessionId: String) -> Date?
    func findProvider(projectKey: String, sessionId: String) -> String?
    func appendHook(projectKey: String, sessionId: String, event: [String: Any])
    func backfillNativeSessionID(projectKey: String, sessionId: String, provider: String, cwd: String) -> SoulRegistry.BackfillResult
    func writeNativeSessionID(projectKey: String, sessionId: String, nativeId: String, provider: String, cwd: String)
}

extension SoulRegistryStore {
    func allSessions(forProject projectKey: String, projectPath: String? = nil) -> [SoulSession] {
        allSessions(forProject: projectKey, limit: nil, projectPath: projectPath)
    }

    func allSessions(forProject projectKey: String, limit: Int, projectPath: String? = nil) -> [SoulSession] {
        allSessions(forProject: projectKey, limit: Optional(limit), projectPath: projectPath)
    }
}

final class LiveSoulRegistryStore: SoulRegistryStore {
    static let shared = LiveSoulRegistryStore()

    private init() {}

    func projects() -> [SoulProject] {
        SoulRegistry.projects()
    }

    func activeProjects() -> [SoulProject] {
        SoulRegistry.activeProjects()
    }

    func sessionCount(forProject projectKey: String) -> Int {
        SoulRegistry.sessionCount(forProject: projectKey)
    }

    func cachedSessions(forProject projectKey: String) -> [SoulSession]? {
        SoulRegistry.cachedSessions(forProject: projectKey)
    }

    func allSessions(forProject projectKey: String, limit: Int?, projectPath: String?) -> [SoulSession] {
        if let limit {
            return SoulRegistry.allSessions(forProject: projectKey, limit: limit, projectPath: projectPath)
        }
        return SoulRegistry.allSessions(forProject: projectKey, projectPath: projectPath)
    }

    func warmCache(forProject projectKey: String, sessions: [SoulSession]) {
        SoulRegistry.warmCache(forProject: projectKey, sessions: sessions)
    }

    func invalidateCache(forProject projectKey: String) {
        SoulRegistry.invalidateCache(forProject: projectKey)
    }

    func firstHookTimestamp(projectKey: String, sessionId: String) -> Date? {
        SoulRegistry.firstHookTimestamp(projectKey: projectKey, sessionId: sessionId)
    }

    func findProvider(projectKey: String, sessionId: String) -> String? {
        SoulRegistry.findProvider(projectKey: projectKey, sessionId: sessionId)
    }

    func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
        SoulRegistry.appendHook(projectKey: projectKey, sessionId: sessionId, event: event)
    }

    func backfillNativeSessionID(projectKey: String, sessionId: String, provider: String, cwd: String) -> SoulRegistry.BackfillResult {
        SoulRegistry.backfillNativeSessionID(projectKey: projectKey, sessionId: sessionId, provider: provider, cwd: cwd)
    }

    func writeNativeSessionID(projectKey: String, sessionId: String, nativeId: String, provider: String, cwd: String) {
        SoulRegistry.writeNativeSessionID(projectKey: projectKey, sessionId: sessionId, nativeId: nativeId, provider: provider, cwd: cwd)
    }
}
