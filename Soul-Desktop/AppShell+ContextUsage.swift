import SwiftUI

struct ContextUsageRequest: Hashable, Sendable {
    let providerRawValue: String
    let sessionId: String
    let cwd: String
    let projectKey: String

    var id: String {
        "\(providerRawValue)|\(cwd)|\(sessionId)|\(projectKey)"
    }
}

extension AppShell {
    @MainActor
    func refreshContextUsage(for request: ContextUsageRequest?) async {
        guard let request else {
            cachedContextUsage = nil
            cachedContextUsageRequestID = nil
            return
        }

        if cachedContextUsageRequestID != request.id {
            cachedContextUsage = nil
            cachedContextUsageRequestID = request.id
        }

        guard let provider = Provider(rawValue: request.providerRawValue) else {
            cachedContextUsage = nil
            return
        }

        let usage = await Task.detached(priority: .utility) {
            ContextUsage.compute(
                provider: provider,
                sessionId: request.sessionId,
                cwd: request.cwd,
                projectKey: request.projectKey
            )
        }.value

        guard !Task.isCancelled, contextUsageRequest == request else { return }
        cachedContextUsageRequestID = request.id
        cachedContextUsage = usage
    }
}
