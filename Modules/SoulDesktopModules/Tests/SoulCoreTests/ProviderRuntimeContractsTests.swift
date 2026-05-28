import Testing
@testable import SoulCore

@Suite("Provider runtime contracts")
struct ProviderRuntimeContractsTests {
    @Test
    func runtimeSessionPrefersNativeSessionForRPC() {
        let kernelOnly = ProviderRuntimeSession(
            provider: .claude,
            projectPath: "/tmp/project",
            kernelSessionID: "kernel"
        )
        let native = ProviderRuntimeSession(
            provider: .claude,
            projectPath: "/tmp/project",
            kernelSessionID: "kernel",
            nativeSessionID: "native"
        )

        #expect(kernelOnly.rpcSessionID == "kernel")
        #expect(native.rpcSessionID == "native")
    }

    @Test
    func promptRequestRequiresSessionAndSubstantiveText() {
        let session = ProviderRuntimeSession(
            provider: .geminiCLI,
            projectPath: "/tmp/project",
            kernelSessionID: "kernel"
        )

        #expect(ProviderRuntimePromptRequest<String>(session: session, text: "hello").canDispatch)
        #expect(!ProviderRuntimePromptRequest<String>(session: session, text: " \n ").canDispatch)
        #expect(ProviderRuntimePromptRequest<String>(
            session: session,
            text: " \n ",
            attachments: ["image-block"]
        ).canDispatch)
        #expect(!ProviderRuntimePromptRequest<String>(
            session: ProviderRuntimeSession(provider: .geminiCLI, projectPath: "/tmp/project"),
            text: "hello"
        ).canDispatch)
    }

    @Test
    func startAndCancelRequestsAreValueContracts() {
        let session = ProviderRuntimeSession(
            provider: .codex,
            projectPath: "/tmp/project",
            kernelSessionID: "kernel",
            nativeSessionID: "native"
        )
        let start = ProviderRuntimeStartRequest(
            session: session,
            skipNewSession: true,
            resumeSessionID: "resume",
            permissionMode: .autoReview
        )
        let cancel = ProviderRuntimeCancelRequest(session: session, activeTurnID: "turn")
        let result = ProviderRuntimeStartResult(
            nativeSessionID: "native",
            capabilities: ProviderRuntimeCapabilities(
                supportsLoadSession: true,
                supportsImageAttachments: true
            )
        )

        #expect(start.session == session)
        #expect(start.skipNewSession)
        #expect(start.resumeSessionID == "resume")
        #expect(start.permissionMode == .autoReview)
        #expect(cancel.session.rpcSessionID == "native")
        #expect(cancel.activeTurnID == "turn")
        #expect(result.capabilities.supportsLoadSession)
        #expect(result.capabilities.supportsImageAttachments)
    }

    @Test
    func loadAndNewSessionRequestsAreValueContracts() {
        let session = ProviderRuntimeSession(
            provider: .claude,
            projectPath: "/tmp/project",
            kernelSessionID: "kernel"
        )
        let load = ProviderRuntimeLoadRequest(session: session, requestedSessionID: "resume")
        let fresh = ProviderRuntimeNewSessionRequest(session: session, systemPrompt: "system")
        let result = ProviderRuntimeNewSessionResult(nativeSessionID: "native")

        #expect(load.session == session)
        #expect(load.requestedSessionID == "resume")
        #expect(fresh.session.projectPath == "/tmp/project")
        #expect(fresh.systemPrompt == "system")
        #expect(result.nativeSessionID == "native")
    }
}
