#!/usr/bin/env bash
# epic-wave.sh — Wave scheduling utilities for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

format_elapsed() {
  local s=$1
  printf "%dm%02ds" $((s / 60)) $((s % 60))
}

# Recursively SIGKILL a process and all its descendants. `pkill -P` only
# matches DIRECT children, so when --timeout wraps the CLI (subshell →
# `timeout` → `claude`), pkill -P kills `timeout` and leaves `claude`
# orphaned to PID 1, where it keeps burning API tokens. Walk the tree
# leaves-first via pgrep -P so grandchildren are reaped before their
# parents disappear. Silent and best-effort: missing pgrep / vanished
# pids are treated as no-ops, never as errors. (bug-073)
# Args: $1 = root pid
kill_tree() {
  local _pid="$1"
  [[ -z "$_pid" ]] && return 0
  local _child
  for _child in $(pgrep -P "$_pid" 2>/dev/null); do
    kill_tree "$_child"
  done
  kill -9 "$_pid" 2>/dev/null || true
}

# Safely add session to MERGED_SESSIONS with validation.
# Ensures SESSION_FILE_BASENAME is populated; warns and skips if not.
# Args: $1 = session id
add_merged_session() {
  local sid="$1"
  local fname="${SESSION_FILE_BASENAME[$sid]:-}"
  if [[ -z "$fname" ]]; then
    warn "  ⚠ session $(printf '%02d' "$sid") has no filename in SESSION_FILE_BASENAME; skipping from merge summary"
    return
  fi
  MERGED_SESSIONS+=("$sid $fname")
}

# Reap any finished jobs from JOB_PIDS[]/JOB_SIDS[], updating SESSION_STATUS.
# Uses JOB_PIDS[], JOB_SIDS[] (re-initialised per wave) and
# SESSION_STATUS[], SESSION_ELAPSED_BY_ID[], SESSION_EXIT_BY_ID[] (global).
reap_finished_jobs() {
  local i new_pids=() new_sids=()
  for i in "${!JOB_PIDS[@]}"; do
    local pid="${JOB_PIDS[$i]}"
    # Reap if the process is gone OR is a zombie. `kill -0` and bare `ps -p`
    # both return success for zombies, so neither alone catches an exited
    # child whose status we haven't yet collected. Reading the process state
    # column distinguishes them: empty = vanished, leading 'Z' = zombie.
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
