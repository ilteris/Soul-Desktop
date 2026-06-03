import Foundation
import Observation

struct WorkspaceSnapshot: Equatable {
    var phase: Phase = .booting
    var projects: [SoulProject] = []
    var selectedProjectId: String? = nil
    var sessionsByProject: [String: ProjectSessions] = [:]
    var counts: [String: Int] = [:]
    var staleProjects: Set<String> = []
    var lastRefresh: [String: Date] = [:]

    var selectedProject: SoulProject? {
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }
    }

    enum Phase: Equatable {
        case booting
        case ready
        case empty
        case failed(String)
    }
}

struct ProjectSessions: Equatable {
    var rows: [SoulSession]
    var freshness: WorkspaceFreshness
    var loadedAt: Date?
}

enum WorkspaceFreshness: Equatable {
    case staleCache
    case freshCache
    case scanned
}

enum WorkspaceRefreshPriority {
    case foreground
    case background
}

struct SidebarFilters: Equatable {
    var chatSourceFilter: String?
    var hideUntitled: Bool
    var showUnreadable: Bool
    var showArchived: Bool
}

struct SidebarLiveOverlay {
    var activeControllers: [ThreadController]
    var liveRecords: [LiveSessionRecord] = []
    var draftSession: SoulSession?
    var activeSessionId: String?
    var activeProjectId: String?
}

protocol WorkspaceProjectService: Sendable {
    func cachedProjects() -> [SoulProject]
    func refreshProjects() async -> [SoulProject]
}

protocol WorkspaceSessionService: Sendable {
    func cachedSessions(projectId: String, allowStale: Bool) async -> [SoulSession]?
    func scanSessions(project: SoulProject) async -> [SoulSession]
    func sessionCount(projectId: String) async -> Int
    func warmCache(projectId: String, sessions: [SoulSession]) async
}

struct LiveWorkspaceProjectService: WorkspaceProjectService {
    func cachedProjects() -> [SoulProject] {
        LiveSoulRegistryStore.shared.cachedActive
    }

    func refreshProjects() async -> [SoulProject] {
        // SoulRegistry.projects() spawns the `soul` CLI synchronously and blocks
        // up to 30s (SafeProcessRunner.runSync). Run it OFF the main thread so a
        // slow/hung CLI can't freeze the UI — the previous `MainActor.run` here
        // ran the blocking spawn on the main actor, which is what surfaced as the
        // main-thread hang + watchdog SIGTERM.
        let all = await Task.detached(priority: .userInitiated) {
            SoulRegistry.projects()
        }.value
        // Publish the @Observable cache on the main actor (SwiftUI observes it).
        await MainActor.run {
            LiveSoulRegistryStore.shared.publish(all)
        }
        return LiveSoulRegistryStore.shared.cachedActive
    }
}

struct LiveWorkspaceSessionService: WorkspaceSessionService {
    func cachedSessions(projectId: String, allowStale: Bool) async -> [SoulSession]? {
        if allowStale {
            return SoulRegistry.cachedSessionsStaleOK(forProject: projectId)
        }
        return SoulRegistry.cachedSessions(forProject: projectId)
    }

    func scanSessions(project: SoulProject) async -> [SoulSession] {
        await Task.detached(priority: .userInitiated) {
            SoulRegistry.allSessions(forProject: project.id, projectPath: project.path)
        }.value
    }

    func sessionCount(projectId: String) async -> Int {
        await Task.detached(priority: .utility) {
            SoulRegistry.sessionCount(forProject: projectId)
        }.value
    }

    func warmCache(projectId: String, sessions: [SoulSession]) async {
        SoulRegistry.warmCache(forProject: projectId, sessions: sessions)
    }
}

@MainActor
@Observable
final class SoulWorkspaceModel {
    private static let selectedProjectDefaultsKey = "soul.selectedProjectId"

    private(set) var snapshot: WorkspaceSnapshot

    private let projectService: WorkspaceProjectService
    private let sessionService: WorkspaceSessionService
    private let persistSelection: Bool

    private var registryWatcher: RegistryWatcher?
    private var generation = 0

    init(
        projectService: WorkspaceProjectService = LiveWorkspaceProjectService(),
        sessionService: WorkspaceSessionService = LiveWorkspaceSessionService(),
        persistedSelectedProjectId: String? = UserDefaults.standard.string(forKey: "soul.selectedProjectId"),
        persistSelection: Bool = true
    ) {
        self.projectService = projectService
        self.sessionService = sessionService
        self.persistSelection = persistSelection

        let projects = projectService.cachedProjects()
        let selected = Self.resolveSelection(
            persistedSelectedProjectId,
            projects: projects
        )
        self.snapshot = WorkspaceSnapshot(
            phase: projects.isEmpty ? .empty : .ready,
            projects: projects,
            selectedProjectId: selected
        )
    }

    var selectedProjectId: String? { snapshot.selectedProjectId }
    var selectedProject: SoulProject? { snapshot.selectedProject }

    func project(id: String?) -> SoulProject? {
        guard let id else { return nil }
        return snapshot.projects.first { $0.id == id }
    }

    func start() async {
        await refreshProjects()
        await primeCachedSessions()
        if let sel = snapshot.selectedProjectId {
            await refreshSessions(projectId: sel, priority: .foreground)
        }
    }

    func selectProject(_ id: String?) {
        let resolved = Self.resolveSelection(id, projects: snapshot.projects)
        snapshot.selectedProjectId = resolved
        persistSelectedProjectId(resolved)
        updateWatcher()
        if let resolved {
            Task {
                await refreshSessions(projectId: resolved, priority: .background)
            }
        }
    }

    func refreshProjects() async {
        generation &+= 1
        let currentGeneration = generation
        let projects = await projectService.refreshProjects()
        guard currentGeneration == generation else { return }
        let selected = Self.resolveSelection(snapshot.selectedProjectId, projects: projects)
        var next = snapshot
        next.projects = projects
        next.selectedProjectId = selected
        next.phase = projects.isEmpty ? .empty : .ready
        snapshot = next
        persistSelectedProjectId(selected)
        updateWatcher()
    }

    func handleProjectMutationCompleted() async {
        await refreshProjects()
    }

    func invalidateSessions(projectId: String) {
        snapshot.staleProjects.insert(projectId)
    }

    func refreshSessions(projectId: String, priority: WorkspaceRefreshPriority = .foreground) async {
        guard let project = project(id: projectId) else { return }
        let currentGeneration = generation
        let rows = await sessionService.scanSessions(project: project)
        guard currentGeneration == generation else { return }
        guard !rows.isEmpty else { return }
        await sessionService.warmCache(projectId: projectId, sessions: rows)
        mergeSessions(projectId: projectId, rows: rows, freshness: .scanned)
    }

    private func updateWatcher() {
        if let key = snapshot.selectedProjectId {
            registryWatcher = RegistryWatcher.watchSessions(forProject: key) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshSessions(projectId: key, priority: .background)
                }
            }
        } else {
            registryWatcher = nil
        }
    }

    func projectedRows(
        for projectId: String,
        filters: SidebarFilters,
        overlay: SidebarLiveOverlay,
        archivedIds: Set<String> = [],
        starredIds: Set<String> = []
    ) -> SidebarRowResolver.Output? {
        let disk = snapshot.sessionsByProject[projectId]?.rows ?? []
        guard !disk.isEmpty || !overlay.activeControllers.isEmpty || !overlay.liveRecords.isEmpty || overlay.draftSession != nil else {
            return nil
        }
        return SidebarRowResolver.resolve(
            SidebarRowResolver.Inputs(
                projectKey: projectId,
                diskSessions: disk,
                activeControllers: overlay.activeControllers,
                liveRecords: overlay.liveRecords,
                draft: overlay.draftSession,
                archivedIds: archivedIds,
                starredIds: starredIds,
                visibilityContext: SidebarRowResolver.VisibilityContext(
                    archivedIds: archivedIds,
                    showUnreadable: filters.showUnreadable,
                    chatSourceFilter: filters.chatSourceFilter,
                    hideUntitled: filters.hideUntitled
                ),
                // SOUL-SOUL_DESKTOP-363: forward the open-session identity the
                // overlay already carries so the resolver can mark it
                // pinned-visible. Previously dropped here on the floor.
                activeSessionId: overlay.activeSessionId,
                activeProjectId: overlay.activeProjectId
            )
        )
    }

    private func primeCachedSessions() async {
        for project in snapshot.projects {
            if let cached = await sessionService.cachedSessions(projectId: project.id, allowStale: false),
               !cached.isEmpty {
                mergeSessions(projectId: project.id, rows: cached, freshness: .freshCache)
            } else if let stale = await sessionService.cachedSessions(projectId: project.id, allowStale: true),
                      !stale.isEmpty {
                mergeSessions(projectId: project.id, rows: stale, freshness: .staleCache)
            }
        }
    }

    private func mergeSessions(projectId: String, rows: [SoulSession], freshness: WorkspaceFreshness) {
        let prior = snapshot.sessionsByProject[projectId]?.rows ?? []
        let priorById = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        let merged = rows.map { fresh in
            guard let old = priorById[fresh.id] else { return fresh }
            var out = fresh
            if fresh.promptCount == 0 && old.promptCount > 0 {
                out.promptCount = old.promptCount
            }
            if fresh.transcriptTurns == 0 && old.transcriptTurns > 0 {
                out.transcriptTurns = old.transcriptTurns
            }
            if fresh.visibleTurnCount == 0 && old.visibleTurnCount > 0 {
                out.visibleTurnCount = old.visibleTurnCount
            }
            return out
        }
        var next = snapshot
        next.sessionsByProject[projectId] = ProjectSessions(
            rows: merged,
            freshness: freshness,
            loadedAt: Date()
        )
        next.staleProjects.remove(projectId)
        next.lastRefresh[projectId] = Date()
        snapshot = next
    }

    private func persistSelectedProjectId(_ id: String?) {
        guard persistSelection else { return }
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedProjectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedProjectDefaultsKey)
        }
    }

    private static func resolveSelection(_ requested: String?, projects: [SoulProject]) -> String? {
        if let requested, projects.contains(where: { $0.id == requested }) {
            return requested
        }
        return projects.first?.id
    }
}
