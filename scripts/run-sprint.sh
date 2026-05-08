#!/usr/bin/env bash
# run-sprint.sh — Multi-epic sprint orchestrator. Runs N epics sequentially
# on a shared trunk branch and produces one PR for the whole sprint.
#
# Each epic in the sprint runs as a separate `run-sessions.sh` invocation
# in series — never in parallel. Epic N+1 only starts after epic N exits.
# Every epic shares the same `--branch`, so the trunk branch grows commit
# by commit across the sprint and dependent epics see their predecessors'
# work. To avoid one stray PR per epic, --no-pr is forwarded to every
# epic except the final one — the last epic's run-sessions.sh creates a
# single PR for the full merged branch.
#
# Layout (with --branch epic/<sprint>):
#   .epic-worktrees/<repo>/epic--<sprint>/  ← shared trunk worktree, recreated
#                                              by each epic in turn (the prior
#                                              one is cleaned up before the
#                                              next starts).
#
# Usage:
#   run-sprint.sh --sprint-config <path.json> [pass-through opts]
#   run-sprint.sh <epic-dir> [<epic-dir> ...] --branch <name> [pass-through opts]
#
# sprint.json schema:
#   { "sprint": "<name>",
#     "branch": "epic/<name>",
#     "epics": [ { "dir": "docs/claude-sessions/foo/", "model": "opus" }, ... ] }
#
# Options (sprint-level):
#   --sprint-config FILE    Read epic list + per-epic models from sprint.json
#   --branch NAME           Shared trunk branch (overrides sprint.json branch)
#   --base BRANCH           Base branch for trunk (default: repo default)
#   --model MODEL           Default model when an epic has no per-epic override
#   --cli CMD               Force CLI (claude or opencode) for every epic
#   --continue-on-failure   Run later epics even if one fails (default: stop)
#   --no-final-pr           Never create the final PR (--no-pr for every epic)
#   --dry-run               Forward --dry-run to every epic and exit cleanly
#   -h, --help              Show this help
#
# Pass-through (forwarded verbatim to every run-sessions.sh invocation):
#   --timeout MINS, --retry N, --max-parallel N, --wave-timeout MINS,
#   --strict, --sequential, --skip-plan, --no-worktree, --no-rebase,
#   --no-commit, --no-pr, --keep-worktree, --keep-session-worktrees,
#   --keep-session-docs, --fresh, --show-dag
#
# Value-bearing flags accept both `--flag VALUE` and `--flag=VALUE` forms.
# The `=` form is normalized before forwarding so run-sessions.sh (which
# accepts only the space form) sees what it expects.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[sprint]${NC} $*"; }
ok()   { echo -e "${GREEN}[sprint]${NC} $*"; }
warn() { echo -e "${YELLOW}[sprint]${NC} $*" >&2; }
err()  { echo -e "${RED}[sprint]${NC} $*" >&2; }

usage() {
  sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# Locate run-sessions.sh next to us.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-sessions.sh"
if [[ ! -f "$RUNNER" ]]; then
  err "Cannot find runner: $RUNNER"
  exit 1
fi

PYTHON_CMD=""
for _py in python3 python; do
  if command -v "$_py" >/dev/null 2>&1; then
    PYTHON_CMD="$_py"
    break
  fi
done
unset _py

# --- Parse arguments ---
SPRINT_CONFIG=""
EPIC_DIRS=()
BRANCH=""
BASE_BRANCH=""
GLOBAL_MODEL=""
CLI_OVERRIDE=""
CONTINUE_ON_FAILURE=false
NO_FINAL_PR=false
DRY_RUN=false
PASS_THROUGH=()

# Guard `$2` for value-bearing flags so missing values produce a
# clear diagnostic instead of `set -u`'s opaque error. (bug-200)
require_flag_value() {
  if (( $# < 2 )); then
    err "Missing value for $1"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    # Sprint-level value flags accept both `--flag value` and `--flag=value`.
    --sprint-config)        require_flag_value "$@"; SPRINT_CONFIG="$2"; shift 2 ;;
    --sprint-config=*)      SPRINT_CONFIG="${1#*=}"; shift ;;
    --branch)               require_flag_value "$@"; BRANCH="$2"; shift 2 ;;
    --branch=*)             BRANCH="${1#*=}"; shift ;;
    --base)                 require_flag_value "$@"; BASE_BRANCH="$2"; shift 2 ;;
    --base=*)               BASE_BRANCH="${1#*=}"; shift ;;
    --model)                require_flag_value "$@"; GLOBAL_MODEL="$2"; shift 2 ;;
    --model=*)              GLOBAL_MODEL="${1#*=}"; shift ;;
    --cli)                  require_flag_value "$@"; CLI_OVERRIDE="$2"; shift 2 ;;
    --cli=*)                CLI_OVERRIDE="${1#*=}"; shift ;;
    --continue-on-failure)  CONTINUE_ON_FAILURE=true; shift ;;
    --no-final-pr)          NO_FINAL_PR=true; shift ;;
    --dry-run)              DRY_RUN=true; PASS_THROUGH+=(--dry-run); shift ;;
    --timeout|--retry|--max-parallel|--wave-timeout)
                            require_flag_value "$@"; PASS_THROUGH+=("$1" "$2"); shift 2 ;;
    --timeout=*|--retry=*|--max-parallel=*|--wave-timeout=*)
                            # Normalize `=` form — run-sessions.sh only takes the space form.
                            PASS_THROUGH+=("${1%%=*}" "${1#*=}"); shift ;;
    --strict|--sequential|--skip-plan|--no-worktree|--no-rebase|--no-commit|--no-pr|--keep-worktree|--keep-session-worktrees|--keep-session-docs|--fresh|--show-dag)
                            PASS_THROUGH+=("$1"); shift ;;
    --help|-h)              usage ;;
    --*)
      err "Unknown option: $1"
      usage
      ;;
    *)
      if [[ "$1" == *.json ]]; then
        if [[ -n "$SPRINT_CONFIG" ]]; then
          err "Multiple sprint configs supplied: $SPRINT_CONFIG and $1"
          exit 1
        fi
        SPRINT_CONFIG="$1"
      elif [[ -d "$1" ]]; then
        EPIC_DIRS+=("$1")
      else
        err "Argument is neither a sprint config (.json) nor an epic directory: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Resolve epic list from sprint config or positional args ---
SPRINT_EPIC_DIRS=()
SPRINT_EPIC_MODELS=()

if [[ -n "$SPRINT_CONFIG" ]]; then
  if [[ ! -f "$SPRINT_CONFIG" ]]; then
    err "Sprint config not found: $SPRINT_CONFIG"
    exit 1
  fi
  if [[ -z "$PYTHON_CMD" ]]; then
    err "python3 (or python) is required to parse sprint config; install Python and retry."
    exit 1
  fi

  # First line: branch (may be empty). Subsequent: <dir>\t<model> per epic.
  if ! _config_lines="$("$PYTHON_CMD" - "$SPRINT_CONFIG" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        cfg = json.load(f)
except Exception as e:
    sys.stderr.write("sprint config parse error: " + str(e) + "\n")
    sys.exit(2)
if not isinstance(cfg, dict):
    sys.stderr.write("sprint config root must be an object\n")
    sys.exit(2)
branch = cfg.get("branch") or ""
if not isinstance(branch, str):
    sys.stderr.write("sprint config 'branch' must be a string\n")
    sys.exit(2)
epics = cfg.get("epics")
if not isinstance(epics, list) or not epics:
    sys.stderr.write("sprint config has no non-empty 'epics' list\n")
    sys.exit(2)
print(branch)
for e in epics:
    if not isinstance(e, dict):
        sys.stderr.write("each epic entry must be an object: " + repr(e) + "\n")
        sys.exit(2)
    d = e.get("dir") or ""
    m = e.get("model") or ""
    if not isinstance(d, str) or not d:
        sys.stderr.write("epic entry missing 'dir': " + repr(e) + "\n")
        sys.exit(2)
    if not isinstance(m, str):
        sys.stderr.write("epic 'model' must be a string: " + repr(e) + "\n")
        sys.exit(2)
    if "\t" in d or "\n" in d or "\t" in m or "\n" in m:
        sys.stderr.write("epic dir/model may not contain tab or newline: " + d + "\n")
        sys.exit(2)
    print(d + "\t" + m)
PYEOF
  )"; then
    err "Failed to parse sprint config: $SPRINT_CONFIG"
    exit 1
  fi

  _first=true
  while IFS= read -r _line; do
    if $_first; then
      _first=false
      [[ -z "$BRANCH" && -n "$_line" ]] && BRANCH="$_line"
      continue
    fi
    _dir="${_line%%	*}"
    _model="${_line#*	}"
    [[ "$_model" == "$_dir" ]] && _model=""
    SPRINT_EPIC_DIRS+=("$_dir")
    SPRINT_EPIC_MODELS+=("$_model")
  done <<<"$_config_lines"
  unset _first _line _dir _model _config_lines
fi

if (( ${#EPIC_DIRS[@]} > 0 )); then
  if (( ${#SPRINT_EPIC_DIRS[@]} > 0 )); then
    err "Cannot mix --sprint-config with positional epic directories. Pick one."
    exit 1
  fi
  for _d in "${EPIC_DIRS[@]}"; do
    SPRINT_EPIC_DIRS+=("$_d")
    SPRINT_EPIC_MODELS+=("")
  done
  unset _d
fi

if (( ${#SPRINT_EPIC_DIRS[@]} == 0 )); then
  err "No epics specified. Pass --sprint-config <path.json> or one or more epic directories."
  usage
fi

if [[ -z "$BRANCH" ]]; then
  err "No --branch specified and sprint config has no 'branch'. Sprints share a trunk branch — choose one (e.g. epic/<sprint-name>)."
  exit 1
fi

# Validate every epic dir up front so we fail before any work begins.
for _i in "${!SPRINT_EPIC_DIRS[@]}"; do
  _d="${SPRINT_EPIC_DIRS[$_i]}"
  if [[ ! -d "$_d" ]]; then
    err "Epic directory not found: $_d"
    exit 1
  fi
done
unset _i _d

TOTAL=${#SPRINT_EPIC_DIRS[@]}

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Sprint plan${NC}: ${TOTAL} epic(s) on shared branch '${BRANCH}'"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for _i in "${!SPRINT_EPIC_DIRS[@]}"; do
  _idx=$((_i + 1))
  _d="${SPRINT_EPIC_DIRS[$_i]}"
  _m="${SPRINT_EPIC_MODELS[$_i]}"
  if [[ -n "$_m" ]]; then
    log "  ${_idx}/${TOTAL}  ${_d}  (model: ${_m})"
  elif [[ -n "$GLOBAL_MODEL" ]]; then
    log "  ${_idx}/${TOTAL}  ${_d}  (model: ${GLOBAL_MODEL} [default])"
  else
    log "  ${_idx}/${TOTAL}  ${_d}"
  fi
done
unset _i _idx _d _m
log ""

SUCCEEDED=0
FAILED=0
FAILED_EPICS=()
SPRINT_RC=0

for _i in "${!SPRINT_EPIC_DIRS[@]}"; do
  epic_dir="${SPRINT_EPIC_DIRS[$_i]}"
  epic_model="${SPRINT_EPIC_MODELS[$_i]}"
  epic_num=$((_i + 1))
  is_last=false
  if (( epic_num == TOTAL )); then
    is_last=true
  fi

  epic_args=("$epic_dir" --branch "$BRANCH")
  [[ -n "$BASE_BRANCH" ]] && epic_args+=(--base "$BASE_BRANCH")
  if [[ -n "$epic_model" ]]; then
    epic_args+=(--model "$epic_model")
  elif [[ -n "$GLOBAL_MODEL" ]]; then
    epic_args+=(--model "$GLOBAL_MODEL")
  fi
  [[ -n "$CLI_OVERRIDE" ]] && epic_args+=(--cli "$CLI_OVERRIDE")

  # Final epic creates the PR; suppress for everyone else.
  if ! $is_last || $NO_FINAL_PR; then
    epic_args+=(--no-pr)
  fi

  if (( ${#PASS_THROUGH[@]} > 0 )); then
    epic_args+=("${PASS_THROUGH[@]}")
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "${BOLD}Epic ${epic_num}/${TOTAL}${NC}: ${epic_dir}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  bash run-sessions.sh ${epic_args[*]}"

  rc=0
  bash "$RUNNER" "${epic_args[@]}" || rc=$?

  if (( rc == 0 )); then
    SUCCEEDED=$((SUCCEEDED + 1))
    ok "Epic ${epic_num}/${TOTAL} complete: ${epic_dir}"
  else
    FAILED=$((FAILED + 1))
    FAILED_EPICS+=("${epic_dir} (rc=${rc})")
    err "Epic ${epic_num}/${TOTAL} FAILED: ${epic_dir} (rc=${rc})"
    SPRINT_RC=1
    if ! $CONTINUE_ON_FAILURE; then
      err "Sprint stopped at epic ${epic_num}/${TOTAL}. Resume by re-running with the remaining epic(s), or pass --continue-on-failure."
      break
    fi
  fi
done

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Sprint summary${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if (( FAILED == 0 )); then
  ok "${SUCCEEDED}/${TOTAL} epics complete on branch '${BRANCH}'"
  exit 0
else
  err "${SUCCEEDED}/${TOTAL} succeeded, ${FAILED} failed:"
  for _e in "${FAILED_EPICS[@]}"; do
    err "  - $_e"
  done
  exit "$SPRINT_RC"
fi
