#!/usr/bin/env python3
"""
SOUL-SOUL_DESKTOP-058 probe.

Question: does `gemini --acp` accept a session UUID minted by the gemini CLI
in a terminal? If yes, terminal-origin Gemini rows in Soul-Desktop's sidebar
are live-resumable with no content-match needed — same-binary providers share
a single namespace, like Codex.

Mechanics: spawn `gemini --acp`, do the ACP handshake, then call
`session/load` with a UUID pulled from `~/.gemini/tmp/<basename>/chats/`.
Report the response. Newline-delimited JSON-RPC, matching ACPTransport.

Usage:
  scripts/probe_gemini_resume.py                       # auto-pick first UUID dir
  scripts/probe_gemini_resume.py <uuid>                # explicit UUID
  scripts/probe_gemini_resume.py <uuid> --cwd <path>   # explicit cwd
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def find_cli_minted_uuid() -> tuple[str, str] | None:
    """Walk ~/.gemini/tmp/<basename>/chats/ and return (uuid, cwd_basename)."""
    root = Path.home() / ".gemini" / "tmp"
    if not root.is_dir():
        return None
    for basename_dir in sorted(root.iterdir()):
        chats = basename_dir / "chats"
        if not chats.is_dir():
            continue
        for entry in sorted(chats.iterdir()):
            if entry.is_dir() and UUID_RE.match(entry.name):
                return entry.name, basename_dir.name
    return None


def encode_frame(obj: dict) -> bytes:
    return (json.dumps(obj) + "\n").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("uuid", nargs="?", help="Gemini session UUID; auto-discovered if omitted")
    parser.add_argument("--cwd", default=os.getcwd(), help="cwd to pass on session/load (default: $PWD)")
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    target_uuid = args.uuid
    if not target_uuid:
        found = find_cli_minted_uuid()
        if not found:
            print("error: no UUID-named dir under ~/.gemini/tmp/*/chats/", file=sys.stderr)
            return 2
        target_uuid, basename = found
        print(f"auto-picked uuid={target_uuid} (from ~/.gemini/tmp/{basename}/chats/)")

    print(f"probe: gemini --acp ← session/load sessionId={target_uuid} cwd={args.cwd}")

    proc = subprocess.Popen(
        ["gemini", "--acp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    assert proc.stdin and proc.stdout and proc.stderr

    pending: dict[int, dict] = {}
    pending_lock = threading.Lock()
    stderr_lines: list[str] = []

    def read_stdout():
        for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace").rstrip()
            if not line:
                continue
            try:
                env = json.loads(line)
            except json.JSONDecodeError:
                print(f"[non-json stdout] {line}")
                continue
            req_id = env.get("id")
            if req_id is not None and "method" not in env:
                with pending_lock:
                    pending[req_id] = env
                continue
            # Server-initiated request from gemini (e.g. fs/read or permission).
            if "method" in env and req_id is not None:
                print(f"[server-request id={req_id}] method={env.get('method')}")
                # Refuse cleanly so the agent doesn't hang on us.
                resp = {"jsonrpc": "2.0", "id": req_id,
                        "error": {"code": -32601, "message": "probe does not implement client side"}}
                try:
                    proc.stdin.write(encode_frame(resp))
                    proc.stdin.flush()
                except BrokenPipeError:
                    return
                continue
            if "method" in env:
                # Pure notification — log first few then go quiet.
                print(f"[notif] method={env.get('method')}")

    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode("utf-8", errors="replace").rstrip()
            if line:
                stderr_lines.append(line)

    threading.Thread(target=read_stdout, daemon=True).start()
    threading.Thread(target=read_stderr, daemon=True).start()

    def call(method: str, params: dict, req_id: int) -> dict | None:
        frame = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
        try:
            proc.stdin.write(encode_frame(frame))
            proc.stdin.flush()
        except BrokenPipeError:
            return None
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            with pending_lock:
                if req_id in pending:
                    return pending.pop(req_id)
            time.sleep(0.05)
        return None

    # 1. initialize
    init_resp = call("initialize", {
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True}, "terminal": False},
        "clientInfo": {"name": "soul-desktop-probe", "version": "0.1"},
    }, req_id=1)

    if init_resp is None:
        print("FAIL: no initialize response within timeout")
        proc.kill()
        for line in stderr_lines[-20:]:
            print(f"[stderr] {line}")
        return 1

    if "error" in init_resp:
        print(f"FAIL: initialize error: {init_resp['error']}")
        proc.kill()
        return 1

    agent_caps = init_resp.get("result", {}).get("agentCapabilities", {})
    load_supported = agent_caps.get("loadSession", False)
    print(f"initialize ok: agentCapabilities.loadSession={load_supported}")
    print(f"agentInfo={init_resp.get('result', {}).get('agentInfo')}")

    if not load_supported:
        print("STOP: this gemini build does not advertise loadSession; cross-surface resume is impossible at the protocol level.")
        proc.kill()
        return 0

    # 2. session/load with the CLI-minted UUID
    load_resp = call("session/load", {
        "cwd": args.cwd,
        "mcpServers": [],
        "sessionId": target_uuid,
    }, req_id=2)

    if load_resp is None:
        print("INCONCLUSIVE: no session/load response within timeout (agent may be streaming history; rerun with larger --timeout)")
        proc.kill()
        return 1

    if "error" in load_resp:
        err = load_resp["error"]
        print(f"REJECTED: session/load error code={err.get('code')} message={err.get('message')!r}")
        print("→ Gemini does NOT accept CLI-minted UUIDs over ACP from a fresh process.")
        print("→ Repair-link content-match remains the only path for terminal-origin rows.")
    else:
        print(f"ACCEPTED: session/load result={load_resp.get('result')}")
        print("→ Gemini accepts CLI-minted UUIDs cross-process. Terminal-origin rows are live-resumable.")
        print("→ Wire LiveSessionRow to drop the isResumable=false gate for Gemini and route loadSession with the on-disk UUID.")

    proc.terminate()
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        proc.kill()

    if stderr_lines:
        print("--- stderr tail ---")
        for line in stderr_lines[-10:]:
            print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
