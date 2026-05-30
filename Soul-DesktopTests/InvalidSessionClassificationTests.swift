import Foundation
import Testing
import SoulACP
@testable import Soul_Desktop

/// SOUL-SOUL_DESKTOP-358: `isInvalidSessionRPC` is the boundary that decides
/// whether a `session/*` rpcError is a recoverable "agent lost the session"
/// failure (→ re-establish + retry) or an unrelated error (→ surface to the
/// user). `ensureSessionResilient` and the prompt-loop recovery both gate on
/// it, so the classification must stay stable across providers.
@MainActor
@Suite("Invalid-session RPC classification")
struct InvalidSessionClassificationTests {

    @Test("recoverable session-loss errors are classified for retry")
    func recoverableErrorsMatch() {
        // Gemini-CLI: -32602 Invalid params (the SOUL-356 recovery surface).
        #expect(ThreadController.isInvalidSessionRPC(JSONRPCError(code: -32602, message: "Invalid params")))
        // Gemini-CLI: -32603 with an explicit message.
        #expect(ThreadController.isInvalidSessionRPC(JSONRPCError(code: -32603, message: "Invalid session identifier")))
        // Claude: resource-not-found on an unknown sid.
        #expect(ThreadController.isInvalidSessionRPC(JSONRPCError(code: -32002, message: "resource not found")))
        // Message-based match regardless of code.
        #expect(ThreadController.isInvalidSessionRPC(JSONRPCError(code: -1, message: "unknown session id")))
    }

    @Test("unrelated errors are not misclassified as session loss")
    func unrelatedErrorsDoNotMatch() {
        #expect(!ThreadController.isInvalidSessionRPC(JSONRPCError(code: -32601, message: "Method not found")))
        #expect(!ThreadController.isInvalidSessionRPC(JSONRPCError(code: -32700, message: "Parse error")))
        #expect(!ThreadController.isInvalidSessionRPC(JSONRPCError(code: 500, message: "internal model error")))
    }
}
