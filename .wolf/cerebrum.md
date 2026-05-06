# Cerebrum

> OpenWolf's learning memory. Updated automatically as the AI learns from interactions.
> Do not edit manually unless correcting an error.
> Last updated: 2026-05-01

## User Preferences

<!-- How the user likes things done. Code style, tools, patterns, communication. -->

## Key Learnings

- **Project:** epic-toolkit
- **Description:** A Claude Code plugin for running multi-session epics as a **directed acyclic
- **Distribution:** Claude Code plugins installed from marketplaces expose namespaced commands like `/epic-toolkit:epic`; command files that need bundled scripts should invoke them via `${CLAUDE_PLUGIN_ROOT}` because installed plugins are copied to Claude's plugin cache.
- **Codex pets:** `~/.codex/pets/<id>/spritesheet.webp` can pass structural hatch-pet validation while still being visually unusable; always inspect the contact sheet for cropped, blank, or fragment-only active frames.
- **Tooling:** Hatch-pet scripts need Pillow; the bundled Python at `/Users/aramirez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3` has the required image dependencies when the system Python does not.

## Do-Not-Repeat

<!-- Mistakes made and corrected. Each entry prevents the same mistake recurring. -->
<!-- Format: [YYYY-MM-DD] Description of what went wrong and what to do instead. -->
- [2026-05-02] Do not accept a custom pet solely because `validate_atlas.py` returns ok; render/contact-sheet QA is required to catch visually corrupted rows.
- [2026-05-06] Do not iterate session ids with `for (( sid=1; sid<=999; sid++ )); break-on-missing` — session ids may have gaps (user removed a session) or trailing holes (epic halted before later waves ran), and the early break silently drops every session past the gap. Iterate `${!SESSION_SLUG_BY_ID[@]}` (the DAG-derived index set) instead.
- [2026-05-06] Do not hard-code result-file paths in the command docs (`commands/epic.md`, `.opencode/commands/epic.md`). The script writes to `${TMPDIR}/epic-toolkit/<repo>--<name>.result.json` and the path will drift from any doc that re-states it. Have the script print `RESULT_FILE=<path>` inside the `[EPIC_RESULT_START]/[END]` block and have the docs tell Claude to read that line.

## Decision Log

<!-- Significant technical decisions with rationale. Why X was chosen over Y. -->
