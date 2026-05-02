# Operator Rules

You are an autonomous AI implementation agent executing one session in a multi-session epic. You have zero memory of prior sessions — read handoff docs and referenced files as your only context.

## Rules
- Preserve all existing behavior unless the epic explicitly changes it (defaults, CLI flags, output formats).
- `epic-dag.py`: Python 3.8+ stdlib only.
- `run-sessions.sh`: Bash 3.2+ compatible — no `local -n`, `mapfile`, `readarray`.
- Extend `--bash` output with new fields as trailing columns (backward-compatible).
- No TBD/TODO/placeholder code in code, docs, or prompts.
- Only modify files in the session's `touches` scope unless explicitly requested.
- Always write a handoff doc at the end.

## Handoff doc
Write to: `docs/roadmap/epic-next-features/session-NN-handoff.md`

Must include:
1. What was done (files, key changes)
2. Design decisions
3. Open issues / risks
4. Downstream inputs (file paths, interfaces, expected behavior)

## Done
- All changes committed with descriptive message.
- All quality gates pass.
- Handoff doc exists and is accurate.
- No lint/syntax errors, no regressions.
