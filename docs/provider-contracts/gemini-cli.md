# Gemini-CLI Provider Contract

Soul Desktop treats Gemini as an ACP provider backed by Gemini CLI.

Gemini is run through a version-controlled runtime path so Soul can keep ACP behavior and local patches stable. See also `docs/gemini-runtime.md`.

## Current Runtime Model

Gemini provider spawning resolves in this order:

1. `SOUL_GEMINI_LOCAL` development override
2. App-bundled Gemini CLI runtime
3. `gemini` on `PATH`

The runtime shape is:

- Spawn command: Gemini CLI with `--acp`
- Transport: ACP / JSON-RPC over stdio
- Runtime adapter: `ACPProviderRuntimeAdapter`
- Wire client: `ACPClient`
- UI/event bridge: `ThreadController+ACP`

Soul passes additional include directories for the Soul kernel and dotfiles when available so spawned Gemini sessions can inspect project-adjacent Soul context.

## Identity And Resume

Gemini supports ACP `session/load`.

Soul keeps:

- **Kernel session id**: the durable Soul ledger id.
- **Native session id**: Gemini's provider-side session id, persisted through `NativeSessionID` hooks when the ids diverge.

Gemini historically has sharper failure modes around stale or mismatched native ids, including metadata-only stub files. Soul therefore prefers ledger-first rendering and uses native ids only as provider runtime handles.

## Hydration

Gemini sessions are hydrated ledger-first.

Soul prefers `hooks.jsonl` when it contains both user and assistant content. If the ledger is partial, Soul can fall back to `GeminiTranscriptReader`.

For reopened sessions, Soul may stage prior context through the preamble/resume path rather than asking the model to replay the entire historical transcript into the live context.

## Rendered Capabilities

Gemini streams through the generic ACP renderer.

Rendered or tracked surfaces include:

- User and assistant message chunks
- Reasoning/thought chunks when emitted
- Tool calls and tool-call updates
- Plans
- Available command updates
- Session load replay chunks
- Permission and cancellation flow through the generic ACP runtime

## Non-Goals

Soul Desktop does not embed Gemini CLI's terminal UI or private persistence model.

The following remain outside the provider contract unless Gemini exposes them through ACP or Soul reconstructs them from the ledger:

- Gemini terminal-only UI affordances
- Provider-private chat file behavior as a source of truth
- Undocumented CLI state
- Runtime behavior from an unbundled Gemini build when the bundled runtime is active

