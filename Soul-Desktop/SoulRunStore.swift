import Foundation
import Combine
import Darwin

@MainActor
final class SoulRunStore: ObservableObject {
    @Published private(set) var runs: [SoulRunRecord] = []
    @Published private(set) var workStatus: SoulWorkStatusPayload? = nil
    @Published private(set) var reviewSummary: SoulRunReviewPayload.Summary? = nil
    @Published private(set) var subagents: [SoulSubagentRecord] = []
    @Published private(set) var projectBinding: SoulProjectBinding? = nil
    @Published private(set) var workProjection: SoulWorkProjection? = nil
    @Published private(set) var workProjectionError: SoulProjectionError? = nil
    @Published private(set) var isLoading: Bool = false

    private var boundProject: String? = nil
    private var registryMonitor: SoulRegistryMonitor? = nil
    private var pendingRefreshTask: Task<Void, Never>? = nil
    private var appServerTask: Task<Void, Never>? = nil
    private var appServerClient: SoulAppServerClient? = nil
    private var lastOrchestrationVersion: String? = nil
    private var lastWorkProjectionFingerprint: String? = nil
    private var appServerConnectionError: SoulProjectionError? = nil
    private var isRefreshing: Bool = false
    private var needsRefreshAfterCurrent: Bool = false

    var activeRuns: [SoulRunRecord] {
        runs.filter(\.isActive)
    }

    var activeSubagents: [SoulSubagentRecord] {
        subagents.filter(\.isActive)
    }

    var recentRuns: [SoulRunRecord] {
        runs
    }

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        runs = []
        workStatus = nil
        reviewSummary = nil
        subagents = []
        projectBinding = nil
        workProjection = nil
        workProjectionError = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        appServerTask?.cancel()
        appServerTask = nil
        appServerClient = nil
        lastOrchestrationVersion = nil
        lastWorkProjectionFingerprint = nil
        appServerConnectionError = nil
        registryMonitor = nil
        guard let projectKey, !projectKey.isEmpty else { return }
        startAppServerLoop(project: projectKey)
    }

    deinit {
        pendingRefreshTask?.cancel()
        appServerTask?.cancel()
        registryMonitor = nil
    }

    private func scheduleRegistryRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let project = boundProject, !project.isEmpty else { return }
        if isRefreshing {
            needsRefreshAfterCurrent = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        isLoading = true
        let snapshot: Snapshot
        if let appServerClient {
            do {
                snapshot = try await Self.loadFromAppServer(projectKey: project, client: appServerClient)
                appServerConnectionError = nil
                registryMonitor = nil
            } catch {
                appServerConnectionError = SoulProjectionError(
                    code: "app_server_unavailable",
                    message: error.localizedDescription
                )
                if appServerClient.allowsLocalFallback {
                    self.appServerClient = nil
                    snapshot = await Self.loadFromCLI(projectKey: project)
                    activateRegistryMonitor(project: project, snapshot: snapshot)
                } else {
                    self.appServerClient = appServerClient
                    snapshot = Snapshot()
                    registryMonitor = nil
                }
            }
        } else {
            snapshot = await Self.loadFromCLI(projectKey: project)
            activateRegistryMonitor(project: project, snapshot: snapshot)
        }
        guard boundProject == project else {
            isLoading = false
            return
        }
        lastOrchestrationVersion = snapshot.version ?? lastOrchestrationVersion
        lastWorkProjectionFingerprint = snapshot.workProjection?.projectionFingerprint ?? lastWorkProjectionFingerprint
        runs = snapshot.runs
        workStatus = snapshot.workStatus
        reviewSummary = snapshot.reviewSummary
        subagents = snapshot.subagents
        projectBinding = snapshot.projectBinding
        workProjection = snapshot.workProjection
        workProjectionError = snapshot.workProjection == nil ? appServerConnectionError : nil
        isLoading = false
        if needsRefreshAfterCurrent {
            needsRefreshAfterCurrent = false
            Task { await refresh() }
        }
    }

    private struct Snapshot: Sendable {
        var runs: [SoulRunRecord] = []
        var workStatus: SoulWorkStatusPayload? = nil
        var reviewSummary: SoulRunReviewPayload.Summary? = nil
        var subagents: [SoulSubagentRecord] = []
        var projectBinding: SoulProjectBinding? = nil
        var workProjection: SoulWorkProjection? = nil
        var version: String? = nil
    }

    struct WorkProjectionRefreshRequest: Equatable, Sendable {
        var sessionID: String?
        var projectionFingerprint: String?
        var projectionError: SoulProjectionError?
    }

    private func startAppServerLoop(project: String) {
        appServerTask = Task { [weak self] in
            await self?.runAppServerLoop(project: project)
        }
    }

    private func runAppServerLoop(project: String) async {
        let client = SoulAppServerClient()
        do {
            try await client.connectAndInitialize()
            try await client.subscribe(projectKey: project)
            guard boundProject == project, !Task.isCancelled else { return }
            appServerClient = client
            registryMonitor = nil
            await refresh()

            for await notification in client.notifications {
                guard boundProject == project, !Task.isCancelled else { return }
                if notification.method == "orchestration.updated" {
                    guard let params = try? await client.decodeNotificationParams(
                        SoulOrchestrationUpdatedParams.self,
                        from: notification.params
                    ) else { continue }
                    guard params.projectKey == project else { continue }
                    if let version = params.version, version == lastOrchestrationVersion {
                        continue
                    }
                    await refresh()
                    continue
                }
                if notification.method == "work_projection.updated" {
                    guard let params = try? await client.decodeNotificationParams(
                        SoulWorkProjectionUpdatedParams.self,
                        from: notification.params
                    ) else { continue }
                    guard let request = Self.workProjectionRefreshRequest(
                        from: params,
                        project: project,
                        lastFingerprint: lastWorkProjectionFingerprint
                    ) else { continue }
                    do {
                        let projection = try await client.workProjection(
                            projectKey: project,
                            sessionID: request.sessionID
                        )
                        guard boundProject == project, !Task.isCancelled else { return }
                        workProjection = projection
                        workProjectionError = nil
                        lastWorkProjectionFingerprint = projection.projectionFingerprint ?? request.projectionFingerprint
                    } catch {
                        guard boundProject == project, !Task.isCancelled else { return }
                        workProjectionError = request.projectionError ?? SoulProjectionError(
                            code: "work_projection_get_failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }

            guard boundProject == project, !Task.isCancelled else { return }
            appServerConnectionError = SoulProjectionError(
                code: "app_server_unavailable",
                message: "Soul app-server connection closed."
            )
            if client.allowsLocalFallback {
                appServerClient = nil
                await refresh()
            } else {
                appServerClient = client
                runs = []
                workStatus = nil
                reviewSummary = nil
                subagents = []
                projectBinding = nil
                workProjection = nil
                workProjectionError = appServerConnectionError
                isLoading = false
            }
        } catch {
            guard boundProject == project, !Task.isCancelled else { return }
            appServerConnectionError = SoulProjectionError(
                code: "app_server_unavailable",
                message: error.localizedDescription
            )
            if client.allowsLocalFallback {
                appServerClient = nil
                await refresh()
            } else {
                appServerClient = client
                runs = []
                workStatus = nil
                reviewSummary = nil
                subagents = []
                projectBinding = nil
                workProjection = nil
                workProjectionError = appServerConnectionError
                isLoading = false
            }
        }
    }

    nonisolated static func workProjectionRefreshRequest(
        from params: SoulWorkProjectionUpdatedParams,
        project: String,
        lastFingerprint: String?
    ) -> WorkProjectionRefreshRequest? {
        guard params.projectKey == project else { return nil }
        if let fingerprint = params.projectionFingerprint,
           !fingerprint.isEmpty,
           fingerprint == lastFingerprint {
            return nil
        }
        return WorkProjectionRefreshRequest(
            sessionID: params.sessionID,
            projectionFingerprint: params.projectionFingerprint,
            projectionError: params.projectionError
        )
    }

    nonisolated private static func loadFromAppServer(
        projectKey: String,
        client: SoulAppServerClient
    ) async throws -> Snapshot {
        let result = try await client.orchestrationStatus(
            projectKey: projectKey,
            runLimit: 12,
            reviewLimit: 25,
            subagentLimit: 25
        )
        var snapshot = snapshot(from: result)
        snapshot.workProjection = try await client.workProjection(projectKey: projectKey)
        return snapshot
    }

    nonisolated private static func snapshot(from result: SoulOrchestrationStatusResult) -> Snapshot {
        let snapshot = result.snapshot
        let subagents = snapshot.subagentList.subagents.isEmpty
            ? snapshot.subagents
            : snapshot.subagentList.subagents
        return Snapshot(
            runs: snapshot.runReview.runs,
            workStatus: snapshot.workStatus,
            reviewSummary: snapshot.runReview.summary,
            subagents: subagents,
            projectBinding: snapshot.projectBinding,
            workProjection: nil,
            version: snapshot.version
        )
    }

    nonisolated private static func loadFromCLI(projectKey: String) async -> Snapshot {
        async let history: SoulRunHistoryPayload? = loadJSON(
            ["run", "history", "-p", projectKey, "--limit", "12", "--json"],
            as: SoulRunHistoryPayload.self
        )
        async let workStatus: SoulWorkStatusPayload? = loadJSON(
            ["work", "status", "-p", projectKey, "--json"],
            as: SoulWorkStatusPayload.self
        )
        async let review: SoulRunReviewPayload? = loadJSON(
            ["run", "review", "-p", projectKey, "--limit", "25", "--json"],
            as: SoulRunReviewPayload.self
        )
        async let subagents: SoulSubagentListPayload? = loadJSON(
            ["subagent", "list", "-p", projectKey, "--json"],
            as: SoulSubagentListPayload.self
        )
        let historyPayload = await history
        let workStatusPayload = await workStatus
        let reviewPayload = await review
        let subagentPayload = await subagents

        return Snapshot(
            runs: historyPayload?.runs ?? [],
            workStatus: workStatusPayload,
            reviewSummary: reviewPayload?.summary,
            subagents: subagentPayload?.subagents ?? []
        )
    }

    nonisolated private static func loadJSON<T: Decodable & Sendable>(_ args: [String], as type: T.Type) async -> T? {
        try? await SoulCLI.runJSON(args, as: type)
    }

    private func activateRegistryMonitor(project: String, snapshot: Snapshot) {
        if registryMonitor == nil {
            registryMonitor = SoulRegistryMonitor { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRegistryRefresh()
                }
            }
        }
        configureRegistryMonitor(project: project, snapshot: snapshot)
    }

    private func configureRegistryMonitor(project: String, snapshot: Snapshot) {
        let root = Self.registryRootURL()
        var urls: [URL] = [
            root.appendingPathComponent("tasks"),
            root.appendingPathComponent("tasks").appendingPathComponent(project),
            root.appendingPathComponent("runs"),
            root.appendingPathComponent("runs").appendingPathComponent(project),
            root.appendingPathComponent("sessions").appendingPathComponent(project),
            root.appendingPathComponent("sessions").appendingPathComponent(project).appendingPathComponent("subagents")
        ]

        if let taskFile = snapshot.workStatus?.task?.file {
            urls.append(Self.fileURL(from: taskFile))
        }

        for run in snapshot.runs {
            let fileURL = run.fileURL
            urls.append(fileURL)
            urls.append(fileURL.deletingLastPathComponent())
        }

        for subagent in snapshot.subagents {
            if let file = subagent.file {
                let fileURL = Self.fileURL(from: file)
                urls.append(fileURL)
                urls.append(fileURL.deletingLastPathComponent())
            }
            if let liveLog = subagent.liveLog {
                urls.append(Self.fileURL(from: liveLog))
            }
            if let findingPath = subagent.findingPath {
                urls.append(Self.fileURL(from: findingPath))
            }
        }

        registryMonitor?.update(paths: urls)
    }

    private static func registryRootURL() -> URL {
        let raw = ProcessInfo.processInfo.environment["SOUL_REGISTRY"] ?? "\(NSHomeDirectory())/soul_registry"
        return fileURL(from: raw)
    }

    private static func fileURL(from raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }
}

final class SoulRegistryMonitor {
    private final class Watch {
        private let source: DispatchSourceFileSystemObject
        private var isCancelled = false

        init(path: String, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) throws {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .delete, .rename],
                queue: queue
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            source.cancel()
        }

        deinit {
            cancel()
        }
    }

    private let queue = DispatchQueue(label: "soul.desktop.run-registry-monitor")
    private let onChange: @Sendable () -> Void
    private var watches: [String: Watch] = [:]

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func update(paths: [URL]) {
        let existingPaths = Set(paths.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        })

        for path in Array(watches.keys) where !existingPaths.contains(path) {
            watches.removeValue(forKey: path)?.cancel()
        }

        for path in existingPaths where watches[path] == nil {
            if let watch = try? Watch(path: path, queue: queue, onChange: onChange) {
                watches[path] = watch
            }
        }
    }

    deinit {
        for watch in watches.values {
            watch.cancel()
        }
    }
}
