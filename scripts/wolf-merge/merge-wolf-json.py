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
    # encoding="utf-8" — locale fallback breaks on em-dashes/CJK in bug entries. (bug-035)
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        return None


def write(path: str, data) -> None:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _bug_signature(bug):
    # No timestamp — parallel sessions detecting the same root cause
    # within sub-second produce different ISO times, defeating dedup. (bug-098)
    return (
        bug.get("error_message", ""),
        bug.get("file", ""),
        bug.get("root_cause", ""),
    )


def _bug_id(bug) -> str:
    """Bug id as string, '' for missing/unhashable. Funnels bad ids
    through the same fresh-id rescue path as missing ones."""
    bid = bug.get("id")
    return bid if isinstance(bid, str) and bid else ""


def _last_seen(bug) -> str:
    """last_seen as string, '' for missing/non-str — `None > str` would
    crash the duplicate-merge branch. (bug-183)"""
    val = bug.get("last_seen", "")
    return val if isinstance(val, str) else ""


def _occurrences(bug) -> int:
    """occurrences as int >=1, default 1. Reject bool (subclass of int)
    and non-int — would crash arithmetic in the duplicate branch. (bug-184)"""
    val = bug.get("occurrences", 1)
    if isinstance(val, bool) or not isinstance(val, int):
        return 1
    return val if val >= 1 else 1


def _next_free_bug_id(used_ids):
    max_n = 0
    for bid in used_ids:
        try:
            n = int(str(bid).rsplit("-", 1)[-1])
        except (ValueError, IndexError):
            continue
        if n > max_n:
            max_n = n
    return f"bug-{max_n + 1:03d}"


def merge_buglog(ours, theirs, ancestor=None):
    """Union bugs[] by id. True duplicates (matching signature) merge
    occurrence counts via ours+theirs-ancestor; id collisions on
    different events get renumbered. (bug-090, bug-137)
    """
    if not isinstance(ours, dict) or not isinstance(theirs, dict):
        return ours
    # Reject non-list `bugs` and skip non-dict items — null/dict/str/int
    # shapes would all crash the iteration. (bugs 148, 182)
    def _bugs_of(src) -> list:
        if not isinstance(src, dict):
            return []
        bugs = src.get("bugs")
        if not isinstance(bugs, list):
            return []
        return [b for b in bugs if isinstance(b, dict)]
    ancestor_occ: dict[str, int] = {}
    if isinstance(ancestor, dict):
        for bug in _bugs_of(ancestor):
            bid = _bug_id(bug)
            if bid:
                ancestor_occ[bid] = _occurrences(bug)
    else:
        # Ancestor unreadable / brand-new file — fall back to
        # min(ours, theirs) per id so we don't double-count. (bug-154)
        ours_by_id = {_bug_id(b): b for b in _bugs_of(ours) if _bug_id(b)}
        theirs_by_id = {_bug_id(b): b for b in _bugs_of(theirs) if _bug_id(b)}
        for bid in ours_by_id.keys() & theirs_by_id.keys():
            ours_occ = _occurrences(ours_by_id[bid])
            theirs_occ = _occurrences(theirs_by_id[bid])
            ancestor_occ[bid] = min(ours_occ, theirs_occ)
    used_ids = {
        _bug_id(bug)
        for src in (ours, theirs)
        for bug in _bugs_of(src)
        if _bug_id(bug)
    }
    by_id = {}
    extras = []
    for src in (ours, theirs):
        for bug in _bugs_of(src):
            bid = _bug_id(bug)
            if not bid:
                # Allocate fresh id so missing/malformed-id entries
                # survive the merge instead of being dropped. (bug-105)
                new_bid = _next_free_bug_id(used_ids)
                used_ids.add(new_bid)
                renumbered = dict(bug)
                renumbered["id"] = new_bid
                extras.append(renumbered)
                continue
            existing = by_id.get(bid)
            if existing is None:
                by_id[bid] = bug
                continue
            if _bug_signature(bug) == _bug_signature(existing):
                # True duplicate — accumulate counts; bug-137's
                # `ours+theirs-ancestor` formula avoids double-counting.
                ours_occ = _occurrences(existing)
                theirs_occ = _occurrences(bug)
                base_occ = ancestor_occ.get(bid, 0)
                summed = max(1, ours_occ + theirs_occ - base_occ)
                if _last_seen(bug) > _last_seen(existing):
                    winner = dict(bug)
                else:
                    winner = dict(existing)
                winner["occurrences"] = summed
                by_id[bid] = winner
                continue
            new_bid = _next_free_bug_id(used_ids)
            used_ids.add(new_bid)
            renumbered = dict(bug)
            renumbered["id"] = new_bid
            extras.append(renumbered)
    merged = dict(ours)
    merged["bugs"] = sorted(
        list(by_id.values()) + extras,
        key=lambda b: b.get("id", ""),
    )
    return merged


def main() -> int:
    if len(sys.argv) < 5:
        return 1
    ancestor_path, ours_path, theirs_path, pathname = sys.argv[1:5]
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
        ancestor = load(ancestor_path)
        result = merge_buglog(ours, theirs, ancestor)
    else:
        result = ours  # token-ledger, _session, others -> keep ours

    write(ours_path, result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
