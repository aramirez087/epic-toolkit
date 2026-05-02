---
session: 05
title: "CI gate and integration verification"
depends_on: [02, 03, 04]
touches: []
parallel_safe: false
---

# Session 05: CI Gate and Integration Verification

Paste this into a new agent session:

```md
Continue from Session 02, 03, 04 artifacts.

Mission: Run the full integration verification suite, fix any failures, and produce a go/no-go report for the epic.

Repository anchors:
- scripts/epic-dag.py
- scripts/run-sessions.sh
- README.md
- docs/epic-guide.md
- commands/epic.md
- .opencode/commands/epic.md
- docs/roadmap/epic-next-features/session-01-handoff.md
- docs/roadmap/epic-next-features/session-02-handoff.md
- docs/roadmap/epic-next-features/session-03-handoff.md
- docs/roadmap/epic-next-features/session-04-handoff.md

Tasks:
1. Read all handoff docs and repository anchors.
2. Run syntax validation:
   a. python3 -m py_compile scripts/epic-dag.py
   b. bash -n scripts/run-sessions.sh
3. Run functional verification on epic-dag.py:
   a. python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --show
   b. python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --bash
   c. python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --json
   d. Verify `--bash` SESSION lines have the expected column count (model + cli appended).
   e. Verify the JSON output contains `model` and `cli` fields for every session.
4. Run functional verification on run-sessions.sh:
   a. bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --show-dag --timeout 30 --retry 2
   b. bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --dry-run --timeout 0 --retry 0
   c. bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --dry-run --cli claude --model haiku
5. Cross-check documentation consistency:
   a. Verify README.md flag table matches run-sessions.sh help text.
   b. Verify docs/epic-guide.md `.epic-config.json` keys match what run-sessions.sh reads.
   c. Verify commands/epic.md and .opencode/commands/epic.md are in sync.
6. If any check fails, fix the issue in the relevant file and re-run the check. Iterate until all pass.
7. Write the final go/no-go report.

Deliverables:
1. docs/roadmap/epic-next-features/session-05-handoff.md (go/no-go report with pass/fail per category, any fixes applied, and final verdict)

Quality gates:
- python3 -m py_compile scripts/epic-dag.py
- bash -n scripts/run-sessions.sh
- python3 scripts/epic-dag.py docs/claude-sessions/epic-next-features --bash | awk '/^SESSION/ {print NF}' | sort -u | grep -q "7" (expected column count)
- bash scripts/run-sessions.sh docs/claude-sessions/epic-next-features --dry-run --timeout 30 --retry 1
- Documentation consistency checks pass

Exit criteria:
- All syntax checks pass.
- All functional checks pass.
- Documentation is consistent with implementation.
- Handoff doc contains a clear GO or NO-GO verdict.
- If NO-GO, list specific blockers and remediation steps.
```
