import Foundation
import Combine

@MainActor
final class SoulRunStore: ObservableObject {
    @Published private(set) var runs: [SoulRunRecord] = []
    @Published private(set) var reviewSummary: SoulRunReviewPayload.Summary? = nil
    @Published private(set) var isLoading: Bool = false

    private var boundProject: String? = nil
    private var timer: Timer? = nil

    var activeRuns: [SoulRunRecord] {
        runs.filter(\.isActive)
    }

    var recentRuns: [SoulRunRecord] {
        runs
    }

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        runs = []
        reviewSummary = nil
        timer?.invalidate()
        timer = nil
        guard let projectKey, !projectKey.isEmpty else { return }
        Task { await refresh() }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() async {
        guard let project = boundProject, !project.isEmpty else { return }
        isLoading = true
        let snapshot = await Self.load(projectKey: project)
        guard boundProject == project else { return }
        runs = snapshot.runs
        reviewSummary = snapshot.reviewSummary
        isLoading = false
    }

    private struct Snapshot: Sendable {
        var runs: [SoulRunRecord] = []
        var reviewSummary: SoulRunReviewPayload.Summary? = nil
    }

    nonisolated private static func load(projectKey: String) async -> Snapshot {
        do {
            async let history: SoulRunHistoryPayload = SoulCLI.runJSON(
                ["run", "history", "-p", projectKey, "--limit", "12", "--json"],
                as: SoulRunHistoryPayload.self
            )
            async let review: SoulRunReviewPayload = SoulCLI.runJSON(
                ["run", "review", "-p", projectKey, "--limit", "25", "--json"],
                as: SoulRunReviewPayload.self
            )
            return Snapshot(runs: try await history.runs, reviewSummary: try await review.summary)
        } catch {
            return Snapshot()
        }
    }
}
