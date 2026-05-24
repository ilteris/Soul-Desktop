import Foundation

/// Single source of truth for "should this session row appear in the sidebar?"
///
/// Replaces three previously-duplicated filter sites:
///   • `SoulRegistry+Sessions.isUserVisibleSidebarSession` (scan-time, stored
///     as the `substantive` field on `SoulSession`)
///   • `SidebarView+Projects.mergedChatList` filter closure (render-time)
///   • `SidebarView+Projects.filteredChatCount` filter (badge-count site)
///
/// Each had its own subset of checks and they could disagree. Consolidation
/// means: the badge count and the rendered list are guaranteed to match,
/// the policy is testable in one place, and adding a new filter (e.g. a
/// future "hide finalize-only summaries" toggle) is a single edit.
enum SidebarVisibilityPolicy {

    /// UI-state inputs the policy needs that aren't carried on `SoulSession`
    /// itself. Pass a fresh value per render — these are cheap to construct.
    struct Context {
        /// Sessions the user has archived for this project. Hidden unless
        /// the user has explicitly enabled the archived disclosure.
        let archivedIds: Set<String>
        /// When false (default), rows without an offline transcript or hooks
        /// ledger are hidden. The "Show unreadable" filter toggle flips this
        /// to true so the user can see crash-residue rows for diagnostics.
        let showUnreadable: Bool
        /// Optional provider filter chip — e.g. "claude" hides Gemini rows.
        let chatSourceFilter: String?
        /// When true, sessions whose resolved title is empty get hidden.
        let hideUntitled: Bool
    }

    /// True when the row should appear in the sidebar's active list under
    /// the current UI state. Archived sessions are NOT excluded here — the
    /// renderer partitions on `archivedIds` separately so it can show the
    /// "Archived (N)" disclosure group. Callers that only want the active
    /// list combine `shouldShow(_:in:)` with `!context.archivedIds.contains`.
    static func shouldShow(_ session: SoulSession, in context: Context) -> Bool {
        // 1. Writer stamp wins. Title-generation, subagent, and other
        //    machine-driven sessions ship with `session_visibility = "machine"`
        //    from `ThreadController+Events` (title-gen subprocess env) and
        //    `soul_subagent.py` (delegate spawn env). The kernel middleware
        //    propagates it into every hook event.
        if session.sessionVisibility == "machine" { return false }

        // 1a. Partial-capture sessions. UserPrompt events landed but the
        //     writer never persisted AfterAgent — the row would open onto
        //     an empty canvas. We trashed historical instances; this filter
        //     keeps future ones from leaking into the sidebar if the writer
        //     ever drifts again. Detection is in readHooksMetadata.
        if session.partialCapture { return false }

        // 1b. Defense-in-depth for synthetic rows. A live `ThreadController`
        //     that mirrors a subagent invocation (e.g. when the kernel
        //     spawns gemini-cli with `-p "ACT AS @specialist. TASK: …"`)
        //     surfaces a synthetic row whose `displayTitle` starts with
        //     "ACT AS" but whose `sessionVisibility` is nil because no
        //     hook ever reached the kernel ledger to stamp it. Same goes
        //     for echoed `<prior_session_context>` blocks. Pattern-match
        //     these and hide. This used to live in `isSidebarControlTitle`
        //     and was scattered across three filter sites; it's now one
        //     check inside the unified policy.
        if let title = (session.intent ?? session.summary)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isMachineTitlePattern(title) {
            return false
        }

        // 2. Launchd-started rows with no prompts are daemon residue, not
        //    chats. `ppid == 1` means the parent process is launchd.
        if !session.hasFinalize, session.sessionStartPpid == 1, session.promptCount == 0 {
            return false
        }

        // 3. Delegation-stub leak. A kernel-minted session whose only events
        //    are `DelegationStarted/Completed/Failed` from a `soul delegate`
        //    invocation (when the parent crashed or never had a UserPrompt
        //    of its own). Without this clamp the conversation check below
        //    treats four delegation rows as real content and the row shows
        //    as "New chat" with a single delegate tool call inside.
        let nonDelegationEvents = max(0, session.eventCount - session.delegationEventCount)
        if !session.hasFinalize,
           session.promptCount == 0,
           session.transcriptTurns == 0,
           session.delegationEventCount > 0,
           nonDelegationEvents < 2 {
            return false
        }

        // 4. Conversation gate — STRICT. User content has to actually exist
        //    in the ledger or provider transcript. Finalize-only orphans
        //    (a sibling <sid>.json with no UserPrompts in hooks.jsonl) were
        //    historically a codex-writer-drift artifact; the kernel fix
        //    upstream stops minting them, so we don't surface the legacy
        //    ones either. If a real chat lost its UserPrompts to the
        //    SOUL-247 payload-drop class, transcriptTurns from the
        //    provider transcript still rescues it.
        let hasConversation = session.promptCount > 0 || session.transcriptTurns > 0
        guard hasConversation else { return false }

        // 5. Loadability. Rows without a kernel ledger AND without an
        //    off-disk provider transcript get hidden unless the user
        //    explicitly toggles "Show unreadable" — those rows can only
        //    open in Replay so most users want them out of the way.
        if !context.showUnreadable, !(session.loadable || session.replayable) {
            return false
        }

        // 6. Provider chip filter. UI sets `chatSourceFilter` when the user
        //    clicks a provider chip (Claude / Gemini / Pi / Codex) to narrow
        //    the list. Match against the session's source — `source` is the
        //    finalized writer; `liveProvider` is the live spawn target.
        if let filter = context.chatSourceFilter,
           (session.source ?? session.liveProvider ?? "") != filter {
            return false
        }

        // 7. Untitled toggle. Hide rows whose resolved title is empty — for
        //    users who don't want to see ledger-only sessions where the
        //    title hook never fired.
        if context.hideUntitled {
            let title = (session.intent ?? session.summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { return false }
        }

        return true
    }

    /// Title prefixes that mark a session as machine-only, used as a
    /// defense-in-depth check when `session_visibility=machine` didn't
    /// land (synthetic rows from active controllers, pre-writer-fix
    /// historical sessions, etc.).
    private static func isMachineTitlePattern(_ title: String) -> Bool {
        let upper = title.uppercased()
        if upper.hasPrefix("ACT AS @") { return true }
        if upper.hasPrefix("ACT AS ") { return true }
        if upper.hasPrefix("PRODUCE A CONCISE 3-5 WORD TITLE FOR THE FOLLOWING CHAT") {
            return true
        }
        if title.hasPrefix("<prior_session_context>") { return true }
        if title.hasPrefix("</prior_session_context>") { return true }
        return false
    }
}
