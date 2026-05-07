#!/usr/bin/env python3
"""
epic-dag.py — Parse epic session files, build a DAG, compute parallel waves.

Each session-NN-*.md may declare YAML frontmatter:

    ---
    session: 03
    title: "Auth API"
    depends_on: [01]
    touches:
      - src/api/auth/**
      - supabase/migrations/*auth*
    parallel_safe: true
    ---

    # Session 03: Auth API
    ...

Sessions without frontmatter implicitly depend on session N-1 (linear chain),
preserving back-compat with pre-DAG epics.

Session 00 is the operator-rules file; it is excluded from the DAG and
prepended to every prompt at runtime.

Output formats:
  --bash    line-oriented, parsed by run-sessions.sh (default for the runner)
  --json    structured plan
  --show    human-readable ASCII rendering
  --validate  exit 0 if schedule is valid, else non-zero

Exit codes:
  0  success
  1  hard error (cycle, missing dep, malformed file)
  2  --strict and a touches-glob overlap was detected within a wave
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from typing import Any

SESSION_RE = re.compile(r"^session-(\d+)-(.+)\.md$")


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """Minimal YAML-frontmatter parser. Stdlib only."""
    # Normalise line endings before any anchored search. CRLF-encoded files
    # (Windows checkouts, or anything committed without core.autocrlf) used
    # to silently fail the `\n---\n` look-ups and return {} — every session
    # then collapsed to the implicit linear-chain fallback, killing the
    # user's parallel DAG with no error.
    if "\r" in text:
        text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        end = text.find("\n---", 4)
        if end == -1:
            return {}, text
        body_start = end + 4
    else:
        body_start = end + 5
    fm_text = text[4:end]
    body = text[body_start:]

    def _strip_inline_comment(line: str) -> str:
        """Remove YAML inline comments ( # ...) while preserving # inside quoted values.

        A quote character only opens a string when it sits at the FIRST non-space
        position of a value (right after `:` or `- `). Mid-token quotes — most
        commonly an apostrophe in an unquoted scalar like `title: It's a test` —
        are treated as ordinary characters, so a trailing `# comment` is still
        stripped instead of being preserved as part of the value. (bug-117)
        """
        stripped = line.lstrip()
        leading_ws = len(line) - len(stripped)

        value_start = -1
        # Accept both `- ` (dash-space) AND `-\t` (dash-tab) as block-list-item
        # value starts. The block-list parser at the bottom of parse_frontmatter
        # has accepted `-\t` since bug-127, but the comment-stripper still only
        # matched ASCII-space, so a `\t-\t"x # y"` row fell through to scalar
        # mode, in_quote never opened on the following `"`, and the
        # `#`-stripper truncated the value at the first `#`. Symmetric to
        # bug-126 in the block-list-item branch. (bug-135)
        if len(stripped) >= 2 and stripped[0] == "-" and stripped[1] in (" ", "\t"):
            value_start = leading_ws + 2
        elif ":" in stripped:
            value_start = line.find(":") + 1

        # Skip BOTH spaces and tabs between the `:`/`- ` separator and the
        # opening quote of a value. ASCII-space-only previously left
        # `key:\t"hello # world"` parsed as `hello` — the tab kept value_start
        # pointing one byte before the `"`, in_quote never opened, and the
        # `#`-stripper (which DOES accept tab as a separator since bug-124)
        # then truncated the value at the first `#` inside the string.
        # Symmetric to bug-124. (bug-126)
        while 0 <= value_start < len(line) and line[value_start] in (" ", "\t"):
            value_start += 1

        in_quote: str | None = None
        flow_depth = 0  # nested `[`/`{` levels; quotes inside open mid-line
        scan_start = max(value_start, 1)
        if 0 <= value_start < len(line):
            c0 = line[value_start]
            if c0 in ('"', "'"):
                in_quote = c0
                scan_start = value_start + 1
            elif c0 in ("[", "{"):
                # Flow-list / flow-map context. Quotes inside `[...]` open
                # mid-line, not at value_start, so the value-start quote test
                # above never fires for flow contents. Without explicit flow
                # tracking, every `"` inside the brackets was walked past as a
                # scalar character and the first ` #` inside any quoted entry
                # truncated the line — corrupting the value before the
                # (quote-aware since bug-132) `_split_flow_list` ever saw it.
                # `tags: ["a # b", c]` parsed as the string `["a` instead of
                # the 2-element list, and load_sessions then surfaced the
                # misleading error 'touches must be a list of globs' against
                # syntactically valid YAML. (bug-134)
                flow_depth = 1
                scan_start = value_start + 1

        i = scan_start
        while i < len(line):
            ch = line[i]
            if in_quote is not None:
                if ch == in_quote:
                    if in_quote == "'":
                        # YAML 1.2 §7.3.2: backslash is LITERAL inside single-
                        # quoted strings; the only escape is `''` (two
                        # apostrophes) for a literal apostrophe. Reusing the
                        # bug-123 backslash-parity rule for single quotes
                        # silently kept any value that legitimately ended in
                        # `\` (Windows-ish paths, regex literals) open and
                        # leaked the trailing `# comment` into the value.
                        # Detect `''` and skip both characters; otherwise
                        # close unconditionally. (bug-136)
                        if i + 1 < len(line) and line[i + 1] == "'":
                            i += 2
                            continue
                        in_quote = None
                    else:
                        # Double-quoted: backslash escapes apply. Count the
                        # run of consecutive `\` immediately before i. Even
                        # count (incl. zero) means the quote is the actual
                        # terminator; odd count means the quote is escaped.
                        # Preserves the bug-123 fix for `\\"` endings. Same
                        # class as bug-117 in the apostrophe branch. (bug-123)
                        bs = 0
                        j = i - 1
                        while j >= 0 and line[j] == "\\":
                            bs += 1
                            j -= 1
                        if bs % 2 == 0:
                            in_quote = None
                i += 1
                continue
            if flow_depth > 0:
                if ch in ('"', "'"):
                    in_quote = ch
                elif ch in ("[", "{"):
                    flow_depth += 1
                elif ch in ("]", "}"):
                    flow_depth -= 1
                i += 1
                continue
            if ch == "#" and line[i - 1] in (" ", "\t"):
                # YAML 1.2 §6.6 requires whitespace before `#`. The previous
                # check only matched ASCII space, so a tab-separated comment
                # (`key: value\t# note`) silently leaked the comment text into
                # the value — same defect class as bug-117/bug-123 in the
                # apostrophe and double-quote branches. Tab is the only other
                # in-line whitespace YAML allows; keep the set explicit so a
                # newline (impossible here, splitlines() already split on it)
                # or stray Unicode whitespace can't be misinterpreted as a
                # separator. (bug-124)
                return line[:i].rstrip()
            i += 1
        return line

    def _split_flow_list(s: str) -> list[str]:
        """Split a `[...]` flow-list body on `,`, respecting quoted spans.

        A blind `s.split(",")` (the previous implementation) splits inside a
        legitimate quoted item — `["a, b", c]` produced `['a', 'b', 'c']`
        instead of `['a, b', 'c']`. For a session's `touches:` / `produces:`
        list this corrupts any path or glob containing a literal comma, and
        the validator (validate-session-deliverables.py) then false-flags the
        session because the entries it's matching against were silently
        rebuilt under different keys. Same defect class as the quote-aware
        audits already applied to `_strip_inline_comment` (bug-117 apostrophe,
        bug-123 escaped backslash, bug-124 tab-before-`#`, bug-126
        tab-after-`:`); this is the remaining unaudited site. (bug-132)
        """
        items: list[str] = []
        buf = ""
        in_q: str | None = None
        i = 0
        n = len(s)
        while i < n:
            ch = s[i]
            if in_q is not None:
                buf += ch
                if ch == in_q:
                    if in_q == "'":
                        # YAML 1.2 single-quoted: backslash is literal; the
                        # only escape is `''`. Mirror the bug-136 fix in
                        # `_strip_inline_comment` so a single-quoted entry
                        # ending in `\` (e.g. a Windows-ish path) closes
                        # correctly here too. Without this the bug-132
                        # backslash-parity check kept the entry "open",
                        # absorbed the comma into the buffer, and merged
                        # what should have been two list items into one.
                        if i + 1 < n and s[i + 1] == "'":
                            buf += "'"
                            i += 2
                            continue
                        in_q = None
                    else:
                        bs = 0
                        j = i - 1
                        while j >= 0 and s[j] == "\\":
                            bs += 1
                            j -= 1
                        if bs % 2 == 0:
                            in_q = None
                i += 1
                continue
            if ch in ('"', "'"):
                in_q = ch
                buf += ch
            elif ch == ",":
                cleaned = buf.strip().strip("'\"")
                if cleaned:
                    items.append(cleaned)
                buf = ""
            else:
                buf += ch
            i += 1
        cleaned = buf.strip().strip("'\"")
        if cleaned:
            items.append(cleaned)
        return items

    result: dict[str, Any] = {}
    current_key: str | None = None
    for raw in fm_text.splitlines():
        raw = _strip_inline_comment(raw)
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        # Recognise a block-list item at any indent (any mix of spaces and
        # tabs), and accept either `- value`, `-\tvalue`, or a bare `-` row.
        # The previous prefix whitelist `("  - ", "- ", "    - ")` only
        # covered 0/2/4-space indents, so a perfectly normal 3-space or
        # tab-indented `produces:` list silently dropped every item, leaving
        # `result['produces'] = []`. Downstream that took
        # validate-session-deliverables.py through the metadata-only fallback
        # and rubber-stamped sessions whose `produces:` declaration was being
        # ignored. (bug-127)
        lstripped = raw.lstrip(" \t")
        if lstripped == "-" or lstripped.startswith(("- ", "-\t")):
            item = lstripped[1:].strip().strip("'\"")
            if current_key is not None:
                result.setdefault(current_key, []).append(item)
            continue
        if ":" not in raw:
            continue
        k, _, v = raw.partition(":")
        k = k.strip()
        v = v.strip()
        current_key = None
        if not v:
            current_key = k
            result[k] = []
        elif v.startswith("[") and v.endswith("]"):
            inner = v[1:-1].strip()
            result[k] = _split_flow_list(inner) if inner else []
        elif v.lower() in ("true", "false", "yes", "no", "on", "off", "y", "n"):
            # YAML 1.1 boolean spellings (yes/no/on/off + y/n shorthand)
            # join true/false in the parser whitelist. Without this, a
            # frontmatter line like `parallel_safe: no` falls through to
            # the string branch and load_sessions's `bool(...)` coerces
            # the non-empty string to True — silently inverting the user's
            # explicit "do not run me in parallel" intent. (bug-097)
            result[k] = v.lower() in ("true", "yes", "on", "y")
        elif (v.startswith("-") and v[1:].isdigit()) or v.isdigit():
            # Accept at most one leading sign. The previous test
            # `v.lstrip('-').isdigit()` strips ALL leading dashes, so values
            # like `--3` or `---5` pass the predicate and then crash int() with
            # an unhandled ValueError, which propagates out through main() and
            # surfaces in run-sessions.sh as a bare 'DAG validation failed'
            # with the actual cause hidden in stderr. (bug-114)
            result[k] = int(v)
        else:
            result[k] = v.strip("'\"")
    return result, body


def load_sessions(sessions_dir: str) -> tuple[list[dict[str, Any]], str | None]:
    sessions: list[dict[str, Any]] = []
    operator: str | None = None
    # Track every session id we've already accepted so two files claiming the
    # same NN are rejected before they can ever reach build_dag/compute_waves.
    # Without this, sorted(...) by id leaves both files in `sessions`, the
    # implicit-dep chain at the bottom of this function makes the second one
    # `depends_on=[N]` (i.e. on itself, since the prior list element shares
    # the same id) and build_dag prints the misleading error
    # "session NN cannot depend on itself" — pointing the user at a YAML
    # frontmatter problem when the actual issue is duplicate filenames.
    # With explicit `depends_on: []` the misleading error never fires and
    # the bug is worse: emit_bash writes two SESSION rows with the same id,
    # the runner's META parser overwrites SESSION_FILE_BASENAME[N] /
    # SESSION_SLUG_BY_ID[N] with whichever line came last (silently dropping
    # the first file), AND appends both ids to WAVE_IDS[N], so the wave
    # loop in run-sessions.sh attempts to create the same per-session
    # worktree twice — racing against the in-flight first session. (bug-133)
    seen_ids: dict[int, str] = {}
    for entry in sorted(os.listdir(sessions_dir)):
        m = SESSION_RE.match(entry)
        if not m:
            continue
        path = os.path.join(sessions_dir, entry)
        sid = int(m.group(1))
        slug = m.group(2)
        # Whitelist [A-Za-z0-9._-] for slugs. Rejects:
        #   space — breaks `set -- $_rest` field splitting in run-sessions.sh (bug-062)
        #   pipe  — breaks `|`-delimited result rows in epic-result.sh (bug-082)
        #   tab   — breaks IFS word-splitting of SESSION lines in run-sessions.sh
        #   glob meta (* ? [ ]) — silently expands during `set -- $_rest` if the
        #     cwd contains matching files, corrupting later columns (bug-092)
        #   shell meta ($ ` ; & < > etc) — defensive; never used in real slugs
        # The same whitelist also keeps sess_branch and sess_wt_dir_name
        # construction in run-sessions.sh:837-838 safe by construction.
        if not re.match(r"^[A-Za-z0-9._-]+$", slug):
            safe_suggestion = re.sub(r"[^A-Za-z0-9._-]", "-", slug)
            raise SystemExit(
                f"ERROR: {entry} — slug must match [A-Za-z0-9._-]+. "
                f"Rename the file using hyphens only "
                f"(e.g. session-{sid:02d}-{safe_suggestion}.md)"
            )
        if sid in seen_ids:
            raise SystemExit(
                f"ERROR: duplicate session id {sid:02d}: {seen_ids[sid]} and {entry}. "
                f"Each session-NN-*.md must have a unique NN — rename one file."
            )
        seen_ids[sid] = entry
        if sid == 0:
            operator = path
            continue
        # `utf-8-sig` strips an optional leading UTF-8 BOM (﻿) on read.
        # Files saved by Windows editors (Notepad, some VS Code configs) with
        # "UTF-8 with BOM" prepend \xef\xbb\xbf; `encoding="utf-8"` leaves it
        # in `text`, causing `text.startswith("---\n")` to fail and returning {}
        # — the session silently loses depends_on/parallel_safe and the whole DAG
        # collapses to the implicit linear chain with no error. (bug-081)
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
        fm, _ = parse_frontmatter(text)
        fm_session = fm.get("session")
        if fm_session is not None:
            try:
                fm_session_int = int(fm_session)
            except (TypeError, ValueError):
                raise SystemExit(
                    f"ERROR: {entry} session: must be a numeric session id, "
                    f"got {fm_session!r}"
                )
            if fm_session_int != sid:
                raise SystemExit(
                    f"ERROR: {entry} declares session={fm_session} "
                    f"but filename says {sid:02d}"
                )
        deps_raw = fm.get("depends_on", None)
        implicit = deps_raw is None
        if implicit:
            deps: list[int] = []
        else:
            try:
                deps = [int(d) for d in deps_raw]
            except (TypeError, ValueError) as exc:
                raise SystemExit(
                    f"ERROR: {entry} depends_on must be a list of session numbers; "
                    f"got {deps_raw!r}"
                ) from exc
        touches = fm.get("touches", []) or []
        if not isinstance(touches, list):
            raise SystemExit(f"ERROR: {entry} touches must be a list of globs")
        # Defence-in-depth alongside the bug-097 fix in parse_frontmatter:
        # any string that survived the boolean-recognition whitelist (typo,
        # capitalised brand-name like `parallel_safe: Maybe`, accidental
        # quoting, etc.) would otherwise be silently coerced via bool()
        # into True. Refuse those explicitly so the user sees a clear error
        # at validation time instead of mysterious parallel-wave behavior.
        ps_raw = fm.get("parallel_safe", True)
        if isinstance(ps_raw, str):
            raise SystemExit(
                f"ERROR: {entry} parallel_safe must be a boolean "
                f"(true/false/yes/no/on/off), got string {ps_raw!r}. "
                f"Quote the value if you intend it as a literal string."
            )
        cli_raw = fm.get("cli", "") or ""
        if cli_raw and cli_raw not in ("claude", "opencode"):
            raise SystemExit(
                f"ERROR: {entry} cli must be 'claude' or 'opencode' (or omit for auto-detect), "
                f"got {cli_raw!r}"
            )
        sessions.append(
            {
                "id": sid,
                "file": entry,
                "path": path,
                "slug": slug,
                "title": fm.get("title", slug.replace("-", " ").title()),
                "depends_on": deps,
                "implicit_dep": implicit,
                "touches": [str(t) for t in touches],
                "parallel_safe": bool(ps_raw),
                "model": fm.get("model", ""),
                "cli": cli_raw,
                "has_frontmatter": bool(fm),
            }
        )

    sessions.sort(key=lambda s: s["id"])

    # Implicit linear chain for sessions without frontmatter or without depends_on:
    # session N → [N-1] (the prior session in numeric order).
    for i, s in enumerate(sessions):
        if s["implicit_dep"]:
            s["depends_on"] = [] if i == 0 else [sessions[i - 1]["id"]]

    return sessions, operator


def build_dag(sessions: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    by_id = {s["id"]: s for s in sessions}
    for s in sessions:
        for d in s["depends_on"]:
            if d not in by_id:
                raise SystemExit(
                    f"ERROR: session {s['id']:02d} depends on {d:02d}, "
                    f"which is not present"
                )
            if d == s["id"]:
                raise SystemExit(f"ERROR: session {s['id']:02d} cannot depend on itself")

    color = {s["id"]: 0 for s in sessions}  # 0 white, 1 gray, 2 black
    stack: list[tuple[int, int]] = []  # (node, dep-iter-index)

    def visit(start: int) -> None:
        stack.append((start, 0))
        color[start] = 1
        while stack:
            node, idx = stack[-1]
            deps = by_id[node]["depends_on"]
            if idx >= len(deps):
                color[node] = 2
                stack.pop()
                continue
            stack[-1] = (node, idx + 1)
            nxt = deps[idx]
            if color[nxt] == 1:
                path = " → ".join(f"{n:02d}" for n, _ in stack) + f" → {nxt:02d}"
                raise SystemExit(f"ERROR: cycle detected: {path}")
            if color[nxt] == 0:
                color[nxt] = 1
                stack.append((nxt, 0))

    for s in sessions:
        if color[s["id"]] == 0:
            visit(s["id"])
    return by_id


def compute_waves(sessions: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """
    Kahn-style level partitioning. A session that declares parallel_safe=False
    runs alone in its wave (after its deps finish, before its dependents start).
    """
    waves: list[list[dict[str, Any]]] = []
    completed: set[int] = set()
    remaining = {s["id"] for s in sessions}
    by_id = {s["id"]: s for s in sessions}

    while remaining:
        ready = sorted(
            (
                s
                for s in sessions
                if s["id"] in remaining and all(d in completed for d in s["depends_on"])
            ),
            key=lambda x: x["id"],
        )
        if not ready:
            blocked = ", ".join(f"{x:02d}" for x in sorted(remaining))
            raise SystemExit(
                f"ERROR: schedule deadlock — could not place sessions {blocked}"
            )

        # Partition: any parallel_safe=False session is solo and goes first
        # among ready (so dependents in later waves are not held up unnecessarily).
        non_parallel = [s for s in ready if not s["parallel_safe"]]
        parallel = [s for s in ready if s["parallel_safe"]]

        if non_parallel:
            wave = [non_parallel[0]]
        else:
            wave = parallel

        waves.append(wave)
        for s in wave:
            completed.add(s["id"])
            remaining.discard(s["id"])

    return waves


def globs_overlap(a_globs: list[str], b_globs: list[str]) -> bool:
    """
    Heuristic overlap: directory-prefix containment, fnmatch on the patterns
    themselves, or literal equality. Not exact (we don't enumerate the FS).
    """

    def _stem(g: str) -> str:
        return g.split("**")[0].rstrip("/").rstrip("*")

    def _is_under(child: str, parent: str) -> bool:
        # Anchor on the path separator so sibling directories that share a
        # name prefix (e.g. `src/foo` vs `src/foo-extra`) are not falsely
        # flagged as overlapping. Same class as the bug-022/bug-033 literal-
        # prefix glob bugs in run-sessions.sh.
        return child == parent or child.startswith(parent + "/")

    for ag in a_globs:
        for bg in b_globs:
            if ag == bg:
                return True
            if fnmatch.fnmatch(ag, bg) or fnmatch.fnmatch(bg, ag):
                return True
            ap, bp = _stem(ag), _stem(bg)
            if ap and bp and (_is_under(ap, bp) or _is_under(bp, ap)):
                return True
    return False


def find_overlaps(wave: list[dict[str, Any]]) -> list[tuple[int, int]]:
    pairs: list[tuple[int, int]] = []
    for i in range(len(wave)):
        for j in range(i + 1, len(wave)):
            a, b = wave[i], wave[j]
            if a["touches"] and b["touches"] and globs_overlap(a["touches"], b["touches"]):
                pairs.append((a["id"], b["id"]))
    return pairs


def render_ascii(waves: list[list[dict[str, Any]]]) -> str:
    lines = []
    width = max(
        (len(s["slug"]) for w in waves for s in w),
        default=10,
    )
    for i, w in enumerate(waves, 1):
        cells = "  ".join(f"[{s['id']:02d} {s['slug']:<{width}}]" for s in w)
        marker = "║" if len(w) == 1 else "╠"
        lines.append(f"  {marker} Wave {i}: {cells}")
    return "\n".join(lines)


def emit_bash(plan: dict[str, Any]) -> None:
    """
    Emit bash-parseable plan. SESSION lines have been extended with model/cli columns
    for backward compatibility: older parsers can ignore the extra trailing columns.
    Format: SESSION <wave> <id> <file> <deps> <slug> <parallel> <model> <cli>

    Empty optional fields (model, cli) are rendered as the sentinel `-`. The
    bash side splits the SESSION row via unquoted `set -- $_rest`, which
    collapses consecutive whitespace; an empty middle field would otherwise
    shift every later field one slot left. With model="" and cli="claude"
    the row would parse as smodel="claude" / scli="" — silently losing the
    per-session CLI override and treating "claude" as a model id. Same family
    as the deps field, which already uses `-` for "no parents". (bug-076)
    """
    print(f"META operator_path={plan['operator_path']}")
    print(f"META operator_file={os.path.basename(plan['operator_path'])}")
    print(f"META wave_count={len(plan['waves'])}")
    print(f"META any_frontmatter={'true' if plan['any_frontmatter'] else 'false'}")
    for wi, w in enumerate(plan["waves"], 1):
        print(f"WAVE {wi} {len(w)}")
        for s in w:
            parents = ",".join(f"{p}" for p in s["depends_on"]) or "-"
            model = s["model"] or "-"
            cli = s["cli"] or "-"
            print(
                f"SESSION {wi} {s['id']} {s['file']} {parents} {s['slug']} "
                f"{'1' if s['parallel_safe'] else '0'} {model} {cli}"
            )


def main() -> None:
    # On Windows, Python's text-mode stdout translates "\n" to "\r\n", which
    # breaks downstream bash parsing. Force LF newlines and UTF-8 so the
    # shell wrapper sees clean output regardless of platform.
    try:
        sys.stdout.reconfigure(newline="\n", encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("sessions_dir")
    ap.add_argument("--bash", action="store_true", help="emit line-oriented format")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--strict", action="store_true", help="fail on touches overlap")
    args = ap.parse_args()

    if not os.path.isdir(args.sessions_dir):
        print(f"ERROR: not a directory: {args.sessions_dir}", file=sys.stderr)
        sys.exit(1)

    sessions, operator = load_sessions(args.sessions_dir)
    if operator is None:
        print(
            f"ERROR: no session-00-*.md (operator rules) in {args.sessions_dir}",
            file=sys.stderr,
        )
        sys.exit(1)
    if not sessions:
        print(f"ERROR: no session-NN-*.md files (NN > 0) in {args.sessions_dir}", file=sys.stderr)
        sys.exit(1)

    build_dag(sessions)
    waves = compute_waves(sessions)

    overlaps: list[tuple[int, int, int]] = []
    for wi, w in enumerate(waves, 1):
        for a, b in find_overlaps(w):
            overlaps.append((wi, a, b))

    plan = {
        "operator_path": os.path.abspath(operator).replace("\\", "/"),
        "waves": [
            [
                {
                    "id": s["id"],
                    "file": s["file"],
                    "path": os.path.abspath(s["path"]).replace("\\", "/"),
                    "slug": s["slug"],
                    "title": s["title"],
                    "depends_on": s["depends_on"],
                    "touches": s["touches"],
                    "parallel_safe": s["parallel_safe"],
                    "model": s["model"],
                    "cli": s["cli"],
                }
                for s in w
            ]
            for w in waves
        ],
        "overlaps": [{"wave": wi, "a": a, "b": b} for (wi, a, b) in overlaps],
        "any_frontmatter": any(s["has_frontmatter"] for s in sessions),
    }

    if args.json:
        print(json.dumps(plan, indent=2))
    elif args.bash:
        emit_bash(plan)
    elif args.show or args.validate:
        print(f"Sessions: {len(sessions)} across {len(waves)} wave(s)")
        print(render_ascii(waves))
        if overlaps:
            print("\nTouches-overlap warnings:")
            for wi, a, b in overlaps:
                print(f"  wave {wi}: session {a:02d} ↔ session {b:02d}")
        if not plan["any_frontmatter"]:
            print(
                "\nNote: no session declared frontmatter. "
                "Falling back to linear chain (one session per wave)."
            )
    else:
        # Default = --show
        print(f"Sessions: {len(sessions)} across {len(waves)} wave(s)")
        print(render_ascii(waves))

    if args.strict and overlaps:
        sys.exit(2)


if __name__ == "__main__":
    main()
