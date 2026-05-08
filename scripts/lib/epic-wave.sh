#!/usr/bin/env bash
# epic-wave.sh — Wave scheduling utilities for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

format_elapsed() {
  local s=$1
  printf "%dm%02ds" $((s / 60)) $((s % 60))
}

# Recursive SIGKILL — pkill -P only walks one level, so `timeout`
# wrapper grandchildren leak as orphans burning API tokens. (bug-073)
kill_tree() {
  local _pid="$1"
  [[ -z "$_pid" ]] && return 0
  local _child
  for _child in $(pgrep -P "$_pid" 2>/dev/null); do
    kill_tree "$_child"
  done
  kill -9 "$_pid" 2>/dev/null || true
}

# Append to MERGED_SESSIONS; warn and skip if filename is empty.
add_merged_session() {
  local sid="$1"
  local fname="${SESSION_FILE_BASENAME[$sid]:-}"
  if [[ -z "$fname" ]]; then
    warn "  ⚠ session $(printf '%02d' "$sid") has no filename in SESSION_FILE_BASENAME; skipping from merge summary"
    return
  fi
  MERGED_SESSIONS+=("$sid $fname")
}

reap_finished_jobs() {
  local i new_pids=() new_sids=()
  for i in "${!JOB_PIDS[@]}"; do
    local pid="${JOB_PIDS[$i]}"
    # State column distinguishes vanished (empty) from zombie (Z*) —
    # kill -0 / bare ps -p succeed for both.
    local pstate
    pstate="$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$pstate" || "$pstate" == Z* ]]; then
      local rc=0
      wait "$pid" || rc=$?
      local sid="${JOB_SIDS[$i]}"
      local elapsed=$(( $(date +%s) - ${SESSION_START_TS[$sid]:-0} ))
      SESSION_ELAPSED_BY_ID[$sid]=$elapsed
      SESSION_EXIT_BY_ID[$sid]=$rc
      if [[ $rc -eq 0 ]]; then
        SESSION_STATUS[$sid]="done"
        mark_session "${STATUS_FILE:-}" "$sid" "done" "$elapsed"
        ! $LIVE_UI && ok "  ✓ session $(printf '%02d' "$sid") (${SESSION_SLUG_BY_ID[$sid]}) finished in $(format_elapsed "$elapsed")"
      else
        SESSION_STATUS[$sid]="failed"
        mark_session "${STATUS_FILE:-}" "$sid" "failed" "$elapsed"
        ! $LIVE_UI && err "  ✗ session $(printf '%02d' "$sid") (${SESSION_SLUG_BY_ID[$sid]}) FAILED in $(format_elapsed "$elapsed") (exit $rc)"
      fi
    else
      new_pids+=("$pid")
      new_sids+=("${JOB_SIDS[$i]}")
    fi
  done
  if [[ ${#new_pids[@]} -gt 0 ]]; then
    JOB_PIDS=("${new_pids[@]}")
    JOB_SIDS=("${new_sids[@]}")
  else
    JOB_PIDS=()
    JOB_SIDS=()
  fi
}
