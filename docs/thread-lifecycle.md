# Thread lifecycle — clicks, controllers, scroll restore

Quick mental model for "where does the user land when they click X?"

There are **two independent state machines** in play:

1. **`ThreadController` lifecycle.** Lives in `AppSessionCoordinator.threads[id]`. Up to 3 alive at a time (LRU cap, -220). A controller is *mounted* when it's in the dict and *torn down* when LRU evicts it.
2. **`ThreadView` SwiftUI lifecycle.** One ThreadView per mounted controller (ForEach in AppShell). Mount-once, opacity-toggle visibility — switching between threads does NOT remount the view.

The scroll-restore logic lives at the intersection. The user-facing question — "where does the scroll land?" — is fully determined by which of four cases the click hits.

---

## The four user actions, by case

```mermaid
flowchart TD
    Click["User clicks session row in sidebar"]:::user

    Click --> Q1{"Active session?"}
    Q1 -->|"yes — this is the foreground thread"| C2[("Case 2: no-op")]:::noop
    Q1 -->|no| Q2{"Controller still mounted?<br/>(in threads dict)"}

    Q2 -->|"yes — opened it earlier this launch,<br/>LRU hasn't evicted it"| C3[("Case 3: opacity switch")]:::warm
    Q2 -->|no| Q3{"Was it ever mounted<br/>this launch?"}

    Q3 -->|"no — never seen this sid"| C1[("Case 1: cold open")]:::cold
    Q3 -->|"yes — LRU evicted it"| C4[("Case 4: re-open after eviction")]:::cold

    C1 --> H1["Build new ThreadController<br/>assignSessionId(sid)<br/>mount → activeThreadKey<br/>Task: hydrateFromDisk"]
    C4 --> H1

    C3 --> S3["Set activeThreadKey = ctrl.id<br/>(opacity flips: hidden ←→ visible)<br/><br/>ThreadView .onAppear DOES NOT fire<br/>ScrollView position preserved"]

    C2 --> S2["Nothing happens.<br/>activeThreadKey already matched."]

    H1 --> H2["isHydrating = true<br/>skeleton overlay paints"]
    H2 --> H3["Off-main:<br/>read transcript / kernel ledger"]
    H3 --> H4["items.append(history)<br/>isHydrating = false (defer)"]
    H4 --> H5["onChange(isHydrating → false)<br/>scrollTo __bottom__"]:::bottom

    classDef user fill:#1f2937,color:#fff,stroke:#374151
    classDef cold fill:#7c2d12,color:#fff,stroke:#9a3412
    classDef warm fill:#1e3a8a,color:#fff,stroke:#1e40af
    classDef noop fill:#374151,color:#9ca3af,stroke:#4b5563
    classDef bottom fill:#14532d,color:#fff,stroke:#166534
```

### What each case lands on

| Case | Click target | Scroll lands at |
|---|---|---|
| **1. Cold open** | Session never seen this launch | **Bottom** (always) |
| **2. No-op** | Already-active session | Wherever you left it |
| **3. Opacity switch** | Mounted but inactive (you'd opened it earlier and switched away) | **Wherever you left it** (preserved across opacity toggle) |
| **4. Re-open after eviction** | Mounted earlier this launch but LRU evicted it | **Bottom** (same code path as Case 1 — controller is rebuilt from scratch) |

> **Insight:** Cases 1 and 4 are indistinguishable to the system. From the controller's perspective, it's being built fresh in both. Both go through `hydrateFromDisk` → skeleton → bottom.

---

## The "re-attach" case (theoretical)

There's a fifth case I mentioned in the task notes but it's *rarely triggered in normal use*:

- **Case 5: ThreadView re-mounts on a still-hydrated controller.** ScrollView's `.onAppear` fires while `controller.isHydrating` is already `false`. This would happen if SwiftUI tears down and re-creates the view structure (window resize triggering a major restructure, parent `.id()` change, etc.) without touching the underlying controller.

In this case, the `.onAppear` path runs `performScrollRestore(proxy:)` which respects the saved anchor (`controller.scrollAnchorAtBottom` / `scrollAnchorItemId`). The user would land where they last were.

You won't normally hit this through user actions in the current AppShell — opacity-toggle (Case 3) is the user-visible "switch threads" path and it doesn't trigger `.onAppear`.

---

## ScrollView lifecycle in time

```mermaid
sequenceDiagram
    participant U as User
    participant AS as AppShell
    participant TC as ThreadController
    participant SV as ScrollView
    participant Skel as Skeleton

    U->>AS: click session row (cold)
    AS->>TC: ThreadController(...).assignSessionId(sid)
    AS->>AS: sessions.mount(controller)<br/>activeThreadKey = ctrl.id
    AS->>TC: Task { hydrateFromDisk(sid) }
    activate TC
    TC->>TC: isHydrating = true
    Note over SV: ThreadView mounts<br/>(ForEach added a child)
    SV->>SV: .onAppear<br/>suppressAnchorWrites = true<br/>controller.isHydrating == true<br/>→ DEFER restore

    activate Skel
    Note over Skel: skeleton overlay paints<br/>(gated on isHydrating)

    TC->>TC: off-main: read transcript
    TC->>TC: items.append(history)
    TC->>TC: isHydrating = false (defer)
    deactivate TC
    deactivate Skel

    SV->>SV: .onChange(isHydrating → false)<br/>scrollTo __bottom__
    Note over SV: skeleton fades out<br/>(easeOut 0.18)
    SV->>SV: + 0.25s: clear suppressAnchorWrites
```

---

## Why "fresh = bottom, re-attach = saved anchor"

Two different UX intents:

- **Fresh open (Case 1, 4):** the user is opening this session to **see what happened**. Most recent message is the answer to "what's the latest?" Bottom is right.
- **Re-attach (Case 3, hypothetical Case 5):** the user was reading at a specific point, opened another thread, came back. They want to resume reading, not jump to the end. Saved anchor is right.

The previous bug was that fresh open *also* read the saved anchor, but the saved anchor was the **default** `scrollAnchorAtBottom = true` value (no real prior position because the controller is brand new). That **should have** landed at bottom — but the scroll fired against an empty ScrollView (hydrate hadn't completed yet), no-opped, then row `.onAppear` handlers flipped the anchor based on whatever happened to be top-of-viewport. Final position = race winner.

Fix in -233:

```
Old:                                  New:
.onAppear fires immediately            .onAppear: if !isHydrating → restore now
  → scrollTo bottom on empty view      .onChange(isHydrating → false) → scrollTo bottom
  → race with row handlers
```

Plus: row `.onAppear/.onDisappear` now respect `suppressAnchorWrites` so they can't clobber state during the restore window.

---

## Where each piece of state lives

| State | Type | Lives in | Lifetime |
|---|---|---|---|
| `threads: [String: ThreadController]` | dict | `AppSessionCoordinator` | app launch |
| `activeThreadKey: String?` | id | `AppSessionCoordinator` | app launch |
| `threadRecency: [String]` | LRU order | `AppSessionCoordinator` | app launch |
| `isHydrating: Bool` | per-controller | `ThreadController` | controller lifetime |
| `items: [ThreadItem]` | per-controller | `ThreadController` | controller lifetime |
| `scrollAnchorAtBottom: Bool` | per-controller | `ThreadController` | controller lifetime |
| `scrollAnchorItemId: String?` | per-controller | `ThreadController` | controller lifetime |
| `anchor.atBottom / .itemId / .visibleIds` | per-view | `ThreadView`'s `@State ScrollAnchor` | view mount |
| `suppressAnchorWrites: Bool` | per-view | `ThreadView`'s `@State` | view mount |

The two `anchor` pairs at the bottom mirror each other: view-local for hot writes during scroll (no `@Bindable` invalidation per -094/-096), flushed back to controller on `.onDisappear`.
