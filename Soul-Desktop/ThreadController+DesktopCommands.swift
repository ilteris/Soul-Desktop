import Foundation
import SoulCore

extension ThreadController {
    func runDesktopFinalize() {
        guard !isWorking else { return }
        Task {
            do {
                try await ensureSession()
                guard let sid = sessionId else {
                    throw NSError(
                        domain: "Soul-Desktop",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot finalize without a session id."]
                    )
                }
                isWorking = true
                items.append(.status(id: UUID(), text: "Finalizing session..."))
                _ = try await SoulCLI.runText(
                    ["finalize", "--project", project.id],
                    environmentOverrides: [
                        "SOUL_PROJECT": project.id,
                        "SOUL_SESSION_ID": sid,
                    ]
                )
                items.append(.status(id: UUID(), text: "Finalize complete"))
                injectFinalizeSummaryIfFresh(sessionId: sid)
            } catch {
                let message = Self.humanReadable(error)
                items.append(.error(id: UUID(), text: message))
                lastError = message
            }
            isWorking = false
        }
    }
}
