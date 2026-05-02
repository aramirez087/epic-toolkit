---
session: 01
title: "Charter and architecture"
depends_on: []
touches:
  - docs/roadmap/epic-next-features/**
parallel_safe: false
---

# Session 01: Charter and Architecture

Paste this into a new agent session:

```md
Mission: Audit the codebase, define exact interfaces for all new features, and write the architecture decision record so downstream sessions can run in parallel.

Repository anchors:
- scripts/epic-dag.py          — DAG parser and scheduler
- scripts/run-sessions.sh      — wave orchestrator (Bash)
- README.md                   — high-level docs
- docs/epic-guide.md          — detailed user guide
- commands/epic.md            — Claude Code slash command
- .opencode/commands/epic.md  — OpenCode slash command
- epic-prompt-next-features.md — the full problem statement

Tasks:
1. Read all repository anchors listed above.
2. Document the exact interface contract for each new feature in a decision record:
   a. Timeout/retry: `--timeout MINS` (default 0 = no timeout), `--retry N` (default 0). `timeout` CLI wrapping `run_cli`, exit 124 handling, retry loop, summary print.
   b. Per-session `model:` frontmatter key: parsed by epic-dag.py, exported as extra column in `--bash` output, consumed by run-sessions.sh falling back to global `--model` then `sonnet`.
   c. Per-session `cli:` frontmatter key: parsed by epic-dag.py, exported as extra column in `--bash` output, consumed by run-sessions.sh falling back to global `--cli` then auto-detect.
   d. `.epic-config.json`: read from repo root, keys `timeout`, `retry`, `cli`, `model`, `maxParallel`, `autoCommit`, `autoPr`, `skipPlan`, `keepWorktree`. CLI flags override config; config overrides hardcoded defaults. Silent fallback on missing/malformed file.
   e. Stale worktree cleanup: before creating new worktrees, scan `.epic-worktrees/`, remove directories/branches matching the epic pattern but not in the current DAG plan. Log removals.
   f. Documentation updates: flag tables, frontmatter examples, config file schema.
3. Identify any hidden coupling between features that would prevent parallel implementation. If found, document it and adjust the plan.
4. Write the architecture decision record to:
   docs/roadmap/epic-next-features/session-01-handoff.md

Deliverables:
1. docs/roadmap/epic-next-features/session-01-handoff.md (exact interface contracts, file-by-file change plan, no TBDs)

Quality gates:
- python3 -m py_compile scripts/epic-dag.py
- bash -n scripts/run-sessions.sh
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --show

Exit criteria:
- Handoff doc exists and contains unambiguous interfaces for all 6 feature areas.
- No code changes yet (charter is read-only exploration and documentation).
- Quality gates pass.
```
