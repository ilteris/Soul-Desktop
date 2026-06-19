import Foundation
import SwiftUI
import Combine

@MainActor
final class SoulSpecialistStore: ObservableObject {
    @Published private(set) var specialists: [String] = SoulSpecialistStore.fallbackSpecialists

    private var boundProject: String? = nil

    func bind(projectKey: String?, selected: String, onSelect: @escaping (String) -> Void) {
        guard projectKey != boundProject else {
            ensureSelection(selected: selected, onSelect: onSelect)
            return
        }
        boundProject = projectKey
        Task {
            let loaded = await Self.load(projectKey: projectKey)
            specialists = loaded
            ensureSelection(selected: selected, onSelect: onSelect)
        }
    }

    private func ensureSelection(selected: String, onSelect: (String) -> Void) {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if specialists.contains(trimmed) { return }
        if specialists.contains("systems_architect") {
            onSelect("systems_architect")
        } else if let first = specialists.first {
            onSelect(first)
        }
    }

    nonisolated private static func load(projectKey: String?) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var discovered: [String] = []
            discovered.append(contentsOf: projectTeam(projectKey: projectKey))
            discovered.append(contentsOf: agentFileSpecialists())
            discovered.append(contentsOf: fallbackSpecialists)
            return orderedUnique(discovered.filter { !$0.isEmpty })
        }.value
    }

    nonisolated private static func projectTeam(projectKey: String?) -> [String] {
        guard let projectKey, !projectKey.isEmpty else { return [] }
        // Single source of truth: `soul project show <key>` (kernel CLI).
        // The legacy dual-path read of ~/dotfiles/soul/config/PROJECTS.json
        // + ~/soul_registry/PROJECTS.json was retired in
        // SOUL-SOUL_DESKTOP-261 — the CLI now handles project-key lookup
        // and harness_config resolution. Returns [] on CLI failure or when
        // the project has no team configured.
        guard let data = SoulCLI.runSync(["project", "show", projectKey]),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let harness = project["harness_config"] as? [String: Any],
              let team = harness["team"] as? [Any]
        else { return [] }

        return team.compactMap { member -> String? in
            if let name = member as? String { return name }
            guard let object = member as? [String: Any] else { return nil }
            return object["persona"] as? String
                ?? object["name"] as? String
                ?? object["specialist"] as? String
                ?? object["id"] as? String
        }
    }

    nonisolated private static func agentFileSpecialists() -> [String] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let directories = [
            home.appendingPathComponent("dotfiles/soul/agents"),
            home.appendingPathComponent("dotfiles/gemini/agents"),
            home.appendingPathComponent(".gemini/agents")
        ]

        var names: [String] = []
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension == "md" {
                if let name = frontMatterName(url: url) {
                    names.append(name)
                } else {
                    names.append(url.deletingPathExtension().lastPathComponent)
                }
            }
        }
        return names
    }

    nonisolated private static func frontMatterName(url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.prefix(1200).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("name:") else { continue }
            return line.dropFirst(5)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        }
        return nil
    }

    nonisolated private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    nonisolated private static let fallbackSpecialists = [
        "systems_architect",
        "information_retriever",
        "code_archaeologist",
        "terrain_mapper",
        "registry_guardian",
        "adversarial_judge",
        "product_shaper",
        "visual_auditor"
    ]
}
