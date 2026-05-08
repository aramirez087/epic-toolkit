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
    # Normalise CRLF — anchored `\n---\n` lookups silently fail otherwise. (bug-024)
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
        """Strip ` # ...` comments while preserving `#` inside quoted values.

        Quotes only open at value-start (after `:` / `- `); mid-token quotes
        (`title: It's a test`) are scalar chars. Tracks flow_depth for
        `[...]` / `{...}` entries. (bugs 117, 123, 124, 126, 134, 135, 136)
        """
        stripped = line.lstrip()
        leading_ws = len(line) - len(stripped)

        # Pre-scan the key portion (positions 1..first `:`) for an inline
        # comment marker. Without this, a `:` that sits INSIDE a comment
        # (e.g., `key  # has : in comment`) would be misread by the
        # value_start logic below as the key/value separator, jumping the
        # scan cursor past the `#` and leaving the comment un-stripped —
        # parse_frontmatter then partitions at the comment's `:` and
        # records a bogus key/value pair. Unquoted YAML keys have no
        # quoted regions, so a plain linear scan is sufficient here.
        # (bug-268)
        _colon_pos = line.find(":")
        _key_end = _colon_pos if _colon_pos >= 0 else len(line)
        for _j in range(1, _key_end):
            if line[_j] == "#" and line[_j - 1] in (" ", "\t"):
                return line[:_j].rstrip()

        value_start = -1
        if len(stripped) >= 2 and stripped[0] == "-" and stripped[1] in (" ", "\t"):
            value_start = leading_ws + 2
        elif ":" in stripped:
            value_start = line.find(":") + 1

        while 0 <= value_start < len(line) and line[value_start] in (" ", "\t"):
            value_start += 1

        in_quote: str | None = None
        flow_depth = 0
        scan_start = max(value_start, 1)
        if 0 <= value_start < len(line):
            c0 = line[value_start]
            if c0 in ('"', "'"):
                in_quote = c0
                scan_start = value_start + 1
            elif c0 in ("[", "{"):
                flow_depth = 1
                scan_start = value_start + 1

        i = scan_start
        while i < len(line):
            ch = line[i]
            if in_quote is not None:
                if ch == in_quote:
                    if in_quote == "'":
                        # YAML 1.2 §7.3.2: `\` is literal in single-quoted
                        # strings; only `''` is an escape. (bug-136)
                        if i + 1 < len(line) and line[i + 1] == "'":
                            i += 2
                            continue
                        in_quote = None
                    else:
                        # Double-quoted: even backslash count = real terminator. (bug-123)
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
                return line[:i].rstrip()
            i += 1
        return line

    def _unquote_scalar(raw: str) -> str:
        """Decode a YAML 1.2 quoted scalar — escapes for double-quoted,
        `''` for single-quoted, fall back to strip("'\"") for unquoted. (bug-145)"""
        if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
            esc = {
                '\\': '\\', '"': '"', '/': '/',
                'n': '\n', 't': '\t', 'r': '\r', '0': '\0',
                'a': '\a', 'b': '\b', 'v': '\v', 'f': '\f', 'e': '\x1b',
            }
            out: list[str] = []
            i = 1
            end = len(raw) - 1
            while i < end:
                ch = raw[i]
                if ch == '\\' and i + 1 < end:
                    out.append(esc.get(raw[i + 1], raw[i + 1]))
                    i += 2
                else:
                    out.append(ch)
                    i += 1
            return ''.join(out)
        if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
            out = []
            i = 1
            end = len(raw) - 1
            while i < end:
                if raw[i] == "'" and i + 1 < end and raw[i + 1] == "'":
                    out.append("'")
                    i += 2
                else:
                    out.append(raw[i])
                    i += 1
            return ''.join(out)
        return raw.strip("'\"")

    def _split_flow_list(s: str) -> list[str]:
        """Split `[...]` body on `,`, respecting quotes and nested flow. (bug-132, bug-149)"""
        items: list[str] = []
        buf = ""
        in_q: str | None = None
        flow_depth = 0
        i = 0
        n = len(s)
        while i < n:
            ch = s[i]
            if in_q is not None:
                buf += ch
                if ch == in_q:
                    if in_q == "'":
                        # `''` is the only single-quote escape per YAML 1.2 §7.3.2. (bug-136)
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
            elif ch in ("[", "{"):
                flow_depth += 1
                buf += ch
            elif ch in ("]", "}"):
                if flow_depth > 0:
                    flow_depth -= 1
                buf += ch
            elif ch == "," and flow_depth == 0:
                cleaned = _unquote_scalar(buf.strip())
                if cleaned:
                    items.append(cleaned)
                buf = ""
            else:
                buf += ch
            i += 1
        cleaned = _unquote_scalar(buf.strip())
        if cleaned:
            items.append(cleaned)
        return items

    result: dict[str, Any] = {}
    current_key: str | None = None
    for raw in fm_text.splitlines():
        raw = _strip_inline_comment(raw)
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        # Accept block-list items at any indent (spaces or tabs) — a fixed
        # whitelist would silently drop 3-space or tab-indented entries. (bug-127)
        lstripped = raw.lstrip(" \t")
        if lstripped == "-" or lstripped.startswith(("- ", "-\t")):
            item = _unquote_scalar(lstripped[1:].strip())
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
            # YAML 1.1 booleans — without this whitelist, `parallel_safe: no`
            # falls through to bool("no") = True. (bug-097)
            result[k] = v.lower() in ("true", "yes", "on", "y")
        elif (v.startswith("-") and v[1:].isdigit()) or v.isdigit():
            # At most one leading sign — `lstrip('-').isdigit()` accepts
            # `--3` and crashes int(). (bug-114)
            result[k] = int(v)
        else:
            result[k] = _unquote_scalar(v)
    return result, body


def load_sessions(sessions_dir: str) -> tuple[list[dict[str, Any]], str | None]:
    sessions: list[dict[str, Any]] = []
    operator: str | None = None
    # Reject duplicate session ids — emit_bash would otherwise write two
    # SESSION rows that race the per-session worktree creation. (bug-133)
    seen_ids: dict[int, str] = {}
    for entry in sorted(os.listdir(sessions_dir)):
        m = SESSION_RE.match(entry)
        if not m:
            continue
        path = os.path.join(sessions_dir, entry)
        sid = int(m.group(1))
        slug = m.group(2)
        # [A-Za-z0-9._-] only — rejects shell meta, IFS chars, glob chars
        # that would corrupt SESSION-row word-splitting downstream. (bugs 062, 082, 092)
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
        # utf-8-sig strips Windows-editor BOM that breaks `---\n` lookup. (bug-081)
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
        fm, _ = parse_frontmatter(text)
        fm_session = fm.get("session")
        if fm_session is not None:
            # Reject bool first — int(True)==1 would slip past the try/except
            # and surface a misleading session/filename mismatch error. (bug-146)
            if isinstance(fm_session, bool):
                raise SystemExit(
                    f"ERROR: {entry} session: must be a numeric session id, "
                    f"got boolean {fm_session!r}. YAML 1.1 spellings "
                    f"(yes/no/on/off/y/n/true/false) are coerced to booleans "
                    f"by the frontmatter parser — quote the value if you "
                    f"intend a literal string, or use the numeric id."
                )
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
            # Reject non-list shapes — quoted-string `"12"` would iterate
            # char-by-char into deps=[1,2]. (bug-165)
            if isinstance(deps_raw, bool):
                raise SystemExit(
                    f"ERROR: {entry} depends_on must be a list of session "
                    f"numbers, got boolean {deps_raw!r}. YAML 1.1 spellings "
                    f"(yes/no/on/off/y/n/true/false) are coerced to booleans "
                    f"by the frontmatter parser — write `depends_on: [N]` "
                    f"instead, or use a block list with `- N` items."
                )
            if not isinstance(deps_raw, list):
                raise SystemExit(
                    f"ERROR: {entry} depends_on must be a list of session "
                    f"numbers, got {type(deps_raw).__name__} {deps_raw!r}. "
                    f"Use flow-list syntax `depends_on: [N]` or a block list "
                    f"with `- N` items. A bare scalar (`depends_on: 12`) or "
                    f"quoted string (`depends_on: \"12\"`) is not a list."
                )
            try:
                deps = [int(d) for d in deps_raw]
            except (TypeError, ValueError) as exc:
                raise SystemExit(
                    f"ERROR: {entry} depends_on must be a list of session numbers; "
                    f"got {deps_raw!r}"
                ) from exc
        # Name bool case first — `touches: yes` would otherwise surface as
        # the symptom-level "must be a list" error. (bug-170)
        touches_raw = fm.get("touches", [])
        if isinstance(touches_raw, bool):
            raise SystemExit(
                f"ERROR: {entry} touches must be a list of globs, got boolean "
                f"{touches_raw!r}. YAML 1.1 spellings (yes/no/on/off/y/n/"
                f"true/false) are coerced to booleans by the frontmatter "
                f"parser — write `touches: [path/glob]` instead, or a block "
                f"list with `- glob` items."
            )
        if not isinstance(touches_raw, list):
            raise SystemExit(
                f"ERROR: {entry} touches must be a list of globs, got "
                f"{type(touches_raw).__name__} {touches_raw!r}. Use flow-list "
                f"syntax `touches: [path/glob]` or a block list with `- glob` "
                f"items. A bare scalar (`touches: src/foo`) or quoted string "
                f"(`touches: \"src/foo\"`) is not a list."
            )
        touches = touches_raw
        # Reject string (typo'd boolean) and list/dict/None (empty value
        # with mistakenly indented children). bool([]) silently inverts. (bug-164)
        ps_raw = fm.get("parallel_safe", True)
        if isinstance(ps_raw, str):
            raise SystemExit(
                f"ERROR: {entry} parallel_safe must be a boolean "
                f"(true/false/yes/no/on/off), got string {ps_raw!r}. "
                f"Quote the value if you intend it as a literal string."
            )
        if not isinstance(ps_raw, (bool, int)):
            raise SystemExit(
                f"ERROR: {entry} parallel_safe must be a boolean "
                f"(true/false/yes/no/on/off), got {type(ps_raw).__name__} "
                f"{ps_raw!r}. This usually means the YAML key has no value "
                f"(empty `parallel_safe:`) or has accidental indented children. "
                f"Either remove the key (defaults to true) or set it to true/false."
            )
        # Reject non-string shapes for str-typed keys. YAML 1.1 booleans
        # (`model: yes` → True), empty values ([]), and bare ints all
        # corrupt the SESSION row downstream. (bugs 142, 172, 173)
        for _str_key in ("title", "model", "cli"):
            _str_val = fm.get(_str_key)
            if _str_val is None:
                continue
            if isinstance(_str_val, bool):
                raise SystemExit(
                    f"ERROR: {entry} {_str_key} must be a string, got boolean "
                    f"{_str_val!r}. YAML 1.1 spellings (yes/no/on/off/y/n/"
                    f"true/false) are coerced to booleans by the frontmatter "
                    f"parser — quote the value if you intend a literal string."
                )
            if not isinstance(_str_val, str):
                raise SystemExit(
                    f"ERROR: {entry} {_str_key} must be a string, got "
                    f"{type(_str_val).__name__} {_str_val!r}. This usually "
                    f"means the YAML key has no value (empty `{_str_key}:`) "
                    f"with accidental indented children below it, or a "
                    f"non-string scalar (`{_str_key}: 5`). Quote the value "
                    f"if you intend a literal string, or remove the line."
                )
        cli_raw = fm.get("cli", "") or ""
        if cli_raw and cli_raw not in ("claude", "opencode"):
            raise SystemExit(
                f"ERROR: {entry} cli must be 'claude' or 'opencode' (or omit for auto-detect), "
                f"got {cli_raw!r}"
            )
        # SESSION row is space-delimited — whitespace or shell meta in
        # model would shift every later field. (bug-143)
        model_raw = fm.get("model", "") or ""
        if model_raw and not re.match(r"^[A-Za-z0-9._/+:-]+$", str(model_raw)):
            raise SystemExit(
                f"ERROR: {entry} model={model_raw!r} contains characters that "
                f"break the SESSION row's space-delimited format. model must "
                f"match [A-Za-z0-9._/+:-]+ (no spaces, tabs, or shell meta)."
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
        # rstrip("/*") strips slash + star together; two-pass left
        # `src/foo/*` as `src/foo/` and broke `_is_under`.
        return g.split("**")[0].rstrip("/*")

    def _is_under(child: str, parent: str) -> bool:
        # Anchor the separator — `src/foo` vs `src/foo-extra`. (bug-022, bug-033)
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
    """Emit bash-parseable plan.
    Format: SESSION <wave> <id> <file> <deps> <slug> <parallel> <model> <cli>
    Empty model/cli render as `-` so word-splitting on `set -- $_rest`
    doesn't shift fields. (bug-076)
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
    # Force LF stdout — Windows text-mode would emit CRLF and break bash parsing.
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
