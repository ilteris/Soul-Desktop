# Soul-Desktop — Audit Brief

This document is a reference for an auditor reviewing the Soul-Desktop codebase.
It is self-contained: read it cold, then use it to scope your audit. Cite files
as `path:line` so findings are trivially navigable.

---

## 1. What Soul-Desktop is

A native macOS SwiftUI app that hosts coding-agent chat sessions for three
providers behind one UI: **Gemini-CLI**, **Claude Code**, and **Pi**. It speaks
to each agent over the **Agent Client Protocol (ACP)** — a JSON-RPC stdio
protocol the provider's CLI implements as a child process. The app then layers
a project-keyed **session registry** on top so chats are persistent, replayable,
finalizable, and resumable across surfaces (terminal ↔ desktop).

It is **not** a wrapper around the agent CLIs' interactive TUIs. It spawns the
agent's ACP server mode and drives it directly.

The companion system is **Soul OS** — a personal architecture layer that lives
in `~/dotfiles/soul/` (config) and `~/soul_registry/` (state). Soul-Desktop is
one Soul OS surface; the other is the terminal harness (Gemini/Claude CLI with
Soul middleware hooks). Both write to the same registry.

---

## 2. High-level architecture

```
┌──────────────────────────────────────────────────────────────┐
│  SwiftUI views (AppShell, SidebarView, ThreadView, …)        │
│                          │                                   │
│                  ThreadController       ← @MainActor owner   │
│                          │                                   │
│                     ACPClient           ← JSON-RPC client    │
│                          │                                   │
│                    ACPTransport         ← line-delimited     │
│                          │                                   │
│                ACPProviderSpawn         ← child Process      │
│                          │                                   │
│   ┌──────────────────────┼──────────────────────┐            │
│   │ gemini --experimental-acp                   │            │
│   │ npx @agentclientprotocol/claude-agent-acp   │            │
│   │ pi acp                                      │            │
│   └─────────────────────────────────────────────┘            │
│                                                              │
│              SoulRegistry  ← ~/soul_registry filesystem ops  │
│              HooksReader   ← hooks.jsonl streaming           │
└──────────────────────────────────────────────────────────────┘
```

**Process model**: one ACP child per active thread. A thread can spawn,
prompt, cancel, and tear down independently. AppShell owns the list of
ThreadControllers.

**State**: split between transient `@Observable` view-model state
(`ThreadController.items`, etc.) and durable on-disk state in
`~/soul_registry/sessions/<project_key>/<session_uuid>/hooks.jsonl`. The
disk file is append-only, line-delimited JSON; both the kernel (Python) and
the desktop app write to it.

---

## 3. File map (Swift, by responsibility)

### 3.1 App shell + entry
- `Soul-Desktop/Soul_DesktopApp.swift` (19) — SwiftUI `@main`.
- `Soul-Desktop/AppShell.swift` (723) — three-pane layout, thread switching,
  project selection, session-load dispatch, harness picker.

### 3.2 ACP layer (`Soul-Desktop/ACP/`)
- `ACPProtocol.swift` (255) — typed envelopes for JSON-RPC messages
  (Initialize, NewSession, LoadSession, Prompt, SessionUpdate, ToolCall, …).
- `ACPTransport.swift` (93) — line-buffered framing over Process stdio.
- `ACPClient.swift` (295) — request/response correlation, notification
  fan-out via `Event` enum, cancel + permission-mode plumbing.
- `ACPProviderSpawn.swift` (142) — child-process launch per provider; `which`
  resolution (module-visible since `-006` LLM-title work).
- `SoulHydration.swift` (143) — runs `soul_*_harness.py` to inject the active
  project's Soul context into the agent's system prompt at session start.
- `ACPSmokeView.swift` (350) — developer-only diagnostics surface; check
  whether it's reachable from production UI.

### 3.3 Thread + canvas
- `ThreadController.swift` (1159) — single-thread owner: items list, ACP
  send/cancel, tool-call lifecycle, streaming coalescing, stall watchdog,
  session/load + content-match backfill retry, LLM-title generation.
- `ThreadView.swift` (983) — render of the items list (LazyVStack, anchor
  tracking, inline Edit/Write diff cards, side-by-side diff).
- `ComposerView.swift` (837) — input box, slash-command expansion, branch
  chip, permission-mode picker.
- `MarkdownView.swift` (429) — markdown→AttributedString.
- `WorkingSetPanel.swift` (92) — files touched this turn.

### 3.4 Sidebar + project model
- `SidebarView.swift` (770) — projects pane + chats pane; live-session
  surfacing, worktree sub-grouping, context menu (Open / Replay /
  **Repair session link**).
- `NewProjectWizard.swift` (313) — kebab key, path, pillar, tier picker.
- `RegistryWatcher.swift` (47) — `DispatchSource.makeFileSystemObjectSource`
  to refresh sidebar on hooks.jsonl writes.

### 3.5 Registry + readers
- `SoulRegistry.swift` (967) — **the single biggest file**; reads/writes
  `~/soul_registry/`, classifies sessions (desktop/terminal/unknown),
  agent-match heuristics, NativeSessionID backfill content-match scanner,
  Title sniff, POSIX-O_APPEND-safe `appendHook`.
- `HooksReader.swift` (183) — streaming reader for replay.
- `ClaudeTranscriptReader.swift` (183) — render legacy Claude transcripts
  read-only when session/load isn't possible.

### 3.6 Replay
- `ReplayController.swift` (187), `ReplayView.swift` (189),
  `PlaybackBar.swift` (172) — chapter grouping, speed slider, real-time
  pacing from hooks.jsonl event timestamps.

### 3.7 Review (git)
- `ReviewPanel.swift` (425), `GitReview.swift` (322) — diff parser, status,
  per-file stage/unstage.

### 3.8 Settings + design
- `SettingsView.swift` (849) — 12-pane Codex-style; real-wired panes:
  General, Appearance, MCP servers, Hooks, Advanced (stall budgets).
- `DesignSystem.swift` (144) — `SoulColor`, `SoulFont`, `SoulIcon`,
  `@AppStorage`-backed accent color.

### 3.9 Misc
- `Providers.swift` (81) — `Provider` enum, stall budgets per provider.
- `PermissionMode.swift` (58) — default / auto-review / full-access.
- `SkillsRegistry.swift` (65), `TerminalPanel.swift` (251),
  `SoulTraceChip.swift` (110), `ToolFailureLog.swift` (38),
  `ContextUsage.swift` (209), `HeroEmptyState.swift` (55).

---

## 4. External contracts

### 4.1 ACP child processes
- **Gemini**: `gemini --experimental-acp` (or whatever the resolver picks).
- **Claude**: `npx -y @agentclientprotocol/claude-agent-acp`.
- **Pi**: `pi acp`.

ACP is JSON-RPC 2.0 over line-delimited stdio. Notable shapes: `session/new`,
`session/load`, `session/prompt`, `session/cancel`, `session/update`,
`session/request_permission`. Errors of interest: `-32602` "Invalid session
identifier" (triggers backfill).

### 4.2 Filesystem registry
- `~/soul_registry/PROJECTS.json` (legacy) → `~/dotfiles/soul/config/PROJECTS.json`
  (authoritative since 2026-05-03 per SOUL-AUDIT-002).
- `~/soul_registry/sessions/<project>/<uuid>/hooks.jsonl` — live ledger.
- `~/soul_registry/sessions/<project>/<uuid>.json` — finalized record sibling.
- `~/soul_registry/tasks/<project>/<TASK-ID>.json` — task definitions.

### 4.3 Agent native transcripts (read-only by the desktop)
- Gemini: `~/.gemini/tmp/<basename-of-cwd>/chats/session-*.{json,jsonl}`.
- Claude: `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
- Pi: `~/.pi/pi-acp/session-map.json` (direct kernel↔agent map).

### 4.4 Soul harness (Python)
- `~/dotfiles/soul/harnesses/soul_gemini_harness.py`
- `~/dotfiles/soul/harnesses/soul_claude_harness.py`
- Pi: via `soul-orchestrator` extension.

Invoked from `SoulHydration.swift`; output is injected into the agent's
opening system prompt.

---

## 5. Session lifecycle (read this before auditing session code)

A first-class diagram lives in `docs/session-lifecycle-matrix.md`. Short version:

1. **Spawn**: ACPProviderSpawn launches the child; ACPClient initializes.
2. **Hydration**: SoulHydration runs the harness; agent system prompt now
   includes the active project's identity + soul context.
3. **NewSession**: agent mints its native UUID. Soul-Desktop stores its own
   kernel UUID and writes an identity-mapping `NativeSessionID` hook
   (`kernel_uuid → kernel_uuid`).
4. **Prompts**: each `session/prompt` writes a `UserPrompt` hook with
   timestamp + text. Agent replies stream as `session/update`
   notifications.
5. **First-turn title** (since `-006`): after first reply lands, spawn
   `claude -p` subprocess to generate a 3-5 word title, write `Title` hook
   with `source: "llm"`. Falls back to active-session prompt if `claude`
   isn't on PATH.
6. **Cancel / stall**: stall watchdog ticks every second; emits
   `StallDetected` hook when budget exceeded, auto-cancels at the 5-min
   ceiling.
7. **Resume**: AppShell.loadSession asks ACP to `session/load <kernel-uuid>`.
   Identity mapping means the agent looks up its own transcript by the same
   UUID. **Legacy sessions** (started in terminal or before NativeSessionID
   was wired) fail this; the catch path invokes
   `SoulRegistry.backfillNativeSessionID` which content-matches the first
   user prompt against agent-native transcripts, writes the real mapping,
   and retries once. See §6.
8. **Finalize** (Python-side, not desktop): `/finalize` slash command runs
   the kernel which writes the `<uuid>.json` summary.

---

## 6. Cross-namespace session resume (the trickiest area)

Two separate UUID namespaces — Soul kernel UUIDs vs agent-native UUIDs —
caused legacy sessions to fail `session/load`. The fix has multiple layers;
audit each:

1. **Identity mapping at spawn** (`ThreadController.swift` around session
   creation): writes `NativeSessionID` with `nativeId == sessionId` so the
   common case skips backfill entirely.
2. **Content-match scanner**
   (`SoulRegistry.backfillNativeSessionID`, ~line 621):
   - 20-char floor on the needle (avoid false matches on "hi"/"ok").
   - 500 candidate-file cap, 64 KB read budget per file.
   - Whitespace normalization on both sides.
   - Ambiguity guard: emits `BackfillAmbiguous` hook with both UUIDs.
   - **.json fallback**: when truncated JSON fails to parse, regex-extracts
     `sessionId` from the head + best-effort prompt salvage. Critical for
     11MB+ transcripts. Audit the regex (`readGeminiChatHeader`).
3. **Failed-load retry** (`ThreadController.loadSession` catch path):
   detects `Invalid session identifier`, calls backfill, retries once.
4. **User-triggered repair** (`SidebarView.swift:213-220`, helpers below):
   contextMenu "Repair session link" runs backfill off-main.

**Audit questions for this area**:
- Can the regex fallback overmatch? (UUIDv4 pattern is constrained.)
- What happens if two candidates have identical first prompts that exceed
  the 20-char floor — is the ambiguity hook actually surfaced to the user
  anywhere?
- Does the user-rename path (when it ships) collide with `source: "llm"`
  Title precedence? Today `findTitle` returns first hit.

---

## 7. Concurrency model

- All UI state lives on `@MainActor` (ThreadController, SidebarView).
- Disk I/O is offloaded via `Task.detached(priority: .userInitiated)` —
  search for `Task.detached` to enumerate (sidebar scans, hydration,
  backfill, LLM-title subprocess).
- `appendHook` uses `open(O_WRONLY|O_APPEND|O_CREAT)` + a single `write` so
  the Python kernel and the desktop app can interleave atomic line writes
  without locking.
- Two `nonisolated(unsafe)` caches exist: `SoulRegistry.cache`
  (project-scan cache) and `whichCache` in ACPProviderSpawn. Both are
  guarded by `NSLock`. **Audit**: confirm every read/write goes through
  the lock and that lock release is paired (defer).

---

## 8. Persistence schema (hooks.jsonl)

One JSON object per line. Required fields written by `appendHook`:
- `timestamp` — ISO-8601 microsecond UTC.
- `session_id` — the kernel UUID.
- `event` — discriminator.

Event types Soul-Desktop emits (search for `"event":`):
- `UserPrompt` — `text` field.
- `Title` — `text`, `source` ("llm" since -006).
- `NativeSessionID` — `provider`, `nativeId`, `cwd`, optional `source: "backfill"`.
- `BackfillAmbiguous` — `provider`, `cwd`, `candidates: [uuid]`.
- `StallDetected` — `elapsed`, `provider`.
- Kernel-written events (UserMessage, AgentMessage, AfterTool, etc.) also
  appear; the schema is union of both writers.

**Audit**: check every reader for "what does it do with an unknown event
type" — it should skip cleanly.

---

## 9. Known weak spots / explicit non-goals

- **No XCTest target wired**. The Xcode project has no test scheme. Any
  audit recommendation that demands "add a unit test for X" needs to
  account for this (filing a precursor task to wire XCTest).
- **`-006` LLM titles** (just shipped): graceful fallback when `claude`
  isn't on PATH means feature *appears* to work but silently degrades.
  Audit: should there be a Settings toggle to disable, or a visible
  indicator of which path generated the title?
- **`-022` remaining**: docs/session-lifecycle-matrix.md §7.1 e2e smoke
  not yet written; perf assertion (≤1s for 500 candidates) not codified.
- **Stall watchdog auto-cancel ceiling** (`Providers.swift:73`, default
  300s) is global; might want per-provider tuning.
- **No telemetry on backfill hits/misses** — we don't know if it's helping
  users in the field.
- **Pi history rendering** (`-014`) — not implemented; clicking a Pi
  legacy row is a no-op surface.

---

## 10. Audit scope suggestions

Pick whichever fits the time budget. Cite `file:line` and quote the
problem in your own words.

### A. Quick pass (≤2h)
- Skim §3 file map; spot any responsibilities that bleed across files.
- Read `ThreadController.swift` end-to-end. It's 1159 lines and is the
  single most complex module; identify state-machine corners.
- Verify `SoulRegistry.swift` lock discipline (§7).

### B. Concurrency / data race audit (half day)
- Enumerate every `nonisolated(unsafe)` and `Task.detached`.
- Confirm no `@MainActor` state is mutated from a detached task without
  hopping back via `await MainActor.run`.
- Look for `Sendable` violations in captured closures.

### C. Persistence + cross-process safety (half day)
- Atomicity of `appendHook` writes.
- Reader robustness to partially-written lines (kernel + desktop are
  writing concurrently).
- `RegistryWatcher` debouncing under burst writes.
- What happens when the registry directory doesn't exist / isn't
  writable (locked filesystem, sandbox, etc.).

### D. ACP layer correctness (half day)
- JSON-RPC id correlation under cancellation.
- What happens when the child process dies mid-prompt
  (`session/cancel` vs broken pipe).
- SIGPIPE handling (mentioned in arc notes — "SIGPIPE ignored
  process-wide"; verify).
- Permission-mode propagation when changed mid-turn.

### E. Session resume + backfill (half day)
- All four layers from §6.
- Specifically: regex robustness, ambiguity surfacing, 20-char floor
  rationale, identity-map invariants.

### F. UI / SwiftUI audit (variable)
- LazyVStack anchor restoration (`ThreadView.swift`, in-progress -023).
- Sidebar cache invalidation paths (mtime fast-path stamping).
- Context-menu gating logic in `SidebarView.swift:213` + helpers below.

### G. Security / sandboxing
- Child processes run with the user's full PATH; any path that passes
  user-supplied text to a shell?
- `Process` invocations across the app — confirm none use `/bin/sh -c`
  with interpolated input.
- File reads — any user-controlled paths that aren't normalized?

---

## 11. Out-of-scope for this audit

- Soul OS kernel (Python) — separate review, separate repo
  (`~/dotfiles/soul/kernel/`).
- Agent CLIs themselves (Gemini, Claude, Pi).
- Registry data correctness (the user's actual chats).
- ACP protocol design — it's an external standard.
- Marketing copy / icons / colors.

---

## 12. How to deliver findings

Format each finding as:

```
### <severity>: <one-line title>

**Where**: `path/to/file.swift:LINE`

**What**: <1-2 sentences quoting the actual code if helpful>

**Why it's a problem**: <concrete failure mode, not vibes>

**Suggested fix**: <surgical change, or "investigate" if speculative>
```

Severities: P0 (data loss / crash / security) · P1 (correctness bug
users will hit) · P2 (smell / future trap) · P3 (style / nit).

Aggregate at the top: count by severity, top 3 priorities.

---

## 13. Useful commands

```bash
# Build green check
xcodebuild -scheme Soul-Desktop -configuration Debug build 2>&1 | tail -5

# Recent commit context
git log --oneline -20

# All hook event types the app emits
grep -rn '"event":' Soul-Desktop/ | grep -v ".git"

# All Task.detached call sites
grep -rn "Task.detached" Soul-Desktop/

# All nonisolated(unsafe) state
grep -rn "nonisolated(unsafe)" Soul-Desktop/

# All Process() spawns
grep -rn "Process()" Soul-Desktop/

# ACP error handling
grep -rn "rpcError\|-32602\|Invalid session" Soul-Desktop/
```

---

## 14. Reference docs

- `docs/session-lifecycle-matrix.md` — definitive resume/load state machine.
- `docs/session-model-redesign.md` — historical UUID-namespace context.
- `~/dotfiles/soul/docs/PLAYBOOK.md` — Soul OS operational playbook
  (mostly orthogonal to this audit but useful for context).
- `CLAUDE.md` (repo root) — auto-managed Soul session context;
  treat as input metadata, not source of truth.

---

End of brief. The auditor should feel free to widen scope where the code
demands it, but call out scope expansions explicitly so the user can
re-prioritize.
