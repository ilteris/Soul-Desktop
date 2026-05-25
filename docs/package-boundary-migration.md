# Package Boundary Migration

Soul Desktop is moving from folder-only boundaries to SwiftPM-enforced module
boundaries, following the same architectural direction as Boldly:

```text
App target -> feature/UI assembly
SoulCore  -> pure domain contracts
SoulACP   -> ACP/Codex wire protocol and stdio transport
SoulLedger -> registry, hooks, replay, transcript readers
SoulRuntime -> reusable agent/session orchestration
```

## Current Inventory

The app currently has 33k+ Swift lines in one Xcode app target. The largest
coupling knots are:

- `AppShellV2.swift` at ~2700 lines: control-panel prototype, task queue,
  operation rendering, and subagent launch concerns in one UI file.
- `SoulRegistry.swift` + `SoulRegistry+Sessions.swift` at ~2100 lines:
  project/session domain models, filesystem roots, cache policy, registry
  scans, provider transcript matching, and CLI fallback.
- `ThreadController.swift` plus extensions at ~5300 lines: domain display
  models, live state machine, ACP event application, Codex bridging, hydrate,
  queueing, watchdogs, and transcript backfill.
- `HooksReader.swift` at ~620 lines: read-side ledger mapping into UI
  `ThreadItem` models.
- `ComposerView.swift`, `ThreadView.swift`, and sidebar files: SwiftUI surfaces
  that should remain app/UI-layer code.

## Target Slices

### SoulCore

Pure Swift domain contracts. No SwiftUI, AppKit, Process, UserDefaults, or
filesystem scanning.

Initial candidates:

- `AgentProvider` / `Provider` domain identity after splitting UI-only
  labels/icons/settings.
- `SoulProject`, `SoulSession`, `SessionWriter`.
- `ThreadItem`, `ToolCallDetails`, `PlanEntry`.
- `AgentPermissionMode` / `PermissionMode`, `SlashCommand`,
  `SlashCommandParse`.

### SoulACP

Wire protocol and process transport for ACP-compatible agents and Codex
app-server. This package should not know about SwiftUI views.

Initial compiled slice:

- `ACPProtocol.swift`
- `ACPTransport.swift`

Later moves:

- `ACPClient.swift` after `ACPProviderSpawn` and `PermissionMode` dependencies
  are split cleanly.
- `CodexClient.swift` once the shared JSON-RPC wire layer is extracted.
- `ACPProviderSpawn.swift` after provider identity and registry-root settings
  live in non-UI services.

### SoulLedger

Local ledger and transcript readers. Depends on `SoulCore`, not SwiftUI.

Candidates:

- `HooksReader.swift`
- `ThreadLedger.swift`
- `SoulRegistry` scan/cache services after domain models move to `SoulCore`.
- `ClaudeTranscriptReader.swift`, `GeminiTranscriptReader.swift`,
  `PiTranscriptReader.swift`.
- `ReplayController` only after replay output is decoupled from SwiftUI
  observation.

### SoulRuntime

Reusable session orchestration. Depends on `SoulCore`, `SoulACP`, and
`SoulLedger`; should be testable without rendering SwiftUI.

Candidates:

- Thread lifecycle/turn/queue/watchdog/hydrate services currently distributed
  across `ThreadController*.swift`.
- `ProviderTranscriptWatcher`, `FinalizeWatcher`, `AutoCompactController`.

## Migration Order

1. Add SwiftPM package scaffolding and compile the smallest stable boundary.
2. Move pure domain types into `SoulCore`.
3. Complete `SoulACP` by splitting provider spawn and permission dependencies.
4. Extract ledger readers into `SoulLedger`.
5. Peel reusable runtime services out of `ThreadController`.
6. Only then consider a `SoulDesktopUI` package; the app target can remain the
   macOS assembly surface until the lower layers are stable.

## Guardrails

- Package targets must not import SwiftUI unless the target name is explicitly
  UI-oriented.
- The app target should be the only place that wires AppKit windows, SwiftUI
  navigation, smoke views, and user-facing sheets.
- Do not move `ThreadController` wholesale. Split its domain models and service
  dependencies first, then reduce the controller.
- Every extraction step should build both `swift build` for package boundaries
  and the Xcode scheme for app integration.
- Package platforms should match the app floor (`macOS 26.3`) so extracted
  code does not silently compile against a weaker deployment assumption than
  the desktop app actually supports.

## Task Mirror

The Soul registry tasks for the next `SoulACP` migration phase map to the
native Codex execution plan as follows:

| Soul task | Codex task | Verification |
| --- | --- | --- |
| `SOUL-SOUL_DESKTOP-284` | Extract ACP core domain dependencies into `SoulCore`: provider identity and permission policy first. | `swift build --package-path Modules/SoulDesktopModules`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-283` | Move `ACPClient.swift` into `SoulACP` after its dependencies are module-safe. | `swift build --package-path Modules/SoulDesktopModules`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-286` | Move `CodexClient.swift` into `SoulACP` and keep omitted-`jsonrpc` behavior explicit. | `swift build --package-path Modules/SoulDesktopModules`, Codex request tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-285` | Add SwiftPM tests for the extracted ACP boundary. | `swift test --package-path Modules/SoulDesktopModules`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-292` | Rewire the Xcode app target to consume `SoulCore` and `SoulACP` as local package products instead of compiling extracted sources directly. | Xcode package dependency inspection, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-295` | Create `SoulLedger` and move only UI-free ledger models/read helpers first. | `swift build`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-297` | Move `HooksReader` and replay ledger parsing behind `SoulLedger`. | Ledger/replay tests, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-296` | Extract session loadability and provider transcript readers behind a package boundary. | Sidebar/loadability tests, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-298` | Extract provider process/session lifecycle from `ThreadController` into a UI-free runtime boundary. | Queue/watchdog tests, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-299` | Move prompt queue and cancellation contracts behind runtime protocols after lifecycle extraction. | Queue/cancel tests, Xcode tests, verifier subagent. |

### `SOUL-SOUL_DESKTOP-283` Subtasks

| Soul task | Codex task | Verification |
| --- | --- | --- |
| `SOUL-SOUL_DESKTOP-288` | Bridge ACP permission policy from app `PermissionMode` to package `AgentPermissionMode`. | `swift build`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-287` | Include `ACPClient.swift` in the `SoulACP` target after dependencies compile. | `swift build`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-289` | Document the app/package integration bridge and remaining blockers for removing app-target compilation. | Doc review, verifier subagent. |
| `SOUL-SOUL_DESKTOP-290` | Expose the spawn configuration value needed by `ACPClient` without moving app-level provider resolution. | `swift build`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-291` | Bridge `ACPClient` protocol logging for package builds without pulling app logging into `SoulACP`. | `swift build`, Xcode tests, verifier subagent. |

## Core Naming Bridge

The first `SoulCore` extraction introduces non-colliding package names:

- `AgentProvider`
- `AgentPermissionMode`
- `ACPProviderSpawn`

The app target currently owns same-concept UI-facing names (`Provider` and
`PermissionMode`). Once the Xcode project imports the package products, those
app names can either become typealiases plus UI extensions or migrate call
sites directly. This avoids duplicate symbol collisions while the app target is
still compiling its original files.

`ACPClient.swift` uses a transitional `ACPPermissionMode` alias:

- SwiftPM/package build: `ACPPermissionMode == SoulCore.AgentPermissionMode`
- Current Xcode app build: `ACPPermissionMode == PermissionMode`

This allows the same source file to compile in both contexts until the app
target consumes the package product directly.

`ACPProviderSpawn` is now also present in `SoulCore` as a package-safe launch
configuration value. The existing app file with the same type name still owns
provider-specific resolution. When the app target eventually imports
`SoulCore`, that local resolver can be reduced to extensions/factories over
the package type.

### `SOUL-SOUL_DESKTOP-286` Subtasks

| Soul task | Codex task | Verification |
| --- | --- | --- |
| `SOUL-SOUL_DESKTOP-294` | Include `CodexClient.swift` in the `SoulACP` target after confirming its dependencies are already package-safe. | `swift build --package-path Modules/SoulDesktopModules --target SoulACP`, Xcode tests, verifier subagent. |
| `SOUL-SOUL_DESKTOP-293` | Pin Codex app-server's omitted-`jsonrpc` envelope behavior with SwiftPM tests. | `swift test --package-path Modules/SoulDesktopModules`, Codex request tests, verifier subagent. |

## Remaining Boundary Order

The migration should keep moving from leaf modules toward the SwiftUI app:

1. `SoulACP`: finish `CodexClient`, then add package-level protocol tests.
2. Xcode app adoption: link `SoulCore`/`SoulACP` into the app target and stop
   compiling extracted ACP files directly.
3. `SoulLedger`: move pure ledger models/readers before replay/session
   hydration code.
4. Runtime boundary: extract provider lifecycle first, then queue and
   cancellation contracts.

This order keeps the highest-risk step, Xcode package adoption, after both ACP
clients compile as package code but before larger ledger/runtime extractions
multiply the bridge surface.
