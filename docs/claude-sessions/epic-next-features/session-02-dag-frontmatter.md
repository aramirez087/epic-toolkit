---
session: 02
title: "DAG parser frontmatter extensions"
depends_on: [01]
touches:
  - scripts/epic-dag.py
parallel_safe: true
---

# Session 02: DAG Parser Frontmatter Extensions

```md
Continue from Session 01.

Mission: Extend epic-dag.py to parse per-session `model` and `cli` from YAML frontmatter, export in `--bash` output.

Anchors:
- scripts/epic-dag.py
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read epic-dag.py and Session 01 handoff.
2. In `load_sessions`: extract `model` and `cli` from frontmatter (string, default "").
3. Store in session dict, include in JSON plan output.
4. In `emit_bash`: append two tab-separated columns `<model> <cli>` to each `SESSION` line. Emit empty strings if absent (backward-compatible).
5. Verify `--bash`, `--json`, `--show` all work.
6. Add comment near `emit_bash` explaining the backward-compat extension.

Deliverables: Updated scripts/epic-dag.py, session-02-handoff.md

Quality gates:
- python3 -m py_compile scripts/epic-dag.py
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --show
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --bash | grep -E '^SESSION' | awk '{print NF}' | sort -u
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --json | python3 -m json.tool > /dev/null

Exit: model/cli parsed in all outputs. --bash has +2 columns. Sessions without keys still work (empty). Gates pass.
```
