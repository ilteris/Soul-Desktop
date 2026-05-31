# Session Worktree Merge-Back

**Status:** Draft for sign-off — no code lands until this is approved.
**Author:** Teddy (systems_architect), 2026-05-31
**Task:** SOUL-SOUL_DESKTOP-370 (companion to -364 per-session worktree isolation; realizes the merge-back deferred in `session-worktree-isolation.md` §4.4)
**Scope:** Bring the per-session branches created by SOUL-364 back to an integration branch. Make divergence visible continuously, automate only the operations that are provably reversible and side-effect-free, and keep every history-altering step human-blessed and behind a verification gate.

---

## 1. The problem

SOUL-364 gives every session its own worktree on `soul/session/<project-key>/<short-sid>-<slug>`, branched from the main checkout's HEAD. That solves last-writer-wins on disk. It does not solve the next question: how does a session's work come home.

Parallel editing is, by construction, a parallel-merge problem. The branches will diverge, and some of those divergences will conflict. No system can make overlapping edits to the same lines merge automatically and correctly. So the goal here is not "merge everything automatically." It is:

1. Make divergence **visible** the moment it happens, not at merge time.
2. Automate the steps that are **provably safe** (reversible, no history rewrite, no working-tree mutation the user can see).
3. Keep every step that alters shared history **deliberate, gated, and reversible**.

An adversarial design review (2026-05-31) rejected the original "auto-seal then auto-land" framing. This spec reflects that review. The single most dangerous assumption it killed: that committing a worktree is "just a harmless snapshot." It is not. See §3.

---

## 2. Two mechanisms, not one

The original design conflated "I need a tree to reason about mergeability" with "I am writing a durable commit into history." These are different operations with different safety profiles. Split them.

### 2.1 The probe tree (automatable, safe, never commits)

The mergeability signal needs a *tree object*, not a *commit*. Build one from the worktree's current files without touching the real index, by pointing git at a throwaway index:

```sh
TMP_INDEX="$(mktemp)"
GIT_INDEX_FILE="$TMP_INDEX" git -C <worktree> add -A
GIT_INDEX_FILE="$TMP_INDEX" git -C <worktree> write-tree   # -> ephemeral tree SHA
```

Why this is safe:

- It never writes the worktree's real `.git/index`, so it **cannot race the agent's own `git`** (Claude/Codex run git inside the worktree; see §3.2). This is the property that makes it automatable.
- `add -A` honors `.gitignore`, so gitignored secrets (`.env`, keys) are excluded for free. Including untracked-but-unignored files in a *probe* is fine: nothing lands.
- The tree is ephemeral (no ref, no commit). A momentarily-inconsistent probe taken mid-turn just yields a transient badge state that self-corrects on the next probe.

This is the entire foundation of the mergeability badge (§4) and it commits nothing, ever.

### 2.2 The durable seal (deliberate, gated, never on a timer)

A commit that enters history happens only at an explicit, human-blessed moment (land or finalize), under all of these rules:

- **Prefer the agent's own commits.** Agents frequently `git commit` their own work. If the session branch HEAD already contains the work, do nothing. Only the *uncommitted remainder* needs handling.
- **Surface the remainder, do not blind-commit it.** Show the uncommitted diff to the user before creating any commit.
- **Tracked-only by default.** `git add -u` or a reviewed pathspec, never `git add -A`. Closes the secret/junk-leak vector.
- **Bot identity, never the user's.** Author the commit as a Soul/bot identity with a message naming the session and sid, so `git blame` on the integration branch is never falsely attributed to Ilteris.
- **Idle-only.** Seal only when `isWorking == false` (turn complete, no half-written streamed files) and the session is at finalize/retire, where the agent is idle by construction.

There is no timer-based seal. The dangerous version does not exist in this spec.

---

## 3. Why auto-seal was rejected (recorded so it stays rejected)

### 3.1 `git add -A` is a leak vector
Agents write `.env`, tokens, `*.pem`, build droppings. A blind `add -A` commit sweeps anything not gitignored onto a branch that later merges to integration. Tracked-only (`add -u`) plus `.gitignore` respect is mandatory.

### 3.2 The agent-vs-seal index race is real corruption
Claude and Codex run `git` directly inside the worktree. A timer-fired `git commit` racing the agent's `git add`/`checkout`/`stash` means two processes write `.git/index` concurrently, which corrupts it. A Swift-side lock does nothing because the agent's git does not route through it. Mitigation: never write the real index while the agent might run git (the §2.1 probe path sidesteps this entirely; the §2.2 durable seal only runs at idle/finalize).

### 3.3 Authorship pollution
Forging the user's identity on auto-commits permanently pollutes `git blame` and history on the integration branch. Bot identity only.

### 3.4 Partial edits
Agents stream files. Sealing mid-turn can commit a truncated file. Tie any durable seal to turn completion (`isWorking == false`).

---

## 4. The mergeability badge (build this first)

The highest-value, zero-write-risk piece. Per session row, a continuously-meaningful signal:

- `✓ clean to land` — probe tree merges into target with no conflict.
- `⚠ conflicts with main` — overlaps the integration branch.
- `⚠ conflicts with <session>` — overlaps a sibling session's probe tree.

### 4.1 The primitive
`git merge-tree --write-tree <target-commit> <probe-tree-or-branch>` (git 2.38+) computes the full merge in memory and reports conflicts without checking anything out and without touching any working tree.

### 4.2 Hard constraints the review surfaced
- **Apple git is too old.** macOS ships a git without `--write-tree`. Resolve a modern git (we already fall back to `/usr/local/bin/git`), version-check at startup, and **degrade gracefully**: if `merge-tree --write-tree` is unavailable, the badge shows `mergeability unknown` rather than lying. Do not assume the primitive exists.
- **Rename/limit sensitivity.** `merge.renameLimit` and rename detection mean large diffs can miss renames and over-report conflicts. Document this as a known false-positive source; do not treat a conflict report as ground truth for *blocking*, only for *warning*.
- **LFS / binary / submodules.** merge-tree treats LFS pointers as text; a "clean" textual merge can still produce a broken pointer or an unrepresentable binary conflict. Flag repos using LFS/submodules as `mergeability approximate`.
- **Conflict-report format drift.** The machine-readable conflict section changed across 2.38 → 2.40+. Pin to a known format, parse defensively, and fall back to `unknown` on a parse miss.

### 4.3 Cost: lazy, not continuous
Sibling-conflict checking is O(N²) (every session vs every other) plus O(N) vs target, recomputed on any commit on any branch. "Continuous" probing is constant subprocess churn at 5+ sessions. Therefore:
- Probe **on demand**: on finalize, on hover/expand of a session row, on explicit refresh. Not on a timer.
- **Cache by commit-pair SHA** (`<target-sha>:<probe-tree-sha>`); a cache hit is free and self-invalidates when either side moves.
- Bound sibling checks: only probe siblings on explicit "check divergence," not ambiently.

---

## 5. Safety tiers (what auto means)

| Tier | Operation | Auto? | Why |
|---|---|---|---|
| T0 | Ephemeral probe tree (§2.1) | **Yes** | No commit, no real-index write, no working-tree mutation. |
| T1 | Fast-forward land when target has not moved | **Yes** | Pure ref advance, no merge logic, trivially reversible (save prior ref). |
| T2 | 3-way merge when probe reports zero conflicts | **No — human-blessed, behind gate** | Text-clean ≠ semantically correct; cross-file semantic conflicts compile-break. |
| T3 | Resolve textual conflicts | **Never auto** | No safe automatic resolution. Human, or agent-assisted under the same gate. |

T1 is the only auto-land. Everything T2 and above is deliberate.

---

## 6. The verification gate (and its limits)

Before any ref that others depend on advances (T2 land), materialize the merged tree in a **dedicated scratch integration worktree** (never the user's main checkout), build, and test there. Land only on green.

### 6.1 What it cannot be trusted to do
A worktree contains only committed, tracked files. `node_modules`, `.build`, `Pods`, generated code, and `.env` are in no commit. So the scratch tree may:
- **false-red**: fail to build for reasons unrelated to the merge (missing deps), blocking a clean merge; or
- **false-green**: if we copy deps in to compensate, test against stale/foreign deps and pass when integration would fail.

Conclusion: the gate is a useful guard for human-initiated lands, but **it cannot authorize an unattended auto-land**. T2 stays human-blessed. The gate informs the human; it does not replace them.

---

## 7. Concurrency: a merge queue

N sessions landing on one integration branch must serialize, because the target is a single ref and each land moves it (stale-ing the others' probes).

- **Default: optimistic with re-probe.** Land clean sessions one at a time; re-probe the rest against the new target after each land. Cheap when sessions touch disjoint areas (the common case at this scale).
- **Merge-train** (test-as-if-landed-in-order, land the green prefix) only if heavy contention ever materializes. Not built initially.
- **Lock:** one land at a time per target branch. Soul-side advisory lock; the actual ref move is a single `update-ref`.

---

## 8. Rollback and remote (non-negotiable)

- **Save the prior ref before any ref move.** Record `<target>@<sha-before>` so a bad land is one `update-ref` to undo. `reflog` is the backstop.
- **No remote push as part of landing.** Landing advances a *local* integration branch only. Pushing is a separate, explicitly-authorized action (Gate S16). A bad land that was never pushed is fully recoverable; a pushed bad land is not.
- **Never touch the user's main checkout.** All probing and landing happen against refs and in scratch worktrees. The user's working tree and its dirty state are out of the blast radius. Enforce this as an invariant in code, not an aspiration.

---

## 9. Triggers

- **Probe (T0):** on demand — finalize, row hover/expand, explicit refresh. Never on a timer. SHA-cached.
- **Durable seal (§2.2):** only at land/finalize, idle-only, after surfacing the uncommitted remainder.
- **Auto fast-forward (T1):** offered when the badge is `clean to land` and target has not moved; one click, reversible.
- **T2 land:** human-initiated, runs the §6 gate, saves the prior ref, lands on green.
- **Conflict wall (T3):** offer "resolve with an agent" — spins a resolution agent in the scratch worktree, then re-runs the §6 gate. Assisted, never silent.
- **Retire:** on successful land, `git worktree remove` + archive/delete the branch (reuses SOUL-364 cleanup). On failure, keep everything so nothing is lost.

---

## 10. Failure branches (S7)

### Δ1: `merge-tree --write-tree` unavailable (old git)
**R1:** badge shows `mergeability unknown`; landing falls back to human-driven `git merge` in the scratch worktree. No feature is blocked, only the ambient signal degrades.

### Δ2: Probe parse fails (format drift)
**R1:** treat as `unknown`, log the raw output to the agent log, never report a false `clean`.

### Δ3: Scratch-worktree build fails for dep reasons (false-red)
**R1:** surface "gate could not build — missing deps, not a merge conflict" distinctly from "tests failed." Let the human override-land with an explicit confirmation.

### Δ4: Agent runs git concurrently with a durable seal
**R1:** the idle-only rule (§2.2) prevents this by construction. If `isWorking` is somehow true at seal time, abort the seal and surface "session still active — finish the turn before landing."

### Δ5: Two sessions land simultaneously
**R1:** the per-target advisory lock serializes them; the second re-probes against the post-land target before proceeding.

### Δ6: Bad land discovered after the fact
**R1:** the saved prior ref makes undo one `update-ref`. Surface a "revert last land" affordance that restores `<target>@<sha-before>`.

### Δ7: Worktree/branch leakage on crash
**R1:** reuse SOUL-364's `soul worktree prune`; extend it to also `git branch -D` orphan `soul/session/*` branches whose session is gone.

---

## 11. Implementation order

1. **Modern-git resolution + version probe** — detect `merge-tree --write-tree` support; expose a capability flag.
2. **`WorktreeMergeProbe.swift`** (new): temp-index `write-tree` (§2.1) + `merge-tree` invocation + defensive conflict parse → `Mergeability { clean, conflictsWith([…]), unknown }`. SHA-cached. Tested standalone against temp repos.
3. **Mergeability badge** in `SidebarView+Projects` (which already buckets by worktree): on-demand + cached, degrades to `unknown`.
4. **T1 fast-forward land**: save prior ref, `update-ref`, retire worktree. One click, reversible.
5. **Durable seal at finalize** (§2.2): tracked-only, bot identity, idle-only, remainder surfaced.
6. **§6 scratch-worktree gate** for human-initiated T2 lands, with false-red/false-green messaging.
7. **Merge queue** (optimistic + re-probe) and **revert-last-land** affordance.

Steps 1–3 are the high-value, zero-risk core and can ship alone. 4–7 are the gated landing path and ship incrementally.

---

## 12. Decision required

Need explicit sign-off on:

- (a) Ship the badge (T0 probe + mergeability signal) first, landing later — yes/no.
- (b) Two-mechanism split: ephemeral temp-index probe vs gated finalize-time durable seal; no timer seal — yes/no.
- (c) T1 fast-forward is the only auto-land; T2+ human-blessed behind the gate — yes/no.
- (d) Landing is local-only; remote push stays separately authorized (S16) — yes/no.
- (e) Bot commit identity for any Soul-authored seal, never the user's — yes/no.

If all five are yes, the §11 order is locked. If any are no, this draft revises before code lands.
