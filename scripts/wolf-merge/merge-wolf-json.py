#!/usr/bin/env python3
"""Git custom merge driver for OpenWolf JSON metadata files.

Invoked by git as: merge-wolf-json.py <ancestor> <ours> <theirs> <pathname>
Writes merged result to <ours> path. Exits 0 on success, 1 on unresolvable.

Per-file strategies:
  .wolf/buglog.json         -> union bugs[] by id (latest last_seen wins)
  .wolf/token-ledger.json   -> keep ours (local accumulation is authoritative)
  .wolf/hooks/_session.json -> keep ours (current session state)
  default                   -> keep ours
"""
import json
import sys
from pathlib import Path


def load(path: str):
    # Force UTF-8: bare read_text() falls back to locale.getpreferredencoding(False),
    # which is cp1252 on Windows / ASCII under LC_ALL=C. buglog.json entries
    # routinely contain em-dashes, smart quotes, and accented chars in error
    # messages and file paths — without explicit encoding the merge driver
    # crashes mid-merge (UnicodeDecodeError) and git records the file as
    # unresolvable. Same class as bug-035; cerebrum flagged this as
    # "audit every open( site, not just the ones in the file you're editing".
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        return None


def write(path: str, data) -> None:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def merge_buglog(ours, theirs):
    """Union bugs[] dedup'd by id; keep entry with latest last_seen."""
    if not (isinstance(ours, dict) and isinstance(theirs, dict)):
        return ours
    by_id = {}
    for src in (ours, theirs):
        for bug in src.get("bugs", []):
            bid = bug.get("id")
            if not bid:
                continue
            existing = by_id.get(bid)
            if existing is None or bug.get("last_seen", "") > existing.get("last_seen", ""):
                by_id[bid] = bug
    merged = dict(ours)
    merged["bugs"] = sorted(by_id.values(), key=lambda b: b.get("id", ""))
    return merged


def main() -> int:
    if len(sys.argv) < 5:
        return 1
    _ancestor, ours_path, theirs_path, pathname = sys.argv[1:5]
    ours = load(ours_path)
    theirs = load(theirs_path)

    if ours is None and theirs is None:
        return 1
    if ours is None:
        write(ours_path, theirs)
        return 0
    if theirs is None:
        return 0  # ours is already in place

    name = Path(pathname).name
    if name == "buglog.json":
        result = merge_buglog(ours, theirs)
    else:
        result = ours  # token-ledger, _session, others -> keep ours

    write(ours_path, result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
