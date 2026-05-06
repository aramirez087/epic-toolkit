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
    if any(c in declared for c in "*?["):
        return [p for p in changed_paths if fnmatch.fnmatchcase(p, declared)]
    return [p for p in changed_paths if p == declared]


def _is_metadata_only(changed_paths: list[str]) -> bool:
    # Empty diff means the session committed (HEAD changed) but added no files
    # outside metadata — typically an empty commit or a commit whose only
    # content was rename-equivalent. The no-op guard in run_one_session passes
    # because HEAD moved; without treating empty as metadata-only here, the
    # session would silently sail through deliverables validation too.
    for p in changed_paths:
        if not any(rx.match(p) for rx in HEURISTIC_METADATA_PATTERNS):
            return False
    return True


def _read_diff(worktree: str, base_ref: str) -> tuple[list[str], list[str]]:
    """Return (changed_or_added, deleted) paths between base_ref and HEAD."""
    # core.quotePath=false: git's default quotes any path with bytes >= 0x80
    # (and whitespace/control chars) as `"src/T\303\253st.cs"`. The exact-match
    # compare against the unquoted `produces:` entry then silently fails, so
    # any session that produces a file containing a non-ASCII char (em-dash,
    # accented letter, CJK) or a literal space gets flagged as "declared
    # deliverable missing" even when the file is plainly in the diff. Force
    # raw bytes so the comparison reflects real path identity. (bug-104)
    #
    # encoding="utf-8": text=True alone decodes git's stdout via
    # locale.getpreferredencoding() — cp1252 on Windows / ASCII under LC_ALL=C —
    # which mangles the very non-ASCII paths bug-104 went out of its way to
    # preserve. Pin UTF-8 so _matches_declared compares two consistently-decoded
    # strings on every locale. (bug-107)
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

    if fm.get("skip_deliverables_check") is True:
        return 0

    try:
        changed, deleted = _read_diff(worktree, base_ref)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    produces = fm.get("produces", []) or []
    if not isinstance(produces, list):
        print(
            "ERROR: produces: must be a list of paths or fnmatch globs",
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
