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
        let targetMatch = targetAppMatch(in: lower)
        let target = targetMatch?.app
        let screenshotAction = containsScreenshotActionCue(in: lower)
        let visualInspection = containsVisualInspectionCue(in: lower)
        let targetedInspection = targetMatch.map { match in
            containsTargetedInspectionCue(in: lower)
                || containsAdjacentVisualCue(in: lower, subject: match.needle)
        } ?? false
        let browserInspection = containsTokenPhrase("browser", in: lower)
            && containsBrowserInspectionCue(in: lower)
        let navigationURL = browserNavigationURL(in: lower, target: target)

        guard screenshotAction || visualInspection || targetedInspection || browserInspection else { return nil }
        return ComputerUsePromptIntent(
            target: target ?? (browserInspection ? "Google Chrome" : nil),
            navigationURL: navigationURL
        )
    }

    private static func targetAppMatch(in lower: String) -> (app: String, needle: String)? {
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
        for target in targets {
            if let needle = target.needles.first(where: { containsTokenPhrase($0, in: lower) }) {
                return (target.app, needle)
            }
        }
        return nil
    }

    private static func containsScreenshotActionCue(in lower: String) -> Bool {
        containsAnyTokenPhrase([
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
        ], in: lower)
    }

    private static func containsVisualInspectionCue(in lower: String) -> Bool {
        let screenPatterns = [
            "capture the screen",
            "capture screen",
            "what's on screen",
            "what is on screen",
            "look at the screen",
            "current screen"
        ]
        for phrase in screenPatterns where containsScreenPhrase(phrase, in: lower) {
            return true
        }

        return containsAnyTokenPhrase([
            "take a picture",
            "look at this app",
            "inspect the ui",
            "inspect ui",
            "inspect the app",
            "visual state",
            "visible state",
            "display state",
            "current display",
            "currently visible",
            "what is visible",
            "what's visible",
            "what do you see",
            "what is showing",
            "what's showing"
        ], in: lower)
    }

    private static func containsTargetedInspectionCue(in lower: String) -> Bool {
        containsAnyTokenPhrase([
            "inspect",
            "look at",
            "what's on",
            "what is on",
            "what do you see",
            "what is visible",
            "what's visible",
            "currently visible",
            "current display",
            "display state",
            "visual state",
            "visible state",
            "what is showing",
            "what's showing"
        ], in: lower)
    }

    private static func containsBrowserInspectionCue(in lower: String) -> Bool {
        containsTargetedInspectionCue(in: lower)
            || containsAdjacentVisualCue(in: lower, subject: "browser")
            || containsTokenPhrase("screenshot", in: lower)
    }

    private static func containsAdjacentVisualCue(in lower: String, subject: String) -> Bool {
        let escapedSubject = NSRegularExpression.escapedPattern(for: subject.lowercased())
        let gap = #"(?:[^A-Za-z0-9_]+[A-Za-z0-9_]+){0,3}[^A-Za-z0-9_]+"#
        let cuePatterns = [
            "screen(?![^A-Za-z0-9_]+reader\\b)",
            "visible",
            "visual",
            "display",
            "showing",
            "state"
        ]

        for cue in cuePatterns {
            let afterSubject = #"(?<![A-Za-z0-9_])"# + escapedSubject + #"(?![A-Za-z0-9_])"# + gap + #"(?<![A-Za-z0-9_])"# + cue + #"(?![A-Za-z0-9_])"#
            let beforeSubject = #"(?<![A-Za-z0-9_])"# + cue + #"(?![A-Za-z0-9_])"# + gap + #"(?<![A-Za-z0-9_])"# + escapedSubject + #"(?![A-Za-z0-9_])"#
            if lower.range(of: afterSubject, options: .regularExpression) != nil
                || lower.range(of: beforeSubject, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private static func containsScreenPhrase(_ phrase: String, in lower: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.lowercased())
        let pattern = #"(?<![A-Za-z0-9_])"# + escaped + #"(?![A-Za-z0-9_])"# + #"(?![^A-Za-z0-9_]+reader\b)"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsAnyTokenPhrase(_ phrases: [String], in lower: String) -> Bool {
        phrases.contains { containsTokenPhrase($0, in: lower) }
    }

    private static func containsTokenPhrase(_ phrase: String, in lower: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.lowercased())
        let pattern = #"(?<![A-Za-z0-9_])"# + escaped + #"(?![A-Za-z0-9_])"#
        return lower.range(of: pattern, options: .regularExpression) != nil
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
            "inspect ",
            "go to ",
            "load ",
            "visit "
        ].contains { lower.contains($0) }
    }

    private static func containsWebDestination(in lower: String) -> Bool {
        lower.contains("http://")
            || lower.contains("https://")
            || lower.contains("localhost")
            || lower.contains("127.0.0.1")
            || lower.contains("[::1]")
            || lower.contains("::1")
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
            || token.hasPrefix("localhost")
            || token.hasPrefix("127.0.0.1")
            || token.hasPrefix("[::1]")
            || token.hasPrefix("::1")
            || token.hasPrefix("www.")
            || token.contains(".com")
            || token.contains(".org")
            || token.contains(".net")
    }

    private static func normalizeWebAddress(_ token: String) -> String {
        if token.hasPrefix("http://") || token.hasPrefix("https://") {
            return token
        }
        if token.hasPrefix("localhost") || token.hasPrefix("127.0.0.1") || token.hasPrefix("[::1]") {
            return "http://\(token)"
        }
        if token.hasPrefix("::1") {
            return "http://[\(token)]"
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
        computerUseActivity = computerUseActivityTitle(for: intent)
        defer { computerUseActivity = nil }

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

    private func computerUseActivityTitle(for intent: ComputerUsePromptIntent) -> String {
        if let target = intent.target {
            return "Inspecting \(target)..."
        }
        return "Inspecting screen..."
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
            await enrichWithBrowserInspectionFallback(turn: &turn, intent: intent, url: url, captureError: error)
        }
    }

    private func enrichWithBrowserInspectionFallback(
        turn: inout QueuedPrompt,
        intent: ComputerUsePromptIntent,
        url: String,
        captureError: Error
    ) async {
        do {
            let inspection = try await ComputerUseService.inspectUI(
                target: intent.target,
                projectPath: activeProjectPath
            )
            appendComputerUseInspection(inspection, intent: intent, url: url, captureError: captureError, to: &turn)
        } catch {
            appendComputerUseFailure(captureError, intent: intent, to: &turn)
            turn.agent += """

            <computer_use_request>
            Soul Desktop could not complete the bundled Peekaboo browser-navigation capture for \(url): \(captureError.localizedDescription)
            Soul Desktop also could not inspect the visible UI tree: \(error.localizedDescription)
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

    private func appendComputerUseInspection(
        _ inspection: ComputerUseInspection,
        intent: ComputerUsePromptIntent,
        url: String,
        captureError: Error,
        to turn: inout QueuedPrompt
    ) {
        let visibleElements = visibleComputerUseElements(from: inspection)
        items.append(.toolCall(
            id: UUID(),
            kind: "computer_use",
            title: intent.target.map { "Visible UI: \($0)" } ?? "Visible UI",
            status: "captured",
            locationHint: nil,
            details: ToolCallDetails(kind: .output(text: "Screenshot was blank; using visible UI inspection instead."))
        ))

        turn.agent += """

        <computer_use_observation>
        Soul Desktop opened \(url) with bundled Peekaboo, but the screenshot capture was rejected because it was blank: \(captureError.localizedDescription)
        Target: \(inspection.targetDetail ?? intent.target ?? "frontmost app")
        Visible UI text from Peekaboo accessibility inspection:
        \(visibleElements)
        Use this visible UI observation as the source of truth for the user's request.
        Do not search for Peekaboo, do not run /opt/homebrew/bin/peekaboo, do not run AppleScript, do not run osascript, do not run screencapture, and do not inspect unrelated project files unless the user asks for code work.
        </computer_use_observation>
        """
    }

    private func visibleComputerUseElements(from inspection: ComputerUseInspection) -> String {
        let names = inspection.elements
            .map(\.displayName)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "group" && $0 != "link" && $0 != "button" && $0 != "tab" }

        var unique: [String] = []
        var seen = Set<String>()
        for name in names where !seen.contains(name) {
            seen.insert(name)
            unique.append(name)
        }

        return unique.prefix(20).map { "- \($0)" }.joined(separator: "\n")
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
