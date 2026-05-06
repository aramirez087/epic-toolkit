#!/usr/bin/env bash
# epic-session.sh — Session execution functions for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

# --- Extract prompt from markdown code fence ---
# Capture between the first ```md fence and its matching closer. Inner
# language-tagged code blocks (```bash, ```python, ```diff, …) inside the
# prompt are tracked via a depth counter so their closing ``` does NOT
# silently terminate the outer capture — that previously truncated prompts
# at the first inner code fence with no error. Bare-``` inner blocks are
# still ambiguous in CommonMark; the template tells users to indent code
# examples instead.
extract_prompt() {
  local file="$1" content
  # `sub(/\r$/, "")` normalises CRLF line endings before any anchored
  # comparison. Without it, awk sees `$0 == "```md\r"` and the literal
  # match against "```md" fails on Windows/Git-Bash checkouts where
  # core.autocrlf=true converts session files to CRLF — both this
  # primary path and the fallback below silently returned empty,
  # which made run-sessions.sh exit with "Could not extract operator
  # prompt" before any session ran. Mirrors the bug-024 fix in
  # epic-dag.py for the Python parser.
  content="$(awk '
    BEGIN { capture=0; depth=0 }
    {
      sub(/\r$/, "")
      if (NR == 1) sub(/^\357\273\277/, "")
      if (!capture) {
        if ($0 == "```md") { capture=1 }
        next
      }
      if ($0 ~ /^```[A-Za-z]/) { depth++; print; next }
      if ($0 == "```") {
        if (depth > 0) { depth--; print; next }
        exit
      }
      print
    }
  ' "$file")"
  if [[ -z "$content" ]]; then
    # Strip frontmatter and the title line, return the rest.
    # `awaiting_title` is true ONLY between the frontmatter close and the
    # first non-blank body line. The title (`^# …`) is stripped only in
    # that window; any later `# Heading` inside the body is left intact.
    # The previous version used a single fm_done flag and stripped the
    # FIRST `# ` heading anywhere after the frontmatter — so a file with
    # no leading title silently lost its first body section header.
    content="$(awk '
      BEGIN { in_fm=0; awaiting_title=0 }
      { sub(/\r$/, "") }
      NR==1 { sub(/^\357\273\277/, "") }
      NR==1 && /^---$/ { in_fm=1; next }
      in_fm && /^---$/ { in_fm=0; awaiting_title=1; next }
      in_fm { next }
      awaiting_title && /^[[:space:]]*$/ { print; next }
      awaiting_title && /^# / { awaiting_title=0; next }
      awaiting_title { awaiting_title=0 }
      { print }
    ' "$file")"
  fi
  echo "$content"
}

# Check if a worktree directory is in use by another process.
# Uses multiple detection methods in order of preference:
#   1. /proc-based check (Linux/Unix)
#   2. lsof command (BSD/macOS fallback)
#   3. fuser command (alternative to lsof)
# Args: $1 = worktree directory path
# Returns: 0 if in use, 1 if not in use
is_worktree_in_use() {
  local wt_dir="$1"
  [[ -d "$wt_dir" ]] || return 1

  # Method 1: Check /proc (Linux/Unix) for any process with CWD in this directory.
  # Match exact dir OR a path strictly under it ("$wt_dir"/*) — never a bare
  # prefix glob like "$wt_dir"*, which would match unrelated siblings such as
  # `…--s01-foo-extra` and falsely block cleanup of `…--s01-foo`.
  if [[ -d /proc ]]; then
    for proc_dir in /proc/*/cwd; do
      [[ -L "$proc_dir" ]] || continue
      local link_target
      link_target="$(readlink "$proc_dir" 2>/dev/null)" || continue
      if [[ "$link_target" == "$wt_dir" || "$link_target" == "$wt_dir"/* ]]; then
        return 0
      fi
    done
  fi

  # Method 2: Try lsof (macOS/BSD fallback)
  if command -v lsof >/dev/null 2>&1; then
    if lsof +D "$wt_dir" 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  # Method 3: fuser command (alternative to lsof)
  if command -v fuser >/dev/null 2>&1; then
    if fuser "$wt_dir" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# Look up a session id's handoff file under docs/roadmap/<epic>/
# Search the current epic's roadmap dir first (intra-epic dependency),
# then fall back to all epic dirs (cross-epic handoff).
find_handoff_for() {
  local pid="$1" padded
  padded="$(printf "%02d" "$pid")"
  for cand in "$REPO_ROOT/docs/roadmap/$EPIC_NAME_SLUG/session-${padded}-handoff.md"; do
    [[ -f "$cand" ]] && { echo "$cand"; return; }
  done
  for cand in "$REPO_ROOT/docs/roadmap/"*"/session-${padded}-handoff.md"; do
    [[ -f "$cand" ]] && { echo "$cand"; return; }
  done
}

# Build the multi-parent handoff section for a session.
# Emits the "## Previous Session Handoffs" header ONLY when at least one
# parent has a handoff file on disk. Without this guard, sessions whose
# parents declined to write a handoff (or whose handoff lives at a path
# find_handoff_for doesn't probe) saw an orphan header followed by the
# intro paragraph and no entries — a misleading prompt fragment that
# hinted at "memory of prior work" the model could not actually access.
build_handoff_section() {
  local deps_csv="$1"
  local entries="" pid path
  [[ "$deps_csv" == "-" || -z "$deps_csv" ]] && return
  IFS=',' read -ra parents <<< "$deps_csv"
  for pid in "${parents[@]}"; do
    path="$(find_handoff_for "$pid")"
    if [[ -n "$path" ]]; then
      entries+="
### From session $(printf '%02d' "$pid")  →  ${path/#$REPO_ROOT\//}

$(cat "$path")
"
    fi
  done
  [[ -z "$entries" ]] && return
  echo "
---

## Previous Session Handoffs

These handoff documents come from your DAG parents. Treat their file paths as
the only memory of prior work — you have no other recollection.
${entries}"
}

# Run a single AI-CLI pipe-invocation with optional progress stream.
# Args: <prompt_file> <log_file> <phase_label> <quiet:true|false> [session_id]
DISALLOWED_TOOLS="EnterPlanMode,ExitPlanMode,AskUserQuestion,EnterWorktree"

run_cli() {
  local prompt_file="$1" log_file="$2" phase_label="$3" quiet="${4:-false}" sid="${5:-0}"

  # Check for session-specific overrides
  local session_model="$MODEL"
  local session_cli="$CLI_CMD"
  if [[ "$sid" -gt 0 && -n "${SESSION_MODEL_BY_ID[$sid]:-}" ]]; then
    local raw_model="${SESSION_MODEL_BY_ID[$sid]}"
    session_model="$(map_model_shorthand "$raw_model" "$session_cli")"
  fi
  if [[ "$sid" -gt 0 && -n "${SESSION_CLI_BY_ID[$sid]:-}" ]]; then
    session_cli="${SESSION_CLI_BY_ID[$sid]}"
    # Re-map model if CLI changed (e.g. session overrides cli from opencode to claude
    # or vice versa — model shorthand depends on which CLI is in use).
    # Fall back to MODEL_RAW (the user-supplied form before the global map) so
    # we don't feed the opencode-style id `opencode/claude-sonnet-4` to claude
    # when the global cli was opencode but this session forces cli: claude.
    local raw_model_for_remap="${SESSION_MODEL_BY_ID[$sid]:-${MODEL_RAW:-$MODEL}}"
    session_model="$(map_model_shorthand "$raw_model_for_remap" "$session_cli")"
  fi

  # Build progress args (status file updates work even in quiet/parallel mode)
  local progress_args=(--log "$log_file" --phase "$phase_label")
  if [[ -n "${STATUS_FILE:-}" && -f "${STATUS_FILE:-}" && "$sid" -gt 0 ]]; then
    progress_args+=(--session-id "$sid" --status-file "$STATUS_FILE")
  fi

  # Build timeout wrapper if enabled
  local timeout_cmd=()
  if [[ "$TIMEOUT" -gt 0 ]]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd=(timeout $((TIMEOUT * 60)))
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd=(gtimeout $((TIMEOUT * 60)))
    else
      warn "timeout command not available, ignoring --timeout setting"
    fi
  fi

  # Build the model flag using session-specific model
  local model_flag=()
  if [[ "$session_cli" == "opencode" ]]; then
    if [[ -n "$session_model" ]]; then model_flag=(-m "$session_model"); fi
  else
    model_flag=(--model "$session_model")
  fi

  set +e
  if [[ -f "$PROGRESS_SCRIPT" ]]; then
    local stderr_tmp="${log_file%.log}-stderr.tmp"
    if [[ "$session_cli" == "claude" ]]; then
      # Claude Code with timeout wrapper
      if [[ "$quiet" == "false" ]]; then
        ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u CLAUDECODE claude -p \
          "${model_flag[@]}" \
          --dangerously-skip-permissions \
          --disallowedTools "$DISALLOWED_TOOLS" \
          --output-format stream-json \
          --verbose \
          < "$prompt_file" \
          2>"$stderr_tmp" \
          | "$PYTHON_CMD" "$PROGRESS_SCRIPT" "${progress_args[@]}"
      else
        ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u CLAUDECODE claude -p \
          "${model_flag[@]}" \
          --dangerously-skip-permissions \
          --disallowedTools "$DISALLOWED_TOOLS" \
          --output-format stream-json \
          --verbose \
          < "$prompt_file" \
          2>"$stderr_tmp" \
          | "$PYTHON_CMD" "$PROGRESS_SCRIPT" "${progress_args[@]}" 2>/dev/null
      fi
      local exit_code=${PIPESTATUS[0]}
      cat "$stderr_tmp" >> "$log_file" 2>/dev/null || true
      rm -f "$stderr_tmp"
    else
      # OpenCode with timeout wrapper
      if [[ "$quiet" == "false" ]]; then
        ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u OPENCODE_SESSION_ID opencode run "${model_flag[@]}" \
          --format json \
          --dangerously-skip-permissions \
          < "$prompt_file" \
          2>"$stderr_tmp" \
          | "$PYTHON_CMD" "$PROGRESS_SCRIPT" "${progress_args[@]}"
      else
        ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u OPENCODE_SESSION_ID opencode run "${model_flag[@]}" \
          --format json \
          --dangerously-skip-permissions \
          < "$prompt_file" \
          2>"$stderr_tmp" \
          | "$PYTHON_CMD" "$PROGRESS_SCRIPT" "${progress_args[@]}" 2>/dev/null
      fi
      local exit_code=${PIPESTATUS[0]}
      cat "$stderr_tmp" >> "$log_file" 2>/dev/null || true
      rm -f "$stderr_tmp"
    fi
  else
    # No progress script available
    if [[ "$session_cli" == "claude" ]]; then
      ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u CLAUDECODE claude -p \
        "${model_flag[@]}" \
        --dangerously-skip-permissions \
        --disallowedTools "$DISALLOWED_TOOLS" \
        < "$prompt_file" > "$log_file" 2>&1
      local exit_code=$?
    else
      ${timeout_cmd[@]+"${timeout_cmd[@]}"} env -u OPENCODE_SESSION_ID opencode run "${model_flag[@]}" \
        --format json \
        --dangerously-skip-permissions \
        < "$prompt_file" > "$log_file" 2>&1
      local exit_code=$?
    fi
  fi

  if [[ $exit_code -eq 124 ]]; then
    echo "ERROR: Session timed out after ${TIMEOUT}m" >> "$log_file"
  fi

  set -e
  return $exit_code
}

# Backward-compat alias
run_claude() { run_cli "$@"; }

# Atomically update one session's entry in the shared status JSON.
# Args: <status_file> <session_id> <new_status> [elapsed_seconds]
mark_session() {
  local sf="${1:-}" sid="$2" st="$3" elapsed="${4:-0}"
  [[ -z "$sf" || ! -f "$sf" ]] && return 0
  "$PYTHON_CMD" - "$sf" "$sid" "$st" "$elapsed" <<'PYEOF'
import sys, json, os, time
sf, sid, st = sys.argv[1], sys.argv[2], sys.argv[3]
elapsed = float(sys.argv[4]) if len(sys.argv) > 4 else 0
lock = sf + '.lock'
STALE_SECS = 60  # lock older than this was left by a SIGKILL'd process
for _ in range(200):
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd); break
    except (FileExistsError, OSError):
        try:
            if time.time() - os.path.getmtime(lock) > STALE_SECS:
                os.unlink(lock)
        except OSError:
            pass
        time.sleep(0.05)
else:
    sys.exit(0)
try:
    with open(sf, encoding='utf-8') as f: data = json.load(f)
    entry = data['sessions'].setdefault(sid, {})
    entry['status'] = st
    if st == 'running': entry['started_at'] = time.time()
    if elapsed > 0: entry['elapsed'] = elapsed
    tmp = sf + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f: json.dump(data, f, indent=2)
    os.replace(tmp, sf)
finally:
    try: os.unlink(lock)
    except: pass
PYEOF
}

# ---------------------------------------------------------------------------
# run_one_session — execute one session inside its dedicated worktree.
#
# Args (positional):
#   1: session id (int)
#   2: per-session worktree dir
#   3: friendly name (lowercase words)
#   4: handoff section text (may be empty)
#   5: quiet mode ("true" in parallel waves, "false" otherwise)
#
# Reads from globals: $TRUNK_SESSIONS_DIR, $OPERATOR_PROMPT, $SKIP_PLAN, $MODEL
# Writes plan/exec logs at $TRUNK_SESSIONS_DIR/.session-NN-{plan,exec}.log
# Writes plan markdown at $TRUNK_SESSIONS_DIR/.session-NN-plan.md
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------------
run_one_session() {
  local sid="$1" wt_dir="$2" friendly="$3" handoff_text="$4" quiet="$5"
  local fname="${SESSION_FILE_BASENAME[$sid]}"
  local session_path="$TRUNK_SESSIONS_DIR/$fname"
  # Use zero-padded sid for all artifact names so the writer and the
  # reader (write_epic_result / classify_error) agree on the filename.
  local padded_sid; padded_sid="$(printf '%02d' "$sid")"
  local plan_file="$TRUNK_SESSIONS_DIR/.session-${padded_sid}-plan.md"
  local plan_log="$TRUNK_SESSIONS_DIR/.session-${padded_sid}-plan.log"
  local exec_log="$TRUNK_SESSIONS_DIR/.session-${padded_sid}-exec.log"
  local session_prompt
  session_prompt="$(extract_prompt "$session_path")"
  if [[ -z "$session_prompt" ]]; then
    echo "ERROR: could not extract prompt from $session_path" > "$exec_log"
    return 2
  fi

  local prev_cwd; prev_cwd="$(pwd)"
  cd "$wt_dir"

  # ── Resume support ──────────────────────────────────────────────────
  # Two levels of caching, both controlled by --fresh:
  #
  # 1. Skip the entire session if a successful commit already exists on
  #    the current branch. Detection delegates to session_completed_on_branch
  #    so it tolerates AI subject-line variation (em-dash vs hyphen vs
  #    colon) and Git Bash on Windows where regex multibyte handling is
  #    unreliable. Partial-commits use `feat(partial):` and are NOT
  #    matched, so they correctly trigger a re-run.
  # 2. Reuse a cached plan file if it exists, is non-empty, and is
  #    newer than the session prompt. The mtime check ensures that
  #    edits to the session prompt invalidate the cached plan.
  local plan_cached=false
  if ! $FRESH; then
    if session_completed_on_branch "$sid" HEAD "$wt_dir"; then
      log "  ✓ session ${padded_sid} already committed on this branch — skipping (use --fresh to force re-run)"
      cd "$prev_cwd"
      return 0
    fi
    if ! $SKIP_PLAN && [[ -s "$plan_file" && "$plan_file" -nt "$session_path" ]]; then
      plan_cached=true
    fi
  fi
  # ────────────────────────────────────────────────────────────────────

  local rc=0
  local attempt=1
  local max_attempts=$((RETRY + 1))

  # Capture worktree HEAD before the session runs so we can detect a
  # no-op completion below: a model that returns rc=0 without creating
  # any files, modifying anything, or committing — the session did
  # nothing and must not be reported as success.
  local baseline_head
  baseline_head="$(git rev-parse HEAD 2>/dev/null || echo "")"

  while [[ $attempt -le $max_attempts ]]; do
    rc=0
    if [[ $attempt -gt 1 ]]; then
      echo "Retry attempt $attempt of $max_attempts" >> "$exec_log"
    fi

    if $SKIP_PLAN; then
      local prompt; prompt="$(cat <<SINGLE_EOF
Execute Session ${sid}. Read referenced files and handoff docs, implement, commit.

OPERATOR RULES:
$OPERATOR_PROMPT

SESSION INSTRUCTIONS:
$session_prompt
$handoff_text

DO:
1. Read all referenced files and handoff docs.
2. Implement everything — no TBDs/TODOs.
3. Run all CI checks. Create the handoff doc if required.
4. Stage and commit ALL changes:
   git add -A
   git commit -m "feat: Session ${sid} — ${friendly}"
SINGLE_EOF
)"
      local prompt_file; prompt_file="$(mktemp)"
      echo "$prompt" > "$prompt_file"
      run_claude "$prompt_file" "$exec_log" "S${sid}-EXEC" "$quiet" "$sid" || rc=$?
      rm -f "$prompt_file"
    else
      # PLAN pass — skipped entirely if a fresh cached plan exists.
      if $plan_cached; then
        local plan_size; plan_size="$(wc -c < "$plan_file" | tr -d ' ')"
        log "  ↻ session ${padded_sid}: reusing cached plan (${plan_size} bytes, mtime newer than prompt)"
      else
        local plan_prompt; plan_prompt="$(cat <<PLAN_EOF
Read-only planning for Session ${sid}. Do NOT modify source, tests, or docs.

OPERATOR RULES:
$OPERATOR_PROMPT

SESSION INSTRUCTIONS:
$session_prompt
$handoff_text

TASK: Write an implementation plan to ${plan_file} containing:
- Files to create/modify (full paths)
- Design decisions and rationale
- Risks and mitigations
- Verification steps (tests, CI commands)
- Exact order of operations

Write the plan and finish. Do not wait for approval.
PLAN_EOF
)"
        local prompt_file; prompt_file="$(mktemp)"
        echo "$plan_prompt" > "$prompt_file"
        if ! run_claude "$prompt_file" "$plan_log" "S${sid}-PLAN" "$quiet" "$sid"; then
          rc=1
        else
          rm -f "$prompt_file"
          if [[ ! -f "$plan_file" ]]; then
            echo "ERROR: plan phase finished but plan file was not created: $plan_file" >> "$exec_log"
            rc=1
          fi
        fi
        rm -f "$prompt_file"
      fi

      # EXECUTE pass — runs whenever we have a usable plan, whether
      # it was just generated or pulled from cache.
      if [[ $rc -eq 0 ]]; then
        local plan_contents; plan_contents="$(cat "$plan_file")"
        local exec_prompt; exec_prompt="$(cat <<EXEC_EOF
Execute Session ${sid} using the plan below. Implement fully — no TBDs/TODOs, no re-exploration.

OPERATOR RULES:
$OPERATOR_PROMPT

SESSION INSTRUCTIONS:
$session_prompt
$handoff_text

PLAN:
$plan_contents

DO:
1. Implement everything in the plan.
2. Run all CI checks the plan calls for.
3. Create the handoff doc if required.
4. Stage and commit ALL changes:
   git add -A
   git commit -m "feat: Session ${sid} — ${friendly}"

Commit with descriptive message. Execute immediately.
EXEC_EOF
)"
        prompt_file="$(mktemp)"
        echo "$exec_prompt" > "$prompt_file"
        run_claude "$prompt_file" "$exec_log" "S${sid}-EXEC" "$quiet" "$sid" || rc=$?
        rm -f "$prompt_file"
      fi
    fi

    # Break on success or final attempt
    if [[ $rc -eq 0 || $attempt -eq $max_attempts ]]; then
      break
    fi

    attempt=$((attempt + 1))
    echo "Session failed, retrying in 5 seconds..." >> "$exec_log"
    sleep 5
  done

  # Auto-commit fallback inside the session worktree with timeout.
  # Runs regardless of rc — if Claude created files but didn't commit
  # (timeout, error, or model just forgot the final step), we capture
  # the work rather than lose it. The merge step later validates via
  # build/test gates.
  if $AUTO_COMMIT; then
    if ! git diff --quiet HEAD 2>/dev/null \
       || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
      git add -A
      # Distinguish auto-recovered work from successful sessions
      local commit_subject="feat: Session ${sid} — ${friendly}"
      local commit_note="Automated execution of $fname."
      if [[ $rc -ne 0 ]]; then
        commit_subject="feat(partial): Session ${sid} — ${friendly}"
        commit_note="Auto-recovered after session exited rc=$rc. Files were created but session did not commit them. Verify before merging."
      fi
      # Use timeout/gtimeout when available to prevent git commit hanging on index.lock.
      # Stock macOS has neither; in that case, run git commit directly so the
      # fallback still captures work instead of failing with command-not-found.
      local commit_timeout_cmd=()
      if command -v timeout >/dev/null 2>&1; then
        commit_timeout_cmd=(timeout 60)
      elif command -v gtimeout >/dev/null 2>&1; then
        commit_timeout_cmd=(gtimeout 60)
      fi
      if ${commit_timeout_cmd[@]+"${commit_timeout_cmd[@]}"} git commit -q -m "$commit_subject

$commit_note

Co-Authored-By: AI <noreply@ai>" 2>/dev/null; then
        if [[ $rc -ne 0 ]]; then
          warn "  ⚠ session $sid auto-recovered uncommitted work (rc=$rc)"
        fi
      else
        warn "git commit timed out or failed (index.lock contention); continuing"
      fi
    fi
  fi

  # No-op session guard. If the underlying CLI returned success but the
  # session produced nothing — no new commits beyond baseline, no diff,
  # no untracked files — we must NOT report success. Most commonly seen
  # when the model aborts early (oversized prompt, transient API issue)
  # but the wrapper still exits 0. Reporting success here corrupts the
  # epic: dependent sessions read missing artifacts and either stub out
  # or compound the failure.
  if [[ $rc -eq 0 && -n "$baseline_head" ]]; then
    local current_head
    current_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
    if [[ "$current_head" == "$baseline_head" ]] \
       && git diff --quiet HEAD 2>/dev/null \
       && [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
      echo "ERROR: session $sid completed with rc=0 but produced no output (no commits, no diff, no untracked files). Treating as failure." >> "$exec_log"
      warn "  ⚠ session $sid produced no output — marking failed (likely model no-op)"
      rc=99
    fi
  fi

  cd "$prev_cwd"
  return $rc
}
