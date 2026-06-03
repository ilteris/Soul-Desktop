# Claude Provider Contract

Soul Desktop treats Claude as an ACP provider backed by `@agentclientprotocol/claude-agent-acp`.

Claude has the strongest first-class ACP resume story in the current provider set. Soul still owns durable identity and ledger replay; Claude's provider transcript is a cache and recovery source.

## Current Runtime Model

- Spawn command: `npx -y @agentclientprotocol/claude-agent-acp`
- Transport: ACP / JSON-RPC over stdio
- Runtime adapter: `ACPProviderRuntimeAdapter`
- Wire client: `ACPClient`
- UI/event bridge: `ThreadController+ACP`

Soul may also use `SOUL_CLAUDE_ACP_LOCAL` to run a local development checkout of `claude-agent-acp`.

## Identity And Resume

Claude supports ACP `session/load`.

Soul keeps two identities when necessary:

- **Kernel session id**: the durable Soul session id used for ledger, sidebar, replay, finalize matching, and project history.
- **Native session id**: Claude's provider-side session id, persisted through `NativeSessionID` hooks when available.

For new Soul-created Claude sessions, these ids usually match. For recovered or cross-surface sessions, Soul resolves the native id from the ledger before calling `session/load`.

## Hydration

Claude sessions are hydrated ledger-first.

Soul prefers `hooks.jsonl` when the ledger contains both user and assistant content. If the ledger is partial, Soul can fall back to Claude's transcript files under the provider persistence directory.

This preserves the kernel ledger as the source of truth while still allowing historical recovery when provider transcripts contain content the ledger missed.

## Rendered Capabilities

Claude streams through the generic ACP renderer.

Rendered or tracked surfaces include:

- User and assistant message chunks
- Reasoning/thought chunks when emitted
- Tool calls and tool-call updates
- Plans
- Available command updates
- Session load replay chunks
- Permission and cancellation flow through the generic ACP runtime

## Non-Goals

Soul Desktop does not embed Claude Code's terminal UI.

The following remain outside the provider contract unless ACP exposes them:

- Claude Code private terminal affordances
- Provider-private local UI state
- Transcript behavior not represented by ACP or the Soul ledger
- Undocumented Claude Code commands that bypass ACP

