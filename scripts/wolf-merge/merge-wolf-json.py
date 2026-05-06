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


def _bug_signature(bug):
    # Semantic identity of a bug = (what failed, where, why). Timestamp is
    # intentionally NOT in the signature: two parallel sessions detecting
    # the same root cause within sub-second of each other produce different
    # ISO timestamps, and including it here would force the same-id branch
    # in merge_buglog to treat them as distinct events and renumber one
    # under a fresh id — duplicating the same bug across two log entries
    # despite this driver existing precisely to dedupe parallel detections.
    # (bug-098)
    return (
        bug.get("error_message", ""),
        bug.get("file", ""),
        bug.get("root_cause", ""),
    )


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


def merge_buglog(ours, theirs):
    """Union bugs[] by id; preserve both entries on a true id collision.

    Two parallel sessions can independently allocate the same next-free id
    because each hook reads its own local buglog.json before appending —
    neither sees the sibling's addition. When the colliding entries describe
    the SAME event (matching timestamp/file/error/cause), keep the one with
    the latest last_seen (true duplicate). When they describe DIFFERENT
    events that merely collided on id, the previous behavior silently
    dropped one; instead, re-id the second under the next free slot so both
    survive the merge. (bug-090)
    """
    if not (isinstance(ours, dict) and isinstance(theirs, dict)):
        return ours
    used_ids = {
        bug.get("id")
        for src in (ours, theirs)
        for bug in src.get("bugs", [])
        if bug.get("id")
    }
    by_id = {}
    extras = []
    for src in (ours, theirs):
        for bug in src.get("bugs", []):
            bid = bug.get("id")
            if not bid:
                # Same data-loss class as bug-090's id-collision case: a
                # bug entry without an id (malformed write, partially-flushed
                # entry from a SIGKILL'd hook, schema drift) was previously
                # dropped on the floor by `continue`. Allocate a fresh id
                # and route through extras so the entry survives. (bug-105)
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
                # True duplicate: keep the newer entry's metadata but
                # accumulate occurrences from both sides. The previous
                # implementation replaced existing wholesale on a newer
                # last_seen, silently discarding the older entry's
                # occurrence count — and after bug-098's signature
                # tightening, parallel detections that previously
                # renumbered now correctly land here, so this branch is
                # the one that has to preserve the count. (bug-098)
                summed = (existing.get("occurrences", 1) or 1) + (
                    bug.get("occurrences", 1) or 1
                )
                if bug.get("last_seen", "") > existing.get("last_seen", ""):
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
