import Foundation
import SoulRuntime

final class ThreadProviderRuntimeStore {
    var acp: ACPProviderRuntimeAdapter?
    var codex: CodexProviderRuntimeAdapter?

    var hasACPRuntime: Bool {
        acp != nil
    }

    var hasCodexRuntime: Bool {
        codex != nil
    }

    func stopACP() async {
        await acp?.stop()
        acp = nil
    }

    func stopCodex() async {
        await codex?.stop()
        codex = nil
    }

    func stopAll() async {
        await stopACP()
        await stopCodex()
    }
}
