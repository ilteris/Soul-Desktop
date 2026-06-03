# Provider Contracts

Soul Desktop treats each agent as a provider runtime with a narrow, explicit contract.

The desktop owns:

- Project selection and routing
- Durable kernel session identity
- Ledger writes and replay
- Sidebar rows and session grouping
- Slash-command expansion where the provider does not own it
- Provider-neutral transcript rendering
- Recovery affordances, stall handling, and queue behavior

Each provider owns only the behavior exposed through its runtime protocol or CLI surface. Provider-native transcripts are useful caches, not Soul's source of truth.

## Providers

- [Claude](./claude.md)
- [Gemini-CLI](./gemini-cli.md)
- [Pi](./pi.md)
- [Codex](./codex.md)

## Shared Design Rule

Provider-specific behavior must be mapped into Soul's provider-neutral runtime contracts before the UI depends on it.

If a feature is exposed through ACP, app-server JSON-RPC, or a documented CLI path, Soul may render or route it. If it only exists inside a provider's private app/runtime state, Soul should either reconstruct it from the kernel ledger or document it as unsupported.

## Streaming UI Invariant

Provider token streams are not transcript rows. While an assistant response is incomplete, text and reasoning deltas must accumulate outside Observation in a stream buffer. The SwiftUI transcript may receive a bounded throttled preview, but preview publishing must pause during active scroll. Only materialize final markdown into `ThreadController.items` at explicit safe boundaries: item completion, turn completion, cancellation, recovery, or provider termination.
