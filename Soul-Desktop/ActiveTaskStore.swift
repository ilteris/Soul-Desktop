import Foundation
import SwiftUI
import Combine

/// SOUL-SOUL_DESKTOP-055: surface the active Soul-OS task's Definition of
/// Done as a checklist in the canvas overlay.
///
/// Data flows entirely through the unified `soul task status -p <project> --json`
/// CLI (kernel-side: SOUL-SOUL_DESKTOP-260). No direct `.soul_task` / `<id>.json`
/// reads remain — the kernel is the source of truth, and any schema change
/// inside the registry JSON propagates to the desktop automatically.
///
/// Polls every 4s while bound to a project so the overlay stays current as
/// the assistant flips bullets done by appending to `completed_criteria`.
/// No file watcher — the cost of a 4s CLI invocation is negligible and
/// matches the cadence already used by CanvasInfoModel.
@MainActor
final class ActiveTaskStore: ObservableObject {
    struct Criterion: Hashable {
        var text: String
        var done: Bool
    }

    @Published private(set) var taskId: String? = nil
    @Published private(set) var subject: String? = nil
    @Published private(set) var status: String? = nil
    @Published private(set) var criteria: [Criterion] = []

    private var boundProject: String? = nil
    private var timer: Timer? = nil

    func bind(projectKey: String?) {
        guard projectKey != boundProject else { return }
        boundProject = projectKey
        taskId = nil
        subject = nil
        status = nil
        criteria = []
        timer?.invalidate()
        timer = nil
        guard let key = projectKey, !key.isEmpty else { return }
        Task { await refresh() }
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private struct Payload: Decodable {
        var task_id: String?
        var subject: String?
        var status: String?
        var done_criteria: [String]?
        var completed_criteria: [String]?
        var error: String?
    }

    private func refresh() async {
        guard let key = boundProject else { return }
        let snap = await Self.load(projectKey: key)
        if taskId != snap.taskId { taskId = snap.taskId }
        if subject != snap.subject { subject = snap.subject }
        if status != snap.status { status = snap.status }
        if criteria != snap.criteria { criteria = snap.criteria }
    }

    private struct Snap {
        var taskId: String? = nil
        var subject: String? = nil
        var status: String? = nil
        var criteria: [Criterion] = []
    }

    private static func load(projectKey: String) async -> Snap {
        let payload: Payload
        do {
            payload = try await SoulCLI.runJSON(
                ["task", "status", "-p", projectKey, "--json"],
                as: Payload.self
            )
        } catch {
            // CLI unavailable or decode failure — render empty rather than
            // stale. Caller's poll picks back up automatically.
            return Snap()
        }
        if payload.error != nil {
            return Snap(taskId: payload.task_id)
        }
        let dod = payload.done_criteria ?? []
        let done = Set(payload.completed_criteria ?? [])
        let normalizedStatus = payload.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let criteria = dod.map { Criterion(text: $0, done: done.contains($0)) }
        return Snap(
            taskId: payload.task_id,
            subject: payload.subject,
            status: normalizedStatus,
            criteria: criteria
        )
    }
}
