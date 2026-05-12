# Cross-Surface Session Lifecycle — Edge Case Matrix

_Status: draft. Owner: Soul-Desktop. Related: SOUL-SOUL-004 (cross-namespace UUID mapping), `docs/session-model-redesign.md`._

This doc enumerates every realistic combination of (where a session was born, where it gets resumed, what state survives on disk) so we can audit which combinations work today, which fail destructively, and which need new mechanism. Goal: stop fixing resume bugs reactively, one symptom at a time.

---

## 1. The two UUID namespaces

The whole problem starts here.

- **Kernel UUID** — what the Soul kernel writes into `~/soul_registry/sessions/<project>/<UUID>/hooks.jsonl`. The directory name *is* this UUID. Soul-Desktop's sidebar surfaces it.
- **Agent UUID** — what the agent (Claude / gemini-cli / pi-acp) minted internally and stored its own transcript under.

These are equal *only* when the spawn coordinated them. They diverge silently otherwise.

| Source of spawn                          | Kernel UUID written? | Agent UUID written? | Same UUID? |
|------------------------------------------|----------------------|---------------------|------------|
| Soul-Desktop ACP `session/new`           | yes (we adopt agent UUID) | yes | **yes** |
| Soul-Desktop ACP `session/load` resume   | yes (already same)   | already exists      | yes |
| Terminal wrapper sets `SOUL_SESSION_ID`  | yes                  | yes (uses env)      | **yes** |
| Terminal, no wrapper / no env            | yes (kernel mints)   | yes (agent mints, independent) | **no** |
| External IDE, no Soul integration        | no                   | yes                 | n/a — invisible to Soul |
| Direct `claude` / `gemini` with kernel-injected env | yes | yes (uses env)      | yes |

The **`NativeSessionID` hook** is the bridge. When Soul-Desktop spawns, we write an event into `hooks.jsonl` mapping `kernel_uuid → agent_uuid` (currently identity-mapped because they agree). For sessions where they diverged, no such hook exists.

`ThreadController.loadSession` resolves:
```swift
let nativeId = SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid)
let resumeId = nativeId ?? sid
```

If no mapping exists → we send the kernel UUID → agent says "Resource not found." Most cross-surface failures collapse to this one root cause.

---

## 2. Surfaces (origin × resume)

**Origin surfaces** (where a session can be born):

| Code | Surface                                            |
|------|----------------------------------------------------|
| O1   | Soul-Desktop, ACP `session/new`                    |
| O2   | Terminal `claude` (with kernel wrapper)            |
| O3   | Terminal `claude` (no wrapper / direct binary)     |
| O4   | Terminal `g` (gemini-cli, with kernel wrapper)     |
| O5   | Terminal `g` (no wrapper / direct binary)          |
| O6   | Terminal `pi` (with kernel wrapper)                |
| O7   | Terminal `pi` (no wrapper)                         |
| O8   | External IDE integration (Cursor/VS Code Claude)   |

**Resume surfaces** (where a session can be clicked / `--resume`'d):

| Code | Surface                                                                |
|------|------------------------------------------------------------------------|
| R1   | Soul-Desktop sidebar — live row (no finalize JSON)                     |
| R2   | Soul-Desktop sidebar — finalized row (has `<UUID>.json`)               |
| R3   | Terminal `claude --resume <uuid>`                                      |
| R4   | Terminal `g --resume <uuid>`                                           |
| R5   | Terminal `pi --resume <uuid>`                                          |

---

## 3. Per-session state shapes

A row in the sidebar can be in any of these states. The matrix in §4 references these.

| Code | State                                                                                                |
|------|------------------------------------------------------------------------------------------------------|
| S0   | Healthy: hooks.jsonl + agent transcript + (optional) NativeSessionID hook                            |
| S1   | Soul UUID exists, agent file exists, **no NativeSessionID hook** (the divergence case)               |
| S2   | Soul UUID exists, **agent file deleted** (agent's periodic cleanup ran)                              |
| S3   | Soul UUID exists, agent file is a **metadata-only stub** (destructive-fallback aftermath)            |
| S4   | Soul UUID exists, agent file exists, but **cwd mismatch** (spawn cwd ≠ original cwd, basename or encoded path)|
| S5   | Soul UUID exists, agent file exists, **finalized JSON sibling present** (R2 candidate)               |
| S6   | hooks.jsonl exists but has no user/assistant content (crash residue or kernel-only ledger fragment)  |
| S7   | hooks.jsonl exists, kernel-only ledger (SESSION_START + tool events), **no Soul-Desktop UserPrompt** |

---

## 4. The matrix

For each (origin, current state, resume target), what happens today and what *should* happen.

### Origin O1 — Soul-Desktop ACP spawn

| State | Resume R1 (live row)   | Resume R2 (finalized) | Resume R3/R4 (terminal --resume) |
|-------|------------------------|-----------------------|-----------------------------------|
| S0    | ✅ load + replay        | ✅ load + replay       | ✅ matches by UUID                 |
| S2    | ❌ hard error (gemini), graceful re-render (Claude) | ❌ same | ❌ "session not found"             |
| S3    | row hidden by `isResumableGeminiChatFile` (today) | n/a — only live rows go stub | ❌ |
| S4    | ❌ load fails (basename/encoded-path mismatch) — currently no detection | ❌ same | ❌ |
| S5    | n/a — finalized rows are R2 by definition | ✅ resume works | ✅ |

**Gap**: S4 (cwd mismatch) is the only quiet failure here. Need a probe that compares current spawn cwd to the cwd recorded in the original hooks ledger before attempting load. If they differ, refuse to load with a clear "this session was authored in <other-cwd>, click reroots" affordance.

### Origin O2/O4/O6 — Terminal *with* wrapper (`SOUL_SESSION_ID` env)

Kernel + agent agree on UUID via env injection. Effectively same as O1 from Soul-Desktop's perspective.

| State | R1/R2                                                  | R3/R4/R5                         |
|-------|--------------------------------------------------------|----------------------------------|
| S0    | ✅ load + replay (NativeSessionID hook usually written by wrapper) | ✅ |
| S1    | ❌ no bridge — load fails, identity-mapped UUID rejected | depends on agent: Claude resumes, gemini may not |
| S2/S3 | ❌ same as O1                                           | ❌ |
| S4    | ❌ same as O1                                           | ❌ |
| S6    | row should be hidden (`origin != .desktop` filter)     | n/a |
| S7    | row hidden today; ledger shape is `.terminal`         | possible via terminal --resume   |

**Gap**: S1 with wrapper is rarer but happens when the wrapper sets `SOUL_SESSION_ID` but the agent doesn't honor it (older versions). Need: at session end, write a `NativeSessionID` mapping into the wrapper's hooks ledger so future loads from Soul-Desktop bridge correctly.

### Origin O3/O5/O7 — Terminal *without* wrapper

This is the most painful class. Kernel may know nothing about the session, *or* knows about it but never minted a matching UUID.

| State | R1 (live row in sidebar)                                | R3/R4/R5 (terminal --resume) |
|-------|---------------------------------------------------------|-------------------------------|
| —     | Session probably **doesn't appear in sidebar at all** because there's no hooks.jsonl with `.desktop`-shape | ✅ works in own terminal |

These sessions live entirely in the agent's persistence (`~/.claude/projects/…`, `~/.gemini/tmp/.../chats/`) but never get a Soul registry entry. They're invisible to Soul-Desktop today.

**Gap (SOUL-SCAN-001)**: a one-shot importer that walks each agent's persistence dir, fabricates a hooks.jsonl skeleton (SESSION_START + minimal Title from first user prompt), and writes a `NativeSessionID` mapping. After running once per project, terminal-only sessions become first-class sidebar rows.

### Origin O8 — External IDE (no Soul integration)

Same as O3/O5/O7 — invisible to Soul until imported. Out of scope unless we add explicit IDE adapters.

---

## 5. Per-agent quirks that don't generalize

Worth keeping in front of mind, in addition to the matrix.

**Claude**
- Persistence: `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`. `encoded-cwd` = `cwd.replacingOccurrences(of: "/", with: "-")` with a leading `-`.
- Error code for missing session: `-32002` "Resource not found" (structured).
- `session/new` after failed load: mints a *new* UUID, writes to a new file. **Non-destructive** to the original.
- `renderHistoryIfAvailable` can paint the historical transcript from disk into the canvas — read-only continuity.
- Auto-purge: yes, periodic. Old `.jsonl` files get cleaned.

**Gemini-cli**
- Persistence: `~/.gemini/tmp/<basename(cwd)>/chats/session-<TS>-<first8>.{json,jsonl}`. May have a `-<N>` collision suffix on the basename dir.
- Error code for missing session: `-32603` "Internal error", details in `data.details`. Not as cleanly typed as Claude.
- `session/new` after failed load: **reuses the requested UUID** and writes a metadata-only stub. **Destructive** — overwrites original on disk if filenames collide.
- `getAllSessionFiles` filter: skips files lacking user/assistant messages → stubs become invisible to `findSession` → second resume on the same UUID → "Invalid session identifier".
- Compression at `compressionThreshold: 0.2` of context window — older turns get summarized in-place.
- `tokens.{input,cached,thoughts,total}` available per turn for precise context-usage display.

**Pi**
- Persistence: `~/.pi/pi-acp/session-map.json` (index) → `~/.pi/agent/sessions/--<encoded-cwd>--/<TS>_<uuid>.jsonl` (transcript).
- Error semantics: not yet characterized in production.
- ACP `loadSession` capability: untested. We currently use CLI `--resume` flag as the resume path for Pi.
- agentMatch / agentHasSession: **no Pi case implemented**. Pi rows never get `liveProvider` tagged, so they fall through `default: return harness` in `AppShell.loadSession`.

---

## 6. Defensive mechanisms in place today

| Mechanism                                                            | Protects against                       |
|----------------------------------------------------------------------|----------------------------------------|
| `SoulRegistry.isResumableGeminiChatFile`                             | S3 — hides metadata-only stubs from sidebar |
| `ThreadController.backupAgentChatIfPresent`                          | S3 — pre-load snapshot before any resume |
| Hard-stop instead of `session/new` fallback for gemini-cli           | S3 destructive write                    |
| `agentMatch` cwd scoping (basename + collision suffix)               | S4 false positives where another project's basename matches |
| `detectOrigin` filter (`.desktop` only)                              | S6, S7 — kernel-only ledgers don't render as live rows |
| `firstHookTimestamp` for total session age display                   | UX, not correctness                     |

---

## 7. Recommended new mechanisms (priority order)

1. **`NativeSessionID` backfill (SOUL-SOUL-004)** — on first failed load, scan the agent's transcript dir for a file whose first user prompt matches our hooks ledger's first prompt; record the mapping. One-time cost per orphan; after that resume works for real.
   - Bridges every S1 case.
   - Bridges O2/O4/O6 with stale wrappers.
   - Does NOT bridge S2 (agent purged) or S4 (cwd mismatch).

2. **cwd-mismatch probe** — before attempting `session/load`, compare the spawn cwd to the cwd recorded in the hooks ledger's `SESSION_START`. If different, show an affordance: "this session was authored in `<other-cwd>` — load there?" Refuses the destructive-quiet failure of S4.

3. **Gemini transcript reader** — mirror of `ClaudeTranscriptReader`. When `session/load` fails for gemini, paint the chat JSONL into the canvas as read-only continuity (then `session/new` for any continuation). Matches Claude's degraded-but-usable failure mode.

4. **Terminal-session importer (SOUL-SCAN-001)** — walk `~/.claude/projects/*` and `~/.gemini/tmp/*/chats/` per project, fabricate hooks.jsonl skeletons + `NativeSessionID` mappings for any session not already in the registry. Makes O3/O5 visible.

5. **Pi `agentMatch` + provider routing** — implement Pi's persistence-path probe (`~/.pi/pi-acp/session-map.json`). Without this, Pi cross-harness clicks silently land on the wrong agent.

---

## 7b. Ways past each failure mode (with tradeoffs)

For every failure class in §4, what are the realistic options and what does each cost? Not all paths are mutually exclusive — some compose.

### Failure: **S1 — Soul UUID ≠ agent UUID, no bridge**

| Option | Cost | Completeness | Notes |
|--------|------|--------------|-------|
| **A. Content-match backfill** (#1 in §7) | Medium one-time. ~50 ms per session on first failed click. | High — recovers virtually all S1 cases | Risk: false-positive match if two sessions have identical first prompts. Mitigate: also match on `startTime` window. |
| **B. Manual "this is session X" prompt** | Low engineering, high UX cost | Medium — only works if user knows the agent's UUID | A small dialog: "couldn't resume — paste the agent's UUID if you have it". For power users; most users won't. |
| **C. Maintain a side-channel mapping at spawn time always** | Already done for new Soul-Desktop sessions. Won't help legacy sessions. | High for *new* sessions; zero for legacy | This is what `NativeSessionID` writes already. Just needs to be retroactively applied via A. |
| **D. Treat all cross-surface rows as read-only forever** | Zero engineering | Zero recovery, just honesty | Hides the destructive failure mode but kills the use case. |

**Recommended**: A (content-match backfill) is the right structural move. D is the honest stopgap until A ships — surface a "read-only history, new session for continuation" badge instead of pretending resume might work.

### Failure: **S2 — agent purged its persistence**

| Option | Cost | Completeness |
|--------|------|--------------|
| **A. Replay-as-context from hooks.jsonl** | Medium. Need to reconstruct user/assistant turns from kernel events, ship as system-prompt prefix to a fresh `session/new`. | Partial — agent sees text but it's third-party narrative, not its own memory. Token-expensive. |
| **B. Soul-side transcript archive** | High. Soul-Desktop captures every turn to its own ledger as it streams, independent of agent purge. | Full historical preservation. Doesn't help with already-purged sessions. |
| **C. Just show what we have, refuse load** | Zero engineering | Zero recovery, but no destructive write |

**Recommended**: B is the long-term right answer (we shouldn't depend on the agent's persistence layer for memory durability). A is a stopgap; useful when user explicitly wants to "rehydrate the agent with this conversation."

### Failure: **S3 — metadata-only stub**

Already mitigated by `isResumableGeminiChatFile` (row hidden) + `backupAgentChatIfPresent` (snapshot before any load attempt) + hard-stop on destructive fallback. The only remaining work is offering a recover-from-`.bak` flow if the user wants to manually restore an overwritten file.

| Option | Cost | Completeness |
|--------|------|--------------|
| **A. Auto-restore from `.bak` when stub detected** | Low | High — undoes the destructive write |
| **B. Manual "restore session" command in sidebar context menu** | Low | High — gives user control |

**Recommended**: B. A is too magic; user should know they're restoring from a backup.

### Failure: **S4 — cwd mismatch**

| Option | Cost | Completeness |
|--------|------|--------------|
| **A. Pre-load cwd probe** (#2 in §7) | Low | High |
| **B. Spawn with the original cwd, ignore current project.path** | Medium. Need to plumb a per-session-spawn-cwd override through ACPProviderSpawn. | High |
| **C. Multi-cwd lookup in agentMatch** — try every basename variant we've seen | Medium. Risk of false-positive matches. | Medium |

**Recommended**: A + B together. Probe first to detect, then offer to re-spawn at the recorded cwd.

### Failure: **S6/S7 — kernel-only ledger, no agent record**

These sessions are sidebar-noise — they never had an agent transcript to begin with (crash residue, ledger fragments, or kernel-only events from an aborted spawn). Already filtered by `detectOrigin != .desktop`.

| Option | Cost | Completeness |
|--------|------|--------------|
| **A. Reaper script** that GCs hooks dirs older than N days with no agent file | Low | High |
| **B. Show under a separate "archived/unresolved" sidebar group** | Medium UI | Honest — user sees they exist but knows they're not resumable |

**Recommended**: A as a kernel-side hygiene job. B if we want to preserve ledger evidence for post-mortems.

### Failure: **Pi entirely** (no agentMatch case)

| Option | Cost | Completeness |
|--------|------|--------------|
| **A. Implement Pi agentMatch** via `~/.pi/pi-acp/session-map.json` lookup (#5 in §7) | Low (~50 lines) | High for the detection side |
| **B. Verify pi-acp `loadSession` capability** and route through ACP if supported | Medium — needs runtime test against real pi-acp | High — would put Pi on equal footing with Claude/gemini |
| **C. Continue using `--resume` CLI flag, just route correctly** | Low | Medium — works for new spawns but no history replay in canvas |

**Recommended**: A first (small, contained); B as a follow-up to bring Pi to full parity.

---

## 7c. Summary table — "what gets past each failure"

| Failure class      | Cheapest recovery                   | Best recovery                              | Recovers data? |
|--------------------|--------------------------------------|--------------------------------------------|----------------|
| S1 divergent UUIDs | Read-only history (Claude does it)  | Content-match backfill + write NativeSessionID | Yes |
| S2 agent purge     | Read-only history if Soul archived  | Soul-side independent transcript           | Yes if archived |
| S3 stub overwrite  | Hide the row (done today)           | Restore from `.bak`                        | Yes if backup ran |
| S4 cwd mismatch    | Refuse + tell user                  | Re-spawn at recorded cwd                   | Yes |
| S6/S7 kernel-only  | Filter from sidebar (done today)    | Reaper + archive group                     | No (no data existed) |
| Pi-everything      | Treat as new session                | Implement Pi agentMatch + verify loadSession | Yes |

---

## 8. Open questions

- Should sessions that fail to resume be auto-archived after N attempts so they stop cluttering the sidebar? Or always visible with an "unavailable" badge?
- Where should we surface the "this is read-only, your reply will start a fresh session" affordance — banner above the canvas, or just at the bottom near the composer?
- Do we ever want a "fork from this session" action that *copies* the historical transcript into a fresh session as system context? Useful for branching but token-expensive.
- For finalized rows (R2 + S5), is the resume contract different from live rows? Today we treat them the same; possibly we should treat finalized rows as fork-only (no resume attempt) since the session is canonically closed.

---

## 9. Next step

Walk this doc end-to-end with the user, agree on:
- Which gaps in §4 are actually load-bearing today vs theoretical
- Which mechanisms in §7 to scope as proper tasks
- Whether the "cross-surface session" concept needs first-class UX (badge on rows, separate sidebar group) or just better error handling
