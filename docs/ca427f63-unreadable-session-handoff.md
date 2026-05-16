# ca427f63 — Unreadable Gemini Session Handoff

**Author:** Teddy (systems_architect), 2026-05-16
**Audience:** Whichever agent picks this up next.
**Tasks in play:**
- `SOUL-SOUL-010` — Restore `dotfiles/soul` to canonical gemini-cli slug `soul` (completed locally 2026-05-16)
- `SOUL-SOUL-011` — Reconstruct ca427f63 Gemini chat into canonical soul bucket (completed locally 2026-05-16)
- `SOUL-SOUL-012` — Distinguish header-only transcript repair from NativeSessionID backfill (kernel diagnostic landed locally 2026-05-16)
- `SOUL-SOUL_DESKTOP-060` — Detect concurrent-writer terminal Gemini sessions (filed earlier; tangentially related)

The user has a Gemini-CLI session that Soul-Desktop refuses to open as a live canvas — it forces "read-only mode" (Replay). This doc is the file-grounded explanation of *why* and *what to do*.

---

## TL;DR

2026-05-16 correction: this was not a fully missing provider artifact. The native Gemini artifact existed as a one-line, 228-byte header-only stub under `~/.gemini/tmp/soul-1/chats/session-2026-05-16T04-32-ca427f63.jsonl`, while the intact kernel ledger lived at `~/soul_registry/sessions/soul/ca427f63-c29c-4968-b897-c6861f5a801b/hooks.jsonl`.

Local repair completed:

- `~/.gemini/projects.json` now maps `/Users/ilteris/dotfiles/soul` to `"soul"`; `/Users/ilteris/Code/Soul-Desktop` remains `"soul-desktop"`.
- `~/dotfiles/soul/kernel/soul_gemini_repair.py` diagnoses `missing`, `header-only-stub`, `parseable-transcript`, and `wrong-slug-*` states separately from NativeSessionID backfill.
- Reconstructed transcript written to `~/.gemini/tmp/soul/chats/session-2026-05-16T05-11-ca427f63.jsonl` from hooks ledger user/model rows.
- The old `soul-1` ca427f63 stub was backed up as `.bak-20260516T051133Z` and replaced with the reconstructed transcript so no header-only ca427f63 copy remains.

---

## 1. The session on disk

```
✓  ~/soul_registry/sessions/soul/ca427f63-c29c-4968-b897-c6861f5a801b/hooks.jsonl    (152 KB, kernel ledger)
✓  ~/.gemini/tmp/soul/chats/session-2026-05-16T05-11-ca427f63.jsonl                  (reconstructed Gemini JSONL)
✓  ~/.gemini/tmp/soul-1/chats/session-2026-05-16T04-32-ca427f63.jsonl                (replaced with reconstructed copy)
✓  ~/.gemini/tmp/soul-1/chats/session-2026-05-16T04-32-ca427f63.jsonl.bak-20260516T051133Z (original 228-byte stub backup)
```

Verified by:

```sh
find ~/.gemini/tmp -path "*chats/ca427f63*" -o -name "ca427f63-c29c-4968-b897-c6861f5a801b.json"
# (no output)
find ~/.gemini/tmp -name "*ca427f63*"
# only hits under tmp/soul-1/tool-outputs/ — never under chats/
```

The kernel-side ledger has 152 KB of content. The Gemini-CLI-side resumable chat file was a header-only stub and has been reconstructed into the current JSONL shape.

SESSION_START event from hooks.jsonl (first line):

```json
{
  "event": "NativeSessionID",
  "provider": "geminiCLI",
  "timestamp": "2026-05-16T03:35:17.616000Z",
  "session_id": "ca427f63-c29c-4968-b897-c6861f5a801b",
  "cwd": "/Users/ilteris/dotfiles/soul"
}
```

cwd `/Users/ilteris/dotfiles/soul` → Soul OS kernel project (registry project key `soul`).

---

## 2. Where the desktop decides "loadable"

**File:** `Soul-Desktop/SessionLoadability.swift:113-124`

```swift
private static func geminiFileHasContent(sessionId sid: String, projectKey: String) -> Bool {
    let geminiBase = ("~/.gemini/tmp" as NSString).expandingTildeInPath
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: geminiBase) else { return false }
    let candidateDirs = entries.filter { $0 == projectKey || $0.hasPrefix("\(projectKey)-") }
    for dir in candidateDirs {
        if scanGeminiChatsDir("\(geminiBase)/\(dir)/chats", sessionId: sid) != nil {
            return true
        }
    }
    return false
}
```

For project key `soul`, it builds `candidateDirs = ["soul", "soul-1", "soul-desktop" if it starts with "soul-"…]` — anything matching `soul` exactly or starting with `soul-`. Then it scans each `chats/` subdir for a file containing the sid. None match for `ca427f63` → returns false.

The fallback global scan (`SessionLoadability.discover` → `findGeminiAnywhere` at line 129) also returns nil since no chat file exists anywhere on disk.

---

## 3. The route decision

**File:** `Soul-Desktop/AppShell.swift:285-292`

```swift
var discoveredCwdOverride: String? = nil
if !session.loadable, session.replayable {
    if let hit = SessionLoadability.discover(sessionId: session.id) {
        discoveredCwdOverride = hit.cwd
    } else {
        pendingActiveId = nil
        externalLiveSession = session   // ← Replay-only sheet
        return
    }
}
```

- `loadable = false` (no chat file via §2)
- `replayable = true` (kernel ledger exists)
- `discover()` returns nil (no chat file anywhere)
- → fall into the `externalLiveSession` branch → the "read-only mode" UI

That's what the user is seeing.

---

## 4. The slug mapping (gemini-cli internal state)

**File:** `~/.gemini/projects.json` after local repair:

```
/Users/ilteris/dotfiles/soul   → "soul"
/Users/ilteris/Code/Soul-Desktop → "soul-desktop"
```

Gemini-CLI consults this on every spawn. The value here dictates which `~/.gemini/tmp/<slug>/chats/` Gemini writes to.

**History of how this got broken:**

1. The user has two project paths with basename `soul`:
   - `~/Code/Soul-Desktop` (parent or sibling — unimportant)
   - `~/dotfiles/soul` (Soul OS kernel)
2. Gemini-CLI's slug resolver checks basename collisions against existing `~/.gemini/tmp/<slug>/` directories. There's an orphan `tmp/soul/` (May 14 mtime, no current projects.json mapping). When Gemini spawned in `dotfiles/soul`, it saw the `soul` slug "occupied" and suffixed to `soul-1`.
3. A previous cleanup at 2026-05-15T22:58 merged `tmp/soul-1/chats/` contents into `tmp/soul/chats/` and rewrote projects.json. But the orphan `tmp/soul/` dir's internal metadata wasn't updated, so when a fresh Gemini spawn happened at 23:35 in dotfiles/soul (this very ca427f63 session), the basename-collision logic fired again and re-wrote `dotfiles/soul → "soul-1"` in projects.json.
4. The ca427f63 terminal session itself never persisted a chat file in `tmp/soul-1/chats/` — it died (closed, crashed, or got killed) before flushing. Only `tool-outputs/` traces survived.

---

## 5. Why SOUL-SOUL-010 alone did not help ca427f63

SOUL-SOUL-010 restores the canonical slug so future `dotfiles/soul` spawns write under `~/.gemini/tmp/soul`. It does not by itself inflate a header-only chat stub into a usable transcript. SOUL-SOUL-011 was required to reconstruct ca427f63 from `hooks.jsonl`.

The earlier `soul-kernel` recommendation was wrong for this registry. The intended canonical bucket for the Soul kernel project is `~/.gemini/tmp/soul`.

---

## 6. The reconstruction command used

```sh
python3 ~/dotfiles/soul/kernel/soul_gemini_repair.py \
  --project soul \
  --session-id ca427f63-c29c-4968-b897-c6861f5a801b \
  --repair
```

The script reads `UserPrompt` and non-empty `AfterAgent` rows from `hooks.jsonl`, writes a Gemini JSONL header plus user/model message rows, refuses to overwrite non-stub transcripts unless `--force` is passed, and provides `--diagnose` for the desktop repair surface.

**Lossiness:** the reconstruction preserves textual continuity (user/assistant turn sequence + content). It does not preserve tool-call telemetry or reasoning chunks — Gemini's chat-file format is text-only. The Soul-Desktop replay view still shows the full history because that reads from `hooks.jsonl`, not from the Gemini chat file. The chat file is *only* used to unlock live-resume via ACP `session/load`.

**Risk:** if the chat-file JSON shape changes between Gemini-CLI versions, the synthesized file might be rejected by a newer Gemini. Mitigation: read a freshly-written chat from a current gemini-cli session as the shape template, not a months-old file.

---

## 7. Recommended execution order for the next agent

1. **Verify state:** run the `find` and `cat ~/.gemini/projects.json` checks from §1 to confirm nothing has changed since this handoff was written (2026-05-16, ~01:00 ET).
2. **Execute SOUL-SOUL-010 first:** rewrite projects.json (`dotfiles/soul → "soul-kernel"`), `mv ~/.gemini/tmp/soul-1 ~/.gemini/tmp/soul-kernel`. This prevents the slug from drifting under you mid-reconstruction.
3. **Read a healthy Gemini chat file as a shape template:** something like `~/.gemini/tmp/soul-desktop/chats/<some-recent-uuid>.json`. Confirm the JSON shape — message-list with role/parts/timestamp fields. Don't guess; copy.
4. **Build a small Python script** `scripts/reconstruct_gemini_chat.py` that:
   - Takes `--sid`, `--project` args.
   - Reads `~/soul_registry/sessions/<project>/<sid>/hooks.jsonl`.
   - Produces the chat-file JSON via the shape template.
   - Writes to `~/.gemini/tmp/<slug>/chats/<sid>.json` (looking up `<slug>` from projects.json via the cwd recorded in SESSION_START).
   - Idempotent (refuses to overwrite a non-stub file unless `--force`).
5. **Run it for ca427f63.** Then ask the user to reopen Soul-Desktop and confirm the row goes live.
6. **File a task for the reconstructor itself.** Once the script exists, it's a generally-useful "Repair session link" tool — worth promoting to a right-click affordance in the sidebar (related to the existing recovery primitives).

---

## 8. What NOT to do

- **Don't trash `~/.gemini/tmp/soul/`** without auditing the chats inside. It's an orphan from a prior project mapping; some sessions under it might still matter to the user.
- **Don't edit `hooks.jsonl`** to make it look like a Gemini chat file — they have different schemas, and Soul-Desktop's replay path reads `hooks.jsonl` and will choke on a malformed one.
- **Don't run a second cleanup like the 22:58 one** — it merged contents without fixing the basename-collision trigger and produced this exact mess. The slug rename is the structural fix; content merging without an explicit mapping change is a band-aid that gets re-suffixed on the next spawn.
- **Don't quit the running actor-orchestrator daemon** (`zmx run supervisor ... gemini orchestrate`, PID 49405). It's in `/Users/ilteris/Code/actor-orchestrator`, totally unrelated to dotfiles/soul, and not touching projects.json for this slug.

---

## 9. Open questions for the user (not for the next agent)

- After ca427f63 is resurrected, do you want to manually `/finalize` it to capture the work? Or just let it sit live?
- Should the reconstructor live as `scripts/reconstruct_gemini_chat.py` (one-off) or get promoted to a Soul-Desktop right-click "Repair session link" affordance now that we know this class of bug recurs? The 437c9a35 incident plus ca427f63 makes it twice in two days.
