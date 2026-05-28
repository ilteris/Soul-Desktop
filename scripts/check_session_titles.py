#!/usr/bin/env python3
"""Smoke-check session title sources by provider.

This script is intentionally read-only. It uses the kernel `soul session list`
JSON surface, then reports provider/title_source distribution plus obvious
title leaks: prompt-copy titles, Codex file envelopes, machine scaffolds,
absolute paths, and JSON payloads.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from collections import Counter, defaultdict


BAD_TITLE_RE = re.compile(
    r"(Files mentioned by the user|<environment_context|<prior_session_context|"
    r"<command-name>|/var/folders/|TemporaryItems|^/Users/|^~/|"
    r"^# Files mentioned|^# Overview Generate 0 to 3|"
    r"You are Teddy.*Registry Pulse|skeptical auditor|finalized session metadata|"
    r"^\{|\[)",
    re.IGNORECASE,
)


def normalize(text: str) -> str:
    return (
        " ".join(text.split())
        .replace("...", "")
        .replace("…", "")
        .strip()
        .casefold()
    )


def load_project(project: str) -> list[dict]:
    out = subprocess.check_output(
        ["/Users/ilteris/dotfiles/soul/bin/soul", "session", "list", "-p", project, "--json"],
        text=True,
    )
    data = json.loads(out)
    return data.get("sessions", data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("projects", nargs="*", default=["soul-desktop"])
    args = parser.parse_args()

    exit_code = 0
    for project in args.projects:
        rows = load_project(project)
        by_provider = Counter(row.get("provider") or "unknown" for row in rows)
        by_source: dict[str, Counter] = defaultdict(Counter)
        leaks: list[tuple[str, str, str, str]] = []
        prompt_copy_first_prompt: list[tuple[str, str, str, str]] = []

        for row in rows:
            provider = row.get("provider") or "unknown"
            source = row.get("title_source") or "unknown"
            title = (row.get("title") or "").strip()
            by_source[provider][source] += 1
            first = ((row.get("first_user_prompts") or [""])[0] or "").strip()
            prompt_copy = bool(title and first and normalize(title) == normalize(first[: len(title)]))
            if title and BAD_TITLE_RE.search(title):
                leaks.append((row.get("session_id") or "unknown", provider, source, title[:120]))
            elif prompt_copy and source == "first_prompt":
                prompt_copy_first_prompt.append((row.get("session_id") or "unknown", provider, source, title[:120]))
            elif prompt_copy:
                leaks.append((row.get("session_id") or "unknown", provider, source, title[:120]))

        print(f"{project}: sessions={len(rows)} providers={dict(by_provider)}")
        for provider in sorted(by_source):
            print(f"  {provider}: {dict(by_source[provider])}")
        print(f"  bad_title_matches={len(leaks)}")
        print(f"  first_prompt_prompt_copy_rows={len(prompt_copy_first_prompt)}")
        for sid, provider, source, title in leaks[:20]:
            print(f"    BAD {sid} {provider} {source}: {title!r}")
        for sid, provider, source, title in prompt_copy_first_prompt[:10]:
            print(f"    FIRST_PROMPT {sid} {provider} {source}: {title!r}")
        if leaks:
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
