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

    /// Kernel/registry session id. This is the UUID Soul writes hooks under
    /// (~/soul_registry/sessions/<project>/<sessionId>/hooks.jsonl) and the
    /// id AppShell / SidebarView use to identify the chat row. Stable for
    /// the entire thread lifetime — never overwritten by a successful
    /// session/load, even when the agent's native UUID differs.
    var sessionId: String?

    /// Agent-native session id used for ACP calls (session/prompt,
    /// session/cancel, session/load). For Soul-Desktop spawns this equals
    /// `sessionId` (identity mapping written at session/new). For divergent
    /// legacy sessions resumed via backfill, this is the agent's UUID while
    /// `sessionId` stays the kernel id. nil until the first ACP id is known.
    var nativeSessionId: String?

    /// Convenience: native id when known, else the kernel id. Use this at
    /// every ACPClient call site so we never accidentally ask the agent to
    /// resume a UUID it didn't mint.
    var acpSessionId: String? { nativeSessionId ?? sessionId }

    /// Last time we received any event from the agent. Used to compute
    /// "quiet for Ns" once `isWorking` is true and nothing's streaming.
    /// Seeded from the controller on init so pre-spawn writes
    /// (`AppShell` setting it during resume hydration) survive.
    var lastActivityAt: Date

    /// Latest token count reported by codex's `thread/tokenUsage/updated`
    /// notification (`last.totalTokens` from the payload). nil until the
    /// first usage event lands.
    var codexTokensUsed: Int?

    /// Model context-window budget reported by the same notification
    /// (`modelContextWindow`). Drives the toolbar chip's denominator.
    var codexContextWindow: Int?

    init(provider: Provider,
         project: SoulProject,
         initialLastActivityAt: Date = Date()) {
        self.provider = provider
        self.project = project
        self.lastActivityAt = initialLastActivityAt
    }
}
