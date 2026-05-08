# OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow .wolf/OPENWOLF.md every session. Check .wolf/cerebrum.md before generating code. Check .wolf/anatomy.md before reading files.


# AGENTS.md

This file provides guidance to AGENTS.md-aware AI coding agents (Codex, OpenCode, and others) when working with code in this repository.

@.wolf/OPENWOLF.md

## Project

Plugin that adds `/epic-toolkit:epic`, `/epic-toolkit:epic.generate`, and `/epic-toolkit:sprint` slash commands for **Claude Code**, plus `/epic`, `/epic.generate`, and `/sprint` equivalents for **OpenCode**. Epics run as a DAG with parallel waves — independent sessions fan out into isolated git worktrees, execute concurrently, then merge back wave by wave. Sprints run N epics back-to-back on a shared trunk branch and produce a single PR for the whole sprint.

## Architecture

```
commands/epic.generate.md     → Claude Code /epic-toolkit:epic.generate command
commands/epic.md               → Claude Code /epic-toolkit:epic command
commands/sprint.md             → Claude Code /epic-toolkit:sprint command (multi-epic)
.opencode/commands/            → OpenCode equivalents (tool-neutral wording)
scripts/run-sessions.sh         → wave orchestrator; spawns CLI per session (claude or opencode)
scripts/run-sprint.sh           → multi-epic sprint orchestrator; runs N epics sequentially on a shared trunk
scripts/epic-dag.py             → builds DAG from session frontmatter, computes Kahn-style waves
scripts/epic-progress.py        → stream-json progress display (claude and opencode)
scripts/epic-ui.py              → live terminal dashboard (used by run-sessions.sh)
```

Session files live in `docs/claude-sessions/<epic-name>/` with YAML frontmatter (`depends_on`, `touches`, `parallel_safe`). Sessions without frontmatter form an implicit linear chain.

Worktrees are created at `.epic-worktrees/<repo>/epic--<name>/` (trunk) and `.epic-worktrees/<repo>/epic--<name>--sNN-<slug>/` (per session).

## Validation / Preview

```bash
# Preview DAG waves without running
python scripts/epic-dag.py --show docs/claude-sessions/<name>/

# Dry-run the full orchestrator (no side effects)
bash scripts/run-sessions.sh docs/claude-sessions/<name>/ --dry-run
```

## Requirements

Python 3.8+ (stdlib only), Bash 3.2+, git 2.20+, `gh` CLI (optional, for auto-PR). Requires `claude` or `opencode` on PATH (auto-detected or forced with `--cli`).
