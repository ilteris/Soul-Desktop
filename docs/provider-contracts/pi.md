# Pi Provider Contract

Soul Desktop treats Pi as an ACP provider backed by `pi-acp`.

Pi is included as a provider runtime, but its persistence and resume behavior is less mature than Claude and Gemini in Soul's current implementation. The contract should remain conservative until production behavior is characterized further.

## Current Runtime Model

- Spawn command: `npx -y pi-acp`
- Transport: ACP / JSON-RPC over stdio
- Runtime adapter: `ACPProviderRuntimeAdapter`
- Wire client: `ACPClient`
- UI/event bridge: `ThreadController+ACP`

Soul does not pass a Pi-specific `--resume` flag. Resume is routed through ACP `session/load` when available.

## Identity And Resume

Soul keeps:

- **Kernel session id**: the durable Soul ledger id.
- **Native session id**: Pi's provider-side session id, persisted through `NativeSessionID` hooks when available.

Pi ids may not always be UUID-shaped. Soul therefore preserves the kernel id separately and treats the native id as a provider runtime handle.

## Hydration

Pi sessions are hydrated ledger-first.

Soul prefers `hooks.jsonl` when it contains both user and assistant content. If the ledger is partial, Soul can fall back to `PiTranscriptReader` when the native transcript is discoverable.

For reopen-and-continue flows, Soul should preserve the kernel session id and avoid splitting the ledger when Pi rotates or remints native session ids.

## Rendered Capabilities

Pi streams through the generic ACP renderer.

Rendered or tracked surfaces include:

- User and assistant message chunks
- Reasoning/thought chunks when emitted
- Tool calls and tool-call updates
- Plans
- Available command updates
- Session load replay chunks
- Permission and cancellation flow through the generic ACP runtime

## Non-Goals

Soul Desktop does not assume Pi has the same persistence guarantees as Claude or Gemini.

The following remain outside the provider contract unless observed and explicitly wired:

- Pi-private transcript routing beyond the implemented reader
- Pi terminal UI affordances
- Undocumented `pi-acp` flags
- Resume behavior not represented by ACP or the Soul ledger

