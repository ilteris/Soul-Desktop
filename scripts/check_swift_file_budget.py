#!/usr/bin/env python3
"""Report Swift files that exceed Soul Desktop's composability budget."""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = (ROOT / "Soul-Desktop", ROOT / "Soul-DesktopTests")


@dataclass(frozen=True)
class Budget:
    target: int
    hard: int
    owner: str


EXCEPTIONS: dict[str, str] = {
    "Soul-Desktop/MarkdownView.swift": "SOUL-SOUL_DESKTOP-227 follow-up: split markdown block renderers after CPU-spin fix",
    "Soul-Desktop/ThreadController+ACP.swift": "SOUL-SOUL_DESKTOP-225 follow-up: split notification decoders by ACP update kind",
    "Soul-Desktop/ThreadController.swift": "SOUL-SOUL_DESKTOP-225 follow-up: continue facade/state extraction without @Observable regression",
    "Soul-Desktop/ThreadController+Codex.swift": "SOUL-SOUL_DESKTOP-225 follow-up: split Codex event and payload parsing",
    "Soul-Desktop/SoulRegistry.swift": "SOUL-SOUL_DESKTOP-222 follow-up: move remaining scan/cache services behind registry store",
    "Soul-Desktop/SoulRegistry+Sessions.swift": "SOUL-SOUL_DESKTOP-222 follow-up: split native-session and hook-file readers",
    "Soul-Desktop/SidebarView+Rows.swift": "SOUL-SOUL_DESKTOP-220 follow-up: split row menus and metadata badges",
    "Soul-Desktop/ThreadView.swift": "SOUL-SOUL_DESKTOP-221 follow-up: move remaining scroll orchestration into focused helper",
    "Soul-Desktop/ComposerView.swift": "SOUL-SOUL_DESKTOP-219 follow-up: split composer queue and permission controls",
}


def classify(path: Path) -> Budget:
    name = path.name
    rel = path.relative_to(ROOT).as_posix()
    if "View" in name or name.endswith("Pane.swift") or name.endswith("Row.swift"):
        return Budget(target=500, hard=700, owner="view")
    if "Controller" in name or "Coordinator" in name or "Registry" in name or "Store" in name:
        return Budget(target=600, hard=900, owner="coordinator/model")
    if rel.startswith("Soul-DesktopTests/"):
        return Budget(target=500, hard=900, owner="test")
    return Budget(target=600, hard=900, owner="support")


def swift_files() -> list[Path]:
    files: list[Path] = []
    for source_dir in SOURCE_DIRS:
        if not source_dir.exists():
            continue
        for path in source_dir.rglob("*.swift"):
            if "/.build/" in path.as_posix():
                continue
            files.append(path)
    return sorted(files)


def line_count(path: Path) -> int:
    with path.open("rb") as fh:
        return sum(1 for _ in fh)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true", help="Fail on target warnings, not only hard-cap errors.")
    args = parser.parse_args()

    exceptions: list[tuple[str, int, Budget, str]] = []
    warnings: list[tuple[str, int, Budget, str]] = []
    errors: list[tuple[str, int, Budget, str]] = []
    for path in swift_files():
        rel = path.relative_to(ROOT).as_posix()
        count = line_count(path)
        budget = classify(path)
        exception = EXCEPTIONS.get(rel, "")
        if count > budget.hard and exception:
            exceptions.append((rel, count, budget, exception))
        elif count > budget.hard:
            errors.append((rel, count, budget, exception))
        elif count > budget.target:
            warnings.append((rel, count, budget, exception))

    print("Swift file-size budget")
    print(f"root: {ROOT}")
    print("policy: views target <=500 hard <=700; coordinators/models target <=600 hard <=900; no Swift file >1000")
    print()

    if not errors and not exceptions and not warnings:
        print("OK: all Swift files are within target budgets.")
        return 0

    def emit(label: str, rows: list[tuple[str, int, Budget, str]]) -> None:
        if not rows:
            return
        print(label)
        for rel, count, budget, exception in sorted(rows, key=lambda row: row[1], reverse=True):
            task = exception or "no owning task recorded"
            print(f"- {rel}: {count} lines ({budget.owner}, target {budget.target}, hard {budget.hard}) -> {task}")
        print()

    emit("ERROR: hard-cap violations", errors)
    emit("TEMPORARY EXCEPTIONS: over hard cap but task-linked", exceptions)
    emit("WARN: above target budget", warnings)

    if errors or (args.strict and warnings):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
