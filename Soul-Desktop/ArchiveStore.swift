import Foundation
import SwiftUI

/// SOUL-SOUL_DESKTOP-053: per-project set of archived session IDs.
///
/// Archive is sidebar-local — we don't touch the registry on disk. The
/// archived set is persisted to UserDefaults under one key per project so
/// the same chats stay hidden across relaunches. The sidebar filters its
/// `mergedChatList` against `isArchived(id:)` and renders an "Archived (N)"
/// disclosure group at the bottom of each project.
@Observable
@MainActor
final class ArchiveStore {
    static let shared = ArchiveStore()

    /// `projectId -> Set<sessionId>`. In-memory mirror so views observe
    /// changes via the @Observable property; UserDefaults is the durable
    /// store.
    private(set) var archivedByProject: [String: Set<String>] = [:]

    private init() {
        archivedByProject = Self.loadAll()
    }

    func isArchived(_ sessionId: String, project: String) -> Bool {
        archivedByProject[project]?.contains(sessionId) ?? false
    }

    func archivedIDs(forProject project: String) -> Set<String> {
        archivedByProject[project] ?? []
    }

    func archive(_ sessionId: String, project: String) {
        var set = archivedByProject[project] ?? []
        guard set.insert(sessionId).inserted else { return }
        archivedByProject[project] = set
        persist(project: project)
    }

    func unarchive(_ sessionId: String, project: String) {
        guard var set = archivedByProject[project], set.remove(sessionId) != nil else { return }
        archivedByProject[project] = set
        persist(project: project)
    }

    // MARK: - Persistence

    private static func key(for project: String) -> String {
        "soul.sidebar.archived.\(project)"
    }

    private func persist(project: String) {
        let arr = Array(archivedByProject[project] ?? [])
        UserDefaults.standard.set(arr, forKey: Self.key(for: project))
    }

    private static func loadAll() -> [String: Set<String>] {
        // Walk UserDefaults for keys with our prefix. Cheap — typically
        // a few projects with single-digit archived counts each.
        let prefix = "soul.sidebar.archived."
        var out: [String: Set<String>] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            guard k.hasPrefix(prefix), let arr = v as? [String] else { continue }
            let project = String(k.dropFirst(prefix.count))
            out[project] = Set(arr)
        }
        return out
    }
}
