# OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow .wolf/OPENWOLF.md every session. Check .wolf/cerebrum.md before generating code. Check .wolf/anatomy.md before reading files.


# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@.wolf/OPENWOLF.md

## Project

Claude Code plugin that adds `/epic` and `/epic.generate` slash commands. Epics run as a DAG with parallel waves — independent sessions fan out into isolated git worktrees, execute concurrently, then merge back wave by wave.

## Architecture

```
commands/epic.generate.md   → /epic.generate: generates session files under docs/claude-sessions/<name>/
commands/epic.md            → /epic: validates DAG, calls run-sessions.sh
scripts/run-sessions.sh     → wave orchestrator; spawns `claude -p` per session, merges worktrees
scripts/epic-dag.py         → builds DAG from session frontmatter, computes Kahn-style waves
scripts/epic-ui.py          → live terminal dashboard (used by run-sessions.sh)
scripts/epic-progress.py    → stream-json parser for per-session progress
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

Python 3.8+ (stdlib only), Bash 3.2+, git 2.20+, `gh` CLI (optional, for auto-PR).
