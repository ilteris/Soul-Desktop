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
    func enrichWithComputerUseIfNeeded(turn: inout QueuedPrompt) async {
        guard let intent = ComputerUsePromptIntent.detect(in: turn.display) else { return }

        do {
            let capture = try await ComputerUseService.captureImage(
                target: intent.target,
                projectPath: activeProjectPath
            )
            items.append(.toolCall(
                id: UUID(),
                kind: "computer_use",
                title: intent.target.map { "Screenshot: \($0)" } ?? "Screenshot: frontmost app",
                status: "done",
                locationHint: capture.path,
                details: nil
            ))

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
}
