#!/usr/bin/env python3
"""
Scan ~/.gemini/tmp/*/chats/*.jsonl for oversized lines.

Background: gemini-cli's chatRecordingService used to re-serialize the
entire parent message on every tool-call update, embedding the cumulative
tool-result content into every later JSONL line. A 13-turn session with
one 36 MB tool result ballooned to 2.17 GB. The Soul-Desktop streaming
reader caps each parsed line at 32 MB and skips above that, but the user
deserves visibility into how bad the bloat got even when the desktop
silently survives it.

Usage:
    ./scripts/check_gemini_bloat.py            # scan all chat files
    ./scripts/check_gemini_bloat.py <path>     # scan one specific file
    ./scripts/check_gemini_bloat.py --watch    # poll every 2s
"""

import argparse
import glob
import os
import sys
import time

WARN_BYTES = 5 * 1024 * 1024   # 5 MB — visible bloat
SKIP_BYTES = 32 * 1024 * 1024  # 32 MB — Soul-Desktop drops past this


def scan(path: str) -> dict | None:
    """Return stats dict, or None if file is small/empty."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    warned, skipped, largest, lines = 0, 0, 0, 0
    with open(path, "rb") as f:
        for line in f:
            lines += 1
            n = len(line)
            if n > largest:
                largest = n
            if n > SKIP_BYTES:
                skipped += 1
            elif n > WARN_BYTES:
                warned += 1
    return {
        "path": path,
        "size": size,
        "lines": lines,
        "warned": warned,
        "skipped": skipped,
        "largest": largest,
    }


def fmt(stats: dict) -> str:
    size_mb = stats["size"] / 1_048_576
    largest_mb = stats["largest"] / 1_048_576
    flag = ""
    if stats["skipped"] > 0:
        flag = "❌ "
    elif stats["warned"] > 0:
        flag = "⚠️  "
    return (
        f"{flag}{stats['path']}\n"
        f"    size={size_mb:7.1f} MB  lines={stats['lines']:5d}  "
        f"largest={largest_mb:6.2f} MB  "
        f"warned={stats['warned']}  skipped={stats['skipped']}"
    )


def all_chat_files() -> list[str]:
    home = os.path.expanduser("~")
    pattern_jsonl = os.path.join(home, ".gemini/tmp/*/chats/*.jsonl")
    pattern_json = os.path.join(home, ".gemini/tmp/*/chats/*.json")
    return sorted(glob.glob(pattern_jsonl) + glob.glob(pattern_json))


def run_once(paths: list[str]) -> int:
    bloated = 0
    for p in paths:
        s = scan(p)
        if s is None:
            continue
        if s["warned"] == 0 and s["skipped"] == 0:
            continue
        bloated += 1
        print(fmt(s))
    if bloated == 0:
        print("✅ no bloated chat files")
    else:
        print(f"\n{bloated} bloated file(s)")
    return bloated


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("path", nargs="?", help="specific file to scan")
    p.add_argument("--watch", action="store_true", help="poll every 2s")
    args = p.parse_args()

    paths = [args.path] if args.path else all_chat_files()
    if not paths:
        print("no chat files found", file=sys.stderr)
        return 1

    if args.watch:
        try:
            while True:
                os.system("clear")
                print(f"watching {len(paths)} file(s) — Ctrl-C to exit\n")
                run_once(paths)
                time.sleep(2)
        except KeyboardInterrupt:
            return 0
    else:
        return 0 if run_once(paths) == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
