# Per-Session Worktree Isolation

**Status:** Draft for sign-off — no code lands until this is approved.
**Author:** Teddy (systems_architect), 2026-05-16
**Task:** SOUL-SOUL_DESKTOP-076 (supersedes -002 thread-header fork; supersedes -052 sessionCapabilities.fork as automatic-by-default)
**Scope:** Every new session in a git-repo project gets its own worktree on a provider-named branch. ACP child runs with cwd = worktree path. Parallel sessions can't collide because they're on physically separate working trees.

---

## 1. The problem

Right now every session in a project shares the same working tree. Two live sessions — say a Claude session refactoring `AppShell.swift` and a Gemini session editing the same file — race on disk. Whoever writes last wins. The kernel ledger records both turns truthfully but the file state on disk is a half-baked merge of both agents' intent. There is no isolation primitive; the user is the only thing standing between two agents and a corrupted working tree.

The fix is structural: every session works in its own git worktree, on its own branch, under a known path. Parallel work becomes a parallel-merge problem (which git is good at) instead of a last-writer-wins problem (which git can't help with).

---

## 2. Architecture

### 2.1 Worktree location

```
~/.soul/worktrees/<project-key>/<sid>/
```

- `<project-key>` is the existing kernel project id (matches `~/soul_registry/sessions/<project-key>/`).
- `<sid>` is the kernel session id (UUID).
- Predictable, greppable, easy to clean up by project or by session.

Rejected alternative: sibling-of-project (`<project-path>/../<basename>-worktrees/`). Closer to the user's working dir, but pollutes wherever they keep projects. The `~/.soul/` namespace already exists conceptually (we use `~/soul_registry/`) — fold worktrees under the same roof.

### 2.2 Branch naming

```
<provider>/<title-slug>-<short-sid>
```

- `<provider>` is `claude`, `gemini`, `codex`, `pi`.
- `<title-slug>` is the auto-generated session title (already minted by the title-summary LLM pass), kebab-cased, truncated to 40 chars. Falls back to `untitled` if the title hasn't landed yet.
- `<short-sid>` is the first 8 chars of the session uuid — disambiguates two sessions that happen to share a slug.

Example: `claude/auth-refactor-fix-9f3a7b21`.

### 2.3 Creation timing

**Lazy on first send**, not on session create. Reasoning:

- Most sessions die after a single send. Creating a worktree per click would litter `~/.soul/worktrees/` with empties.
- The title slug isn't known until after the first turn anyway.
- A pre-spawn check that "this session has no worktree" is cheap.

The first-send path becomes: title slug exists? → resolve worktree path → exist? if no, `git worktree add` → spawn ACP child with cwd = worktree.

### 2.4 Registry plumbing

A new field on the session row, written into hooks.jsonl at worktree-creation time:

```jsonl
{"event": "WORKTREE_CREATED", "session_id": "<sid>", "worktree_path": "<path>", "branch": "<branch>", "timestamp": "..."}
```

Resume reads the last `WORKTREE_CREATED` event for the session and spawns the child with cwd = that path. If the path doesn't exist on disk anymore (user manually `rm -rf`'d it), offer to re-create or fall back to the project root.

### 2.5 ACP cwd plumbing

`ACPProviderSpawn.swift` already takes a cwd. ThreadController's spawn path passes `project.path` today. New behavior: if a worktree exists for this session, pass the worktree path instead. One-line change at each spawn call site (claude/gemini/pi via ACPClient, codex via CodexClient).

### 2.6 Cleanup lifecycle

- **No auto-cleanup on `/finalize`.** A finalized session is still resumable; killing the worktree would make resume jarring.
- **Right-click menu on archived sessions** gets a "Delete worktree" action that runs `git worktree remove --force <path>` and `git branch -D <branch>`. Confirmation dialog before the delete.
- **Move-to-trash** (existing right-click action) sweeps the worktree alongside the kernel dir.
- **`soul worktree prune`** CLI (new, small): scans `~/.soul/worktrees/` and removes any worktree whose session has been moved to trash or whose session no longer exists. For periodic hygiene.

---

## 3. Failure branches (S7)

### Δ1: `git worktree add` fails
Causes: branch name already exists, path conflict, disk full, repo locked.
**Recovery (R1):** fall back to spawning in the project root (today's behavior). Surface a status row in the canvas: *"Couldn't create isolated worktree — running in main working tree. Click for details."* Log the failure to the agent log panel + a `WORKTREE_FALLBACK` event in hooks.jsonl. Do NOT block the session.

### Δ2: Worktree exists but is corrupt
Causes: user manually deleted the dir but left the git metadata pointer; `.git/worktrees/<sid>/` references a missing path.
**Recovery (R1):** on resume, `git worktree prune` first, then re-create from the recorded branch name (the branch still exists in the main repo). If branch is also gone, fall back to Δ1 path.

### Δ3: Provider child resolves paths against an unexpected root
Causes: agent reads a config file that hardcodes the project root, not the cwd; absolute paths in earlier turns now point outside the worktree.
**Recovery (R1):** test each provider on a representative session (read a file, edit a file, run a shell command) before flipping the default to on. If a provider has a hard problem, ship the toggle defaulted off for that provider only.

### Δ4: Project root isn't a git repo
**Recovery:** no isolation; spawn in `project.path` like today. Log a one-line note to the agent log so the user knows they're not isolated.

### Δ5: User has uncommitted changes in the main worktree
`git worktree add` doesn't touch the index of the main worktree, so this should be safe — the new worktree branches from HEAD, not from the dirty index. **No recovery needed**, but worth a smoke test before shipping.

### Δ6: Sidebar shows the same session from two surfaces simultaneously
(e.g., user has the same session open in two windows.) Both spawn paths would race to create the same worktree.
**Recovery:** worktree creation is gated by a small per-sid lockfile under `~/.soul/worktrees/.locks/<sid>`. Second caller observes the lock, waits ~500ms, then proceeds with the already-created worktree.

---

## 4. Open questions (for sign-off)

1. **Title slug timing.** First send happens before the title-summary LLM pass finishes. Do we mint the worktree with `untitled-<short-sid>` and rename the branch later? Or block first send until the title lands (added latency)? Recommendation: mint with `untitled-` prefix, rename branch on first title update — `git branch -m` is cheap.

2. **Codex.** Codex doesn't speak ACP `session/load` over RPC and hydrates from the kernel ledger. Worktree support is still trivial (just cwd at spawn), but the resume-with-cwd story should be smoke-tested.

3. **Settings toggle default.** Spec says "default on." Argument for "default off, opt-in per project": worktrees double disk usage for every active session, which could surprise users on a small SSD. Counter: solo users keep one session live at a time, so it's usually 2× one tree, not 10×. Recommendation: default on, settings toggle for opt-out, plus a "Don't isolate this project" right-click action on the project row for per-project opt-out.

4. **Merging branches back.** Out of scope for -076. The spec creates branches but doesn't help merge them. A separate task (`-077`?) for "Merge session branch back into main" with a small UI affordance.

5. **Empty worktrees.** If a session does its first send, gets a worktree, and then never receives another turn — is the worktree garbage? Recommendation: leave it until the session is archived. The user might come back.

---

## 5. Implementation order

1. **WorktreeManager.swift** (new): wraps `git worktree add/remove/list/prune` with a Swift API. Tested standalone.
2. **Hooks event**: add `WORKTREE_CREATED` and `WORKTREE_FALLBACK` to the hooks.jsonl event enum.
3. **ThreadController.spawn**: read recorded worktree path or create one; pass to ACP spawn.
4. **SidebarView**: small badge ("⎇ worktree") on rows that have one.
5. **Right-click menu**: "Open worktree in Finder", "Delete worktree" (archived only).
6. **Settings toggle**: Advanced pane.
7. **Smoke test each provider**: read, edit, execute under each of claude/gemini/codex/pi. Confirm cwd resolution.

Hard estimate: half a day for steps 1–3, another half-day for 4–7. Two solo evenings.

---

## 6. Decision required

Need explicit sign-off on:

- (a) Worktree location: `~/.soul/worktrees/<project-key>/<sid>/` — yes/no.
- (b) Lazy-on-first-send creation — yes/no.
- (c) Default on with settings opt-out — yes/no.
- (d) No auto-cleanup on finalize; cleanup via right-click on archived — yes/no.
- (e) Title-slug renaming via `git branch -m` once the title lands — yes/no.

If all five are yes, implementation order in §5 is locked. If any are no, this draft revises before code lands.
