---
description: Run a multi-session epic autonomously. Sessions run as a DAG with parallel waves where possible. Usage /epic <name> [--start N] [--end N] [--dry-run] [--show-dag] [--max-parallel N] [--strict] [--sequential] [--model opus|sonnet|haiku] [--branch <name>]
---

You are the orchestrator for an autonomous multi-session epic. Your job is to invoke
the `run-sessions.sh` script which spawns a **fresh Claude process per session** so
each session gets a clean context window, plans its approach, executes, and commits.

**DAG mode:** Sessions can declare YAML frontmatter (`depends_on`, `touches`,
`parallel_safe`) to form a directed acyclic graph. The runner schedules them into
Kahn-style waves and fans out independent siblings into per-session worktrees that
run concurrently, then iteratively merges them into the trunk branch. Sessions
without frontmatter implicitly form a linear chain (one session per wave).

**Isolation:** By default, the runner creates a trunk worktree
`.epic-worktrees/<repo>/epic--<name>/` and per-session sibling worktrees
`.epic-worktrees/<repo>/epic--<name>--sNN-<slug>/`. Use `--no-worktree` to opt out
(forces sequential).

## Parse arguments

Raw arguments: `$ARGUMENTS`

Defaults:
- `name` — first positional arg (required)
- `--start` — 1
- `--end` — all
- `--max-parallel` — 4
- `--strict` — false (warn on `touches` overlap; with `--strict`, fail)
- `--sequential` — false (forces one-session-per-wave; equivalent to `--max-parallel 1`)
- `--show-dag` — false (when set, print the planned waves and exit)
- `--model` — sonnet
- `--branch` — auto-derived as `epic/<name>` (the trunk branch)
- `--base` — repo default branch (usually `main`)
- `--dry-run` — false (when set, prints the plan and exits with no side effects)
- `--no-worktree` — false (worktree isolation is ON by default)
- `--keep-worktree` — false (trunk worktree auto-cleaned after PR creation)
- `--keep-session-worktrees` — false (per-session worktrees cleaned after each wave)

The sessions directory is: `docs/claude-sessions/<name>/`.

## Validate

1. Confirm `docs/claude-sessions/<name>/` exists in the current repo.
2. If it does NOT exist, list what IS available under `docs/claude-sessions/` and ask the user to pick.

## Execute

Run the global script, forwarding all flags:

```bash
bash scripts/run-sessions.sh docs/claude-sessions/<name>/ \
  [--start N] [--end N] [--max-parallel N] [--strict] [--sequential] \
  [--show-dag] [--model M] [--branch B] [--base B] [--dry-run] \
  [--no-worktree] [--keep-worktree] [--keep-session-worktrees]
```

Run this via the Bash tool. This is a **long-running command** — use `run_in_background: true` so the user isn't blocked, and check on it when notified of completion.

If the user only wants to *see* the planned waves (no execution), forward `--show-dag` — that prints the wave layout and exits.

## After launch

Immediately after starting the background job, tell the user:
- The epic branch all sessions will commit to (e.g., `epic/<name>`, or the explicit `--branch` value if provided — **never say "main"**)
- That you will report back when it completes

Example: "Running epic '<name>' — all sessions will commit to branch `epic/<name>`. I'll report back when it completes."

## After completion

When the script finishes:

1. Read the final orchestrator output for the wave summary.
2. Report to the user:
   - Number of waves and sessions executed
   - Sessions merged into trunk (with branch names)
   - Any failures and how to resume (`--start <failed_id>`)
   - Trunk worktree location (if applicable)
   - Location of session logs and plans
