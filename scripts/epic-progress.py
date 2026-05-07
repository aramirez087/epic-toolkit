#!/usr/bin/env python3
"""epic-progress.py — Live progress display for AI-CLI stream-json output.

Reads newline-delimited JSON from stdin and displays a single-line progress
indicator on stderr. Writes the AI's text output to a log file.

Supports two JSON formats (auto-detected):
  - Claude Code: --output-format stream-json  (content_block_start/delta/stop)
  - OpenCode:    --format json                 (step_start/tool_use/text/step_finish)

Usage:
    claude -p --output-format stream-json < prompt \\
      | python3 epic-progress.py --log session.log --phase PLAN

    opencode run --format json -m opencode/claude-sonnet-4 < prompt \\
      | python3 epic-progress.py --log session.log --phase PLAN
"""

import argparse
import codecs
import json
import os
import queue
import re
import sys
import threading
import time


STALE_LOCK_SECS = 60  # lock older than this was left by a SIGKILL'd process


def update_status_file(path: str, session_id: int, update: dict) -> None:
    """Atomically merge `update` into sessions[session_id] in the shared status JSON."""
    if not path or not os.path.isfile(path):
        return
    lock = path + '.lock'
    acquired = False
    for _ in range(100):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
            acquired = True
            break
        except (FileExistsError, OSError):
            # Recover a lock file left behind by a SIGKILL'd progress process
            # (SIGKILL bypasses finally, so the lock is never released).
            # Mirror the same stale-lock logic in mark_session (bug-061 / bug-064).
            try:
                if time.time() - os.path.getmtime(lock) > STALE_LOCK_SECS:
                    os.unlink(lock)
            except OSError:
                pass
            time.sleep(0.02)
    if not acquired:
        return
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        key = str(session_id)
        # Symmetric guard to mark_session in epic-session.sh. dict.get
        # AND dict.setdefault both return the EXISTING value when the
        # key is present — `setdefault('sessions', {})` returns None
        # whenever data['sessions'] is null (the default fires only for
        # ABSENT keys, not null values), and the next `.setdefault(...)`
        # on None raises AttributeError. Same chain at the inner
        # session entry: a `{"sessions": {"1": null}}` shape lets
        # `setdefault(key, {})` return None and the next `.update(...)`
        # raises AttributeError too.
        # The outer `except Exception: pass` here silently swallows the
        # crash (best-effort discipline), but the broken state persists
        # in the file and every subsequent update call fails the same
        # way — the user loses live progress for the rest of the run
        # with no diagnostic. Same audit class as bug-167/175/178/183/
        # 184. Coerce non-dict shapes to {} at every level so the writer
        # rebuilds the missing structure rather than crashing on it.
        # (bug-186)
        if not isinstance(data, dict):
            data = {}
        sessions_obj = data.get('sessions')
        if not isinstance(sessions_obj, dict):
            sessions_obj = {}
            data['sessions'] = sessions_obj
        entry = sessions_obj.get(key)
        if not isinstance(entry, dict):
            entry = {}
            sessions_obj[key] = entry
        entry.update(update)
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        pass
    finally:
        try:
            os.unlink(lock)
        except Exception:
            pass

SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
REFRESH = 0.2  # seconds between spinner frames


def parse_target(tool_name, buf):
    """Extract a human-readable target from accumulated input_json_delta (Claude)."""
    # `(?:[^"\\]|\\.)*` matches any sequence of non-quote/non-backslash chars OR
    # an escape pair (backslash + any char). The previous `[^"]*` stopped at the
    # FIRST '"' byte, including escaped `\"` inside the value — so a Bash command
    # like `echo "hello world"` (streamed as `"command": "echo \"hello world\""`)
    # captured only `echo \\` and the UI showed a truncated, garbled target. This
    # form respects JSON escapes; the json.loads round-trip below converts them
    # back to the user-visible characters. (bug-116)
    patterns = {
        "Read": r'"file_path"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Edit": r'"file_path"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Write": r'"file_path"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "NotebookEdit": r'"notebook_path"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Glob": r'"pattern"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Grep": r'"pattern"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Bash": r'"command"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "Task": r'"description"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "WebFetch": r'"url"\s*:\s*"((?:[^"\\]|\\.)*)"',
        "WebSearch": r'"query"\s*:\s*"((?:[^"\\]|\\.)*)"',
    }
    pat = patterns.get(tool_name)
    if pat:
        m = re.search(pat, buf)
        if m:
            raw = m.group(1)
            # Decode JSON escapes so the display reads naturally; fall back to
            # the raw capture when the streaming buffer ends mid-escape.
            try:
                return json.loads('"' + raw + '"')
            except (ValueError, json.JSONDecodeError):
                return raw
    return ""


def parse_opencode_target(tool_name, state_input):
    """Extract a human-readable target from opencode tool state.input dict."""
    if not isinstance(state_input, dict):
        return ""
    field_map = {
        "read": "filePath",
        "edit": "filePath",
        "write": "filePath",
        "glob": "pattern",
        "grep": "pattern",
        "bash": "command",
        "task": "description",
        "webfetch": "url",
        "websearch": "query",
    }
    field = field_map.get(tool_name, "")
    if field:
        val = state_input.get(field, "")
        if isinstance(val, str):
            return val
    return ""


OPENCODE_TOOL_ALIASES = {
    "read": "Read",
    "edit": "Edit",
    "write": "Write",
    "glob": "Glob",
    "grep": "Grep",
    "bash": "Bash",
    "task": "Task",
    "webfetch": "WebFetch",
    "websearch": "WebSearch",
}


def shorten(path, max_len):
    """Shorten a file path or string to fit max_len."""
    if len(path) <= max_len:
        return path
    # For file paths, show .../<last components>
    if "/" in path:
        parts = path.split("/")
        result = parts[-1]
        for p in reversed(parts[:-1]):
            candidate = p + "/" + result
            if len(candidate) + 4 > max_len:
                break
            result = candidate
        return ".../" + result if len(".../" + result) <= max_len else result[:max_len]
    return path[:max_len - 3] + "..."


def format_elapsed(seconds):
    """Format seconds as Xm XXs."""
    m, s = divmod(int(seconds), 60)
    return f"{m}m{s:02d}s"


def render_line(spinner_char, elapsed, step, tool, target, term_width):
    """Build the single-line progress string."""
    prefix = f"  {spinner_char} {format_elapsed(elapsed)} │ "
    if tool:
        middle = f"Step {step:<3} │ {tool:<8}→ "
        avail = term_width - len(prefix) - len(middle) - 1
        target_str = shorten(target, max(10, avail)) if target else ""
        return prefix + middle + target_str
    else:
        return prefix + f"Step {step:<3} │ Thinking..."


def main():
    parser = argparse.ArgumentParser(description="Live progress for Claude stream-json")
    parser.add_argument("--log", required=True, help="Path to write Claude text output")
    parser.add_argument("--phase", default="RUN", help="Phase label (for display)")
    parser.add_argument("--session-id", type=int, default=0, help="Session ID (for status file)")
    parser.add_argument("--status-file", default="", help="Shared status JSON path")
    args = parser.parse_args()

    session_id  = args.session_id
    status_file = args.status_file

    log_file = open(args.log, "a", encoding="utf-8")
    start = time.time()
    step = 0
    tool_calls = 0
    current_tool = ""
    current_target = ""
    input_buf = ""
    spinner_idx = 0
    activity = ""  # "tool" or "text" or ""
    last_status_ts = time.time()
    STATUS_INTERVAL = 1.5  # seconds between periodic status file writes

    try:
        term_width = os.get_terminal_size(sys.stderr.fileno()).columns
    except (OSError, ValueError):
        term_width = 80

    # Cross-platform non-blocking stdin: a reader thread pumps chunks into a
    # Queue; the main loop polls with a timeout so the spinner animates even
    # while no events arrive. Replaces select.select(), which only works on
    # POSIX sockets/pipes — it errors on Windows pipes.
    stdin_buffer = sys.stdin.buffer
    chunk_q: queue.Queue = queue.Queue()

    def _reader() -> None:
        while True:
            try:
                chunk = stdin_buffer.read1(65536)
            except (OSError, ValueError):
                chunk_q.put(b"")
                return
            chunk_q.put(chunk)
            if not chunk:
                return

    threading.Thread(target=_reader, daemon=True).start()
    line_buf = ""
    eof = False
    # Streaming UTF-8 decoder. Buffers partial multi-byte sequences across
    # chunk boundaries — `read1(65536)` returns whatever the underlying pipe
    # has available, so a 2/3/4-byte UTF-8 codepoint can land with its first
    # byte(s) at the tail of one chunk and its remainder at the head of the
    # next. The previous `chunk.decode("utf-8", errors="replace")` per chunk
    # treated each fragment as its own complete string, replacing every split
    # codepoint with `�` on both sides — so any em-dash, smart quote, or
    # non-ASCII filename Claude streamed near a 64KB boundary landed garbled
    # in the log file and in the live UI's `target` field. An incremental
    # decoder defers final="False" calls until enough bytes have arrived to
    # complete the codepoint, so cross-boundary sequences round-trip cleanly.
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    try:
        while True:
            try:
                chunk = chunk_q.get(timeout=REFRESH)
            except queue.Empty:
                chunk = None

            if chunk is not None:
                if not chunk:
                    eof = True
                    # Flush any trailing bytes the decoder is still buffering
                    # (partial multi-byte sequence at producer-EOF) so we
                    # don't silently drop a final character.
                    line_buf += decoder.decode(b"", final=True)
                    # Force-flush any trailing partial line (no final newline)
                    # so the parse loop drains it before the outer break test
                    # fires. Without this, a producer that crashes / is killed
                    # mid-line leaves line_buf non-empty forever and the loop
                    # spins at REFRESH Hz on stderr indefinitely.
                    if line_buf and not line_buf.endswith("\n"):
                        line_buf += "\n"
                else:
                    line_buf += decoder.decode(chunk)

                while "\n" in line_buf:
                    line, line_buf = line_buf.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        evt = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    # `evt = json.loads(line)` succeeds for any valid JSON value,
                    # not just objects — `null` → None, `"str"` → str, `[…]` →
                    # list, `123` → int. The downstream `evt.get("type", "")`
                    # crashes with AttributeError on every non-dict, propagating
                    # out of the reader and breaking the producer pipe with
                    # SIGPIPE — claude/opencode then exits 141 and classify_error
                    # reports `cli_crash` instead of the real producer-protocol
                    # cause. Same audit class as bug-167 (`evt.get("error", {})`
                    # accepted None for `"error": null`); the fix there guarded
                    # one call site, but the symmetric guard at the OUTER event
                    # boundary was never added — every nested fetch below
                    # (content_block, delta, part) was implicitly assuming the
                    # outer parse already produced a dict. (bug-175)
                    if not isinstance(evt, dict):
                        continue
                    evt_type = evt.get("type", "")

                    # ── Claude stream-json events ──
                    if evt_type == "content_block_start":
                        # `evt.get("content_block", {})` returns the literal None
                        # when the producer emits `"content_block": null` (the
                        # default ONLY fires for absent keys, not null values)
                        # — same audit class as bug-167. Without the guard, the
                        # next `cb.get(...)` raises AttributeError, breaks the
                        # pipe, and the session is misclassified as cli_crash.
                        # Mirror the bug-167 isinstance(dict) guard. (bug-175)
                        cb = evt.get("content_block")
                        if not isinstance(cb, dict):
                            continue
                        if cb.get("type") == "tool_use":
                            step += 1
                            tool_calls += 1
                            # `cb.get("name", "?")` returns whatever the producer
                            # sent for `name`. If non-str (None, int, list, dict)
                            # the value flows into `parse_target(current_tool, …)`
                            # → `patterns.get(current_tool)` — which raises
                            # `TypeError: unhashable type` for list/dict,
                            # breaking the main loop and triggering the SIGPIPE
                            # → cli_crash chain. Bug-175/176 added isinstance
                            # guards at the OUTER dict-shaped values (evt,
                            # content_block, delta, part); this is the symmetric
                            # guard for the INNER scalar fields. Coerce at the
                            # boundary so downstream code stays str-safe and
                            # non-str shapes degrade to the existing `?`
                            # sentinel. Same audit class. (bug-180)
                            raw_name = cb.get("name", "?")
                            current_tool = raw_name if isinstance(raw_name, str) else "?"
                            current_target = ""
                            input_buf = ""
                            activity = "tool"
                            if session_id > 0 and status_file:
                                now = time.time()
                                update_status_file(status_file, session_id, {
                                    'step': step, 'tool': current_tool,
                                    'target': '', 'elapsed': now - start,
                                })
                                last_status_ts = now
                        elif cb.get("type") == "text":
                            if activity != "tool":
                                activity = "text"
                                current_tool = ""
                                current_target = ""

                    elif evt_type == "content_block_delta":
                        # Same null-safe guard as content_block_start above —
                        # `evt.get("delta", {})` returns None for `"delta": null`
                        # and the next `.get(...)` raises AttributeError,
                        # breaking the producer pipe with SIGPIPE. (bug-175)
                        delta = evt.get("delta")
                        if not isinstance(delta, dict):
                            continue
                        delta_type = delta.get("type", "")

                        if delta_type == "input_json_delta":
                            # `partial_json` is supposed to be a string fragment
                            # of the tool's input JSON. dict.get's default fires
                            # only for ABSENT keys, not null values:
                            # `"partial_json": null` lands None and `input_buf
                            # += None` raises TypeError (str-concat with
                            # NoneType), propagates out of the main loop,
                            # breaks the producer pipe with SIGPIPE, the AI CLI
                            # exits 141 and classify_error reports `cli_crash`
                            # instead of the real producer-protocol cause.
                            # Truthy non-str shapes (`"partial_json": 5`,
                            # `["x"]`) crash the same way. Bug-175/176 added
                            # isinstance(dict) guards at the OUTER dict-shaped
                            # values (evt, content_block, delta, part); this is
                            # the symmetric guard for the INNER scalar field
                            # the earlier audit missed. Same audit class.
                            # (bug-178)
                            pj = delta.get("partial_json", "")
                            if isinstance(pj, str):
                                input_buf += pj
                            new_target = parse_target(current_tool, input_buf)
                            if new_target and new_target != current_target:
                                current_target = new_target
                                if session_id > 0 and status_file:
                                    now = time.time()
                                    if now - last_status_ts >= 0.5:
                                        update_status_file(status_file, session_id, {
                                            'target': current_target,
                                            'elapsed': now - start,
                                        })
                                        last_status_ts = now

                        elif delta_type == "text_delta":
                            # Same str-safe guard as the partial_json site
                            # above. dict.get's default fires only for ABSENT
                            # keys: `"text": null` lands None and
                            # `log_file.write(None)` raises TypeError
                            # ("write() argument must be str, not NoneType"),
                            # propagates out, SIGPIPE, cli_crash. Truthy
                            # non-str shapes (`"text": 5`, `["x"]`) raise the
                            # same TypeError on log_file.write. Same audit
                            # class as bug-175/176/178. (bug-179)
                            text = delta.get("text", "")
                            if isinstance(text, str):
                                log_file.write(text)
                                log_file.flush()
                                if activity != "tool":
                                    activity = "text"

                    elif evt_type == "content_block_stop":
                        if activity == "tool":
                            activity = ""
                            input_buf = ""

                    elif evt_type == "message_stop":
                        pass

                    # ── OpenCode --format json events ──
                    elif evt_type == "step_start":
                        step += 1
                        activity = ""
                        current_tool = ""
                        current_target = ""

                    elif evt_type == "tool_use":
                        # Same null-safe guard — `"part": null` collapses to
                        # None and the next `.get(...)` crashes the reader,
                        # breaking the OpenCode pipe with SIGPIPE. (bug-175)
                        part = evt.get("part")
                        if not isinstance(part, dict):
                            continue
                        # Same str-coerce guard as the Claude
                        # content_block_start site above.
                        # `OPENCODE_TOOL_ALIASES.get(raw_tool, raw_tool)` and
                        # `field_map.get(tool_name, "")` inside
                        # parse_opencode_target both raise TypeError when
                        # raw_tool is unhashable (list/dict from a malformed
                        # producer event). Coerce non-str to the `?` sentinel
                        # at the boundary so downstream code stays str-safe.
                        # (bug-180)
                        raw_tool = part.get("tool", "?")
                        if not isinstance(raw_tool, str):
                            raw_tool = "?"
                        current_tool = OPENCODE_TOOL_ALIASES.get(raw_tool, raw_tool)
                        tool_calls += 1
                        state = part.get("state", {})
                        state_input = state.get("input", {}) if isinstance(state, dict) else {}
                        current_target = parse_opencode_target(raw_tool, state_input)
                        activity = "tool"
                        if session_id > 0 and status_file:
                            now = time.time()
                            update_status_file(status_file, session_id, {
                                'step': step, 'tool': current_tool,
                                'target': current_target, 'elapsed': now - start,
                            })
                            last_status_ts = now

                    elif evt_type == "text":
                        # Same null-safe guard for the OpenCode text event.
                        # (bug-175)
                        part = evt.get("part")
                        if not isinstance(part, dict):
                            continue
                        # `if text:` (the previous guard) catches None and
                        # "" but NOT truthy non-str shapes — `"text": 5`,
                        # `["x"]`, `{"a":1}` all pass through and crash
                        # log_file.write with TypeError, breaking the
                        # OpenCode pipe with SIGPIPE. Reject non-str
                        # alongside the truthy check. Same audit class
                        # as bug-179 in the Claude branch. (bug-179)
                        text = part.get("text", "")
                        if isinstance(text, str) and text:
                            log_file.write(text)
                            log_file.flush()
                        activity = "text"

                    elif evt_type == "step_finish":
                        if activity == "tool":
                            activity = ""
                            current_tool = ""
                            current_target = ""

                    elif evt_type == "error":
                        # `evt.get("error", {})` returns the literal None when the
                        # producer emits `"error": null` (the default only fires
                        # for ABSENT keys). The previous `str(err_data)` fallback
                        # then stringified None to "None", a non-empty string
                        # that passed the `if err_msg:` gate — corrupting the log
                        # with `[ERROR] None` and propagating "None" as the
                        # error_detail in the result file. Same audit class as
                        # bug-148: every .get(key, default) site that consumes
                        # a typed value must reject inputs the producer can emit
                        # but the consumer can't interpret.
                        # Multi-line messages also need normalisation: classify_error
                        # uses `grep -oE '^\[ERROR\] .+' | head -1` which truncates
                        # at the first \n, dropping the rest of the message from
                        # error_detail (it survives in the log only).
                        err_data = evt.get("error")
                        err_msg = ""
                        if isinstance(err_data, dict):
                            msg = err_data.get("message", "")
                            if isinstance(msg, str):
                                err_msg = msg
                        elif isinstance(err_data, str):
                            err_msg = err_data
                        err_msg = " | ".join(
                            ln.strip() for ln in err_msg.splitlines() if ln.strip()
                        )
                        if err_msg:
                            log_file.write(f"\n[ERROR] {err_msg}\n")
                            log_file.flush()
                            if session_id > 0 and status_file:
                                update_status_file(status_file, session_id, {
                                    'error_type': 'cli_error',
                                    'error_detail': err_msg,
                                })

            if eof and not line_buf.strip():
                break

            # Render progress
            elapsed = time.time() - start
            c = SPINNER[spinner_idx % len(SPINNER)]
            spinner_idx += 1

            # Periodic status file update (elapsed + current tool/target)
            now_abs = time.time()
            if session_id > 0 and status_file and (now_abs - last_status_ts) >= STATUS_INTERVAL:
                update_status_file(status_file, session_id, {
                    'elapsed': elapsed,
                    'step': step,
                    'tool': current_tool,
                    'target': current_target,
                })
                last_status_ts = now_abs

            if activity == "tool" and current_tool:
                line_out = render_line(c, elapsed, step, current_tool, current_target, term_width)
            elif activity == "text":
                prefix = f"  {c} {format_elapsed(elapsed)} │ "
                line_out = prefix + "Writing response..."
            elif step > 0:
                line_out = render_line(c, elapsed, step, current_tool, current_target, term_width)
            else:
                prefix = f"  {c} {format_elapsed(elapsed)} │ "
                line_out = prefix + "Starting..."

            # Overwrite line on stderr
            sys.stderr.write(f"\r{line_out:<{term_width}}")
            sys.stderr.flush()

    except KeyboardInterrupt:
        pass
    finally:
        log_file.close()

    # Final summary line
    elapsed = time.time() - start
    summary = f"  ✓ {format_elapsed(elapsed)} │ Done    │ {tool_calls} tool calls"
    sys.stderr.write(f"\r{summary:<{term_width}}\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
