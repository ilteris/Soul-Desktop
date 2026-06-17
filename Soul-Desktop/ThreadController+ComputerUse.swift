import Foundation
import SoulACP
import SoulCore

struct ComputerUsePromptIntent {
    let target: String?

    static func detect(in text: String) -> ComputerUsePromptIntent? {
        let lower = text.lowercased()
        let screenshotAction = [
            "get a screenshot",
            "take a screenshot",
            "capture a screenshot",
            "grab a screenshot",
            "paste a screenshot",
            "send a screenshot",
            "get screenshot",
            "take screenshot",
            "capture screenshot",
            "screenshot of",
            "screen shot of",
            "go to chrome",
            "go to safari",
            "go to xcode",
            "go to finder",
            "go to terminal",
            "go to simulator"
        ].contains { lower.contains($0) }
        let visualInspection = [
            "capture the screen",
            "capture screen",
            "take a picture",
            "what's on screen",
            "what is on screen",
            "look at the screen",
            "look at this app",
            "inspect the ui",
            "inspect ui",
            "inspect the app",
            "visual state",
            "visible state"
        ].contains { lower.contains($0) }

        guard screenshotAction || visualInspection else { return nil }
        return ComputerUsePromptIntent(target: targetApp(in: lower))
    }

    private static func targetApp(in lower: String) -> String? {
        let targets: [(needles: [String], app: String)] = [
            (["chrome", "google chrome"], "Google Chrome"),
            (["safari"], "Safari"),
            (["xcode"], "Xcode"),
            (["finder"], "Finder"),
            (["terminal"], "Terminal"),
            (["iterm", "iterm2"], "iTerm"),
            (["simulator", "ios simulator"], "Simulator"),
            (["notes"], "Notes"),
            (["calendar"], "Calendar"),
            (["mail"], "Mail")
        ]
        return targets.first { target in
            target.needles.contains { lower.contains($0) }
        }?.app
    }
}

extension ThreadController {
    func beginComputerUseArtifactTracking() {
        stopComputerUseArtifactRefresh()
        computerUseArtifactTrackingEnabled = ComputerUseAgentContext.isEnabled(for: provider)
            && ComputerUseService.bundledPeekabooPath() != nil
        computerUseArtifactSignalObserved = false
        guard computerUseArtifactTrackingEnabled else { return }
        computerUseArtifactTrackingStartedAt = Date()
    }

    func endComputerUseArtifactTracking() {
        if computerUseArtifactTrackingEnabled && computerUseArtifactSignalObserved {
            publishNewComputerUseArtifacts()
        }
        stopComputerUseArtifactRefresh()
        computerUseArtifactTrackingEnabled = false
        computerUseArtifactTrackingStartedAt = nil
        computerUseArtifactSignalObserved = false
    }

    func observePotentialComputerUseArtifact(kind: String, title: String, location: String? = nil) {
        guard computerUseArtifactTrackingEnabled,
              ComputerUseArtifactSignal.matches(kind: kind, title: title, location: location)
        else { return }
        computerUseArtifactSignalObserved = true
        publishNewComputerUseArtifacts()
        scheduleComputerUseArtifactRefresh()
    }

    func enrichWithComputerUseIfNeeded(turn: inout QueuedPrompt) async {
        guard let intent = ComputerUsePromptIntent.detect(in: turn.display) else { return }

        do {
            let capture = try await ComputerUseService.captureImage(
                target: intent.target,
                projectPath: activeProjectPath
            )
            insertComputerUseArtifact(path: capture.path, title: intent.target.map { "Screenshot: \($0)" } ?? "Screenshot: frontmost app")

            let context = """

            <computer_use_artifact>
            Screenshot captured by Soul Desktop before this turn.
            Path: \(capture.path)
            Target: \(intent.target ?? "frontmost app")
            </computer_use_artifact>
            """
            turn.agent += context

            if supportsImageAttachments,
               let data = try? Data(contentsOf: URL(fileURLWithPath: capture.path)),
               data.count <= 5 * 1024 * 1024 {
                turn.extraBlocks.append(.image(mimeType: "image/png", base64: data.base64EncodedString()))
            }
        } catch {
            items.append(.toolCall(
                id: UUID(),
                kind: "computer_use",
                title: intent.target.map { "Screenshot: \($0)" } ?? "Screenshot: frontmost app",
                status: "failed",
                locationHint: nil,
                details: nil
            ))
            turn.agent += """

            <computer_use_artifact>
            Soul Desktop tried to capture a screenshot before this turn, but it failed: \(error.localizedDescription)
            </computer_use_artifact>
            """
        }
    }

    private func publishNewComputerUseArtifacts() {
        let cutoff = computerUseArtifactTrackingStartedAt?.addingTimeInterval(-1) ?? .distantPast
        let artifacts = ComputerUseArtifactScanner.currentArtifacts()
        for artifact in artifacts where artifact.modifiedAt >= cutoff && !computerUseArtifactSeenPaths.contains(artifact.path) {
            insertComputerUseArtifact(path: artifact.path, title: artifact.title)
        }
    }

    private func scheduleComputerUseArtifactRefresh() {
        stopComputerUseArtifactRefresh()
        computerUseArtifactRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.publishNewComputerUseArtifacts()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.publishNewComputerUseArtifacts()
        }
    }

    private func stopComputerUseArtifactRefresh() {
        computerUseArtifactRefreshTask?.cancel()
        computerUseArtifactRefreshTask = nil
    }

    private func insertComputerUseArtifact(path: String, title: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        guard !computerUseArtifactSeenPaths.contains(normalized) else { return }
        computerUseArtifactSeenPaths.insert(normalized)
        items.append(.toolCall(
            id: UUID(),
            kind: "computer_use",
            title: title,
            status: "done",
            locationHint: normalized,
            details: nil
        ))
    }
}

struct ComputerUseArtifact: Hashable {
    let path: String
    let title: String
    let modifiedAt: Date
}

enum ComputerUseArtifactSignal {
    static func matches(kind: String, title: String, location: String?) -> Bool {
        let parts = [kind, title, location ?? ""]
        let haystack = parts
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("peekaboo")
            || haystack.contains("computer_use")
            || haystack.contains("computer-use") {
            return true
        }
        guard kind.lowercased().contains("mcp") else { return false }
        let visualMCPNeedles = ["see", "screenshot", "snapshot", "image", "screen", "click", "type"]
        return visualMCPNeedles.contains { haystack.contains($0) }
    }
}

enum ComputerUseArtifactScanner {
    static func currentArtifacts(
        directories: [URL] = defaultDirectories(),
        fileManager: FileManager = .default
    ) -> [ComputerUseArtifact] {
        let urls = directories.flatMap { imageURLs(in: $0, fileManager: fileManager) }
        let grouped = Dictionary(grouping: urls, by: groupKey(for:))
        return grouped.values
            .compactMap { bestArtifact(from: $0) }
            .sorted { $0.modifiedAt < $1.modifiedAt }
    }

    static func defaultDirectories() -> [URL] {
        [
            ComputerUseService.artifactDirectory(),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".peekaboo", isDirectory: true)
                .appendingPathComponent("snapshots", isDirectory: true)
        ]
    }

    private static func imageURLs(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard ext == "png" || ext == "jpg" || ext == "jpeg" else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
    }

    private static func bestArtifact(from urls: [URL]) -> ComputerUseArtifact? {
        guard let url = urls.sorted(by: artifactPreference).first else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return ComputerUseArtifact(
            path: normalizedPath(for: url),
            title: title(for: url),
            modifiedAt: values?.contentModificationDate ?? .distantPast
        )
    }

    private static func artifactPreference(lhs: URL, rhs: URL) -> Bool {
        let left = preferenceScore(lhs)
        let right = preferenceScore(rhs)
        if left != right { return left < right }
        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return leftDate > rightDate
    }

    private static func preferenceScore(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if name.contains("annotated") { return 0 }
        if name == "raw.png" { return 1 }
        return 2
    }

    private static func groupKey(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name == "raw.png" || name == "annotated.png" {
            return normalizedPath(for: url.deletingLastPathComponent())
        }
        if name.hasSuffix("_annotated.png") {
            let groupURL = url.deletingLastPathComponent()
                .appendingPathComponent(String(url.lastPathComponent.dropLast("_annotated.png".count)))
            return normalizedPath(for: groupURL)
        }
        return normalizedPath(for: url.deletingPathExtension())
    }

    private static func title(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        if url.lastPathComponent.lowercased() == "annotated.png" || url.lastPathComponent.lowercased() == "raw.png" {
            return "Peekaboo screenshot: \(parent)"
        }
        return "Peekaboo screenshot"
    }

    private static func normalizedPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
