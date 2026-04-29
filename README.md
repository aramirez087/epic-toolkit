# epic-toolkit

A Claude Code plugin for running multi-session epics as a **directed acyclic
graph**, with **parallel siblings executing in their own git worktrees** and
merging back into a coordinator trunk branch wave by wave.

Adds two slash commands to Claude Code:

- `/epic.generate <problem statement>` — turns a problem statement into a
  sequence of session prompt files with DAG metadata.
- `/epic <name>` — runs the generated epic, fanning out parallel waves and
  auto-creating a PR when done.

## Install

```
/plugin marketplace add aramirez087/epic-toolkit
/plugin install epic-toolkit@epic-toolkit
```

That's it — `/epic` and `/epic.generate` are now available in any project.

## What it does

1. **`/epic.generate`** writes session prompts under
   `docs/claude-sessions/<epic-name>/`. Each session 01+ gets YAML frontmatter
   declaring its DAG edges (`depends_on`, `touches`, `parallel_safe`).
2. **`/epic`** invokes the runner. It:
   - Validates the DAG (no cycles, all deps exist).
   - Computes Kahn-style waves (independent sessions in the same wave).
   - Creates a trunk worktree on `epic/<name>` and per-session worktrees on
     `epic/<name>--sNN-<slug>` for each sibling, branched off the trunk's HEAD.
   - Runs up to `--max-parallel` (default 4) sessions in a wave concurrently
     with a fresh `claude -p` process each (PLAN pass → EXECUTE pass).
   - Iteratively `--no-ff` merges successful siblings into trunk between waves.
   - Auto-commits, auto-creates a GitHub PR via `gh`, cleans up worktrees.

## Layout produced by `/epic.generate`

```
docs/claude-sessions/<epic-name>/
  session-00-operator-rules.md     # prepended to every session
  session-01-charter.md            # solo wave (parallel_safe: false)
  session-02-auth.md               # wave 2 sibling (depends_on: [01])
  session-03-email.md              # wave 2 sibling (depends_on: [01])
  session-04-billing.md            # wave 2 sibling (depends_on: [01])
  session-05-admin-ui.md           # wave 3 (depends_on: [02, 04])
  session-06-ci-gate.md            # final solo wave (depends_on: all)
```

`epic-dag.py --show` renders this as:

```
  ║ Wave 1: [01 charter ]
  ╠ Wave 2: [02 auth   ]  [03 email   ]  [04 billing ]
  ║ Wave 3: [05 admin-ui]
  ║ Wave 4: [06 ci-gate]
```

## Frontmatter fields

```yaml
---
session: 03
title: "Email worker"
depends_on: [01]              # parents in the DAG
touches:                      # globs this session may modify
  - src/email/**
parallel_safe: true           # false forces a solo wave
---
```

Sessions without frontmatter form an implicit linear chain (one per wave) —
the toolkit is fully back-compatible with pre-DAG epics.

## Common flags

| Flag | Default | Description |
|---|---|---|
| `--max-parallel N` | 4 | Concurrent sessions per wave |
| `--strict` | off | Fail on `touches` overlap between siblings |
| `--show-dag` | off | Print the wave layout and exit |
| `--dry-run` | off | Preview without executing (non-destructive) |
| `--start N` | 1 | Resume from session N |
| `--sequential` | off | Force one session per wave (legacy linear) |
| `--model M` | sonnet | Model: `opus`, `sonnet`, `haiku` |
| `--no-worktree` | off | Run trunk in CWD (forces sequential) |

See [`docs/epic-guide.md`](docs/epic-guide.md) for the full reference.

## Requirements

- Claude Code (`claude` CLI) on `PATH`
- Python 3.8+ (stdlib only — no extra packages)
- Bash 3.2+
- `git` 2.20+
- `gh` CLI (optional, for auto-PR creation)

## Files in this plugin

```
.claude-plugin/
  plugin.json          # plugin manifest
  marketplace.json     # makes the repo a self-installable marketplace
commands/
  epic.md              # /epic slash command
  epic.generate.md     # /epic.generate slash command
scripts/
  run-sessions.sh      # wave orchestrator
  epic-dag.py          # DAG builder + wave scheduler
  epic-progress.py     # live-progress display for a single session
docs/
  epic-guide.md        # full user guide
  epic-prompt-template.md
```

## License

MIT.
