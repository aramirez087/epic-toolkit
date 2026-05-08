#!/usr/bin/env bash
# epic-session.sh — Session execution functions for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

# Extract prompt between ```md fences. A depth counter tracks inner
# language-tagged code blocks so their closer doesn't silently truncate
# the capture. CRLF is normalised before any anchored compare. (bug-024)
extract_prompt() {
  local file="$1" content
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
    # Fallback: strip frontmatter + title line. awaiting_title only
    # spans frontmatter-close → first non-blank body line, so later
    # `# Heading`s aren't stripped. (bug-034, bug-155)
    content="$(awk '
      BEGIN { in_fm=0; awaiting_title=1 }
      { sub(/\r$/, "") }
      NR==1 { sub(/^\357\273\277/, "") }
      NR==1 && /^---$/ { in_fm=1; awaiting_title=0; next }
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

# Returns 0 if any process has CWD inside $1. /proc → lsof → fuser.
is_worktree_in_use() {
  local wt_dir="$1"
  [[ -d "$wt_dir" ]] || return 1

  # Anchor the separator — bare prefix glob would match `…-foo-extra`. (bug-022)
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

  if command -v lsof >/dev/null 2>&1; then
    if lsof +D "$wt_dir" 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  if command -v fuser >/dev/null 2>&1; then
    if fuser "$wt_dir" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# Look up a parent session's handoff. Intra-epic only — a cross-epic
# fallback would inject an unrelated epic's artifact as "memory of
# prior work". (bug-159)
find_handoff_for() {
  local pid="$1" padded cand
  padded="$(printf "%02d" "$pid")"
  cand="$REPO_ROOT/docs/roadmap/$EPIC_NAME_SLUG/session-${padded}-handoff.md"
  [[ -f "$cand" ]] && echo "$cand"
}

# Build the parent-handoff section. Emits header only when at least one
# parent has a handoff on disk — orphan headers mislead the model.
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
    # Re-map from MODEL_RAW so a session overriding cli doesn't inherit
    # the already-mapped id from the wrong CLI.
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
    # Coerce non-dict shapes at every level — dict.get default only
    # fires on absent keys, not null values. (bug-186)
    if not isinstance(data, dict):
        data = {}
    sessions_obj = data.get('sessions')
    if not isinstance(sessions_obj, dict):
        sessions_obj = {}
        data['sessions'] = sessions_obj
    entry = sessions_obj.get(sid)
    if not isinstance(entry, dict):
        entry = {}
        sessions_obj[sid] = entry
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
# Writes plan markdown at $TRUNK_SESSIONS_DIR/.session-NN-plan.md (mirrored
# from the session worktree; see plan_file_session below).
# Returns: 0 on success, non-zero on failure.
# ---------------------------------------------------------------------------
run_one_session() {
  local sid="$1" wt_dir="$2" friendly="$3" handoff_text="$4" quiet="$5"
  local fname="${SESSION_FILE_BASENAME[$sid]}"
  local session_path="$TRUNK_SESSIONS_DIR/$fname"
  local padded_sid; padded_sid="$(printf '%02d' "$sid")"
  # Plan written inside session worktree, then mirrored to trunk.
  # claude -p won't write to absolute paths in a sibling worktree. (bug-110)
  local plan_basename=".session-${padded_sid}-plan.md"
  local plan_file="$TRUNK_SESSIONS_DIR/$plan_basename"
  local plan_file_session="$wt_dir/$plan_basename"
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

  # Resume: skip session if already committed; reuse plan if newer
  # than prompt. Both gated by --fresh.
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

  # Baseline for the no-op detector below.
  local baseline_head
  baseline_head="$(git rev-parse HEAD 2>/dev/null || echo "")"

  # Cross-repo: snapshot HEAD of every external git repo referenced by
  # this session's `produces:` / `touches:` frontmatter, so the no-op
  # guard and the deliverables validator can both reason about
  # sibling-repo work (e.g. `produces: [../masterSignalR-clone/Foo.cs]`).
  # Path resolution is anchored at ORIG_REPO_ROOT — the user's original
  # repo, not this per-session worktree — to match how authors mentally
  # write `../sibling/...` when designing the epic.
  local ext_baselines_file="$TRUNK_SESSIONS_DIR/.session-${padded_sid}-external-baselines.json"
  local ext_helper="$CLAUDE_PLUGIN_ROOT/scripts/epic-external-baselines.py"
  if [[ -f "$ext_helper" && -n "${ORIG_REPO_ROOT:-}" ]]; then
    # --warn surfaces per-decl classification failures (e.g. sibling
    # directory missing or not in a git repo) into the exec log at
    # session start, instead of leaving them buried in the JSON
    # sidecar's `warnings` field where the user only sees a downstream
    # "not in session diff" with no diagnostic.
    if ! "$PYTHON_CMD" "$ext_helper" snapshot \
         --session-md "$session_path" \
         --orig-repo-root "$ORIG_REPO_ROOT" \
         --output "$ext_baselines_file" \
         --warn 2>>"$exec_log"; then
      warn "  ⚠ session $sid: external baseline snapshot failed (continuing; cross-repo deliverables won't be validated)"
      rm -f "$ext_baselines_file"
    fi
  fi

  while [[ $attempt -le $max_attempts ]]; do
    rc=0
    if [[ $attempt -gt 1 ]]; then
      echo "Retry attempt $attempt of $max_attempts" >> "$exec_log"
      # Recheck plan cache — if plan succeeded but exec failed, reuse it. (bug-088)
      if ! $plan_cached && ! $SKIP_PLAN && [[ -s "$plan_file" && "$plan_file" -nt "$session_path" ]]; then
        plan_cached=true
        log "  ↻ session ${padded_sid}: reusing plan from prior attempt on retry"
      fi
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

TASK: Write an implementation plan to ${plan_file_session} containing:
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
          if [[ ! -s "$plan_file_session" ]]; then
            echo "ERROR: plan phase finished but plan file was not created or is empty: $plan_file_session" >> "$exec_log"
            rc=1
          else
            # Mirror to trunk so resume finds it after worktree teardown;
            # drop the session-local copy so exec's `git add -A` skips it.
            mkdir -p "$(dirname "$plan_file")"
            cp -p "$plan_file_session" "$plan_file"
            rm -f "$plan_file_session"
          fi
        fi
        rm -f "$prompt_file"
      fi

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

  # Auto-commit fallback — runs regardless of rc so files survive even
  # when Claude exited without committing. Merge step still validates.
  if $AUTO_COMMIT; then
    if ! git diff --quiet HEAD 2>/dev/null \
       || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
      git add -A
      local commit_subject="feat: Session ${sid} — ${friendly}"
      local commit_note="Automated execution of $fname."
      if [[ $rc -ne 0 ]]; then
        commit_subject="feat(partial): Session ${sid} — ${friendly}"
        commit_note="Auto-recovered after session exited rc=$rc. Files were created but session did not commit them. Verify before merging."
      fi
      # timeout if available — bare commit can hang on index.lock.
      # Stock macOS has neither timeout nor gtimeout; fall through. (bug-038)
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

  # No-op guard: rc=0 + zero output = treat as failure. Otherwise
  # dependent sessions read missing artifacts. A session that committed
  # only into a sibling repo is NOT a no-op — the external-baselines
  # check below reads the per-repo HEAD snapshots captured at session
  # start and accepts movement in any of them.
  if [[ $rc -eq 0 && -n "$baseline_head" ]]; then
    local current_head
    current_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
    local internal_noop="false"
    if [[ "$current_head" == "$baseline_head" ]] \
       && git diff --quiet HEAD 2>/dev/null \
       && [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
      internal_noop="true"
    fi
    local external_noop="true"
    if [[ "$internal_noop" == "true" && -f "$ext_baselines_file" && -f "$ext_helper" ]]; then
      # Only spend the subprocess when the worktree itself looks empty —
      # otherwise the session clearly did something internally and we
      # don't need to interrogate siblings.
      local ext_check_out
      ext_check_out="$("$PYTHON_CMD" "$ext_helper" advanced --baselines "$ext_baselines_file" 2>/dev/null || echo "no")"
      [[ "$ext_check_out" == "yes" ]] && external_noop="false"
    fi
    if [[ "$internal_noop" == "true" && "$external_noop" == "true" ]]; then
      echo "ERROR: session $sid completed with rc=0 but produced no output (no commits, no diff, no untracked files in epic worktree, and no external-repo HEAD movement). Treating as failure." >> "$exec_log"
      warn "  ⚠ session $sid produced no output — marking failed (likely model no-op)"
      rc=99
    fi
  fi

  # Deliverables validator: catches sessions that committed only handoff
  # docs + .wolf/* metadata. Opt out with `skip_deliverables_check: true`.
  # We intentionally do NOT gate this on internal-HEAD-advance: a session
  # that did all its real work in a sibling repo (and so left the epic
  # worktree HEAD untouched) still needs to have its declared deliverables
  # checked there. The no-op guard above already short-circuits truly
  # empty sessions to rc=99 before we get here.
  if [[ $rc -eq 0 && -n "$baseline_head" ]]; then
    local validator="$CLAUDE_PLUGIN_ROOT/scripts/validate-session-deliverables.py"
    if [[ -f "$validator" ]]; then
      local validate_err; validate_err="$(mktemp)"
      local vrc=0
      local validator_args=("$session_path" "$wt_dir" "$baseline_head")
      if [[ -f "$ext_baselines_file" ]]; then
        validator_args+=(--external-baselines "$ext_baselines_file")
      fi
      "$PYTHON_CMD" "$validator" "${validator_args[@]}" \
          >>"$exec_log" 2>"$validate_err" || vrc=$?
      if [[ $vrc -ne 0 ]]; then
        {
          echo ""
          echo "=== deliverables validation failed (rc=$vrc) ==="
          cat "$validate_err"
        } >> "$exec_log"
        warn "  ⚠ session $sid deliverables validation failed (see ${exec_log/#$REPO_ROOT\//})"
        rc=97
      fi
      rm -f "$validate_err"
    fi
  fi

  cd "$prev_cwd"
  return $rc
}
