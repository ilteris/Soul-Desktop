import Foundation
import Observation

/// Per-thread ACP session state. Owns the bits of "what does the agent
/// child currently look like" that used to be smeared across
/// `ThreadController` as raw stored properties. Refactor goal is agent
/// ergonomics: shrink `ThreadController` enough that coding agents can
/// hold it in context.
///
/// Step 2/N of the migration: codex token-usage counters only. Subsequent
/// steps move `sessionId` / `nativeSessionId` / `lastActivityAt` (needs a
/// pre-spawn bridge — see SOUL-SOUL_DESKTOP-119) and ultimately the
/// `ACPClient` / `CodexClient` handles + event stream.
///
/// Constructed lazily by `ThreadController` on first need (typically at
/// `spawnAndInitialize`). Historical threads loaded from disk never
/// allocate one. Public reads on `ThreadController` forward to
/// `session?.foo`, so external API stays identical while the storage
/// migrates underneath.
@MainActor
@Observable
final class ACPSession {
    let provider: Provider
    let project: SoulProject

    /// Latest token count reported by codex's `thread/tokenUsage/updated`
    /// notification (`last.totalTokens` from the payload). nil until the
    /// first usage event lands.
    var codexTokensUsed: Int?

    /// Model context-window budget reported by the same notification
    /// (`modelContextWindow`). Drives the toolbar chip's denominator.
    var codexContextWindow: Int?

    init(provider: Provider, project: SoulProject) {
        self.provider = provider
        self.project = project
    }
}
