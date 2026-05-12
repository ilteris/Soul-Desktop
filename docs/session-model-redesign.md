# Session Model Redesign

**Status:** Draft — not yet approved.
**Author:** Claude (audit pass, 2026-05-11)
**Scope:** SoulSession, ThreadController, ReplayController, AppShell multiplex, sidebar click semantics, message-filter boundary.

This document grew out of a user observation: *"this session thing is too strange, it needs a complete overhaul of thinking."* It's preceded by a code audit of the current architecture; references throughout are file:line into `/Users/ilteris/Code/Soul-Desktop/Soul-Desktop`.

The goal is not to ship a refactor. The goal is to **agree on a target model** before any more patches land on the live one.

---

## 1. The complaints

Two recurring problem reports drove this:

1. **Sessions misbehave on click.** Clicking a sidebar row sometimes loads the wrong session, jumps to a different one, or appears to do nothing. The behavior is hard to predict without reading the code.
2. **Protocol scaffolding leaks into the chat.** Claude-injected XML tags (`<local-command-caveat>`, `<task-notification>`, etc.) render verbatim as user-message bubbles. Each new tag has required a separate regex bolt-on in the same function — the second time we did this, the smell was loud.

Both surfaced through the same code paths. Both are symptoms of the same deeper issue: **`SoulSession` is doing too many jobs.**

---

## 2. Where we actually are

### 2.1 `SoulSession` (the overloaded type)

`SoulSession` (SoulRegistry.swift:27-58) has 14 fields. Five distinct concerns are mashed together:

| Concern | Fields |
|---|---|
| Identity | `id`, `project` |
| Disk state | `isLive`, `isDirty`, `status` |
| Origin | `origin`, `source`, `liveProvider` |
| Routing | `worktreePath` |
| Content cache | `timestamp`, `intent`, `summary`, `eventCount`, `promptCount` |

Each row in the sidebar (live or chat) is a `SoulSession`. So is the row in `liveSessions` cache. So is the value passed to `loadSession`. Every code path that touches a session has to know which fields mean something for that path — and they don't all agree.

Specific shadows of this:
- `source` is set at /finalize time (kernel). `liveProvider` is set at row-build time (Soul-Desktop). They serve the same semantic question ("which agent owns this UUID?") but only one is populated at a time, and `AppShell.loadSession` (AppShell.swift:92-108) has a fall-through chain to handle both.
- `origin` is meaningful for live rows only. Finalized rows get `.unknown` by default. Downstream readers have to know to ignore it.
- `worktreePath` was added to handle a specific routing edge case (terminal-spawned worktree sessions), but only one call site reads it (AppShell.swift:128-131). The field rides along on every row regardless.

### 2.2 The disk invariant nobody documented

`SoulRegistry.liveSessions()` line 263 filters out any session directory that has a `.json` sibling:
```swift
if jsonNames.contains(entry) { return nil }
```
So **a UUID is either live or finalized — never both** in the sidebar. This is a real invariant. It means:
- The "Shipping Tr…" + "live · 11810…" rows the user clicked on are **different UUIDs**, not two views of the same one
- The multiplexer collision theory (same UUID in both lists ⇒ click chat surfaces live) is wrong; the on-disk invariant makes that impossible
- The actual bug must be elsewhere — likely in how `liveSessions()` filters (origin gating, `agentMatch`, the recent thrashing) or in the user's mental model of what they're clicking

The audit makes me less confident the bug the user reported is the bug we think it is. It may be a separate confusion — worth a fresh investigation, not a session-model overhaul justification.

### 2.3 The multiplexer (`AppShell.threads`)

The dict is keyed by `ThreadController.id` (a per-controller UUID, not the session id). De-duplication is by sessionId match (AppShell.swift:114):
```swift
if let existing = threads.values.first(where: { $0.sessionId == session.id }) {
    harness = existing.provider
    setActiveThread(existing.id)
    return
}
```

This is correct for the case it was designed for (don't spawn two agents for the same session). It produces a confused-feeling experience only when the user *expects* two different views of the same session — but per §2.2, the on-disk invariant prevents that scenario from arising via the sidebar lists. There is no current code path that legitimately produces "two sidebar rows for the same UUID."

### 2.4 The classifier (`classifyLocalCommand`)

This function (ThreadController.swift:598-653) is called from exactly one place: the `userMessageChunk` case during ACP session-load replay (line 566). It strips Claude protocol scaffolding so the XML doesn't render as a user bubble.

It is **brittle by construction**:
- Per-tag regex bolted on each time a new tag is observed in the wild (`<local-command-caveat>`, `<local-command-stdout|stderr>`, `<task-notification>`)
- One call site means any other ingress path that landed Claude-wrapped text in `items` would render raw (e.g., snapshot hydration of a finalized JSON whose intent/summary field captured the wrapper; live `send()` accidentally fed wrapped text)
- No coverage for `<system-reminder>`, `<bash-stdout>`, slash-command framing, or any tag Anthropic adds tomorrow

This is the same regex pattern applied twice. The third time will be the third sin.

### 2.5 Live-row filtering: years of accreted policy in one function

`liveSessions()` (SoulRegistry.swift:236-316) currently does:
1. Scan directories
2. Drop dirs with .json sibling (§2.2 invariant)
3. Sort by mtime, drop expired
4. Read events, require `events >= minEvents` OR a first UserPrompt
5. Detect origin via `agentMatch` + ledger inspection
6. Drop if origin != `.desktop`
7. Compute `worktreePath` from hooks
8. Tag with `liveProvider` from `agentMatch`

Steps 4-8 have been thrashed over the last week:
- Added provider-mismatch filter, then removed it after "sessions missing" reports
- Added cwd-mismatch filter, then removed it for the same reason
- Floor is now: agent file must exist in this project's cwd-basename dir (gemini) or encoded cwd (Claude)

The filter became the place where every "session correctness" question was answered. That accretion is now the largest opaque function in the registry. It also means there's no place left to think about *what a session is* — only about *what should appear in the sidebar.*

---

## 3. The model we want

The architectural smell is that **identity, state, origin, view-intent, and content** all live on one struct and travel together through every call site. We can separate them.

### 3.1 Two clear layers

```
┌─────────────────────────────────────────────────────────┐
│ Layer 1: SessionRef  — immutable descriptor of an       │
│                         on-disk session at one moment   │
├─────────────────────────────────────────────────────────┤
│ Layer 2: Thread      — in-memory view-model with a      │
│                         specific viewMode + controller  │
└─────────────────────────────────────────────────────────┘
```

#### `SessionRef` (disk → runtime descriptor)

```swift
struct SessionRef: Hashable {
    let id: UUID                  // session_id
    let project: String           // project key
    let state: State              // .live | .finalized
    let origin: Origin            // .desktop | .terminal | .unknown
    let agentProvider: Provider?  // which agent has the persistence file
    let cwd: String               // where the agent was spawned (worktree-aware)
    let title: String?            // display label

    enum State { case live, finalized }
    enum Origin { case desktop, terminal, unknown }
}
```

Properties:
- Immutable. Built once by the registry reader. Never mutated.
- Replaces all five concerns currently on `SoulSession`.
- `agentProvider` is the unified version of `source` + `liveProvider`. The reader picks one signal; downstream code reads one field.
- `cwd` is the resolved spawn cwd (project path overlaid with worktreePath if present). Single field, no overlay logic at the call site.

#### `Thread` (in-memory tab)

```swift
@Observable
class Thread {
    let id: UUID                   // thread instance id (multiplexer key)
    let ref: SessionRef            // identity it represents
    let mode: Mode
    // ... controller-backed state below

    enum Mode {
        case live                  // interactive, ACP-backed
        case snapshot              // read-only timeline reconstruction
        case replay                // paced timeline scrubber
    }
}
```

Properties:
- Multiple threads can reference the same `SessionRef`. The multiplexer no longer de-dupes by session id — it dedupes by thread id (which is unique per tab).
- `mode` decides which controller drives the thread (today's `ThreadController` is `mode == .live`; `ReplayController` is `mode == .replay`; `.snapshot` is new).
- Snapshot mode is the missing piece. Today, "view the finalized chat" is conflated with "open a live thread for the same session." Snapshot threads render the finalized JSON + hooks.jsonl as a read-only canvas with no agent connection. If the user wants to continue, they explicitly **fork** the snapshot into a new live thread.

### 3.2 Click semantics

| Row type | Action |
|---|---|
| Live row | If any live Thread refs this SessionRef, surface it. Else create a new live Thread bound to the ref. |
| Chat (finalized) row | Always create a new snapshot Thread. No de-duplication — the user clicked it, they get a fresh view. |
| Replay button | Create a replay Thread (existing ReplayController logic). |
| Snapshot thread "Continue" action | Create a new live Thread bound to the same ref; load the snapshot's transcript as history. |

This is the heart of the fix. The current code conflates "I want to interact with this session" with "I want to view this session's history." Splitting them is the architectural answer to *"why does clicking Shipping Tr… surface live 11810…?"* — under the new model, those rows have explicit, distinct semantics:
- Click `Shipping Tr…` (chat row, finalized) → always opens a snapshot view, regardless of any live thread state
- Click `live · 11810…` (live row) → ensures-or-surfaces the live thread

There is no ambiguity to resolve at click time.

### 3.3 The message-filter boundary

Move all wrapper-stripping into a single function `inboundText(_ raw: String, from: TextSource) -> Rendered`:

```swift
enum TextSource {
    case composer                // user typed → never filter
    case acpUserChunk            // session/load replay user → strip wrappers
    case acpAgentChunk           // agent chunk → minimal sanitization
    case hooksUserPrompt         // kernel-recorded ledger → maybe strip
    case snapshotIntent          // finalized JSON intent/summary → sanitize
}

enum Rendered {
    case userMessage(String)
    case status(String)
    case skip
}
```

Properties:
- One file, one function, one switch.
- Adding a new wrapper tag means editing one match. Removing one means deleting one match.
- Every `items.append(.userMessage(...))` or `items.append(.status(...))` goes through `inboundText` first. Static analysis (and reviewers) can enforce this.

This isn't a "regex registry" — it's a single chokepoint with explicit per-source policy. The accretion problem the current `classifyLocalCommand` will eventually hit (more tags, more sources, more brittleness) is bounded.

### 3.4 What `SoulRegistry` exposes

Today: a dozen static funcs, each reading some slice of disk and returning a partially-populated `SoulSession`.

Proposed:

```swift
enum SoulRegistry {
    static func projects() -> [SoulProject]
    static func liveRefs(for project: SoulProject) -> [SessionRef]
    static func finalizedRefs(for project: SoulProject, limit: Int) -> [SessionRef]
    static func ref(by id: UUID, project: SoulProject) -> SessionRef?
    // ... internal disk helpers stay private
}
```

The reader builds `SessionRef` objects with all fields resolved. There is no "this field is set on live but not on finalized" condition in the type — every `SessionRef` is complete. Code that needs more (full hooks ledger, transcript) calls a separate function with an explicit reason.

---

## 4. Phased migration

Not a big-bang refactor. Five phases, each independently shippable.

### Phase 1 — Introduce `SessionRef` as a parallel type
- Add `SessionRef` next to `SoulSession`
- Add new readers that return `[SessionRef]`
- Keep all current code paths on `SoulSession`
- One internal call site converts: builds `SessionRef` from a `SoulSession`
- **Outcome:** nothing changes for users; new type exists; tests written against the new readers.

### Phase 2 — Migrate sidebar rendering to `SessionRef`
- `SidebarView` consumes `[SessionRef]` instead of `[SoulSession]`
- Row click closures pass `SessionRef`
- `loadSession(_ ref: SessionRef)` accepts the new type
- The multiplexer still works internally on `ThreadController` (no Thread/Mode split yet)
- **Outcome:** UI now operates on the clean type; bugs from missing fields disappear.

### Phase 3 — Introduce `Thread` with `mode` enum
- Add `Thread` wrapping current controllers
- `Thread.mode == .live` wraps a `ThreadController`
- `Thread.mode == .replay` wraps a `ReplayController`
- `AppShell.threads` keys on `Thread.id`
- **Outcome:** clear runtime/identity separation; no new user-visible behavior.

### Phase 4 — Add snapshot mode + fix click semantics
- Implement `Thread.mode == .snapshot` with a new lightweight controller that renders a finalized session's history without an agent connection
- Wire chat-row clicks to open snapshot threads
- Wire live-row clicks to use the new ensure-or-surface logic
- Add "Continue from here" action on snapshot threads (forks to live)
- **Outcome:** the user-reported click confusion is structurally impossible.

### Phase 5 — Move all text filtering through `inboundText`
- Introduce the boundary function
- Replace `classifyLocalCommand` call site
- Add filters at the other ingress points (`hooksUserPrompt`, `snapshotIntent`, etc.)
- Delete `classifyLocalCommand`
- **Outcome:** the third regex bolt-on becomes a one-line addition in the right place.

Each phase is reviewable on its own. Each leaves the app shippable. Phases 1-3 are mostly mechanical; Phase 4 is the conceptual win; Phase 5 is the cleanup tax.

---

## 5. Open questions

These need answers before any code lands.

1. **Is the click bug actually a session-model problem?** The audit suggests "click Shipping Tr… surfaces live 11810…" cannot be a same-UUID multiplexer collision (the on-disk invariant prevents it). We should reproduce and instrument before committing to a redesign. The redesign is still motivated by §2.1/§2.4/§2.5 even if §2.3 turns out to be a separate bug — but the *order of operations* matters. Don't refactor to fix a bug that isn't there.

2. **Snapshot mode complexity.** Rendering a finalized JSON + hooks.jsonl as a static canvas isn't free — replay items must be ordered, working-set must be computable, scroll must work. We already have `ReplayController` that does most of this; can `snapshot` be `replay` with `seek(.last)` and pause? If yes, Phase 4 collapses significantly.

3. **Fork semantics.** "Continue from snapshot" — does it create a brand-new session (fresh UUID, copy history) or resume the same UUID via session/load? The first is honest but breaks the user's idea of "one chat per topic." The second risks state divergence (agent thinks it's mid-conversation; we just opened it cold).

4. **Worktree's place in the new model.** `cwd` on `SessionRef` is computed once (worktreePath overlay if present). But we still don't have a UI to *spawn* into a worktree. Either the field is structural plumbing waiting for a feature, or we drop it from `SessionRef` and treat worktree-spawned sessions as a terminal-only concept. (Filed for separate discussion in SOUL-SOUL_DESKTOP-021.)

5. **Cost.** Honest estimate: Phases 1-2 are 1 day each. Phase 3 is 1-2 days (touches AppShell, every entry point). Phase 4 is 2-3 days (new controller + UX decisions). Phase 5 is 1 day. Total: ~1-1.5 weeks of focused work, not including testing.

---

## 6. What's not in scope

- ACP layer redesign (separate audit; see upstream `c2e5b28e9 refactor(acp): modularize monolithic acpClient`).
- Gemini-cli session-storage format changes (separate, upstream).
- Worktree spawn UI (filed separately).
- Replay pacing improvements (separate).
- The `<task-notification>` filter — keep the current bolt-on until Phase 5; document it as known debt.

---

## 7. Recommendation

Before any code:

1. Reproduce the "click Shipping Tr… surfaces live 11810…" bug with logging in place. Confirm whether it's same-UUID collision (the audit says no) or something else (most likely: liveProvider mismatch causing harness switch that fails to load).
2. Walk this doc with the user. The biggest decision is §3.2 (click semantics) — does the proposed split match their mental model? If not, the rest of the design is wrong.
3. Decide on Phase 4's snapshot-as-paused-replay option (open question #2) — it changes the cost estimate by ~half.

Then start Phase 1.
