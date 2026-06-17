import Foundation
import SoulACP
import SoulCore

struct ComputerUsePromptIntent {
    let target: String?
    let navigationURL: String?

    var requiresInteractionBeforeCapture: Bool {
        navigationURL != nil
    }

    static func detect(in text: String) -> ComputerUsePromptIntent? {
        let lower = text.lowercased()
        let target = targetApp(in: lower)
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
            "visible state",
            "display state",
            "current display",
            "current screen",
            "currently visible",
            "what is visible",
            "what's visible",
            "what do you see",
            "what is showing",
            "what's showing"
        ].contains { lower.contains($0) }
        let targetedInspection = target != nil
            && ["inspect", "look at", "visible", "visual", "display", "screen", "showing", "state"]
                .contains { lower.contains($0) }
        let browserInspection = lower.contains("browser")
            && ["inspect", "visible", "visual", "display", "screen", "showing", "state", "screenshot"]
                .contains { lower.contains($0) }
        let navigationURL = browserNavigationURL(in: lower, target: target)

        guard screenshotAction || visualInspection || targetedInspection || browserInspection else { return nil }
        return ComputerUsePromptIntent(
            target: target ?? (browserInspection ? "Google Chrome" : nil),
            navigationURL: navigationURL
        )
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

    private static func isBrowserTarget(_ target: String?, lower: String) -> Bool {
        target == "Google Chrome" || target == "Safari" || lower.contains("browser")
    }

    private static func containsBrowserNavigation(in lower: String) -> Bool {
        [
            "open ",
            "opening ",
            "open up",
            "navigate",
            "go to ",
            "load ",
            "visit "
        ].contains { lower.contains($0) }
    }

    private static func containsWebDestination(in lower: String) -> Bool {
        lower.contains("http://")
            || lower.contains("https://")
            || lower.contains("www.")
            || lower.contains(".com")
            || lower.contains(".org")
            || lower.contains(".net")
            || lower.contains(" site")
            || lower.contains(" website")
    }

    private static func browserNavigationURL(in lower: String, target: String?) -> String? {
        guard isBrowserTarget(target, lower: lower),
              containsBrowserNavigation(in: lower),
              containsWebDestination(in: lower)
        else { return nil }

        let trimCharacters = CharacterSet(charactersIn: "'\"`.,;:!?()[]{}<>")
            .union(.whitespacesAndNewlines)
        let tokens = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: trimCharacters) }
            .filter { !$0.isEmpty }

        for token in tokens {
            guard looksLikeWebAddress(token) else { continue }
            let normalized = normalizeWebAddress(token)
            guard let components = URLComponents(string: normalized),
                  components.scheme != nil,
                  components.host != nil
            else { continue }
            return normalized
        }
        return nil
    }

    private static func looksLikeWebAddress(_ token: String) -> Bool {
        token.hasPrefix("http://")
            || token.hasPrefix("https://")
            || token.hasPrefix("www.")
            || token.contains(".com")
            || token.contains(".org")
            || token.contains(".net")
    }

    private static func normalizeWebAddress(_ token: String) -> String {
        if token.hasPrefix("http://") || token.hasPrefix("https://") {
            return token
        }
        return "https://\(token)"
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

        if let navigationURL = intent.navigationURL {
            await enrichWithBrowserNavigationCapture(turn: &turn, intent: intent, url: navigationURL)
            return
        }

        do {
            let capture = try await ComputerUseService.captureImage(
                target: intent.target,
                projectPath: activeProjectPath
            )
            attachComputerUseCapture(capture, intent: intent, to: &turn, introduction: "Screenshot captured by Soul Desktop before this turn.")
        } catch {
            appendComputerUseFailure(error, intent: intent, to: &turn)
        }
    }

    private func enrichWithBrowserNavigationCapture(turn: inout QueuedPrompt, intent: ComputerUsePromptIntent, url: String) async {
        do {
            try await ComputerUseService.openURL(url, target: intent.target, projectPath: activeProjectPath)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let capture = try await ComputerUseService.captureImage(
                target: intent.target,
                projectPath: activeProjectPath
            )
            attachComputerUseCapture(
                capture,
                intent: intent,
                to: &turn,
                introduction: "Soul Desktop opened \(url) with bundled Peekaboo and captured this screenshot before dispatch."
            )
            turn.agent += """

            <computer_use_request>
            This request required live browser navigation before visual inspection.
            Target: \(intent.target ?? "frontmost app")
            URL opened: \(url)
            The screenshot artifact above is the visual source of truth. Describe it directly.
            Do not search for Peekaboo, do not run /opt/homebrew/bin/peekaboo, do not run AppleScript, do not run osascript, do not run screencapture, and do not save additional screenshots into the project workspace unless the user explicitly asks for a fresh capture.
            </computer_use_request>
            """
        } catch {
            appendComputerUseFailure(error, intent: intent, to: &turn)
            turn.agent += """

            <computer_use_request>
            Soul Desktop could not complete the bundled Peekaboo browser-navigation capture for \(url): \(error.localizedDescription)
            Do not fall back to Homebrew Peekaboo, AppleScript, osascript, screencapture, or shell browser automation. Ask the user to fix Soul Desktop computer-use permissions or bundled helper installation.
            </computer_use_request>
            """
        }
    }

    private func attachComputerUseCapture(
        _ capture: ComputerUseCapture,
        intent: ComputerUsePromptIntent,
        to turn: inout QueuedPrompt,
        introduction: String
    ) {
        insertComputerUseArtifact(path: capture.path, title: intent.target.map { "Screenshot: \($0)" } ?? "Screenshot: frontmost app")

        let context = """

        <computer_use_artifact>
        \(introduction)
        Path: \(capture.path)
        Target: \(intent.target ?? "frontmost app")
        Use this screenshot as the visual source of truth for the user's request.
        Do not search for Peekaboo, do not run /opt/homebrew/bin/peekaboo, do not run AppleScript, do not run osascript, do not run screencapture, and do not create another screenshot unless the user explicitly asks for a fresh capture.
        </computer_use_artifact>
        """
        turn.agent += context

        if supportsImageAttachments,
           let data = try? Data(contentsOf: URL(fileURLWithPath: capture.path)),
           data.count <= 5 * 1024 * 1024 {
            turn.extraBlocks.append(.image(mimeType: "image/png", base64: data.base64EncodedString()))
        }
    }

    private func appendComputerUseFailure(_ error: Error, intent: ComputerUsePromptIntent, to turn: inout QueuedPrompt) {
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
