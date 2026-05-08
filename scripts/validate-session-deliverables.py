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
      - "../sibling-repo/path/to/file.cs"     # cross-repo: see below

    skip_deliverables_check: true   # opt out (kickoff/docs-only sessions)

Modes:
  1. produces: declared
       Every entry must match at least one path in the session's diff
       (any status except D). Globs use fnmatch semantics.
  2. produces: not declared
       Metadata-only heuristic: if every changed path matches
       ^\\.wolf/ or ^docs/roadmap/.*-handoff\\.md$ AND no external repo
       advanced, the session is rejected — it committed nothing real.

Cross-repo (`../sibling/...` or absolute) paths:
  When the runner captured `--external-baselines <json>` at session start,
  the validator groups declared paths by their containing git repo and
  diffs each repo against its own captured HEAD. A path declared as
  `../masterSignalR-clone/Services/Foo.cs` thus passes when Foo.cs shows
  up in the masterSignalR-clone diff, even though the epic worktree
  itself only contains metadata changes.

Args (positional):
  <session_md>  path to session-NN-*.md
  <worktree>    git working directory of the session branch
  <base_ref>    commit-ish the session was branched from (use the captured
                baseline_head; works in both worktree and --no-worktree mode)

Optional:
  --external-baselines <json>  sidecar written by epic-external-baselines.py.
                               Without it, all declared paths are matched
                               only against the worktree diff (back-compat).

Exit codes:
  0 — passed
  1 — declared deliverables missing OR metadata-only heuristic fired
  2 — internal error (bad args, frontmatter unparseable, git failed)
"""

from __future__ import annotations

import argparse
import fnmatch  # noqa: F401  — kept for back-compat / external imports
import importlib.util
import json
import os
import re
import subprocess
import sys
from typing import Any

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


def _load_external_baselines(path: str | None) -> dict[str, Any]:
    """Load the sidecar JSON; return an empty shell when absent or
    malformed so callers can stay shape-agnostic."""
    empty = {"external_paths": {}, "repos": {}, "warnings": []}
    if not path:
        return empty
    if not os.path.isfile(path):
        print(
            f"WARNING: --external-baselines file not found: {path} "
            f"(external paths in produces: will be treated as missing)",
            file=sys.stderr,
        )
        return empty
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        # ValueError covers json.JSONDecodeError AND UnicodeDecodeError —
        # a hand-edited / corrupted sidecar with non-UTF-8 bytes would
        # otherwise escape the catch and crash the validator with an
        # unhandled exception (rc=1 → "deliverables validation failed",
        # cause buried in the exec-log traceback).
        print(
            f"WARNING: could not read --external-baselines {path}: {exc} "
            f"(external paths in produces: will be treated as missing)",
            file=sys.stderr,
        )
        return empty
    if not isinstance(data, dict):
        return empty
    external_paths = data.get("external_paths")
    if not isinstance(external_paths, dict):
        external_paths = {}
    repos = data.get("repos")
    if not isinstance(repos, dict):
        repos = {}
    # Snapshot helper records per-decl classification failures here
    # (e.g. "could not resolve git toplevel for '../typo/foo'"). Without
    # surfacing these the user sees a downstream "not in session diff"
    # error with no clue why their cross-repo path wasn't classified.
    warnings_raw = data.get("warnings")
    if not isinstance(warnings_raw, list):
        warnings_raw = []
    warnings = [w for w in warnings_raw if isinstance(w, str)]
    return {"external_paths": external_paths, "repos": repos, "warnings": warnings}


def _read_external_diffs(
    repos: dict[str, Any],
) -> tuple[dict[str, list[str]], dict[str, list[str]], list[str]]:
    """For each external repo with a captured baseline HEAD, run
    `git diff baseline..HEAD` inside that repo. Returns
    (changed_by_repo, deleted_by_repo, errors)."""
    changed_by_repo: dict[str, list[str]] = {}
    deleted_by_repo: dict[str, list[str]] = {}
    errors: list[str] = []
    for repo_root, info in repos.items():
        if not isinstance(info, dict):
            continue
        baseline = info.get("head")
        if not isinstance(baseline, str) or not baseline:
            continue
        if not os.path.isdir(repo_root):
            errors.append(
                f"external repo no longer present at {repo_root!r} "
                f"(captured baseline {baseline[:12]})"
            )
            continue
        try:
            ch, de = _read_diff(repo_root, baseline)
        except RuntimeError as exc:
            errors.append(
                f"git diff failed for external repo {repo_root!r}: {exc}"
            )
            continue
        changed_by_repo[repo_root] = ch
        deleted_by_repo[repo_root] = de
    return changed_by_repo, deleted_by_repo, errors


def _print_diff_summary(
    label: str,
    changed: list[str],
    deleted: list[str],
    *,
    limit: int = 30,
    max_deleted: int = 5,
) -> None:
    print(f"{label}", file=sys.stderr)
    shown = 0
    for p in changed:
        if shown >= limit:
            break
        print(f"  + {p}", file=sys.stderr)
        shown += 1
    for p in deleted[:max_deleted]:
        print(f"  - {p} (deleted)", file=sys.stderr)
    remaining = len(changed) + len(deleted) - shown - min(len(deleted), max_deleted)
    if remaining > 0:
        print(f"  ... and {remaining} more", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        # Keep usage consistent with the historical positional invocation
        # so callers that pass exactly three args still work.
    )
    ap.add_argument("session_md")
    ap.add_argument("worktree")
    ap.add_argument("base_ref")
    ap.add_argument(
        "--external-baselines",
        default=None,
        help="JSON sidecar from epic-external-baselines.py snapshot",
    )

    try:
        args = ap.parse_args()
    except SystemExit as exc:
        # argparse calls sys.exit(2) on bad args — preserve that.
        return int(exc.code) if isinstance(exc.code, int) else 2

    session_md, worktree, base_ref = args.session_md, args.worktree, args.base_ref

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

    baselines = _load_external_baselines(args.external_baselines)
    external_paths: dict[str, Any] = baselines["external_paths"]
    repos: dict[str, Any] = baselines["repos"]
    snapshot_warnings: list[str] = baselines["warnings"]
    ext_changed, ext_deleted, ext_errors = _read_external_diffs(repos)
    for e in ext_errors:
        print(f"WARNING: {e}", file=sys.stderr)

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
        missing: list[tuple[str, str]] = []
        for decl in produces:
            ext = external_paths.get(decl)
            # Inner-shape guard: hand-edited or corrupt sidecar can have
            # `external_paths[decl]` set to a non-dict (string, list, null,
            # ...). Without this check `ext.get(...)` raises AttributeError
            # and the validator crashes on what should be a soft failure.
            # Same audit class as bug-178/179/180 — outer container shape
            # is guarded in _load_external_baselines but inner values were
            # trusted.
            if isinstance(ext, dict):
                repo_root = ext.get("repo_root")
                rel = ext.get("relative")
                # Inner-scalar shape rejection: bug-279 guarded the OUTER
                # ext-is-dict shape, but the inner scalars were trusted.
                # A corrupt sidecar where repo_root is unhashable (list/dict)
                # crashes `ext_changed.get(repo_root)` with TypeError; a
                # non-iterable rel (None, int) crashes `_matches_declared`
                # at `c in declared`. Both surface as an unhandled exception
                # (validator rc=1 → session falsely flagged rc=97 with the
                # traceback buried in the exec log). Same audit class as
                # bug-178/179/180/183/184.
                if not (isinstance(repo_root, str) and repo_root
                        and isinstance(rel, str) and rel):
                    missing.append((
                        decl,
                        "external_paths sidecar entry is malformed "
                        "(missing or non-string repo_root/relative); "
                        "delete the cached "
                        ".session-NN-external-baselines.json and retry",
                    ))
                    continue
                ch_for_repo = ext_changed.get(repo_root)
                if ch_for_repo is None:
                    # Snapshot listed it as external, but its diff is
                    # missing — repo gone, git failed, or invalid baseline.
                    missing.append((decl, "external repo could not be diffed"))
                    continue
                if not _matches_declared(rel, ch_for_repo):
                    missing.append((decl, f"not in {repo_root} diff"))
            else:
                # Either truly internal, or external-but-not-snapshotted
                # (older runner, snapshot helper failed, or sibling repo
                # didn't exist). Try the worktree diff; if it's clearly
                # outside the worktree, report which case we're in.
                if not _matches_declared(decl, changed):
                    looks_external = decl.startswith("../") or os.path.isabs(decl)
                    if looks_external and args.external_baselines is None:
                        missing.append((
                            decl,
                            "looks external but no --external-baselines was "
                            "provided to the validator",
                        ))
                    elif looks_external:
                        # Flag was passed, but this specific decl wasn't
                        # in the snapshot's external_paths. Snapshot
                        # helper warnings printed below explain why
                        # (sibling dir missing, not in a git repo, etc.).
                        missing.append((
                            decl,
                            "looks external but snapshot did not classify "
                            "it as external — see snapshot warnings below",
                        ))
                    else:
                        missing.append((decl, "not in session diff"))
        if missing:
            print(
                "ERROR: declared deliverables missing from session diff:",
                file=sys.stderr,
            )
            for decl, reason in missing:
                print(f"  - {decl}  ({reason})", file=sys.stderr)
            print("", file=sys.stderr)
            _print_diff_summary("Session diff vs baseline (epic worktree):",
                                changed, deleted)
            for repo_root, ch_for_repo in ext_changed.items():
                de_for_repo = ext_deleted.get(repo_root, [])
                short = repos.get(repo_root, {}).get("head_short", "")
                _print_diff_summary(
                    f"External diff in {repo_root} vs baseline {short}:",
                    ch_for_repo, de_for_repo,
                )
            if snapshot_warnings:
                print(
                    "\nSnapshot warnings (from session-start baseline capture):",
                    file=sys.stderr,
                )
                for w in snapshot_warnings:
                    print(f"  - {w}", file=sys.stderr)
            if args.external_baselines is None:
                print(
                    "\nHint: produces: entries that point outside the epic "
                    "repo (e.g. `../sibling-repo/...`) need the runner to "
                    "snapshot the sibling repo at session start. Make sure "
                    "the runner passed --external-baselines.",
                    file=sys.stderr,
                )
            return 1
        return 0

    # No produces: declared. Run the metadata-only heuristic, but only if
    # nothing real happened in any external repo either — otherwise a
    # session that legitimately committed only to a sibling repo would be
    # falsely rejected.
    any_external_advance = any(bool(v) for v in ext_changed.values())
    if any_external_advance:
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
            "Otherwise add a `produces:` list of expected output paths "
            "(cross-repo paths like `../sibling-repo/file` are supported "
            "when the runner snapshots external baselines).",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
