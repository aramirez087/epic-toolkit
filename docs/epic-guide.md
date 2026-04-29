# Epic Sessions Guide

Run multi-session Claude Code tasks autonomously. Sessions are scheduled as a
**directed acyclic graph** and **parallel siblings run concurrently in
per-session worktrees**, then merge into the trunk branch wave by wave.

## Quick start

```bash
# Inside Claude Code
/epic x-api-surface-expansion

# From your terminal (equivalent)
"${CLAUDE_PLUGIN_ROOT}/scripts/run-sessions.sh" docs/claude-sessions/x-api-surface-expansion
```

## Directory convention

```
docs/claude-sessions/<epic-name>/
  session-00-operator-rules.md    # Rules prepended to EVERY session (no frontmatter)
  session-01-charter.md           # Solo wave 1 — sets up the DAG
  session-02-auth.md              # Wave 2 sibling
  session-03-email.md             # Wave 2 sibling — runs in parallel with 02
  session-04-billing.md           # Wave 2 sibling — runs in parallel with 02 & 03
  session-05-admin-ui.md          # Wave 3 — depends on 02 + 04
  session-06-ci-gate.md           # Final solo wave — depends on every prior
```

## Session file format

Sessions 01+ start with YAML frontmatter declaring DAG metadata, then the markdown
body, then the prompt inside a ` ```md ``` ` code fence:

```markdown
---
session: 03
title: "Email worker"
depends_on: [01]
touches:
  - src/email/**
  - workers/email/**
parallel_safe: true
---

# Session 03: Email worker

Paste this into a new Claude Code session:

​```md
Continue from Session 01 artifacts.

Mission: ...

Tasks:
1. ...
2. ...

Deliverables:
1. Implement src/email/worker.ts
2. Create docs/roadmap/<epic-name>/session-03-handoff.md

Exit criteria:
- Worker passes its tests
- Handoff doc exists
​```
```

Session 00 is special — its content is prepended to every other session as
"operator rules" (coding standards, safety constraints, definition of done) and
has no frontmatter.

## Frontmatter fields

| Field | Required | Meaning |
|---|---|---|
| `session` | yes | Integer matching the filename's NN |
| `title` | yes | Human title |
| `depends_on` | yes | List of prior session numbers this depends on. Empty `[]` for the charter. Omitting it falls back to a linear chain (defeats parallelism) |
| `touches` | recommended | List of file globs this session may modify. The runner uses these to detect overlaps between parallel siblings |
| `parallel_safe` | yes | `false` forces a solo wave (charter, CI gate, anything mutating shared state). Default `true` |

## How execution works

1. **DAG validation** — `epic-dag.py` parses every session's frontmatter, builds the
   graph, validates no cycles, and computes Kahn-style waves.
2. **Trunk worktree** — `.epic-worktrees/<repo>/epic--<name>/` is created on
   branch `epic/<name>`.
3. **For each wave:**
   - For each sibling in the wave (capped by `--max-parallel`, default 4): a
     per-session worktree is spun up at
     `.epic-worktrees/<repo>/epic--<name>--sNN-<slug>/` on a branch
     `epic/<name>/sNN-<slug>` branched off trunk's current HEAD.
   - Each session runs as a **fresh Claude process** with the operator rules,
     its session prompt, and concatenated handoff docs from its DAG parents.
   - Two-pass per session: PLAN (read-only exploration) → EXECUTE (commits).
   - Sessions run concurrently. Their output streams to per-session log files;
     the orchestrator prints wave-level start/finish lines.
4. **Wave merge** — successful sibling branches are merged into trunk
   iteratively with `--no-ff`. Conflicts halt the run (you fix and resume).
5. **Cleanup** — successful per-session worktrees are removed; failed ones are
   preserved for inspection.

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--start N` | 1 | Resume from session N |
| `--end N` | all | Stop after session N |
| `--max-parallel N` | 4 | Concurrent sessions per wave |
| `--strict` | off | Fail on `touches` overlap between siblings |
| `--sequential` | off | Force one session per wave (legacy linear) |
| `--show-dag` | off | Print the wave layout and exit |
| `--dry-run` | off | Preview without executing (non-destructive) |
| `--model M` | sonnet | Model: `opus`, `sonnet`, `haiku` |
| `--branch B` | `epic/<name>` | Trunk branch |
| `--base B` | repo default | Base for new trunk branch |
| `--no-commit` | off | Skip auto-commit fallback |
| `--no-pr` | off | Skip auto-PR creation |
| `--skip-plan` | off | Single-pass execution (no plan phase) |
| `--no-worktree` | off | Run trunk in CWD (forces sequential) |
| `--keep-worktree` | off | Retain trunk worktree on success |
| `--keep-session-worktrees` | off | Retain per-session worktrees on success |

## Examples

```bash
# Run the whole DAG
/epic my-epic

# Inspect the planned waves before running
/epic my-epic --show-dag

# Higher parallelism (e.g., big fan-out wave)
/epic my-epic --max-parallel 8

# Resume after a failure at session 04
/epic my-epic --start 4

# Strict-mode: fail if siblings declare overlapping touches globs
/epic my-epic --strict

# Force the legacy sequential behavior
/epic my-epic --sequential

# Preview only — non-destructive
/epic my-epic --dry-run

# From terminal directly
"${CLAUDE_PLUGIN_ROOT}/scripts/run-sessions.sh" docs/claude-sessions/my-epic --max-parallel 6 --model opus
```

## Designing for parallelism

The runner can only parallelize what the DAG allows. To get wide waves:

- **Charter session** (01): create scaffolds, type signatures, empty modules,
  directory structure. Its job is to make downstream work parallelizable.
- **Feature sessions**: each owns a disjoint directory or file family. Declare
  `touches` precisely so the runner can detect accidental overlap.
- **Composition sessions**: depend on multiple feature siblings; sit in a later
  wave that fans in.
- **CI gate**: depends on everything; runs alone last.

If `epic-dag.py --show` reports mostly single-session waves, your work is over-
serialized. Re-examine: are sessions actually competing for the same files, or
just declared as a chain by habit?

## Tips

- **Resume is cheap** — fix the failure, then `--start <failed_id>`. The runner
  detects existing per-session worktrees from the prior attempt and recreates
  them fresh.
- **Use Opus for code-heavy sessions** — `--model opus` materially improves
  output quality on big diffs.
- **Don't skip `touches`** — it's the only signal the runner has to warn before
  sibling sessions step on each other.
- **Conflicts at merge time are real** — if a sibling commit conflicts when
  merged into trunk, the run halts. Fix manually in the trunk worktree, commit,
  and resume.
