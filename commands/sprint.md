---
description: Run a multi-epic sprint sequentially on a shared branch — one PR for the whole sprint. /epic-toolkit:sprint <sprint.json> [opts] | /epic-toolkit:sprint <epic-dir>… --branch <name> [opts]
---

Multi-epic sprint orchestrator. Invoke the bundled `run-sprint.sh` from the installed plugin to run N epics back-to-back on a single trunk branch. Each epic is a normal `/epic-toolkit:epic` run; the sprint wrapper enforces sequential execution (no two epics share a trunk worktree at the same time), forwards `--no-pr` to every epic except the final one, and reports a single sprint-level summary.

**When to use:** the user generated 2+ related epics with `/epic-toolkit:epic.generate` and an emitted `docs/claude-sessions/<sprint>.sprint.json`, OR the epics already exist as separate directories and the user wants them merged into one PR.

**Branching:** every epic uses the same `--branch <shared>` (default `epic/<sprint-name>`). The first epic creates the branch; subsequent epics check out the same branch (run-sessions.sh detects the existing branch and reuses it) and append their commits. One PR is created at the end of the last epic.

## Validate

1. If the first arg ends in `.json`, confirm the file exists; otherwise treat positional args as epic directories under `docs/claude-sessions/` and confirm each one exists. If anything is missing, list what is available under `docs/claude-sessions/` and ask the user to pick.
2. If neither a sprint config nor epic directories are supplied, ask the user which sprint to run (or to run `/epic-toolkit:epic.generate` first).

## Execute

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-sprint.sh" \
  [--sprint-config docs/claude-sessions/<sprint>.sprint.json | <epic-dir> [<epic-dir> ...] --branch <shared>] \
  [--base BRANCH] [--model MODEL] [--cli claude|opencode] \
  [--continue-on-failure] [--no-final-pr] [--dry-run] \
  [--timeout MINS] [--retry N] [--max-parallel N] [--wave-timeout MINS] \
  [--strict] [--sequential] [--skip-plan] [--no-worktree] [--no-rebase] \
  [--no-commit] [--no-pr] [--keep-worktree] [--keep-session-worktrees] \
  [--keep-session-docs] [--fresh] [--show-dag]
```

Run via Bash tool with `run_in_background: true` (long-running — sprint = sum of every epic's runtime). For `--show-dag` only, no background needed.

Per-epic model overrides come from the sprint config when present; the global `--model` is used as the default for any epic that doesn't declare one.

## After launch

Tell the user:
- Sprint length (e.g. "4 epics on branch `epic/<sprint>`")
- That **one** PR will be opened at the end (not one per epic)
- That stop-on-failure is the default — pass `--continue-on-failure` to override
- Will report back when the sprint completes

## After completion

For each epic, the runner emits its own `[EPIC_RESULT_START]` / `[EPIC_RESULT_END]` block (per `/epic-toolkit:epic`'s contract). Plus, the sprint emits a final summary line. Parse all of them:

1. If any `STATUS=failed`: name the failing epic (the orchestrator's own `Epic N/M FAILED: <dir>` line), report the failed session ID(s), error type, exit code, log path, and `ERROR_DETAIL` if present. Provide a resume command using only the remaining epic directories or a trimmed sprint config.
2. If every epic shows `STATUS=success`: report total epics, total sessions, total runtime (sum of per-epic `RUNTIME=` values).
3. Report the shared trunk branch and the URL of the single PR (if `gh pr create` succeeded in the final epic).
4. Report each epic's session logs and plans location.
