---
session: 02
title: "DAG parser frontmatter extensions"
depends_on: [01]
touches:
  - scripts/epic-dag.py
parallel_safe: true
---

# Session 02: DAG Parser Frontmatter Extensions

Paste this into a new agent session:

```md
Continue from Session 01 artifacts.

Mission: Extend epic-dag.py to parse per-session `model` and `cli` overrides from YAML frontmatter and export them in the backward-compatible `--bash` plan output.

Repository anchors:
- scripts/epic-dag.py
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read the current scripts/epic-dag.py and the Session 01 handoff.
2. In `load_sessions`, extract optional `model` and `cli` keys from frontmatter (string values, default empty string).
3. Store them in the session dict and include them in the JSON plan output.
4. Update `emit_bash` so each `SESSION` line appends two additional tab-separated columns:
   `<model> <cli>`
   If absent, emit empty strings for those columns so older parsers that read only the first fields continue to work.
5. Verify that `--bash`, `--json`, and `--show` all work correctly.
6. Add a brief comment near `emit_bash` explaining the backward-compat column extension.

Deliverables:
1. Updated scripts/epic-dag.py
2. docs/roadmap/epic-next-features/session-02-handoff.md

Quality gates:
- python3 -m py_compile scripts/epic-dag.py
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --show
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --bash | grep -E '^SESSION' | awk '{print NF}' | sort -u (verify column count increased by 2)
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --json | python3 -m json.tool > /dev/null

Exit criteria:
- `model` and `cli` frontmatter keys are parsed and present in all output formats.
- `--bash` output has exactly 2 more columns than before.
- Existing sessions without these keys still work (empty values).
- All quality gates pass.
```
