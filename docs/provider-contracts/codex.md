# Codex Provider Contract

Soul Desktop treats Codex as a provider engine exposed through `codex app-server`, not as an embedded copy of Codex Desktop.

This boundary is intentional. Soul owns the desktop shell, durable session identity, ledger replay, project scoping, slash-command expansion, and provider-neutral transcript rendering. Codex supplies a live turn engine through the protocol surface it exposes.

## Current Runtime Model

The Codex provider uses a dedicated runtime path instead of the generic ACP session lifecycle.

- Spawn command: `codex app-server`
- Transport: JSON-RPC over stdio
- Runtime adapter: `CodexProviderRuntimeAdapter`
- Wire client: `CodexClient`
- UI/event bridge: `ThreadController+Codex`

The supported app-server calls are currently:

- `initialize`
- `initialized`
- `thread/start`
- `turn/start`
- `turn/interrupt`

Codex does not participate in Soul's ACP `session/load` path. `CodexProviderRuntimeAdapter.loadSession` explicitly rejects that operation because Codex app-server does not expose the same resume contract as the ACP providers.

## Identity Split

Soul keeps Codex identity split into two layers:

- **Kernel session id**: the durable Soul session id used for `hooks.jsonl`, sidebar rows, replay, finalize matching, and project-scoped history.
- **Codex thread id**: the native app-server thread id used when sending RPC calls to Codex.

The kernel session id is the source of truth. The Codex thread id is a provider-side runtime handle.

This prevents a freshly-created Codex thread from clobbering the existing Soul ledger id when a user reopens an older session. New turns continue writing into the same Soul session directory even when the Codex native thread changes.

## Resume And Hydration

Codex sessions are hydrated ledger-first.

On open, Soul reads the kernel ledger from:

```text
~/soul_registry/sessions/<project>/<sid>/hooks.jsonl
```

That ledger is used to paint the visible transcript. Soul does not currently read a Codex-owned transcript file for historical rendering.

When the user sends a new prompt after reopening a Codex session, Soul starts or reuses a Codex app-server thread for the live turn while preserving the original kernel session id. In practice, this means session continuity is owned by Soul's ledger and preamble/resume machinery, not by Codex Desktop's private state.

## Rendered Codex Capabilities

Soul translates Codex app-server notifications into provider-neutral `ThreadItem` rows.

Currently rendered or tracked surfaces include:

- Assistant message deltas
- Reasoning summaries
- Command execution rows
- Live command output
- File-change rows and diffs
- MCP tool calls
- Web search rows
- Image view rows
- Plan updates
- Token usage updates
- Context compaction status
- Review-mode status
- Connection retry and transport warnings
- Command approval requests

Streaming text and reasoning follow the shared streaming UI invariant: deltas accumulate outside the observed transcript graph, the UI receives only a bounded throttled preview, and final markdown is materialized into transcript rows at completion boundaries. Command output may continue to update tool rows because it is rendered as tool state, not assistant transcript text.

## Non-Goals

Soul Desktop does not guarantee Codex Desktop feature parity.

The following are out of scope unless Codex app-server exposes them directly or Soul reconstructs them through its own ledger/runtime model:

- Codex Desktop-only UI affordances
- Codex Desktop private session state
- Provider-private transcript formats
- Native Codex Desktop resume behavior
- Internal Codex Desktop permission UI
- Features that depend on Codex Desktop's app runtime rather than the app-server protocol

## Design Rule

Treat Codex as a protocol-visible provider subset.

If a Codex feature is exposed by `codex app-server`, Soul may map it into the provider-neutral runtime and UI. If it is only available inside Codex Desktop, Soul should not assume it exists. The correct fallback is either:

- preserve the behavior through Soul's ledger and session model, or
- document the unsupported capability explicitly.
