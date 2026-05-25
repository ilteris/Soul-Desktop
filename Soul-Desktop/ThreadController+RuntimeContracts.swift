import Foundation
import SoulCore
import SoulRuntime

extension Provider {
    var agentProvider: AgentProvider {
        AgentProvider(rawValue: rawValue) ?? .geminiCLI
    }
}

extension AgentProvider {
    var appProvider: Provider? {
        Provider(rawValue: rawValue)
    }
}

extension ThreadController {
    func runtimeSessionSnapshot() -> ProviderRuntimeSession {
        ProviderRuntimeSession(
            provider: provider.agentProvider,
            projectPath: project.path,
            kernelSessionID: sessionId,
            nativeSessionID: nativeSessionId
        )
    }

    func runtimeStartRequest(skipNewSession: Bool, resumeSessionId: String? = nil) -> ProviderRuntimeStartRequest {
        ProviderRuntimeStartRequest(
            session: runtimeSessionSnapshot(),
            skipNewSession: skipNewSession,
            resumeSessionID: resumeSessionId,
            permissionMode: permissionMode.agentPermissionMode
        )
    }

    func runtimeLoadRequest(requestedSessionID: String) -> ProviderRuntimeLoadRequest {
        ProviderRuntimeLoadRequest(
            session: runtimeSessionSnapshot(),
            requestedSessionID: requestedSessionID
        )
    }

    func runtimeNewSessionRequest(systemPrompt: String? = nil) -> ProviderRuntimeNewSessionRequest {
        ProviderRuntimeNewSessionRequest(
            session: runtimeSessionSnapshot(),
            systemPrompt: systemPrompt
        )
    }

    func applyRuntimeStartResult(_ result: ProviderRuntimeStartResult) {
        if let nativeSessionID = result.nativeSessionID {
            nativeSessionId = nativeSessionID
        }
        supportsLoadSession = result.capabilities.supportsLoadSession
        supportsImageAttachments = result.capabilities.supportsImageAttachments
    }

    func applyRuntimeNewSessionResult(_ result: ProviderRuntimeNewSessionResult) {
        nativeSessionId = result.nativeSessionID
    }

    func runtimeSpawnResolver() -> RuntimeSpawnResolver {
        { provider, resumeSessionID in
            guard let appProvider = provider.appProvider else { return nil }
            return ACPProviderSpawn.resolve(appProvider, resumeSessionId: resumeSessionID)
        }
    }

    func runtimeHydrationPreparer() -> RuntimeHydrationPreparer {
        { provider, projectKey, projectPath, sessionID in
            guard let appProvider = provider.appProvider else {
                return RuntimeHydrationResult(log: ["runtime hydration skipped: unknown provider \(provider.rawValue)"])
            }
            let result = await SoulHydration.prepare(
                provider: appProvider,
                projectKey: projectKey,
                projectPath: projectPath,
                sessionId: sessionID
            )
            return RuntimeHydrationResult(env: result.env, log: result.log)
        }
    }
}
