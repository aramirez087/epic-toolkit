---
session: 01
title: "Charter and architecture"
depends_on: []
touches:
  - docs/roadmap/epic-next-features/**
parallel_safe: false
---

# Session 01: Charter and Architecture

```md
Mission: Audit the codebase, define interfaces for all new features, write the architecture decision record.

Anchors:
- scripts/epic-dag.py — DAG parser
- scripts/run-sessions.sh — wave orchestrator
- README.md, docs/epic-guide.md — docs
- commands/epic.md, .opencode/commands/epic.md — slash commands
- epic-prompt-next-features.md — problem statement

Tasks:
1. Read all anchors above.
2. Document exact interface contracts for each feature:
   a. Timeout/retry: `--timeout MINS` (default 0), `--retry N` (default 0). Wrap `run_cli` with `timeout`, handle exit 124, retry loop, summary.
   b. Per-session `model:` frontmatter: parse in epic-dag.py, export as extra column in `--bash`, consume in run-sessions.sh (fallback to `--model` → `sonnet`).
   c. Per-session `cli:` frontmatter: same as model, fallback to `--cli` → auto-detect.
   d. `.epic-config.json`: keys `timeout`, `retry`, `cli`, `model`, `maxParallel`, `autoCommit`, `autoPr`, `skipPlan`, `keepWorktree`. CLI > config > defaults. Silent on missing/malformed.
   e. Stale worktree cleanup: scan `.epic-worktrees/`, remove directories/branches not in current DAG plan. Log removals.
   f. Docs: update flag tables, frontmatter examples, config schema.
3. Identify hidden coupling between features that blocks parallel implementation.
4. Write handoff to: docs/roadmap/epic-next-features/session-01-handoff.md

Deliverable: session-01-handoff.md (interface contracts, file-by-file plan, no TBDs)

Quality gates:
- python3 -m py_compile scripts/epic-dag.py
- bash -n scripts/run-sessions.sh
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --show

Exit: Handoff has unambiguous interfaces for all 6 features. No code changes. Gates pass.
```
