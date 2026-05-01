---
session: 03
title: "Runner timeout retry config cleanup"
depends_on: [01]
touches:
  - scripts/run-sessions.sh
parallel_safe: true
---

# Session 03: Runner Core Features

Paste this into a new agent session:

```md
Continue from Session 01 artifacts.

Mission: Add timeout wrapping, retry logic, `.epic-config.json` support, and stale worktree auto-cleanup to run-sessions.sh while preserving all existing defaults and behavior.

Repository anchors:
- scripts/run-sessions.sh
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read the current scripts/run-sessions.sh and the Session 01 handoff.
2. Add CLI argument parsing for `--timeout` (default 0 = no timeout) and `--retry` (default 0 = no retry).
3. Add `.epic-config.json` loading:
   - Read from repo root at startup.
   - Supported keys: `timeout`, `retry`, `cli`, `model`, `maxParallel`, `autoCommit`, `autoPr`, `skipPlan`, `keepWorktree`.
   - CLI flags override config; config overrides hardcoded defaults.
   - If file missing or malformed, silently fall back to hardcoded defaults.
4. Wrap `run_cli` invocations with the `timeout` command when `--timeout > 0`.
   - On exit code 124, mark the session as failed with message "timed out after Xm".
   - If `--retry > 0`, re-run the same session up to N times before final failure.
   - Print timeout/retry usage info in the epic summary.
5. Add stale worktree cleanup before trunk worktree setup:
   - Scan `.epic-worktrees/` for directories matching `epic--<name>--sNN-*`.
   - Remove any worktrees/branches from sessions NOT present in the current DAG plan.
   - Log what was cleaned up.
6. Update the summary banner and final report to mention timeout and retry settings when non-default.
7. Ensure Bash 3.2+ compatibility: no `local -n`, no `mapfile`, no `readarray`.

Deliverables:
1. Updated scripts/run-sessions.sh
2. docs/roadmap/epic-next-features/session-03-handoff.md

Quality gates:
- bash -n scripts/run-sessions.sh
- bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --show-dag --timeout 30 --retry 2 (verify it parses and shows DAG)
- bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --dry-run --timeout 0 --retry 0 (verify backward-compat defaults)

Exit criteria:
- All new CLI flags are accepted and passed through correctly.
- `.epic-config.json` is read when present and ignored when absent/malformed.
- Timeout and retry logic is present but defaults remain 0 (no timeout, no retry).
- Stale cleanup scans and logs without error.
- Bash 3.2+ compatibility is preserved.
- All quality gates pass.
```
