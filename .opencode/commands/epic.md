---
description: Run a multi-session epic autonomously. DAG mode with parallel waves. /epic <name> [--start N] [--end N] [--timeout M] [--retry N] [--dry-run] [--show-dag] [--max-parallel N] [--strict] [--sequential] [--model MODEL] [--cli opencode|claude] [--branch <name>]
---

Orchestrator for multi-session epic. Invoke `run-sessions.sh` which spawns a fresh AI process per session (clean context), plans, executes, commits.

**DAG:** Sessions declare YAML frontmatter (`depends_on`, `touches`, `parallel_safe`) for a DAG. Runner schedules Kahn-style waves, fans out per-session worktrees (concurrent), merges to trunk. No frontmatter = linear chain.

**Isolation:** Trunk worktree `.epic-worktrees/<repo>/epic--<name>/`, per-session siblings `.epic-worktrees/<repo>/epic--<name>--sNN-<slug>/`. `--no-worktree` = sequential.

Sessions dir: `docs/claude-sessions/<name>/`

Per-session frontmatter overrides:
```yaml
session: 02
title: "Analysis task"
depends_on: [01]
model: "opus"
cli: "opencode"
touches: ["analysis/**"]
parallel_safe: true
```

**Multi-epic:** For problems spanning multiple independent subsystems, use `/epic.generate` to split into separate epic directories under `docs/claude-sessions/`. Run each epic sequentially — each must complete and merge to trunk before the next starts:
```bash
/epic epic-1-name
/epic epic-2-name
```

Defaults: `name` (required), `--start 1`, `--end all`, `--max-parallel 4`, `--strict false`, `--sequential false`, `--show-dag false`, `--model sonnet`, `--cli auto`, `--branch epic/<name>`, `--base main`, `--dry-run false`, `--no-worktree false`, `--timeout 0`, `--retry 0`, `--keep-worktree false`, `--keep-session-worktrees false`.

## Validate
1. Confirm `docs/claude-sessions/<name>/` exists. If not, list available under `docs/claude-sessions/` and ask user to pick.

## Execute
```bash
bash scripts/run-sessions.sh docs/claude-sessions/<name>/ [--start N] [--end N] [--timeout M] [--retry N] [--max-parallel N] [--strict] [--sequential] [--show-dag] [--model M] [--cli opencode|claude] [--branch B] [--base B] [--dry-run] [--no-worktree] [--keep-worktree] [--keep-session-worktrees]
```

Run via Bash tool with `run_in_background: true` (long-running). For `--show-dag` only, no background needed.

## After launch
Tell the user:
- Epic branch (e.g., `epic/<name>`, or explicit `--branch` — **never "main"**)
- Will report back when complete

Example: "Running epic '<name>' — all sessions will commit to branch `epic/<name>`. I'll report back when it completes."

## After completion
1. Parse `[EPIC_RESULT_START]` / `[EPIC_RESULT_END]` block from output.
2. If `STATUS=failed`: read `.epic-worktrees/<repo>/<epic--name>/.epic-result.json`, report failed session ID(s), error type, exit code, log path, `ERROR_DETAIL` if present. Provide resume command. Note `.epic-result.json` retained only on failure.
3. If `STATUS=success`: report waves, sessions completed, runtime.
4. Report trunk worktree location (if applicable).
5. Report session logs and plans location.
