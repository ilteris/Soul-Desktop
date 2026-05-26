# Unified Startup Workspace Model

**Status:** Draft - design review incorporated.
**Scope:** App startup, project selection, project/session loading, sidebar row projection, registry watcher ownership.
**Non-scope:** ThreadController internals, ACP/provider runtime behavior, ledger schema, replay semantics.

Soul Desktop currently paints from partial state during launch. `AppShell` starts with no selected project, while `SidebarView` independently loads projects and later mutates the parent selection. The visible symptom is the hero text first rendering as "What should we build in your project?" and then changing to "What should we build in Soul OS?" once the sidebar load finishes.

That flicker is not just copy polish. It exposes an architectural split: the app shell, sidebar, registry cache, and session projection each own pieces of startup truth. A proper macOS app should boot from one coherent workspace snapshot, then apply deltas as the registry changes.

## Current Problem

The split is visible in these ownership boundaries:

- `AppShell` owns `selectedProject` and resolves `currentProject()` through `registryStore.projects()`.
- `SidebarView` owns its own `projects`, `sessionsByProject`, `sessionCounts`, and `sidebarRowsProjection`.
- `SidebarView+Loading.reload()` refreshes `LiveSoulRegistryStore`, loads projects, computes counts, primes cached sessions, kicks off project scans, and assigns `selectedProject` if nil.
- `SidebarView` owns the registry watcher and triggers session reloads for selected project changes.
- `SidebarRowResolver` already owns row merge/filter/sort/archive policy, but its invocation and cached output live inside the sidebar.

The result is layered loading:

1. Canvas renders before selected project is known.
2. Sidebar refresh later chooses the selected project.
3. Session badges and rows update in additional waves.
4. App shell call sites can still read project state differently from sidebar state.

## Goals

- Publish one coherent first workspace snapshot before rendering project-specific UI.
- Make selected project app-owned, not sidebar-owned.
- Keep views declarative: they read project/session state; they do not refresh registry truth directly.
- Reuse existing `SoulRegistry` and `LiveSoulRegistryStore` caches through a facade instead of inventing a second cache.
- Move registry watcher lifecycle into the workspace model.
- Apply session/project changes as explicit deltas.
- Preserve existing row policy in `SidebarRowResolver`.
- Keep `AppSessionCoordinator` responsible for mounted controllers and draft/active thread lifecycle.

## Non-Goals

- Do not rewrite `ThreadController`.
- Do not merge mounted thread lifecycle into the workspace model.
- Do not replace `SoulRegistry` caches in the first migration.
- Do not move purely view-local sidebar state into the workspace model.
- Do not block startup on full scans of every project.

## Target Ownership

### Workspace Model Owns

- Active/all projects for the shell.
- Selected project id and selected project.
- Sessions by project from registry/cache scans.
- Session count/freshness state.
- Registry watcher lifecycle and invalidation policy.
- Project/session refresh orchestration.
- Startup phase.

### AppSessionCoordinator Owns

- Mounted `ThreadController` instances.
- Active thread key.
- Pending active session id.
- Draft session row.
- Thread LRU eviction and teardown.

The workspace model may consume coordinator state as an overlay input for sidebar projection, but it must not own mounted controllers.

### SidebarView Owns

- Folder expansion state.
- Filter controls: source filter, hide untitled, show unreadable, show archived.
- Scroll position/idleness.
- Context menus.
- Alerts, sheets, popovers, and repair UI state.

These are presentation and interaction details. Moving them into the workspace model would overcentralize state and cause wider invalidation than necessary.

### SidebarRowResolver Owns

- Disk/live/draft row merge.
- Row visibility policy.
- Archive partitioning.
- Starred ordering.
- Recency sorting.

This policy already exists in `SidebarRowResolver`. The migration should move invocation and cache ownership out of `SidebarView`, not rewrite the resolver.

## Proposed Types

```swift
@MainActor
@Observable
final class SoulWorkspaceModel {
    private(set) var snapshot: WorkspaceSnapshot

    var selectedProjectId: String? { snapshot.selectedProjectId }
    var selectedProject: SoulProject? { snapshot.selectedProject }

    func start() async
    func selectProject(_ id: String?)
    func handleProjectMutationCompleted() async
    func invalidateSessions(projectId: String)
    func refreshSessions(projectId: String, priority: RefreshPriority) async

    func projectedRows(
        for projectId: String,
        filters: SidebarFilters,
        overlay: SidebarLiveOverlay
    ) -> SidebarRowResolver.Output?
}
```

```swift
struct WorkspaceSnapshot: Equatable {
    var phase: Phase
    var projects: [SoulProject]
    var selectedProjectId: String?
    var sessionsByProject: [String: ProjectSessions]
    var counts: [String: Int]
    var staleProjects: Set<String>
    var lastRefresh: [String: Date]

    var selectedProject: SoulProject? {
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }
    }

    enum Phase: Equatable {
        case booting
        case ready
        case empty
        case failed(String)
    }
}
```

```swift
struct ProjectSessions: Equatable {
    var rows: [SoulSession]
    var freshness: Freshness
    var loadedAt: Date?
}

enum Freshness: Equatable {
    case staleCache
    case freshCache
    case scanned
}
```

```swift
struct SidebarFilters: Equatable {
    var chatSourceFilter: String?
    var hideUntitled: Bool
    var showUnreadable: Bool
    var showArchived: Bool
}
```

```swift
struct SidebarLiveOverlay {
    var activeControllers: [ThreadController]
    var draftSession: SoulSession?
    var activeSessionId: String?
    var activeProjectId: String?
}
```

## Registry Facade

Add service protocols so the workspace model can be tested without shelling out:

```swift
protocol WorkspaceProjectService: Sendable {
    func cachedProjects() -> [SoulProject]
    func refreshProjects() async -> [SoulProject]
}

protocol WorkspaceSessionService: Sendable {
    func cachedSessions(projectId: String, allowStale: Bool) async -> [SoulSession]?
    func scanSessions(project: SoulProject) async -> [SoulSession]
    func sessionCount(projectId: String) async -> Int
    func warmCache(projectId: String, sessions: [SoulSession]) async
}
```

The live implementation should wrap existing code:

- `LiveSoulRegistryStore.shared.cachedActive`
- `LiveSoulRegistryStore.shared.refresh()`
- `SoulRegistry.cachedSessions(forProject:)`
- `SoulRegistry.cachedSessionsStaleOK(forProject:)`
- `SoulRegistry.allSessions(forProject:projectPath:)`
- `SoulRegistry.sessionCount(forProject:)`
- `SoulRegistry.warmCache(forProject:sessions:)`

Do not replace `LiveSoulRegistryStore` in the first pass. Wrap it first. Once all direct view callers are gone, decide whether to fold it into the workspace services.

## Startup Contract

Startup must publish a coherent first snapshot:

1. `SoulWorkspaceModel.start()` seeds projects from the current cached project list.
2. It validates the persisted selected project id against active projects.
3. If the persisted id is invalid, it falls back to the first active project.
4. It publishes `.ready` only after `projects` and `selectedProjectId` agree.
5. If there are no active projects, it publishes `.empty`.
6. It primes cached sessions and counts asynchronously after the first coherent snapshot.
7. It starts registry watching after selected project is known.

Project-specific UI must not render while `snapshot.phase == .booting`.

The hero copy contract becomes:

- `.booting`: neutral loading surface or blank shell.
- `.empty`: add-project surface.
- `.ready` with selected project: project-aware hero.
- `.failed`: recoverable error surface.

This eliminates the "your project" to "Soul OS" identity swap.

## Delta Application

All async work should return immutable values and enter the model through a small delta reducer:

```swift
enum WorkspaceDelta {
    case projectsLoaded([SoulProject])
    case selectedProjectChanged(String?)
    case sessionsLoaded(projectId: String, sessions: [SoulSession], freshness: Freshness)
    case countsLoaded([String: Int])
    case projectInvalidated(String)
    case refreshFailed(projectId: String?, message: String)
}
```

```swift
@MainActor
private func apply(_ delta: WorkspaceDelta)
```

Rules:

- Empty transient scans must not wipe a non-empty prior session list.
- Fresh rows may merge with prior rows to preserve non-regressing turn counts, matching existing `SidebarView+Loading.reloadSessions()` behavior.
- Project list refresh must preserve selected project if it still exists.
- A selected project deletion/archive must choose a deterministic fallback.
- Stale async results must not overwrite newer snapshots.

Use a generation id for refreshes:

```swift
private var generation: Int = 0
```

Each async refresh captures `generation`; before applying, it verifies the generation is still current.

## Bounded Refresh Concurrency

The current sidebar can fire unbounded project scans for `needLoad`. The workspace model should bound refreshes.

Do not implement this as `projects.prefix(concurrencyLimit)`, which scans only the first N projects. Use one of:

- Chunked batches.
- A small worker queue over all pending projects.
- An async semaphore helper.

Example batch contract:

```swift
for batch in pendingProjects.chunked(into: 3) {
    await withTaskGroup(of: ProjectSessionResult.self) { group in
        for project in batch {
            group.addTask {
                await sessionService.scanSessions(project: project)
            }
        }
        for await result in group {
            await apply(result.delta)
        }
    }
}
```

The selected project should use higher priority and refresh first. Other projects can refresh opportunistically for accurate badges and instant expansion.

## Watcher Ownership

Move `RegistryWatcher` lifecycle into `SoulWorkspaceModel`.

Current behavior watches the selected project's session directory from `SidebarView.onChange(of: selectedProject)`. That is data invalidation policy, not sidebar rendering.

Target behavior:

- On selected project change, workspace stops the old selected-project watcher and starts the new one.
- Watcher callback calls `invalidateSessions(projectId:)`.
- Invalidation marks that project stale and schedules `refreshSessions(projectId:priority:)`.
- Project mutation completion calls `handleProjectMutationCompleted()`, which refreshes projects and reconciles selection.

## AppShell Migration Points

The migration must remove direct selected-project ownership from all shell paths, not only hero/sidebar.

Known call sites to convert:

- `AppShell.selectedProject`
- `AppShell.currentProject()`
- `AppShell+Canvas` hero/composer project inputs.
- `AppShell+SessionFlow.loadSession`.
- `AppShell+SessionFlow.openSessionFromNotification`.
- `AppShell+Terminal` run-local project path resolution.
- Toolbar/right-pane project path and display metadata.
- New-project wizard completion.
- Project delete/edit completion.

After migration, `AppShell` should use:

```swift
workspace.selectedProject
workspace.selectProject(projectId)
```

It should not call `registryStore.projects()` for selected project resolution.

## Sidebar Migration Points

`SidebarView` should receive or read workspace snapshot data:

- `projects`
- `sessionsByProject`
- `counts`
- projected rows via `workspace.projectedRows(...)`

Remove from `SidebarView` as source-of-truth:

- `@State var projects`
- `@State var sessionsByProject`
- `@State var sessionCounts`
- `@State var sidebarRowsProjection`
- `.task { await reload() }`
- `reload()`
- `loadProject(_:)`
- `reloadSessions()`
- direct `registryStore.activeProjects()`
- direct `registryStore.allSessions(...)`
- direct watcher ownership

Keep in `SidebarView`:

- filters
- expansion state
- archive disclosure state
- pending alerts/sheets/popovers
- scroll state
- repair UI state

## Projection Strategy

Initial migration can keep filters in `SidebarView` and ask the workspace model for projected rows:

```swift
let rows = workspace.projectedRows(
    for: project.id,
    filters: filters,
    overlay: SidebarLiveOverlay(
        activeControllers: sessions.mountedThreads,
        draftSession: sessions.draftSession,
        activeSessionId: thread?.sessionId ?? sessions.pendingActiveId,
        activeProjectId: thread?.project.id ?? replay.controller?.project.id ?? sessions.draftSession?.project
    )
)
```

If badge counts must reflect the sidebar's current filters, keep the filter-to-count relationship local to sidebar rendering. If counts should be app-wide and stable, keep them filter-independent in the workspace snapshot.

Recommended first pass: workspace owns raw filtered-for-visibility counts, sidebar applies UI filters at render time.

## Persistence

Persist selected project id:

```swift
UserDefaults.standard.set(projectId, forKey: "soul.selectedProjectId")
```

On launch:

- Load persisted id.
- Validate against active projects.
- Keep it if valid.
- Otherwise fall back to first active project.
- If no active projects exist, enter `.empty`.

## Implementation Plan

1. Add `SoulWorkspaceModel`, `WorkspaceSnapshot`, service protocols, and live registry facade.
2. Own one workspace model in the app composition root and inject it through environment.
3. Convert `AppShell.currentProject()` and hero project inputs to workspace reads.
4. Move selected-project persistence and startup selection into workspace.
5. Convert `SidebarView` project list to workspace snapshot data.
6. Move `SidebarView+Loading` behavior into workspace refresh methods.
7. Move registry watcher lifecycle into workspace.
8. Route project mutation completions through `workspace.handleProjectMutationCompleted()`.
9. Move row projection invocation out of sidebar source-of-truth state while preserving `SidebarRowResolver`.
10. Remove obsolete sidebar loading state and direct registry calls.
11. Sweep all `selectedProject` and `registryStore.projects()` shell call sites.

## Tests

Add model tests with fake project/session services:

- Boot with active projects publishes `.ready` with a selected project in the first non-booting snapshot.
- Valid persisted project is restored.
- Invalid persisted project falls back to first active project.
- No active projects publishes `.empty`.
- Cached sessions publish before scanned sessions.
- Fresh scan updates the matching project only.
- Empty transient scan does not wipe prior non-empty sessions.
- Generation mismatch prevents stale refresh from overwriting newer state.
- Project deletion reconciles selected project.
- Registry invalidation marks only the affected project stale.
- Projected rows call `SidebarRowResolver` with disk rows plus live overlay.

Add integration/smoke checks:

- Launch app with existing projects: hero never renders "your project" before selected project is known.
- Switch selected project: sidebar, hero, toolbar, and composer agree.
- Create/delete/edit project: project list and selected project reconcile without a relaunch.
- Registry watcher append: affected project's rows refresh without full app reload.

## Acceptance Criteria

- `AppShell` and `SidebarView` read the same selected project from `SoulWorkspaceModel`.
- Project-specific UI does not render from `nil` selected project during normal startup.
- `SidebarView` no longer calls project/session registry loading APIs directly.
- Registry watcher ownership is outside `SidebarView`.
- Existing `SoulRegistry` caches are reused through a facade.
- `AppSessionCoordinator` remains separate and owns mounted thread lifecycle.
- `SidebarRowResolver` remains the row policy boundary.
- Session updates are delta-applied and non-regressing.
- Tests cover startup selection, cache-first loading, stale refresh suppression, and project mutation reconciliation.

