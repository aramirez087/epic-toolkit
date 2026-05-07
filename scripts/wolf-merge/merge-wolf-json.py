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


def _bug_id(bug) -> str:
    """Return the bug's id as a string, or '' for missing/non-string ids.

    Centralises the "is this id usable as a dict key / set member" check so
    the merge loop never tries to index `by_id[unhashable]` or compute a
    set membership against a list/dict id. Returning '' funnels malformed
    ids through the same extras-renumbering path as missing ids — the entry
    survives the merge with a fresh id rather than crashing the driver.
    """
    bid = bug.get("id")
    return bid if isinstance(bid, str) and bid else ""


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
    """Union bugs[] by id; preserve both entries on a true id collision.

    Two parallel sessions can independently allocate the same next-free id
    because each hook reads its own local buglog.json before appending —
    neither sees the sibling's addition. When the colliding entries describe
    the SAME event (matching timestamp/file/error/cause), keep the one with
    the latest last_seen (true duplicate). When they describe DIFFERENT
    events that merely collided on id, the previous behavior silently
    dropped one; instead, re-id the second under the next free slot so both
    survive the merge. (bug-090)

    ancestor is used to compute occurrence deltas: both ours and theirs
    already include the common ancestor count, so naively summing them
    double-counts the shared baseline. The correct formula is
    ours + theirs - ancestor_count. (bug-137)
    """
    if not (isinstance(ours, dict) and isinstance(theirs, dict)):
        return ours
    # `dict.get(key, default)` only returns the default when the key is ABSENT.
    # If a buglog has `"bugs": null` (a partially-flushed write, a hand-edit, a
    # schema-drift artefact) the call returns None, and `for bug in None` raises
    # TypeError mid-merge — load() only catches JSONDecodeError/OSError/
    # UnicodeDecodeError, so the semantic-shape failure propagates out, the
    # driver exits 1, and git records the file as unresolvable. Same audit
    # class as bug-035's "audit every open() site" — extended here to "audit
    # every .get(key, default) site that consumes an iterable". (bug-148)
    #
    # The bug-148 fix used `or []` which catches null + missing key but does
    # NOT reject truthy non-list shapes the producer can emit:
    #   • `"bugs": {"a": 1}` (dict) — `or []` returns the dict; `for bug in
    #     <dict>` iterates KEYS (strings), then `bug.get("id")` raises
    #     `AttributeError: 'str' object has no attribute 'get'`.
    #   • `"bugs": "malformed"` (str) — same path: iterates CHARACTERS,
    #     same AttributeError on `bug.get`.
    #   • `"bugs": 5` (int) — `for bug in 5` raises `TypeError: 'int' object
    #     is not iterable`.
    #   • `"bugs": [42, "oops"]` (list with non-dict items) — iteration is
    #     fine, but `42.get("id")` / `"oops".get("id")` raises AttributeError
    #     on the first non-dict item.
    #   • `"bugs": [{"id": ["list-id"], ...}]` (dict bug with unhashable id)
    #     — passes the dict-item filter, but `used_ids = {bug.get("id") ...}`
    #     tries to add a list to a set, raising
    #     `TypeError: unhashable type: 'list'`. Same chain at `by_id[bid]`
    #     (dict subscript with unhashable key) and the final `sorted(...,
    #     key=lambda b: b.get("id", ""))` (TypeError comparing list and str
    #     in Python 3).
    # All six crash chains end the same way: driver exits 1, git records the
    # file as unresolvable, the user sees a `.wolf/buglog.json` merge conflict
    # the auto-merge driver was supposed to silently handle. Same audit class
    # as bug-148/154/167/175/176 — every consumer of `.get(key, default)` must
    # reject inputs the parser/producer can emit but the consumer can't
    # interpret. Reject non-list `bugs` and skip non-dict items so the merge
    # treats the malformed side as if it had no bugs (conservative fallback —
    # the data on the other side still merges in cleanly). Pair with `_bug_id`
    # to coerce non-string ids to '' so they route through the same fresh-id
    # rescue path as missing ids (bug-105) instead of crashing the driver.
    # (bug-182)
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
                ancestor_occ[bid] = bug.get("occurrences", 1) or 1
    else:
        # Ancestor was None — load() returns None on JSONDecodeError /
        # OSError / UnicodeDecodeError, and git also passes /dev/null
        # for %O when the file is brand-new in both branches. Without a
        # fallback, ancestor_occ stays empty and bug-137's
        # `ours + theirs - base_occ` formula uses base=0, silently
        # double-counting every true-duplicate bug whose ancestor file
        # we couldn't read. The over-count surfaces invisibly in
        # buglog.json (occurrences=20 instead of 10) and corrupts the
        # signal that drives Do-Not-Repeat triage. Conservative
        # baseline: for any id present on BOTH sides, assume
        # ancestor_occ = min(ours_occ, theirs_occ). The invariant
        # `ancestor_occ <= min(ours_occ, theirs_occ)` always holds
        # because occurrences only grow from the shared baseline, so
        # this never over-counts; it may under-count when one branch
        # added more than the other (acceptable trade-off when the
        # ancestor is genuinely unreadable). Same audit class as
        # bug-148. (bug-154)
        ours_by_id = {_bug_id(b): b for b in _bugs_of(ours) if _bug_id(b)}
        theirs_by_id = {_bug_id(b): b for b in _bugs_of(theirs) if _bug_id(b)}
        for bid in ours_by_id.keys() & theirs_by_id.keys():
            ours_occ = ours_by_id[bid].get("occurrences", 1) or 1
            theirs_occ = theirs_by_id[bid].get("occurrences", 1) or 1
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
                ours_occ = existing.get("occurrences", 1) or 1
                theirs_occ = bug.get("occurrences", 1) or 1
                base_occ = ancestor_occ.get(bid, 0)
                summed = max(1, ours_occ + theirs_occ - base_occ)
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
