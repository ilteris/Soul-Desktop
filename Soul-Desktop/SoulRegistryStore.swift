import Foundation

protocol SoulRegistryStore: Sendable {
    func projects() -> [SoulProject]
    func activeProjects() -> [SoulProject]
    func sessionCount(forProject projectKey: String) -> Int
    func cachedSessions(forProject projectKey: String) -> [SoulSession]?
    /// "Show me anything, even if stale." Used to paint the moment a
    /// project is clicked so the user never sees a blank sidebar on a
    /// busy project whose dir mtime ticks invalidate the strict cache.
    func cachedSessionsStaleOK(forProject projectKey: String) -> [SoulSession]?
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

/// SOUL-SOUL_DESKTOP-161: @Observable cache of the project list.
///
/// Before this change, every call to `projects()` / `activeProjects()` did a
/// disk-stat sweep (one mtime per project dir, ordered by recency). Views
/// that called these from inside their bodies — most notoriously
/// `ComposerView`'s `ProjectChip(projects:)` — triggered the sweep on every
/// re-render. During a session hydrate, `items.count` growth re-rendered
/// the composer per appended item, and CPU pegged at 200%+ on a profile.
///
/// Fix: the store holds two `@Observable` arrays (`cachedProjects`,
/// `cachedActive`) which views read in O(1). `refresh()` is the only path
/// that touches disk. AppShell invokes it on app launch and on project-
/// mutation events (new project wizard, archive/restore). Views reading
/// `cachedActive` only re-evaluate when the published array reference
/// changes — i.e., when refresh() actually mutated state, not on every
/// unrelated re-render.
///
/// The `projects()` / `activeProjects()` protocol methods remain for
/// existing callers (controller logic, SessionLoadability) and now serve
/// from the cache; a `refreshNow()` method exists for the rare caller that
/// needs guaranteed-fresh data after a known mutation it didn't issue.
@Observable
final class LiveSoulRegistryStore: SoulRegistryStore, @unchecked Sendable {
    // NOT @MainActor: SessionLoadability and controller code call
    // projects()/activeProjects() from various contexts (sometimes off
    // main during session probing). Reads of cached arrays are safe from
    // any thread (immutable Array slice into stored state). Writes only
    // happen via refresh(), which AppShell drives from the main actor.
    static let shared = LiveSoulRegistryStore()

    /// Cached output of `SoulRegistry.projects()`. Mutates only via refresh().
    var cachedProjects: [SoulProject] = []
    /// Cached output of `SoulRegistry.activeProjects()`. Mutates only via refresh().
    var cachedActive: [SoulProject] = []

    private init() {
        // Warm the cache so the very first body read doesn't see an empty list.
        let all = SoulRegistry.projects()
        self.cachedProjects = all
        self.cachedActive = all.filter { ($0.status ?? "active") == "active" }
    }

    /// Hit disk, recompute both project lists, publish to observers.
    /// Call this on app launch, project-mutation events, or when the user
    /// explicitly asks for a refresh.
    ///
    /// WARNING: `SoulRegistry.projects()` spawns the `soul` CLI synchronously
    /// (SafeProcessRunner blocks up to 30s on `termination.wait`). Calling this
    /// directly on the main actor freezes the UI and surfaces as the watchdog
    /// SIGTERM that kills the hung child. Off-main callers should compute via
    /// `SoulRegistry.projects()` in a detached task and then call `publish(_:)`
    /// on the main actor instead.
    func refresh() {
        publish(SoulRegistry.projects())
    }

    /// Publish a precomputed project list (computed off-main) to the
    /// `@Observable` cache. Call on the main actor — SwiftUI observes these
    /// arrays. Single source of truth for the active-status filter.
    func publish(_ all: [SoulProject]) {
        self.cachedProjects = all
        self.cachedActive = all.filter { ($0.status ?? "active") == "active" }
    }

    func projects() -> [SoulProject] {
        cachedProjects
    }

    func activeProjects() -> [SoulProject] {
        cachedActive
    }

    func sessionCount(forProject projectKey: String) -> Int {
        SoulRegistry.sessionCount(forProject: projectKey)
    }

    func cachedSessions(forProject projectKey: String) -> [SoulSession]? {
        SoulRegistry.cachedSessions(forProject: projectKey)
    }

    func cachedSessionsStaleOK(forProject projectKey: String) -> [SoulSession]? {
        SoulRegistry.cachedSessionsStaleOK(forProject: projectKey)
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
