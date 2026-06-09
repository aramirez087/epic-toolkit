#!/usr/bin/env bash
# epic-result.sh — Result reporting functions for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

# ---------------------------------------------------------------------------
# Error classification — determine why a session failed
# ---------------------------------------------------------------------------
classify_error() {
  local log_file="$1" exit_code="$2"
  rm -f "${log_file}.errtype"

  if [[ "$exit_code" -eq 124 ]]; then
    echo "timeout"
    return
  fi

  # 137 = SIGKILL from the wave-timeout reaper. (bug-115)
  if [[ "$exit_code" -eq 137 ]]; then
    printf '%s\n' "killed by wave timeout (SIGKILL)" > "${log_file}.errtype"
    echo "wave_timeout"
    return
  fi

  if [[ "$exit_code" -eq 99 ]]; then
    echo "no_output"
    return
  fi

  if [[ "$exit_code" -eq 97 ]]; then
    # Slurp the validator's ERROR header + indented `  - <path>` lines
    # so error_detail names the missing files. Scope to the last marker:
    # persisted logs from older runs can contain stale validation blocks.
    # Claude's prose can include unrelated `ERROR: ...` strings. (bugs 106, 109, 125)
    local err_msg
    err_msg="$(awk '
      function finish_block() {
        if (f && header_done) {
          last = paths ? header ": " paths : header
        }
        f = 0
        header_done = 0
        header = ""
        paths = ""
      }
      /^=== deliverables validation failed \(rc=/ {
        finish_block()
        f = 1
        next
      }
      f && header_done && /^  - / {
        sub(/^  - /, "")
        paths = paths (paths ? "; " : "") $0
        next
      }
      f && header_done {
        finish_block()
        next
      }
      f && /^ERROR: / {
        sub(/^ERROR: /, "")
        header = $0
        sub(/:[[:space:]]*$/, "", header)
        header_done = 1
        next
      }
      END {
        finish_block()
        if (last) print last
      }
    ' "$log_file" 2>/dev/null)"
    if [[ -n "$err_msg" ]]; then
      printf '%s\n' "$err_msg" > "${log_file}.errtype"
    fi
    echo "deliverables_failure"
    return
  fi

  if grep -q "ERROR: could not extract prompt" "$log_file" 2>/dev/null; then
    echo "prompt_error"
    return
  fi

  if grep -q "ERROR: plan phase finished but plan file was not created" "$log_file" 2>/dev/null; then
    echo "plan_failure"
    return
  fi

  if grep -qi "merge conflict" "$log_file" 2>/dev/null; then
    echo "merge_conflict"
    return
  fi

  if grep -qE '^\[ERROR\]' "$log_file" 2>/dev/null; then
    # No pre-escape — json.dump handles it; double-encoding leaks
    # literal backslashes into error_detail.
    local err_msg
    err_msg="$(grep -oE '^\[ERROR\] .+' "$log_file" | head -1 | sed 's/^\[ERROR\] //')"
    echo "cli_error"
    printf '%s\n' "$err_msg" > "${log_file}.errtype"
    return
  fi

  if grep -qE '(exit code|returned|fatal|Segmentation|Killed|out of memory|OOM)' "$log_file" 2>/dev/null; then
    echo "cli_crash"
    return
  fi

  echo "unknown"
}

# ---------------------------------------------------------------------------
# Generate epic result file and structured output block for orchestrator
# ---------------------------------------------------------------------------
write_epic_result() {
  local epic_status="$1"
  # Result file lives outside the repo so external watchers see a stable
  # completion sentinel that survives cleanup + worktree teardown.
  # Persisted on success AND failure. Override via EPIC_RESULT_DIR.
  local result_dir="${EPIC_RESULT_DIR:-${TMPDIR:-/tmp}/epic-toolkit}"
  mkdir -p "$result_dir" 2>/dev/null || true
  local repo_id
  repo_id="$(basename "${ORIG_REPO_ROOT:-$REPO_ROOT}")"
  local result_file="${result_dir}/${repo_id}--${EPIC_NAME_SLUG}.result.json"
  EPIC_RESULT_FILE="$result_file"
  local result_wave
  if $EPIC_FAILED; then result_wave="$wn"; else result_wave="$WAVE_COUNT"; fi

  local start_ts="$EPIC_START_TS"
  local end_ts
  end_ts="$(date +%s)"
  local runtime=$(( end_ts - start_ts ))

  # Iterate actual DAG ids (not 1..999) so id-gaps and unreached waves
  # both appear in the report.
  local tmp_data
  tmp_data="$(mktemp)"
  local _sids_sorted
  _sids_sorted="$(printf '%s\n' "${!SESSION_SLUG_BY_ID[@]}" | sort -n)"
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    local padded
    padded="$(printf '%02d' "$sid")"
    local key="session-${padded}"
    local status="${SESSION_STATUS[$sid]:-pending}"
    local slug="${SESSION_SLUG_BY_ID[$sid]:-unknown}"
    local elapsed="${SESSION_ELAPSED_BY_ID[$sid]:-0}"
    local exit_code="${SESSION_EXIT_BY_ID[$sid]:-0}"
    local error_type="none"
    local log_path="$TRUNK_SESSIONS_DIR/.session-${padded}-exec.log"
    local stderr_path="$TRUNK_SESSIONS_DIR/.session-${padded}-exec.log.errtype"

    if [[ "$status" == "failed" ]]; then
      error_type="$(classify_error "$TRUNK_SESSIONS_DIR/.session-${padded}-exec.log" "$exit_code")"
    fi

    echo "${key}|${status}|${slug}|${elapsed}|${exit_code}|${error_type}|${log_path}|${stderr_path}" >> "$tmp_data"
  done <<< "$_sids_sorted"

  local tmp_merged
  tmp_merged="$(mktemp)"
  for entry in "${MERGED_SESSIONS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    echo "$entry" >> "$tmp_merged"
  done

  local first_failed="null"
  if [[ -n "$FIRST_FAILED_ID" ]]; then
    local padded_ff
    padded_ff="$(printf '%02d' "$FIRST_FAILED_ID")"
    first_failed="\"session-${padded_ff}\""
  fi

  local epic_status_lower
  if [[ "$epic_status" == "success" ]]; then
    epic_status_lower="success"
  else
    epic_status_lower="failed"
  fi

  EPIC_NAME="$EPIC_NAME_SLUG" EPIC_STATUS="$epic_status_lower" \
  RESULT_WAVE="$result_wave" RUNTIME_SECS="$runtime" \
  START_TS="$start_ts" END_TS="$end_ts" \
  FIRST_FAILED="$first_failed" \
    "$PYTHON_CMD" - "$result_file" "$tmp_data" "$tmp_merged" <<'PYEOF_RESULT'
import json, os, sys

data = {
    'epic':           os.environ['EPIC_NAME'],
    'status':         os.environ['EPIC_STATUS'],
    'first_failed_id': json.loads(os.environ['FIRST_FAILED']),
    'sessions':       {},
    'merged_sessions': [l.strip() for l in open(sys.argv[3], encoding='utf-8') if l.strip()],
    'wave':           int(os.environ['RESULT_WAVE']),
    'runtime_seconds': int(os.environ['RUNTIME_SECS']),
    'started_at':     int(os.environ['START_TS']),
    'ended_at':       int(os.environ['END_TS']),
}

with open(sys.argv[2], encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('|')
        sid = parts[0]
        status = parts[1]
        slug = parts[2]
        elapsed = int(parts[3]) if len(parts) > 3 else 0
        entry = {'status': status, 'slug': slug, 'elapsed': elapsed}
        if status == 'failed':
            entry['exit_code'] = int(parts[4]) if len(parts) > 4 else 1
            entry['error_type'] = parts[5] if len(parts) > 5 else 'unknown'
            entry['log_path'] = parts[6] if len(parts) > 6 else ''
            stderr_path = parts[7] if len(parts) > 7 else ''
            if stderr_path:
                try:
                    with open(stderr_path, encoding='utf-8') as ef:
                        entry['error_detail'] = ef.read().strip()
                except Exception:
                    pass
        data['sessions'][sid] = entry

with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
PYEOF_RESULT

  rm -f "$tmp_data" "$tmp_merged"

  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    rm -f "$TRUNK_SESSIONS_DIR/.session-$(printf '%02d' "$sid")-exec.log.errtype"
  done <<< "$_sids_sorted"

  # Emit RESULT_FILE so command docs read the path from the script's
  # output rather than re-stating it (kept in sync this way).
  echo ""
  echo "[EPIC_RESULT_START]"
  echo "RESULT_FILE=$result_file"
  "$PYTHON_CMD" - "$result_file" <<'PYEOF_PRINT'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
if data['status'] == 'failed':
    print('STATUS=failed')
    print('FIRST_FAILED=' + str(data['first_failed_id']))
    print('WAVE=' + str(data['wave']))
    print('RUNTIME=' + str(data['runtime_seconds']) + 's')
    for sid, sdata in data['sessions'].items():
        if sdata['status'] == 'failed':
            print('SESSION_FAIL=' + sid + ' error=' + sdata.get('error_type','unknown') + ' exit=' + str(sdata.get('exit_code',0)) + ' log=' + sdata.get('log_path',''))
            if sdata.get('error_detail'):
                print('ERROR_DETAIL=' + sdata['error_detail'])
else:
    print('STATUS=success')
    print('SESSIONS_COMPLETED=' + str(len(data['sessions'])))
    print('RUNTIME=' + str(data['runtime_seconds']) + 's')
PYEOF_PRINT
  echo "[EPIC_RESULT_END]"
  echo ""
}
