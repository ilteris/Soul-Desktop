# Swift File Budget

Soul Desktop keeps Swift files small enough for code review, agent edits, and
manual debugging. The budget is enforced by:

```sh
./scripts/check_swift_file_budget.py
```

Policy:

- SwiftUI views: target below 500 lines, hard cap 700.
- Coordinators, controllers, registries, models, and stores: target below 600
  lines, hard cap 900.
- Tests and support files: target below 500-600 lines depending on role, hard
  cap 900.
- No Swift file should exceed 1000 lines without an explicit task-linked
  exception.

The checker exits non-zero for hard-cap violations. Use `--strict` to also fail
on target-budget warnings. Current target warnings are allowed only when the
output names an owning task or follow-up, such as the ThreadController and
SoulRegistry decomposition tasks.
