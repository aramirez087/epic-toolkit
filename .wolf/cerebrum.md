# Cerebrum

> OpenWolf's learning memory. Updated automatically as the AI learns from interactions.
> Do not edit manually unless correcting an error.
> Last updated: 2026-05-06

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
- [2026-05-05] Do not use single-method process detection (e.g., only lsof) for concurrent safety checks — if the tool is unavailable, the check silently fails and data corruption results. Use multiple methods (/proc, lsof, fuser) with fallback to conservative error. (bugs 017)
- [2026-05-05] Do not directly access sparse associative arrays without validation (e.g., `${arr[$id]}` when some IDs may not be in the array). Validate with `${arr[$id]:-}` and handle empty case. Use helper functions to enforce consistency. (bug-018)
- [2026-05-05] Do not build PR descriptions with empty arrays silently — always check `${#array[@]} -gt 0` before assuming entries, or provide a fallback message for the empty case. (bug-019)
- [2026-05-05] Do not use literal-prefix glob `[[ "$path" == "$dir"* ]]` to test "is path under dir" — it matches sibling directories that share a name prefix (e.g., `…/s01-foo` matches `…/s01-foo-extra`). Always anchor the separator: `[[ "$path" == "$dir" || "$path" == "$dir"/* ]]`. (bug-022)
- [2026-05-05] Do not parse markdown fenced code blocks with `^```$` as the only terminator — language-tagged inner blocks (```bash, ```python, ```diff) are common and their bare closing ``` will silently truncate the outer capture. Track fence depth: `/^```[A-Za-z]/` opens an inner block; bare `^```$` only closes when depth==0. (bug-023)
- [2026-05-05] Do not anchor text-file searches to LF-only separators (`text.startswith("---\n")`, `text.find("\n---\n")`). Normalise CRLF→LF first, or all Windows/Git-Bash users see the parser silently return empty. (bug-024)
- [2026-05-05] Do not glob `WORKTREE_BASE/*--sNN-*` unscoped — that base is shared across every epic in the repo, so any unfiltered scan can match (and delete) sibling epics' per-session worktrees, including ones holding uncommitted work. Always scope by `${BRANCH_SANITIZED}--s` so cleanup only sees the *current* epic's children.
- [2026-05-05] Do not parse markdown / frontmatter with awk using bare `$0 == "..."` or anchored `/^...$/` regexes — awk strips `\n` between records but keeps trailing `\r`, so CRLF files (Windows / `core.autocrlf=true`) silently fail every literal/anchored test. Strip CR with `sub(/\r$/, "")` as the first action in the awk block. Same class of bug as #024 but in the bash/awk path; both must be normalised.
- [2026-05-05] Do not write boilerplate header or intro into the prompt-section accumulator before checking whether any entries exist. Build entries first; emit the header only when the entries variable is non-empty. Otherwise the model receives a confident "## Section" header followed by nothing and can hallucinate to fill the perceived gap.
- [2026-05-05] Do not use `grep -F` for "is this exact branch/line in this output" checks. `-F` is fixed-string but still matches anywhere on the line, so a prefix-shared sibling (`epic/foo-bar` for `epic/foo`) silently produces a false positive. Use `grep -qFx` (whole-line match) or `awk '$0 == "..."'` whenever the input is one record per line and you want equality. (bug-033)
- [2026-05-05] Do not strip "the title" with a single sticky flag like `fm_done && /^# / { … }`. The flag survives intermediate content, so the rule fires against the first `# Heading` anywhere in the body when there is no leading title. Use a window flag (`awaiting_title`) that is cleared by ANY non-blank non-title line, so the strip only happens immediately after the frontmatter close. (bug-034)
- [2026-05-05] Do not call Python `open(path)` without `encoding="utf-8"` for any text file you wrote yourself or expect to be UTF-8. The default is `locale.getpreferredencoding(False)` — cp1252 on Windows, ASCII when `LC_ALL=C` — and crashes with UnicodeDecodeError on em-dashes / smart quotes / accents. Audit every `open(` site, not just the ones in the file you're editing — sibling helpers often have the same bug. (bug-035, related bug-024)
- [2026-05-06] Do not leave retry-loop status variables initialized only before the loop. Reset `rc` at the start of each attempt and set success explicitly, or a failed first attempt poisons every later retry and can skip execution behind `if [[ $rc -eq 0 ]]`. (bug-036)
- [2026-05-06] Do not implement `--sequential` by only setting `MAX_PARALLEL=1`. That serializes process launch but leaves original DAG waves intact, so same-wave sessions still branch from the same trunk head and merge only after the wave. Flatten to one session per wave or merge after each serial session. (bug-037)
- [2026-05-06] Do not use GNU-only `timeout` unguarded in macOS-supported shell paths. Probe `timeout`/`gtimeout` first or run the command directly as a fallback. The auto-commit fallback currently skips commits on stock Darwin. (bug-038)
- [2026-05-06] Do not run repo-mutating setup before preview exits (`--dry-run`, `--show-dag`). Even "helpful" provisioning violates preview guarantees and can create untracked files during validation. Gate side effects behind real execution. (bug-039)

## Decision Log

<!-- Significant technical decisions with rationale. Why X was chosen over Y. -->
