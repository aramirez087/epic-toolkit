---
session: 05
title: "CI gate and integration verification"
depends_on: [02, 03, 04]
touches: []
parallel_safe: false
---

# Session 05: CI Gate and Integration Verification

```md
Continue from Sessions 02, 03, 04.

Mission: Run full integration verification, fix failures, produce go/no-go report.

Anchors:
- scripts/epic-dag.py, scripts/run-sessions.sh
- README.md, docs/epic-guide.md
- commands/epic.md, .opencode/commands/epic.md
- docs/roadmap/epic-next-features/session-0{1,2,3,4}-handoff.md

Tasks:
1. Read all handoff docs and anchors.
2. Syntax: py_compile epic-dag.py, bash -n run-sessions.sh.
3. epic-dag.py functional: --show, --bash, --json. Verify --bash SESSION columns (+2 for model/cli). Verify JSON has model/cli fields.
4. run-sessions.sh functional: --show-dag --timeout 30 --retry 2, --dry-run --timeout 0 --retry 0, --dry-run --cli claude --model haiku.
5. Docs consistency: README flags match run-sessions.sh help. epic-guide.md config keys match. commands/epic.md matches .opencode/commands/epic.md.
6. Fix failures and re-run until all pass.
7. Write go/no-go report.

Deliverable: session-05-handoff.md (pass/fail per category, fixes, verdict)

Quality gates:
- py_compile epic-dag.py
- bash -n run-sessions.sh
- --bash SESSION column count = 7
- --dry-run --timeout 30 --retry 1 works
- Docs consistency checks pass

Exit: All syntax/functional checks pass. Docs consistent. Clear GO/NO-GO. If NO-GO, list blockers + fixes.
```
