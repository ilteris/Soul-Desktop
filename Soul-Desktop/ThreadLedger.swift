import Foundation

protocol ThreadLedger: Sendable {
    func appendHook(projectKey: String, sessionId: String, event: [String: Any])
    func retireAgentChunks(projectKey: String, sessionId: String)
    func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool
}

struct LiveThreadLedger: ThreadLedger {
    static let shared = LiveThreadLedger()

    func appendHook(projectKey: String, sessionId: String, event: [String: Any]) {
        SoulRegistry.appendHook(projectKey: projectKey, sessionId: sessionId, event: event)
    }

    func retireAgentChunks(projectKey: String, sessionId: String) {
        SoulRegistry.retireAgentChunks(projectKey: projectKey, sessionId: sessionId)
    }

    func ledgerContainsAfterTool(projectKey: String, sessionId: String, toolId: String) -> Bool {
        SoulRegistry.ledgerContainsAfterTool(projectKey: projectKey, sessionId: sessionId, toolId: toolId)
    }
}
