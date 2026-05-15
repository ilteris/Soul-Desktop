# Loadability gate — audit

## What it is

In `AppShell.loadSession(_:)` there is a one-shot guard that runs after
provider routing and before any agent spawn. If a session's on-disk
transcript looks unusable, it short-circuits the click to a recovery sheet
instead of attempting `session/load`:

```swift
let providerSupportsLoadabilityGate = (provider == .claude || provider == .geminiCLI)
if providerSupportsLoadabilityGate, !session.loadable, session.replayable {
    pendingActiveId = nil
    externalLiveSession = session
    return
}
```

`session.loadable` is stamped at `SoulRegistry.allSessions(...)` scan time
by calling `SessionLoadability.canLoadFromDisk(sessionId:project:)`. That
function returns true iff a provider transcript file resolves for the
session id under one of:

- `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`
- `~/.gemini/tmp/<projectKey>(-N)/chats/session-…-<first8>.jsonl(.bak|.corrupt)`

with a non-stub first-line `sessionId` match.

`session.replayable` is true iff `~/soul_registry/sessions/<project>/<sid>/hooks.jsonl`
exists.

The gate fires only when the row is **not loadable** but **is replayable**:
i.e. the kernel ledger has prompts/events recorded but the provider's chat
file is missing, truncated to a stub, or otherwise unparseable. In that
state, attempting `session/load` will fail, and the failure handler will
either spawn a destructively-named fresh session or strand the user in a
new UUID.

## Why the gate exists

Without it, three concrete bad outcomes are reachable on any session whose
on-disk transcript got corrupted (force-quit mid-write), rotated, or never
written.

### 1. Claude: stranded fresh session

`ThreadController.loadSession(id:)` on the `.claude` path tries
`client.loadSession(resumeId)`. On `rpcError`, the fallback chain is:

1. Try `SoulRegistry.backfillNativeSessionID` — content-match the kernel
   ledger's first prompt against agent-side chat files. If a match exists,
   retry `session/load` with the discovered native UUID.
2. If no match: render whatever hooks-ledger history we can via
   `renderHistoryIfAvailable`, then call `client.newSession(cwd:)`.
3. `sessionId` is overwritten with the **new** UUID. The user is now in a
   different session; the prior conversation lives only in the read-only
   history items above the composer.

The bad outcome: a click that the user intended as "continue this chat"
turns into "start a new chat that happens to have the old chat's text
echoed above." The kernel ledger for the original UUID continues to
exist on disk but receives no new hooks. The user's mental model
("I clicked the row, I'm continuing it") diverges silently from reality.

### 2. Gemini-CLI: destructive file overwrite + stranded fresh session

Gemini-CLI's `session/new` fallback under a same-UUID load failure has
been observed to overwrite the original chat file with an empty
228-byte metadata stub. This was documented at
`ThreadController.swift:837-846`:

> Gemini-cli's session/new fallback under a same-UUID load failure is
> destructive (rewrites the chat file with an empty stub). Refuse the
> fallback, surface the backup path...

We mitigate this with `backupAgentChatIfPresent` (copies the file to
`.bak-<epoch>` before any load attempt) and `quarantineCorruptGeminiChat`
(renames the broken live file to `.corrupt-<epoch>` after the fact).
But the user still ends up with a corrupted in-place file and an
unloadable session — and on the second click, the same dance repeats
unless the quarantine has cleared the live file.

### 3. Both: noisy red `session/load rpcError` row in the canvas

Even when the fallback paths technically work, the user sees a wall of
red error text. The gate routes the same situation to a quiet, actionable
sheet ("Replay (read-only)" / "Reveal backup in Finder" / "Start fresh
chat") that explains what happened and offers concrete recovery.

## Why only Claude + Gemini-CLI

The gate's value is "prevent a known-destructive cascade we can predict
in advance." That value only exists when:

1. The provider supports `session/load` at all (we have something to
   "pre-validate").
2. The failure mode of `session/load` is destructive or stranding (a
   silent fresh-session spawn that drops the user into the wrong UUID).
3. We have a `SessionLoadability` probe that can accurately predict the
   failure.

Each provider's actual load path:

### Claude

- Path: `ThreadController.loadSession` → `client.loadSession(resumeId)`
- On rpcError: backfill retry → render hooks history + `client.newSession`
  with a fresh UUID
- Destructive? **Yes** — stranded fresh UUID per case (1) above
- Has probe? **Yes** — `claudeFileExists` in `SessionLoadability`
- **Gate applies.**

### Gemini-CLI

- Path: `ThreadController.loadSession` → `client.loadSession(resumeId)`
- On rpcError: backfill retry → **refuse** newSession fallback → set
  `pendingRecovery` → recovery sheet
- Destructive? **Yes** — direct file overwrite by gemini's own fallback
  if we ever let `session/new` fire; also lands at the recovery sheet
  AFTER spawning the agent process for no reason
- Has probe? **Yes** — `geminiFileHasContent` walks `<projectKey>(-N)/chats/`
  including `.bak` / `.corrupt` siblings
- **Gate applies.** Plus: gating earlier means we don't spawn gemini at all
  for an unloadable row, saving the user from seeing the rpcError flicker
  through the canvas before the sheet covers it.

### Codex

- Path: `ThreadController.loadSession` (`.codex` case) →
  `spawnAndInitializeCodex()` + status row "Codex session resume not yet
  wired — opened as a fresh thread." No `session/load` call.
- Destructive? **No.** Every codex click is *already* a fresh thread by
  design. There's nothing to gate against.
- Has probe? **No.** Codex rollouts aren't yet rendered, so
  `SessionLoadability.canLoadFromDisk` has no codex branch. Asking it
  returns `false` for every codex session.
- **Gate must NOT apply.** Otherwise every codex row routes to the wrong
  recovery sheet, even on a healthy in-memory codex session the user just
  started seconds ago. This was the `"hi codex"` regression that
  triggered this audit.

### Pi (pi-native ACP)

- Path: `ThreadController.loadSession` (`.pi` case). With a recorded
  nativeId → `spawnAndInitialize(skipNewSession: true, resumeSessionId:
  nativeId)` (the agent boots with `--resume <id>` on its CLI). Without
  → `renderHistoryIfAvailable` + `spawnAndInitialize(skipNewSession:
  false)` (fresh).
- Destructive? **No.** Pi-CLI's `--resume` failure mode prints an error
  and exits; it does not overwrite files. The fresh-spawn fallback is
  benign.
- Has probe? **No.** Pi's session-file layout isn't covered by
  `SessionLoadability`; the probe always returns false for pi sessions.
- **Gate must NOT apply.** Same reason as codex: gating without a probe
  routes every desktop-spawned pi session to the recovery sheet.

## Summary table

| Provider   | `session/load` exists? | Failure destructive? | Probe coverage | Gate applies |
|------------|------------------------|----------------------|----------------|--------------|
| Claude     | Yes                    | Strand (new UUID)    | Yes            | **Yes**      |
| Gemini-CLI | Yes                    | Overwrite + strand   | Yes            | **Yes**      |
| Codex      | No (fresh-only)        | n/a                  | No             | **No**       |
| Pi         | Via CLI --resume       | Benign error         | No             | **No**       |

## What changes if we extend `SessionLoadability` to codex/pi later

Two follow-ons unlock turning the gate on for those providers:

1. **Codex Phase 3 (rollout rendering)** — once codex sessions can hydrate
   from a `.rollout` file on disk, `SessionLoadability` gains a codex
   branch and the gate gains value (we can predict whether the rollout
   exists before spawning codex). The `providerSupportsLoadabilityGate`
   bool becomes `[.claude, .geminiCLI, .codex].contains(provider)`.

2. **Pi transcript reader** — analogous; if/when we render pi sessions
   from disk, add a pi probe and include `.pi` in the gate.

Neither is currently planned because rendering codex/pi sessions from
disk isn't blocked on anything but design work.

## Bug history

- **First introduced**: 2026-05-14, in response to the
  `"Visibility Led Strategy Shift"` rpcError. Session was Gemini-CLI;
  its chat file was a 228-byte metadata stub; click cascaded into a red
  rpcError row.
- **First regression**: same day, `"hi codex"` row routed to the
  "Session is running elsewhere" sheet because codex was inside the gate.
  Fixed by `providerSupportsLoadabilityGate` restricting to
  `.claude` + `.geminiCLI`.
- **Pending follow-ups**:
  - When codex rollout rendering ships, revisit gate scope.
  - The sheet's wording was also split here: terminal-origin rows say
    "Session is running elsewhere"; non-loadable rows say "Session can't
    be loaded here" with copy explaining the transcript is missing.
