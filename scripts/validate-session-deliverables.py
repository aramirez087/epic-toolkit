#!/usr/bin/env python3
"""validate-session-deliverables.py

Validate that a session's commits produced the deliverables the session
declared (or, when nothing was declared, that it produced ANY non-metadata
output). Closes the gap where a session committed only its handoff doc and
.wolf/* metadata yet still passed the runner's no-op guard, letting the
epic ship without the actual code the session was meant to produce.

Frontmatter the validator reads:

    produces:                       # optional list of paths or fnmatch globs
      - "src/Users/UsersService.cs"
      - "src/Users/UsersController.cs"
      - "src/Users/Models/*.cs"

    skip_deliverables_check: true   # opt out (kickoff/docs-only sessions)

Modes:
  1. produces: declared
       Every entry must match at least one path in the session's diff
       (any status except D). Globs use fnmatch semantics.
  2. produces: not declared
       Metadata-only heuristic: if every changed path matches
       ^\\.wolf/ or ^docs/roadmap/.*-handoff\\.md$ the session is
       rejected — it committed nothing real.

Args:
  <session_md>  path to session-NN-*.md
  <worktree>    git working directory of the session branch
  <base_ref>    commit-ish the session was branched from (use the captured
                baseline_head; works in both worktree and --no-worktree mode)

Exit codes:
  0 — passed
  1 — declared deliverables missing OR metadata-only heuristic fired
  2 — internal error (bad args, frontmatter unparseable, git failed)
"""

from __future__ import annotations

import fnmatch
import importlib.util
import os
import re
import subprocess
import sys

HEURISTIC_METADATA_PATTERNS = [
    re.compile(r"^\.wolf/"),
    re.compile(r"^docs/roadmap/.*-handoff\.md$"),
]


def _load_dag_module():
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(here, "epic-dag.py")
    spec = importlib.util.spec_from_file_location("epic_dag", src)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not build module spec for {src}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _matches_declared(declared: str, changed_paths: list[str]) -> list[str]:
    # Literal equality first — bare `[` survives Next.js/Remix dynamic
    # segments instead of being interpreted as a fnmatch character class. (bug-118)
    literal = [p for p in changed_paths if p == declared]
    if literal:
        return literal
    if not any(c in declared for c in "*?["):
        return []
    # Custom glob: treat `[`/`]` as literal (so `app/[id]/page.tsx` works),
    # only `*` and `?` are wildcards. `**` is zero-or-more path segments. (bugs 141, 161)
    PH_MID = "\x00GS_MID\x00"
    PH_PREFIX = "\x00GS_PRE\x00"
    PH_SUFFIX = "\x00GS_SUF\x00"
    PH_ALONE = "\x00GS_ALL\x00"
    s = declared.replace("/**/", PH_MID)
    if s.startswith("**/"):
        s = PH_PREFIX + s[3:]
    if s.endswith("/**"):
        s = s[:-3] + PH_SUFFIX
    s = s.replace("**", PH_ALONE)
    pattern = ""
    i = 0
    while i < len(s):
        if s.startswith(PH_MID, i):
            pattern += "(?:/.*)?/"
            i += len(PH_MID)
        elif s.startswith(PH_PREFIX, i):
            pattern += "(?:.*/)?"
            i += len(PH_PREFIX)
        elif s.startswith(PH_SUFFIX, i):
            pattern += "(?:/.*)?"
            i += len(PH_SUFFIX)
        elif s.startswith(PH_ALONE, i):
            pattern += ".*"
            i += len(PH_ALONE)
        else:
            ch = s[i]
            if ch == "*":
                pattern += ".*"
            elif ch == "?":
                pattern += "."
            else:
                pattern += re.escape(ch)
            i += 1
    rx = re.compile(f"^{pattern}$")
    return [p for p in changed_paths if rx.match(p)]


def _is_metadata_only(changed_paths: list[str]) -> bool:
    # Empty diff also counts as metadata-only — HEAD moved (no-op guard
    # passed) but no real files changed.
    for p in changed_paths:
        if not any(rx.match(p) for rx in HEURISTIC_METADATA_PATTERNS):
            return False
    return True


def _read_diff(worktree: str, base_ref: str) -> tuple[list[str], list[str]]:
    """Return (changed_or_added, deleted) paths between base_ref and HEAD."""
    # core.quotePath=false + encoding="utf-8" — default quoting + locale
    # decoding both mangle non-ASCII paths. (bugs 104, 107)
    proc = subprocess.run(
        [
            "git",
            "-C", worktree,
            "-c", "core.quotePath=false",
            "diff",
            "--name-status",
            f"{base_ref}..HEAD",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git diff returned {proc.returncode}: {proc.stderr.strip()}"
        )
    changed: list[str] = []
    deleted: list[str] = []
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0][:1]
        # R/C come as `R100\told\tnew` — score on the new path.
        path = parts[-1]
        if status == "D":
            deleted.append(path)
        else:
            changed.append(path)
    return changed, deleted


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    session_md, worktree, base_ref = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isfile(session_md):
        print(f"ERROR: session file not found: {session_md}", file=sys.stderr)
        return 2

    try:
        dag = _load_dag_module()
    except Exception as exc:
        print(f"ERROR: could not load epic-dag.py parser: {exc}", file=sys.stderr)
        return 2

    # utf-8-sig matches epic-dag.py's BOM-tolerant read (bug-081).
    try:
        with open(session_md, encoding="utf-8-sig") as f:
            text = f.read()
    except OSError as exc:
        print(f"ERROR: could not read {session_md}: {exc}", file=sys.stderr)
        return 2

    fm, _ = dag.parse_frontmatter(text)

    # Reject non-bool shapes — `is True` would silently ignore quoted-string
    # / int / list opt-outs that the user expected to work. (bug-175)
    skip_raw = fm.get("skip_deliverables_check")
    if skip_raw is not None and not isinstance(skip_raw, bool):
        print(
            f"ERROR: skip_deliverables_check must be a boolean (true/false), "
            f"got {type(skip_raw).__name__} {skip_raw!r}. This usually means "
            f"the YAML key has a non-bool value (`skip_deliverables_check: 1`, "
            f"`skip_deliverables_check: \"true\"`) or has accidental indented "
            f"children below it. Use the unquoted YAML 1.1 spellings — "
            f"`skip_deliverables_check: true` / `yes` / `on` — to opt out, "
            f"or omit the key (or set it to `false`) to run validation.",
            file=sys.stderr,
        )
        return 2
    if skip_raw is True:
        return 0

    try:
        changed, deleted = _read_diff(worktree, base_ref)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    # Reject non-list shapes — `produces: false` / `0` / `""` would
    # silently fall through to the metadata-only heuristic. (bug-171)
    produces = fm.get("produces", [])
    if isinstance(produces, bool):
        print(
            f"ERROR: produces: must be a list of paths or fnmatch globs, got "
            f"boolean {produces!r}. YAML 1.1 spellings (yes/no/on/off/y/n/"
            f"true/false) are coerced to booleans by the frontmatter parser — "
            f"write `produces: [path]` instead, or a block list with `- path` "
            f"items. (If you intended to opt out of deliverables validation, "
            f"set `skip_deliverables_check: true` instead.)",
            file=sys.stderr,
        )
        return 2
    if not isinstance(produces, list):
        print(
            f"ERROR: produces: must be a list of paths or fnmatch globs, got "
            f"{type(produces).__name__} {produces!r}. Use flow-list syntax "
            f"`produces: [path]` or a block list with `- path` items. A bare "
            f"scalar (`produces: src/foo`) or quoted string (`produces: \"src/foo\"`) "
            f"is not a list.",
            file=sys.stderr,
        )
        return 2
    produces = [str(p).strip() for p in produces if str(p).strip()]

    if produces:
        missing = [d for d in produces if not _matches_declared(d, changed)]
        if missing:
            print(
                "ERROR: declared deliverables missing from session diff:",
                file=sys.stderr,
            )
            for m in missing:
                print(f"  - {m}", file=sys.stderr)
            print("", file=sys.stderr)
            print("Session diff vs baseline:", file=sys.stderr)
            shown = 0
            for p in changed:
                if shown >= 30:
                    break
                print(f"  + {p}", file=sys.stderr)
                shown += 1
            for p in deleted[:5]:
                print(f"  - {p} (deleted)", file=sys.stderr)
            remaining = len(changed) + len(deleted) - shown - min(len(deleted), 5)
            if remaining > 0:
                print(f"  ... and {remaining} more", file=sys.stderr)
            return 1
        return 0

    if _is_metadata_only(changed):
        if not changed:
            print(
                "ERROR: session HEAD advanced but produced no changed paths — "
                "likely empty commit(s) with no real deliverables",
                file=sys.stderr,
            )
        else:
            print(
                "ERROR: session committed only metadata/handoff files — no real deliverables",
                file=sys.stderr,
            )
            print(
                "All changed paths matched .wolf/* or docs/roadmap/*-handoff.md:",
                file=sys.stderr,
            )
            for p in changed:
                print(f"  + {p}", file=sys.stderr)
        print("", file=sys.stderr)
        print(
            "If this is intentional (kickoff or docs-only session), add to frontmatter:",
            file=sys.stderr,
        )
        print("    skip_deliverables_check: true", file=sys.stderr)
        print(
            "Otherwise add a `produces:` list of expected output paths.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
