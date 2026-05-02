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

```md
Continue from Session 01.

Mission: Update all docs for timeout, retry, per-session frontmatter overrides, `.epic-config.json`.

Anchors:
- README.md, docs/epic-guide.md
- commands/epic.md, .opencode/commands/epic.md
- docs/roadmap/epic-next-features/session-01-handoff.md

Tasks:
1. Read all anchors.
2. README.md: add `--timeout`/`--retry` to flags table, `.epic-config.json` section + example, frontmatter `model`/`cli` example.
3. docs/epic-guide.md: expand Options table, `.epic-config.json` reference (all keys/types/defaults), frontmatter `model`/`cli` subsection, mixed-tool epic example.
4. commands/epic.md + .opencode/commands/epic.md: add `--timeout M`/`--retry N` to description header, defaults block, bash example.
5. Ensure all four docs are consistent.

Deliverables: Updated README.md, docs/epic-guide.md, commands/epic.md, .opencode/commands/epic.md, session-04-handoff.md

Quality gates:
- grep -c "timeout" README.md docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (all 4)
- grep -c "retry" README.md docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (all 4)
- grep -c "epic-config" README.md docs/epic-guide.md (both)
- grep -c "model:" docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (all 3)
- grep -c "cli:" docs/epic-guide.md commands/epic.md .opencode/commands/epic.md (all 3)

Exit: All four docs updated and consistent. Correct defaults. No broken formatting. Gate counts >= 1.
```
