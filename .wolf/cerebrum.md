# Cerebrum

> OpenWolf's learning memory. Updated automatically as the AI learns from interactions.
> Do not edit manually unless correcting an error.
> Last updated: 2026-05-01

## User Preferences

<!-- How the user likes things done. Code style, tools, patterns, communication. -->

## Key Learnings

- **Project:** epic-toolkit
- **Description:** A Claude Code plugin for running multi-session epics as a **directed acyclic
- **Codex pets:** `~/.codex/pets/<id>/spritesheet.webp` can pass structural hatch-pet validation while still being visually unusable; always inspect the contact sheet for cropped, blank, or fragment-only active frames.
- **Tooling:** Hatch-pet scripts need Pillow; the bundled Python at `/Users/aramirez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3` has the required image dependencies when the system Python does not.

## Do-Not-Repeat

<!-- Mistakes made and corrected. Each entry prevents the same mistake recurring. -->
<!-- Format: [YYYY-MM-DD] Description of what went wrong and what to do instead. -->
- [2026-05-02] Do not accept a custom pet solely because `validate_atlas.py` returns ok; render/contact-sheet QA is required to catch visually corrupted rows.

## Decision Log

<!-- Significant technical decisions with rationale. Why X was chosen over Y. -->
