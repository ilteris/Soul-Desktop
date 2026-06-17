import Foundation

enum ComputerUseAgentContext {
    static func isEnabled(for provider: Provider) -> Bool {
        guard let computerUseProvider = ComputerUseProvider(provider) else { return false }
        return ComputerUseMCPConfig.isEnabled(for: computerUseProvider)
    }

    static func prefixIfEnabled(_ text: String, provider: Provider) -> String {
        guard isEnabled(for: provider), !text.contains("<computer_use>") else { return text }
        return "\(guidance())\n\n\(text)"
    }

    static func guidance() -> String {
        var lines = [
            "<computer_use>",
            "Peekaboo MCP is available for permissioned visual/UI inspection and desktop interaction.",
            "Use it only when the user asks to inspect the screen/app UI, understand visible state, click/type in the UI, or debug a visual interaction.",
            "Do not use Peekaboo for ordinary code search, editing, builds, tests, or non-visual repository work.",
            "If permissions are missing, ask the user to grant them in Soul Desktop's Computer pane instead of retrying blindly.",
            "Artifact directory: \(ComputerUseService.artifactDirectory().path)"
        ]
        if let latest = latestInspectionArtifactPath() {
            lines.append("Latest inspection artifact: \(latest)")
        }
        lines.append("</computer_use>")
        return lines.joined(separator: "\n")
    }

    static func latestInspectionArtifactPath(directory: URL = ComputerUseService.artifactDirectory()) -> String? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("see-")
                    && name.hasSuffix(".png")
                    && !name.contains("_annotated")
            }
            .compactMap { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
            .path
    }
}
