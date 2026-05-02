---
session: 04
title: "Documentation and command reference"
depends_on: [01]
touches:
  - README.md
  - docs/epic-guide.md
  - commands/epic.md
  - .opencode/commands/epic.md
parallel_safe: true
---

# Session 04: Documentation and Command Reference

Paste this into a new agent session:

```md
Continue from Session 01 artifacts.

Mission: Update all user-facing documentation to cover the new timeout, retry, per-session frontmatter overrides, and `.epic-config.json` features.

Repository anchors:
- README.md
- docs/epic-guide.md
- commands/epic.md
- .opencode/commands/epic.md
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read all repository anchors listed above and the Session 01 handoff.
2. Update README.md:
   - Add `--timeout` and `--retry` to the Common flags table.
   - Add a `.epic-config.json` section with a minimal example.
   - Add frontmatter example showing `model` and `cli` keys.
3. Update docs/epic-guide.md:
   - Expand the Options table with `--timeout`, `--retry`.
   - Add a `.epic-config.json` reference section listing every key, type, and default.
   - Add a frontmatter reference subsection for `model` and `cli`.
   - Update examples to show mixed-tool epics (some sessions on `claude`, others on `opencode`).
4. Update commands/epic.md and .opencode/commands/epic.md:
   - Add `--timeout M` and `--retry N` to the flag list in the description header.
   - Add the new flags to the defaults block and the bash execution example.
5. Ensure all four docs are consistent: same flag names, same defaults, same examples.

Deliverables:
1. Updated README.md
2. Updated docs/epic-guide.md
3. Updated commands/epic.md
4. Updated .opencode/commands/epic.md
5. docs/roadmap/epic-next-features/session-04-handoff.md

Quality gates:
- grep -c "timeout" README.md docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (verify all 4 mention it)
- grep -c "retry" README.md docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (verify all 4 mention it)
- grep -c "epic-config" README.md docs/epic-guide.md (verify both mention it)
- grep -c "model:" docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (verify frontmatter example present)
- grep -c "cli:" docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (verify frontmatter example present)

Exit criteria:
- All four documentation files are updated and mutually consistent.
- New flags, config file, and frontmatter keys are documented with correct defaults.
- No broken markdown links or formatting.
- Quality gate counts are all >= 1.
```
