import Foundation
import SwiftUI
import Combine

/// SOUL-SOUL_DESKTOP-055: surface the active Soul-OS task's Definition of
/// Done as a checklist in the canvas overlay.
///
/// Reads two files per project:
///   - ~/soul_registry/tasks/<project>/.soul_task — plain-text active task id
///   - ~/soul_registry/tasks/<project>/<id>.json — task record with
///     `done_criteria` (list of bullet strings) and optional
///     `completed_criteria` (list of bullet texts marked done).
///
/// Polls every 4s while bound to a project so the overlay stays current as
/// the assistant flips bullets done by appending to `completed_criteria` in
/// the JSON. No file watcher — the cost of a stat+two-read per 4s is
/// negligible and matches the cadence already used by CanvasInfoModel.
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
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        guard let key = boundProject else { return }
        let snap = Self.load(projectKey: key)
        // Only republish when something actually changed — avoids unnecessary
        // body re-evals downstream.
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

    private static func load(projectKey: String) -> Snap {
        let root = NSHomeDirectory() + "/soul_registry/tasks/\(projectKey)"
        let activeFile = root + "/.soul_task"
        guard let activeRaw = try? String(contentsOfFile: activeFile, encoding: .utf8) else {
            return Snap()
        }
        let id = activeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return Snap() }
        let jsonPath = "\(root)/\(id).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Snap(taskId: id, subject: nil, criteria: [])
        }
        let subject = (obj["subject"] as? String) ?? (obj["title"] as? String)
        let status = (obj["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let dod = (obj["done_criteria"] as? [String]) ?? (obj["definition_of_done"] as? [String]) ?? []
        let done = Set((obj["completed_criteria"] as? [String]) ?? [])
        let criteria = dod.map { Criterion(text: $0, done: done.contains($0)) }
        return Snap(taskId: id, subject: subject, status: status, criteria: criteria)
    }
}
