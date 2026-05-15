# Soul Desktop

A native macOS chat client for coding agents — Claude Code, Gemini-CLI, OpenAI Codex, and Pi — all in one window, backed by a local session ledger.

Soul Desktop talks to each agent over the [Agent Client Protocol](https://github.com/zed-industries/agent-client-protocol) (ACP) and writes every prompt and reply to a project-keyed JSONL ledger on disk. Open the app, click a session from six weeks ago, and pick up where you left off — same context, same agent, same project root. No cloud, no account.

## Why

I switch between Claude, Gemini, Codex, and Pi depending on the task. Every one of them ships a CLI with its own session-resume model, its own transcript file format, and its own quirks. I built Soul Desktop so I can:

- See every conversation across every agent in one sidebar, sorted by recency, filtered by project.
- Resume any of them by clicking — no copy-pasting prompts into a fresh terminal, no `--resume <some-uuid>`.
- Replay any session top-to-bottom from the on-disk ledger, even if the agent's own transcript got rotated or corrupted.
- Run slash commands (`/pulse`, `/finalize`, …) that expand into project-aware prompts before they hit the agent.

The kernel ledger is the authoritative source. Provider transcripts are caches.

## Status

Single-user side project. Built for my own daily workflow on macOS 26.x. Not packaged for distribution. The Xcode scheme `Soul-Desktop Dev` is what I run.

## Build

Requires:
- Xcode 16+ on macOS 26.3 or newer (Apple Silicon)
- The agents themselves on `PATH`:
  - `claude` via `npx @agentclientprotocol/claude-agent-acp`
  - `gemini` (Google's gemini-cli)
  - `codex` (OpenAI's `codex app-server`)
  - `pi` via `npx pi-acp`

Open `Soul-Desktop.xcodeproj` in Xcode, pick the `Soul-Desktop Dev` scheme, hit run.

For a watch-and-rebuild dev loop:

```
brew install fswatch
./scripts/dev.sh
```

This rebuilds and relaunches the app on every save to `Soul-Desktop/*.swift`.

## How it's wired

```
┌──────────────────┐   ACP / JSON-RPC over stdio   ┌─────────────┐
│   Soul Desktop   │ ←──────────────────────────→  │  Agent CLI  │
│   (SwiftUI)      │                               │  (claude,   │
│                  │                               │   gemini,   │
│  ThreadController│                               │   codex,    │
│        ↓         │                               │   pi-acp)   │
│   ACPClient      │                               └─────────────┘
│        ↓         │
│  ACPTransport    │                               ┌─────────────┐
└────────┬─────────┘                               │   Kernel    │
         │                                         │   ledger    │
         └────── hooks.jsonl writes ─────────────→ │  per project│
                                                   └─────────────┘
```

Three layers, top to bottom:

- **SwiftUI surface** — `AppShell.swift`, `SidebarView.swift`, `ThreadView.swift`, `ComposerView.swift`. Everything you see.
- **Controller** — `ThreadController.swift` owns the per-thread state machine: spawn, resume, prompt, cancel, tool-call rendering, queue-on-busy, stall watchdog, slash-command expansion.
- **ACP layer** — `Soul-Desktop/ACP/`. `ACPTransport` is the stdio framer, `ACPClient` is the JSON-RPC client, `ACPProtocol` is the type-checked notification decoder, `ACPProviderSpawn` resolves the right CLI invocation per provider.

### Session resume

Each provider has a different resume story; the desktop normalizes them through ACP's `session/load`:

| Provider | Resume path | Notes |
|---|---|---|
| Claude | ACP `session/load` | First-class. Streams prior transcript via user/agent message chunks. |
| Gemini-CLI | ACP `session/load` | First-class. Files chats under `~/.gemini/tmp/<basename>(-N)/chats/`. |
| Codex | `hydrateFromDisk` + ACP `session/load` | Codex doesn't speak `session/load` over RPC; rendered from kernel ledger, lazy spawn on first send. |
| Pi | ACP `session/load` | First-class as of pi-acp 0.0.27. Earlier code used a `--resume` CLI flag that pi-acp doesn't parse; that's gone. |

### Sources of truth

- **`~/soul_registry/sessions/<project>/<sid>/hooks.jsonl`** — the kernel ledger. Every prompt, every assistant turn, every tool call. Replay reads from this.
- **`~/soul_registry/sessions/<project>/<sid>.json`** — finalize summary written by `/finalize`.
- **`~/dotfiles/soul/config/PROJECTS.json`** — the project manifest. Adds a path/name/pillar entry for every project the sidebar should know about.

Provider-specific transcripts (`~/.claude/projects/...`, `~/.gemini/tmp/...`, `~/.pi/agent/sessions/...`) are treated as caches. If they're missing or corrupt, the kernel ledger is enough to render a Replay.

## Directory map

```
Soul-Desktop/
├── Soul_DesktopApp.swift        SwiftUI App entry
├── AppShell.swift               Three-pane shell: sidebar, canvas, optional right panel
├── SidebarView.swift            Projects + sessions list, filters, archive disclosure
├── ThreadView.swift             Per-thread canvas: transcript + tool rows + composer
├── ComposerView.swift           Bottom input, slash palette, file chips, harness/permission pickers
├── ThreadController.swift       Per-thread state machine; the heart of the app
├── SoulRegistry.swift           Reads ~/soul_registry, builds sidebar rows, caches scans
├── Providers.swift              Provider enum + per-provider stall budgets + icons
├── ACP/
│   ├── ACPTransport.swift       stdio framer, length-prefixed JSON-RPC
│   ├── ACPClient.swift          JSON-RPC client, pending request map, event stream
│   ├── ACPProtocol.swift        Codable types for ACP requests/notifications
│   ├── ACPProviderSpawn.swift   Per-provider executable resolution + argv
│   └── CodexClient.swift        Codex-specific app-server JSON-RPC variant
├── ReplayController.swift       Read-only playback of a finalized session
├── ReplayView.swift             Replay UI + scrubber
├── HooksReader.swift            Streaming hooks.jsonl reader
├── ClaudeTranscriptReader.swift Off-disk Claude transcript → ThreadItems
├── GeminiTranscriptReader.swift Off-disk Gemini chat → ThreadItems
├── SessionLoadability.swift     Per-row "is this resumable?" probe
├── ArchiveStore.swift           Per-project archived-session set
├── ActiveTaskStore.swift        Pulls the active SOUL-* task from the registry
├── DesignSystem.swift           Fonts, colors, metrics, SoulIcon
├── TypographyLab.swift          Standalone window (⌘⌥T) for tuning fonts live
└── ...
```

## Slash commands

The composer expands `/cmd` into a project-aware prompt before sending. Built-ins live in `SkillsRegistry.swift`; user-defined skills are read from `~/.claude/skills/<name>/SKILL.md`.

Claude reads `~/.claude/skills/` natively, so for Claude sessions the desktop sends the bare `/cmd` and lets the agent expand it. For Gemini, Pi, and Codex, the desktop expands client-side.

## Recovery affordances

A few non-obvious surfaces worth knowing about:

- **Skip-ahead** — when the agent stalls past its provider's budget and a queued prompt is waiting, a Recover capsule appears on the working indicator. Cancels the in-flight turn, marks lingering tool rows stopped, and dispatches the next queued prompt.
- **Repair session link** — right-click a session row → "Repair session link" if the provider lost track of the UUID. Does a content-match between the kernel's first prompt and any orphan agent transcripts.
- **Trash a session** — right-click an archived session → "Delete (move to Trash)". Moves the kernel dir, finalize JSON, and any provider-side chat files to `~/.Trash`; recoverable from Finder.

## Diagnostic logging

For ACP-layer visibility during a stall:

```
defaults write Soul-Desktop soul.acp.trace -bool true
```

Every recognized `session/update` lands in the in-memory agent log as `[acp ←] <kind> (<size>)`. Unknown notification kinds and undecodable session updates are logged unconditionally.

## License

No license file. This isn't a packaged product.
