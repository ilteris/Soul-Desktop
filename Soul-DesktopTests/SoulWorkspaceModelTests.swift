import Testing
@testable import Soul_Desktop

@MainActor
struct SoulWorkspaceModelTests {
    @Test func initialSnapshotRestoresValidPersistedProject() async throws {
        let model = SoulWorkspaceModel(
            projectService: FakeProjectService(cached: [
                Self.project("alpha"),
                Self.project("beta"),
            ]),
            sessionService: FakeSessionService(),
            persistedSelectedProjectId: "beta",
            persistSelection: false
        )

        #expect(model.snapshot.phase == .ready)
        #expect(model.selectedProjectId == "beta")
        #expect(model.selectedProject?.name == "Beta")
    }

    @Test func initialSnapshotFallsBackWhenPersistedProjectIsInvalid() async throws {
        let model = SoulWorkspaceModel(
            projectService: FakeProjectService(cached: [
                Self.project("alpha"),
                Self.project("beta"),
            ]),
            sessionService: FakeSessionService(),
            persistedSelectedProjectId: "missing",
            persistSelection: false
        )

        #expect(model.snapshot.phase == .ready)
        #expect(model.selectedProjectId == "alpha")
    }

    @Test func initialSnapshotIsEmptyWhenNoProjectsExist() async throws {
        let model = SoulWorkspaceModel(
            projectService: FakeProjectService(cached: []),
            sessionService: FakeSessionService(),
            persistedSelectedProjectId: nil,
            persistSelection: false
        )

        #expect(model.snapshot.phase == .empty)
        #expect(model.selectedProjectId == nil)
        #expect(model.selectedProject == nil)
    }

    @Test func refreshProjectsPreservesSelectionWhenStillPresent() async throws {
        let service = FakeProjectService(
            cached: [
                Self.project("alpha"),
                Self.project("beta"),
            ],
            refreshed: [
                Self.project("beta"),
                Self.project("gamma"),
            ]
        )
        let model = SoulWorkspaceModel(
            projectService: service,
            sessionService: FakeSessionService(),
            persistedSelectedProjectId: "beta",
            persistSelection: false
        )

        await model.refreshProjects()

        #expect(model.snapshot.phase == .ready)
        #expect(model.selectedProjectId == "beta")
        #expect(model.snapshot.projects.map(\.id) == ["beta", "gamma"])
    }

    private static func project(_ id: String) -> SoulProject {
        SoulProject(
            id: id,
            name: id.prefix(1).uppercased() + id.dropFirst(),
            path: "/tmp/\(id)",
            pillar: nil,
            tier: nil,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
    }
}

private struct FakeProjectService: WorkspaceProjectService {
    var cached: [SoulProject]
    var refreshed: [SoulProject]

    init(cached: [SoulProject], refreshed: [SoulProject]? = nil) {
        self.cached = cached
        self.refreshed = refreshed ?? cached
    }

    func cachedProjects() -> [SoulProject] {
        cached
    }

    func refreshProjects() async -> [SoulProject] {
        refreshed
    }
}

private struct FakeSessionService: WorkspaceSessionService {
    func cachedSessions(projectId: String, allowStale: Bool) async -> [SoulSession]? {
        nil
    }

    func scanSessions(project: SoulProject) async -> [SoulSession] {
        []
    }

    func sessionCount(projectId: String) async -> Int {
        0
    }

    func warmCache(projectId: String, sessions: [SoulSession]) async {}
}
