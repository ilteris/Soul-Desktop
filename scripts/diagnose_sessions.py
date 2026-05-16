#!/usr/bin/env python3
"""
diagnose_sessions.py — registry-wide audit of ~/soul_registry/sessions/

Reports every session the desktop knows about, scored by:
  - hooks.jsonl size + line count (load-cost estimate; predicts beachball risk)
  - SESSION_START.ppid (==1 → launch-agent residue, hidden from sidebar by -061)
  - presence of UserPrompt events (zero → "substantive" gate fails, hidden)
  - presence of finalize JSON sibling (truthy → row promotes to Chats)
  - last activity timestamp
  - provider, project, first-prompt preview

Use this to find (a) sessions heavy enough to beachball the UI and
(b) sessions the sidebar is silently hiding.

No writes. Read-only. Safe to re-run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

REGISTRY = Path(os.path.expanduser(os.environ.get("SOUL_REGISTRY", "~/soul_registry")))
SESSIONS = REGISTRY / "sessions"

# Risk thresholds — tuned by hand, easy to override at the CLI.
HEAVY_BYTES = 1_500_000   # 1.5 MB hooks.jsonl ≈ noticeable load lag
HEAVY_LINES = 4_000


@dataclass
class SessionInfo:
    project: str
    sid: str
    hooks_path: Path
    finalize_path: Optional[Path]
    bytes: int = 0
    lines: int = 0
    user_prompts: int = 0
    agent_messages: int = 0
    tool_calls: int = 0
    session_start_ppid: Optional[int] = None
    session_start_provider: Optional[str] = None
    first_prompt: Optional[str] = None
    finalize_intent: Optional[str] = None
    last_event_ts: Optional[float] = None
    mtime: float = 0.0
    flags: list[str] = field(default_factory=list)

    @property
    def has_finalize(self) -> bool:
        return self.finalize_path is not None

    @property
    def hidden_by_sidebar(self) -> bool:
        # Mirrors the desktop's substantive gate (SOUL-SOUL_DESKTOP-061):
        # launch-agent residue (ppid==1 with no UserPrompt and no finalize)
        # is filtered out of the sidebar.
        if (
            self.session_start_ppid == 1
            and self.user_prompts == 0
            and not self.has_finalize
        ):
            return True
        return False


def _read_jsonl_stream(path: Path):
    """Yield parsed JSON objects from a JSONL file; tolerate truncated lines."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    yield json.loads(raw)
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        return


def _scan_session(project: str, sid: str, hooks_path: Path, finalize_path: Optional[Path]) -> SessionInfo:
    info = SessionInfo(project=project, sid=sid, hooks_path=hooks_path, finalize_path=finalize_path)
    try:
        st = hooks_path.stat()
        info.bytes = st.st_size
        info.mtime = st.st_mtime
    except FileNotFoundError:
        info.flags.append("hooks-missing")
        return info

    for ev in _read_jsonl_stream(hooks_path):
        info.lines += 1
        kind = ev.get("event") or ev.get("type") or ""
        if kind == "SESSION_START":
            info.session_start_ppid = ev.get("ppid")
            info.session_start_provider = ev.get("provider") or ev.get("agent")
        elif kind == "UserPrompt":
            info.user_prompts += 1
            if info.first_prompt is None:
                payload = ev.get("prompt") or ev.get("text") or ev.get("content") or ""
                if isinstance(payload, str):
                    info.first_prompt = payload[:120]
        elif kind in ("AfterAgent", "AgentMessage", "agent_message"):
            info.agent_messages += 1
        elif kind in ("BeforeTool", "AfterTool", "tool_call"):
            info.tool_calls += 1

        ts = ev.get("timestamp") or ev.get("ts")
        if isinstance(ts, str):
            try:
                import datetime as _dt
                dt = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                info.last_event_ts = dt.timestamp()
            except ValueError:
                pass

    if finalize_path is not None:
        try:
            data = json.loads(finalize_path.read_text(encoding="utf-8", errors="replace"))
            intent = data.get("intent") or (data.get("quad") or {}).get("intent")
            if isinstance(intent, str):
                info.finalize_intent = intent[:120]
        except (FileNotFoundError, json.JSONDecodeError):
            info.flags.append("finalize-unreadable")

    if info.bytes >= HEAVY_BYTES or info.lines >= HEAVY_LINES:
        info.flags.append(f"HEAVY({info.bytes // 1024}KB/{info.lines}L)")
    if info.user_prompts == 0 and not info.has_finalize and info.lines > 0:
        info.flags.append("no-prompts")
    if info.session_start_ppid == 1:
        info.flags.append("ppid=1")
    if info.lines == 0:
        info.flags.append("empty")
    if info.hidden_by_sidebar:
        info.flags.append("HIDDEN-BY-SIDEBAR")

    return info


def scan_all() -> list[SessionInfo]:
    out: list[SessionInfo] = []
    if not SESSIONS.exists():
        print(f"[diagnose] registry sessions dir not found: {SESSIONS}", file=sys.stderr)
        return out
    for project_dir in sorted(SESSIONS.iterdir()):
        if not project_dir.is_dir():
            continue
        project = project_dir.name
        # Map every <sid> dir + every <sid>.json finalize sibling.
        sid_dirs: dict[str, Path] = {}
        sid_finalize: dict[str, Path] = {}
        for entry in project_dir.iterdir():
            if entry.is_dir():
                hooks = entry / "hooks.jsonl"
                if hooks.exists():
                    sid_dirs[entry.name] = hooks
            elif entry.suffix == ".json":
                # Finalize names can be <sid>.json or <ts>_<sid>.json.
                stem = entry.stem
                # Heuristic: trailing 36-char UUID-shaped substring.
                tail = stem.split("_")[-1]
                sid_finalize[tail] = entry
        all_sids = set(sid_dirs) | set(sid_finalize)
        for sid in sorted(all_sids):
            hooks = sid_dirs.get(sid) or project_dir / sid / "hooks.jsonl"
            finalize = sid_finalize.get(sid)
            out.append(_scan_session(project, sid, hooks, finalize))
    return out


def _fmt_age(mtime: float) -> str:
    if mtime <= 0:
        return "—"
    age = time.time() - mtime
    if age < 60:
        return f"{int(age)}s"
    if age < 3600:
        return f"{int(age / 60)}m"
    if age < 86400:
        return f"{int(age / 3600)}h"
    return f"{int(age / 86400)}d"


def _fmt_kb(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n // 1024}KB"
    return f"{n / (1024 * 1024):.1f}MB"


def render(sessions: list[SessionInfo], only_flagged: bool, sort: str) -> None:
    if sort == "size":
        sessions.sort(key=lambda s: s.bytes, reverse=True)
    elif sort == "lines":
        sessions.sort(key=lambda s: s.lines, reverse=True)
    elif sort == "age":
        sessions.sort(key=lambda s: s.mtime, reverse=True)
    else:
        sessions.sort(key=lambda s: (s.project, s.sid))

    rows = [s for s in sessions if (not only_flagged or s.flags)]
    if not rows:
        print("[diagnose] no sessions match filter")
        return

    print(f"{'PROJECT':<24} {'SID':<12} {'SIZE':>8} {'LINES':>6} {'U/A/T':>10} {'AGE':>5}  {'FIN':<3} {'PROV':<6} FLAGS / TITLE")
    print("-" * 140)
    for s in rows:
        sid_short = s.sid[:8] if len(s.sid) >= 8 else s.sid
        u_a_t = f"{s.user_prompts}/{s.agent_messages}/{s.tool_calls}"
        title = (s.finalize_intent or s.first_prompt or "").replace("\n", " ")
        if len(title) > 60:
            title = title[:57] + "…"
        flags = " ".join(s.flags)
        line = (
            f"{s.project[:24]:<24} "
            f"{sid_short:<12} "
            f"{_fmt_kb(s.bytes):>8} "
            f"{s.lines:>6} "
            f"{u_a_t:>10} "
            f"{_fmt_age(s.mtime):>5}  "
            f"{'Y' if s.has_finalize else '·':<3} "
            f"{(s.session_start_provider or '—')[:6]:<6} "
            f"{flags + ('  ' + title if title else '')}"
        )
        print(line)

    # Totals + counters
    total = len(sessions)
    heavy = [s for s in sessions if any(f.startswith("HEAVY") for f in s.flags)]
    hidden = [s for s in sessions if "HIDDEN-BY-SIDEBAR" in s.flags]
    empty = [s for s in sessions if "empty" in s.flags]
    finalized = [s for s in sessions if s.has_finalize]
    print()
    print(f"[summary] {total} sessions total")
    print(f"          {len(heavy):3d} HEAVY (>{HEAVY_BYTES//1024}KB or >{HEAVY_LINES} lines)  ← beachball candidates")
    print(f"          {len(hidden):3d} HIDDEN-BY-SIDEBAR (ppid=1, no prompts, no finalize)")
    print(f"          {len(empty):3d} empty hooks.jsonl")
    print(f"          {len(finalized):3d} have finalize sibling")


def main() -> int:
    ap = argparse.ArgumentParser(description="Audit ~/soul_registry/sessions/ for size + sidebar visibility")
    ap.add_argument("--flagged", action="store_true", help="Only show rows with at least one flag")
    ap.add_argument("--sort", choices=("project", "size", "lines", "age"), default="size",
                    help="Sort order (default: size desc)")
    ap.add_argument("--project", help="Limit to a single project key")
    args = ap.parse_args()

    sessions = scan_all()
    if args.project:
        sessions = [s for s in sessions if s.project == args.project]
    render(sessions, only_flagged=args.flagged, sort=args.sort)
    return 0


if __name__ == "__main__":
    sys.exit(main())
