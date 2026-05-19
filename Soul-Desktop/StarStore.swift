import Foundation
import SwiftUI

/// SOUL-SOUL_DESKTOP-198: per-project set of starred (pinned) session IDs.
///
/// Mirrors `ArchiveStore`: sidebar-local, no kernel touch. Starred sessions
/// sort to the top of their project's session list and render a star glyph
/// next to the title. Persisted to UserDefaults under one key per project.
@Observable
@MainActor
final class StarStore {
    static let shared = StarStore()

    private(set) var starredByProject: [String: Set<String>] = [:]

    private init() {
        starredByProject = Self.loadAll()
    }

    func isStarred(_ sessionId: String, project: String) -> Bool {
        starredByProject[project]?.contains(sessionId) ?? false
    }

    func starredIDs(forProject project: String) -> Set<String> {
        starredByProject[project] ?? []
    }

    func star(_ sessionId: String, project: String) {
        var set = starredByProject[project] ?? []
        guard set.insert(sessionId).inserted else { return }
        starredByProject[project] = set
        persist(project: project)
    }

    func unstar(_ sessionId: String, project: String) {
        guard var set = starredByProject[project], set.remove(sessionId) != nil else { return }
        starredByProject[project] = set
        persist(project: project)
    }

    func toggle(_ sessionId: String, project: String) {
        if isStarred(sessionId, project: project) {
            unstar(sessionId, project: project)
        } else {
            star(sessionId, project: project)
        }
    }

    private static func key(for project: String) -> String {
        "soul.sidebar.starred.\(project)"
    }

    private func persist(project: String) {
        let arr = Array(starredByProject[project] ?? [])
        UserDefaults.standard.set(arr, forKey: Self.key(for: project))
    }

    private static func loadAll() -> [String: Set<String>] {
        let prefix = "soul.sidebar.starred."
        var out: [String: Set<String>] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            guard k.hasPrefix(prefix), let arr = v as? [String] else { continue }
            let project = String(k.dropFirst(prefix.count))
            out[project] = Set(arr)
        }
        return out
    }
}
