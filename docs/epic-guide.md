# Epic Sessions Guide

Run multi-session epic tasks autonomously in Claude Code or OpenCode. Sessions are
scheduled as a **directed acyclic graph** and **parallel siblings run concurrently in
per-session worktrees**, then merge into the trunk branch wave by wave.

## Quick start

```bash
# Inside Claude Code or OpenCode
/epic-toolkit:epic x-api-surface-expansion

# From your terminal (equivalent)
bash scripts/run-sessions.sh docs/claude-sessions/x-api-surface-expansion
```

Claude Code marketplace installs expose namespaced commands:
`/epic-toolkit:epic.generate` and `/epic-toolkit:epic`. OpenCode uses the
un-namespaced equivalents: `/epic.generate` and `/epic`.

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

Paste this into a new agent session:

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
| `produces` | recommended | List of paths or `fnmatch` globs the session must create or modify. After the session commits, the runner verifies every entry shows up in its diff vs the wave-start commit; missing entries fail the session before it merges into trunk |
| `skip_deliverables_check` | optional | Set to `true` only on docs-only / kickoff sessions whose only output is a handoff doc and `.wolf/*` updates. Without this opt-out a metadata-only commit fails the deliverables validator |

### Deliverables validation

After every session commits, the runner runs `scripts/validate-session-deliverables.py`
inside the session's worktree. Two modes:

1. **`produces:` declared** — every entry must appear in the session's diff vs the
   wave-start commit (any status except deletion). Globs use `fnmatch` semantics.
2. **No `produces:`** — metadata-only heuristic. If every changed path matches
   `^.wolf/` or `^docs/roadmap/.*-handoff\.md$`, the session is rejected as
   no-real-output. Set `skip_deliverables_check: true` to opt out.

A failure marks the session failed (rc=97), halts the wave before merging into
trunk, and writes a missing-paths summary to `.session-NN-exec.log`.

### Per-Session Overrides

You can override the default model and CLI on a per-session basis:

| Field | Type | Description |
|-------|------|-------------|
| `model` | string | Override default model for this session (e.g., "opus", "sonnet") |
| `cli` | string | Override CLI auto-detection for this session ("opencode" or "claude") |

Example mixed-tool epic:

```yaml
---
session: 02
title: "Complex analysis"
depends_on: [01]
model: "opus"
cli: "claude"
touches: ["analysis/**"]
parallel_safe: true
---
```

Use `model: "opus"` for sessions requiring complex reasoning or risky architecture work. Use `"sonnet"` for balanced work and `"haiku"` for straightforward, repetitive tasks.

## How execution works

1. **DAG validation** — `epic-dag.py` parses every session's frontmatter, builds the
   graph, validates no cycles, and computes Kahn-style waves.
2. **Trunk worktree** — `.epic-worktrees/<repo>/epic--<name>/` is created on
   branch `epic/<name>`.
3. **For each wave:**
   - For each sibling in the wave (capped by `--max-parallel`, default 4): a
     per-session worktree is spun up at
     `.epic-worktrees/<repo>/epic--<name>--sNN-<slug>/` on a branch
     `epic/<name>--sNN-<slug>` branched off trunk's current HEAD.
   - Each session runs as a **fresh CLI process** (Claude Code or OpenCode,
     auto-detected or forced via `--cli`) with the operator rules,
     its session prompt, and concatenated handoff docs from its DAG parents.
   - Two-pass per session: PLAN (read-only exploration) → EXECUTE (commits).
   - Sessions run concurrently. Their output streams to per-session log files;
     the orchestrator prints wave-level start/finish lines.
4. **Wave merge** — successful sibling branches are merged into trunk
   iteratively with `--no-ff`. Conflicts halt the run (you fix and resume).
5. **Cleanup** — successful per-session worktrees are removed; failed ones are
   preserved for inspection.

## Multi-Epic Workflows

When a problem is too large for a single epic, split it into multiple epics that
run sequentially. Each epic is an independent `docs/claude-sessions/` directory
with its own charter, feature sessions, and CI gate.

### When to split

Split into multiple epics when **two or more** of these apply:

- The problem spans **3+ independent subsystems** with no shared state
- The total session count would exceed **10–12** for a single epic
- Different subsystems need **different models** (e.g., opus for complex logic, haiku for CRUD)
- A subsystem is **risky or experimental** — splitting lets you retry just that epic
- The work touches **3+ non-overlapping directory trees** that could be owned by independent teams

Keep as one epic when sessions share significant state, or a single charter must
define architecture consumed by all downstream sessions.

### Directory structure

```
docs/claude-sessions/
  epic-1-subsystem-name/
    session-00-operator-rules.md
    session-01-charter.md
    session-02-feature.md
    ...
  epic-2-another-subsystem/
    session-00-operator-rules.md   (same content or inherit from epic-1)
    session-01-charter.md           (Continuity references epic-1 handoff paths)
    ...
```

### Execution order

Run epics sequentially. Each epic must merge to trunk before the next starts:

```bash
/epic-toolkit:epic epic-1-subsystem-name
# wait for completion, then:
/epic-toolkit:epic epic-2-another-subsystem
```

### Cross-epic handoffs

Later epics reference prior epic handoffs in their session Continuity sections:

```
Continue from Session 01 artifacts at docs/roadmap/epic-1-subsystem-name/session-01-handoff.md.
```

The `session-00-operator-rules.md` can be copied verbatim across epics, or later
epics can include a note pointing to the original epic's operator rules.

### Per-epic model selection

Use `--model` per epic invocation to set the default model:

```bash
/epic-toolkit:epic epic-1-subsystem-name --model opus
/epic-toolkit:epic epic-2-another-subsystem --model sonnet
```

Within each epic, individual sessions can override via frontmatter `model:` field
(see Per-Session Overrides above).

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
| `--model M` | sonnet | Model name (passed to CLI; e.g. `opus`, `sonnet`, `haiku` for Claude) |
| `--cli CMD` | auto | Force CLI: `opencode` or `claude`. Auto-detects from env vars or PATH |
| `--branch B` | `epic/<name>` | Trunk branch |
| `--base B` | repo default | Base for new trunk branch |
| `--no-commit` | off | Skip auto-commit fallback |
| `--no-pr` | off | Skip auto-PR creation |
| `--no-rebase` | off | Skip pre-PR rebase onto `origin/<default>` (default: rebase + auto-resolve `.wolf/`) |
| `--skip-plan` | off | Single-pass execution (no plan phase) |
| `--no-worktree` | off | Run trunk in CWD (forces sequential) |
| `--keep-worktree` | off | Retain trunk worktree on success |
| `--keep-session-worktrees` | off | Retain per-session worktrees on success |
| `--keep-session-docs` | off | Skip removing session prompts and roadmap handoffs from the epic branch on success |
| `--timeout N` | 0 | Session timeout in minutes (0 = no timeout) |
| `--retry N` | 0 | Retry failed sessions N times (0 = no retry) |
| `--wave-timeout MINS` | auto | Max minutes before the entire wave is killed (0 = auto-derive per wave) |
| `--fresh` | off | Disable resume: ignore cached plans and re-run already-committed sessions |

## Configuration File Reference

Create `.epic-config.json` in your repository root to set defaults:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `timeout` | number | 0 | Session timeout in minutes (0 = disabled) |
| `retry` | number | 0 | Retry count for failed sessions (0 = disabled) |
| `cli` | string | "" | Force CLI: "opencode" or "claude" (empty = auto-detect) |
| `model` | string | "sonnet" | Default model for all sessions |
| `maxParallel` | number | 4 | Max concurrent sessions per wave |
| `autoCommit` | boolean | true | Auto-commit on session success |
| `autoPr` | boolean | true | Auto-create GitHub PR |
| `skipPlan` | boolean | false | Single-pass execution (no plan phase) |
| `keepWorktree` | boolean | false | Retain trunk worktree on success |

CLI flags take precedence over config file values.

## Examples

```bash
# Run the whole DAG
/epic-toolkit:epic my-epic

# Inspect the planned waves before running
/epic-toolkit:epic my-epic --show-dag

# Higher parallelism (e.g., big fan-out wave)
/epic-toolkit:epic my-epic --max-parallel 8

# Resume after a failure at session 04
/epic-toolkit:epic my-epic --start 4

# Strict-mode: fail if siblings declare overlapping touches globs
/epic-toolkit:epic my-epic --strict

# Force the legacy sequential behavior
/epic-toolkit:epic my-epic --sequential

# Preview only — non-destructive
/epic-toolkit:epic my-epic --dry-run

# From terminal directly
bash scripts/run-sessions.sh docs/claude-sessions/my-epic --max-parallel 6 --model opus

# Force a specific CLI (when running from a plain terminal)
bash scripts/run-sessions.sh docs/claude-sessions/my-epic --cli opencode

# Use timeout and retry for flaky sessions
/epic-toolkit:epic my-epic --timeout 45 --retry 2

# Mixed configuration: some sessions timeout quickly, others have more time
# (configure per-session via frontmatter model/cli overrides)
/epic-toolkit:epic complex-analysis --timeout 60 --retry 1 --max-parallel 2
```

## CLI detection

The orchestrator auto-detects which AI CLI to use:

1. **`--cli` flag** — explicit override, highest priority.
2. **Environment variables** — `OPENCODE_SESSION_ID` (set by OpenCode) or
   `CLAUDECODE` (set by Claude Code).
3. **PATH fallback** — looks for `opencode` then `claude` on `PATH`.

Progress display adapts to the detected CLI:

- **Claude Code** streams `--output-format stream-json` through
  `epic-progress.py` for real-time step/tool/target tracking with a spinner.
- **OpenCode** pipes `--format json` through the same `epic-progress.py`,
  which handles both Claude's `stream-json` events and OpenCode's JSON format
  (`step_start`/`tool_use`/`text`/`step_finish`).
- `epic-progress.py` also updates the shared status JSON so the TUI dashboard
  (`epic-ui.py`) reflects live progress.
- If neither progress script is available, the session runs with simple
  log output (no spinner).

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
