---
session: 03
title: "Runner timeout retry config cleanup"
depends_on: [01]
touches:
  - scripts/run-sessions.sh
parallel_safe: true
---

# Session 03: Runner Core Features

```md
Continue from Session 01.

Mission: Add timeout, retry, `.epic-config.json`, and stale worktree cleanup to run-sessions.sh.

Anchors:
- scripts/run-sessions.sh
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read run-sessions.sh and Session 01 handoff.
2. Add `--timeout MINS` (default 0) and `--retry N` (default 0) CLI flags.
3. Add `.epic-config.json` loading: keys `timeout`, `retry`, `cli`, `model`, `maxParallel`, `autoCommit`, `autoPr`, `skipPlan`, `keepWorktree`. CLI > config > defaults. Silent on missing/malformed.
4. Wrap `run_cli` with `timeout` when `--timeout > 0`. Exit 124 → session failed ("timed out after Xm"). If `--retry > 0`, retry up to N times.
5. Stale worktree cleanup: scan `.epic-worktrees/` for `epic--<name>--sNN-*`, remove worktrees/branches not in current DAG plan. Log removals.
6. Update banners to show timeout/retry when non-default.
7. Preserve Bash 3.2+ compatibility.

Deliverables: Updated scripts/run-sessions.sh, session-03-handoff.md

Quality gates:
- bash -n scripts/run-sessions.sh
- bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --show-dag --timeout 30 --retry 2
- bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --dry-run --timeout 0 --retry 0

Exit: All flags accepted. Config read when present, ignored when absent. Defaults 0. Cleanup logs cleanly. Bash 3.2+ preserved. Gates pass.
```
