#!/usr/bin/env python3
"""epic-external-baselines.py

Capture HEAD shas of every external git repo referenced by a session's
`produces:` / `touches:` frontmatter, so the runner's no-op guard and the
deliverables validator can both reason about cross-repo work.

The runner anchors path resolution at `--orig-repo-root` (the user's original
working repo, *not* the per-session worktree). A path is "external" iff its
resolved absolute location lives outside `orig_repo_root`. For each external
path the helper finds the enclosing git toplevel via `git rev-parse
--show-toplevel`, captures HEAD, and writes a JSON sidecar.

Subcommands:

  snapshot   --session-md <path> --orig-repo-root <abs> --output <json>
             Read frontmatter, classify produces/touches paths, capture
             HEAD of each unique external git repo. Always writes JSON
             (empty `repos: {}` when nothing is external) so downstream
             callers can rely on the file existing.

  advanced   --baselines <json>
             Print "yes" if any external repo's HEAD has moved since the
             snapshot was taken, "no" otherwise. Used by the no-op guard.

JSON shape:

    {
      "session_md": "<abs path>",
      "orig_repo_root": "<abs path>",
      "captured_at": "<ISO-8601 UTC>",
      "external_paths": {
          "<original declared string>": {
              "repo_root": "<abs path>",
              "relative":  "<path inside that repo, posix-style>"
          }
      },
      "repos": {
          "<repo_root_abs>": { "head": "<sha>", "head_short": "<sha[:12]>" }
      },
      "warnings": [<strings>]
    }

Glob support: only `*` and `?` are wildcards (matches the validator's
matcher, which treats `[`/`]` as literal so Next.js-style `[id]` segments
survive). The literal prefix is used to find the enclosing repo.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import subprocess
import sys
from typing import Any


def _load_dag_module():
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(here, "epic-dag.py")
    spec = importlib.util.spec_from_file_location("epic_dag", src)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not build module spec for {src}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _normalise_path_string(p: str) -> str:
    # YAML is authored with POSIX separators; Windows-authored files may use
    # backslashes. Treat both as `/` for splitting/joining; let os.path
    # collapse them on this OS at resolve time.
    return p.replace("\\", "/")


def literal_anchor_dir(path: str) -> str:
    """Return the deepest literal directory of a path-or-glob.

    Only `*` and `?` are wildcards (mirror the validator). The portion
    *before* the first wildcard is literal; we walk back to the last `/` to
    get a directory we can hand to `git rev-parse --show-toplevel`. Returns
    the empty string if no separator is found before the first wildcard.
    """
    s = _normalise_path_string(path)
    cut = len(s)
    for ch in ("*", "?"):
        i = s.find(ch)
        if 0 <= i < cut:
            cut = i
    literal = s[:cut]
    if not literal:
        return ""
    last = literal.rfind("/")
    if last < 0:
        # No separator → the literal portion is itself a single segment;
        # anchor at the parent (cwd-ish). Caller will treat as "no anchor".
        return ""
    return literal[:last]


def _safe_realpath(p: str) -> str:
    try:
        return os.path.realpath(p)
    except OSError:
        return os.path.abspath(p)


def _is_inside(child: str, parent: str) -> bool:
    """True iff child == parent or child is strictly inside parent.
    Both arguments must be absolute, normalised paths."""
    try:
        common = os.path.commonpath([child, parent])
    except ValueError:
        # Different drives on Windows — definitely not inside.
        return False
    return common == parent


def classify(decl: str, orig_repo_root_abs: str) -> dict[str, Any]:
    """Classify a single declared path string.

    Returns a dict with keys:
        kind: "internal" | "external"
        anchor_abs: absolute directory used to discover the enclosing repo
                    (only meaningful for kind=="external")
        full_abs:   absolute path/glob for the declaration
                    (used to compute repo-relative form once we know the
                    repo root). For globs this is the resolved form of the
                    raw declaration, NOT just the literal prefix.

    cmd_snapshot handles the "external but no enclosing git repo" case
    via git_toplevel returning None and recording a warning — classify
    itself never produces an "unresolvable" kind.
    """
    s = _normalise_path_string(decl)
    if os.path.isabs(decl) or os.path.isabs(s):
        full_abs = os.path.normpath(s)
        anchor = literal_anchor_dir(s)
        anchor_abs = os.path.normpath(anchor) if anchor else os.path.dirname(full_abs)
    else:
        full_abs = os.path.normpath(os.path.join(orig_repo_root_abs, s))
        anchor = literal_anchor_dir(s)
        if anchor:
            anchor_abs = os.path.normpath(os.path.join(orig_repo_root_abs, anchor))
        else:
            anchor_abs = os.path.dirname(full_abs) or orig_repo_root_abs

    # Realpath the anchor (for symlink-resolved comparison) but keep
    # full_abs un-realpathed so we don't follow symlinks across repo
    # boundaries when the actual file doesn't exist yet.
    anchor_real = _safe_realpath(anchor_abs)
    if _is_inside(anchor_real, orig_repo_root_abs):
        return {"kind": "internal", "anchor_abs": anchor_abs, "full_abs": full_abs}
    return {"kind": "external", "anchor_abs": anchor_real, "full_abs": full_abs}


def _walk_to_existing_dir(start: str) -> str:
    """Walk upward until we find an existing directory. Returns "" if we
    walk past the filesystem root (shouldn't happen in practice)."""
    cur = start
    while cur and not os.path.isdir(cur):
        parent = os.path.dirname(cur)
        if parent == cur:
            return ""
        cur = parent
    return cur


def git_toplevel(start_dir: str) -> str | None:
    """Return the absolute path of the git toplevel containing start_dir,
    or None if start_dir is not inside any git repo (or git failed)."""
    if not start_dir:
        return None
    existing = _walk_to_existing_dir(start_dir)
    if not existing:
        return None
    proc = subprocess.run(
        ["git", "-C", existing, "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if proc.returncode != 0:
        return None
    top = proc.stdout.strip()
    if not top:
        return None
    return _safe_realpath(top)


def git_head(repo_root: str) -> str | None:
    proc = subprocess.run(
        ["git", "-C", repo_root, "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if proc.returncode != 0:
        return None
    sha = proc.stdout.strip()
    return sha or None


def relative_to_repo(decl: str, orig_repo_root_abs: str, repo_root_abs: str) -> str:
    """Translate a declared path into a path relative to repo_root, in
    POSIX form (since the validator's matcher splits on `/`).

    Both the declared path and repo_root_abs need to live in the same
    symlink-resolved namespace before we relpath them — otherwise a system
    where /var → /private/var (macOS) makes an absolute decl resolve to
    `/var/...` while git_toplevel returns `/private/var/...`, and relpath
    walks back up through the filesystem looking for a common prefix that
    doesn't exist syntactically. (caught by edge-case tests)"""
    s = _normalise_path_string(decl)
    if os.path.isabs(decl) or os.path.isabs(s):
        abs_full = os.path.normpath(s)
    else:
        abs_full = os.path.normpath(os.path.join(orig_repo_root_abs, s))
    abs_full_real = _safe_realpath(abs_full)
    rel = os.path.relpath(abs_full_real, repo_root_abs)
    return rel.replace(os.sep, "/")


def _gather_declared_paths(fm: dict[str, Any]) -> list[str]:
    """Pull strings out of `produces:` and `touches:` (in that order),
    de-duplicating preserving first-seen ordering. Non-string entries and
    non-list shapes are silently ignored — the validator and DAG loader
    own type-checking and we don't want to double-fail here."""
    out: list[str] = []
    seen: set[str] = set()
    for key in ("produces", "touches"):
        v = fm.get(key, [])
        if not isinstance(v, list):
            continue
        for entry in v:
            if not isinstance(entry, str):
                continue
            s = entry.strip()
            if s and s not in seen:
                seen.add(s)
                out.append(s)
    return out


def _atomic_write_json(path: str, payload: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def cmd_snapshot(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.session_md):
        print(f"ERROR: session file not found: {args.session_md}", file=sys.stderr)
        return 2
    orig = _safe_realpath(args.orig_repo_root)
    if not os.path.isdir(orig):
        print(f"ERROR: --orig-repo-root is not a directory: {args.orig_repo_root}", file=sys.stderr)
        return 2

    try:
        dag = _load_dag_module()
    except Exception as exc:
        print(f"ERROR: could not load epic-dag.py: {exc}", file=sys.stderr)
        return 2

    try:
        with open(args.session_md, encoding="utf-8-sig") as f:
            text = f.read()
    except OSError as exc:
        print(f"ERROR: could not read {args.session_md}: {exc}", file=sys.stderr)
        return 2

    try:
        fm, _ = dag.parse_frontmatter(text)
    except Exception as exc:
        # Frontmatter parse failures are not fatal here — the DAG loader
        # will surface them with a better error. Fall through with an empty
        # frontmatter so the JSON file still gets written.
        print(f"WARNING: frontmatter parse failed for {args.session_md}: {exc}", file=sys.stderr)
        fm = {}

    declared = _gather_declared_paths(fm if isinstance(fm, dict) else {})

    external_paths: dict[str, dict[str, str]] = {}
    repos: dict[str, dict[str, str]] = {}
    warnings: list[str] = []

    for decl in declared:
        c = classify(decl, orig)
        if c["kind"] != "external":
            continue
        top = git_toplevel(c["anchor_abs"])
        if not top:
            warnings.append(
                f"could not resolve git toplevel for {decl!r} "
                f"(anchor: {c['anchor_abs']}). External path will fail "
                f"deliverables validation unless the directory exists "
                f"inside a git repo."
            )
            continue
        head = git_head(top)
        if not head:
            warnings.append(
                f"could not read HEAD for repo {top!r} (referenced by {decl!r})"
            )
            continue
        repos.setdefault(top, {"head": head, "head_short": head[:12]})
        rel = relative_to_repo(decl, orig, top)
        external_paths[decl] = {"repo_root": top, "relative": rel}

    payload = {
        "session_md": os.path.abspath(args.session_md),
        "orig_repo_root": orig,
        "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "external_paths": external_paths,
        "repos": repos,
        "warnings": warnings,
    }

    try:
        _atomic_write_json(args.output, payload)
    except OSError as exc:
        print(f"ERROR: could not write baselines to {args.output}: {exc}", file=sys.stderr)
        return 2

    if args.warn and warnings:
        for w in warnings:
            print(f"WARNING: {w}", file=sys.stderr)
    return 0


def cmd_advanced(args: argparse.Namespace) -> int:
    """Emit "yes"/"no" depending on whether any external repo's HEAD has
    moved since baseline capture. Anything that prevents the comparison
    (missing file, missing repo, git failure) prints "no" — that keeps
    the no-op guard's behavior as conservative as the single-repo path:
    if we can't prove the session did external work, we don't claim it."""
    if not os.path.isfile(args.baselines):
        print("no")
        return 0
    try:
        with open(args.baselines, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        print("no")
        return 0
    repos = data.get("repos") if isinstance(data, dict) else None
    if not isinstance(repos, dict) or not repos:
        print("no")
        return 0
    for repo_root, info in repos.items():
        if not isinstance(info, dict):
            continue
        baseline = info.get("head")
        if not isinstance(baseline, str) or not baseline:
            continue
        if not os.path.isdir(repo_root):
            continue
        current = git_head(repo_root)
        if current and current != baseline:
            print("yes")
            return 0
    print("no")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    sn = sub.add_parser("snapshot", help="Capture external-repo baselines")
    sn.add_argument("--session-md", required=True)
    sn.add_argument("--orig-repo-root", required=True)
    sn.add_argument("--output", required=True)
    sn.add_argument("--warn", action="store_true",
                    help="Print warnings to stderr (otherwise silent)")
    sn.set_defaults(func=cmd_snapshot)

    ad = sub.add_parser("advanced",
                        help="Print yes/no for any external repo HEAD movement")
    ad.add_argument("--baselines", required=True)
    ad.set_defaults(func=cmd_advanced)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
