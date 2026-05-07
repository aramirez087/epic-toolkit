#!/usr/bin/env bash
# run-sessions.sh — DAG-aware epic runner. Executes a directed acyclic graph
# of session prompts, fanning out parallel waves into per-session worktrees
# and iteratively merging them into a coordinator trunk branch.
#
# Two-pass execution per session:
#   1. PLAN pass    — read-only exploration, writes an implementation plan file
#   2. EXECUTE pass — implements from the plan, commits changes
#
# Sessions can declare their DAG edges via YAML frontmatter (see epic-dag.py).
# Sessions without frontmatter implicitly form a linear chain — back-compat
# with pre-DAG epics.
#
# Layout:
#   .epic-worktrees/<repo>/
#     epic--<name>/                ← trunk worktree (branch: epic/<name>)
#     epic--<name>--s02-auth-api/  ← per-session worktree, ephemeral
#     epic--<name>--s03-email/     ← (parallel sibling)
#
# Usage:
#   run-sessions.sh <sessions-dir> [options]
#
# Options:
#   --start N            Resume from session N (default: 1)
#   --end N              Stop after session N (default: run all)
#   --max-parallel N     Max concurrent sessions per wave (default: 4)
#   --timeout MINS       Session timeout in minutes (default: 0 = disabled)
#   --retry N            Retry attempts per failed session (default: 0 = disabled)
#   --strict             Fail when sibling sessions declare overlapping `touches` globs
#   --sequential         Force one-session-per-wave (treats DAG as a linear chain)
#   --show-dag           Print the planned waves and exit
#   --dry-run            Preview without executing
#   --branch NAME        Trunk branch (default: epic/<name>)
#   --base BRANCH        Base branch for trunk (default: repo default)
#   --model MODEL        Model name (passed through to the CLI; e.g. opus, sonnet, haiku for Claude)
#   --cli CMD            Force CLI: opencode or claude (default: auto-detect)
#   --no-commit          Skip auto-commit fallback
#   --no-pr              Skip auto-PR creation
#   --no-rebase          Skip pre-PR rebase onto origin/<default> (default: rebase + auto-resolve .wolf/)
#   --skip-plan          Single-pass mode (no separate plan phase)
#   --no-worktree        Run trunk in CWD (forces --max-parallel 1)
#   --keep-worktree      Retain trunk worktree on success
#   --keep-session-worktrees  Retain per-session worktrees on success
#   --wave-timeout MINS  Max minutes before the entire wave is killed (default: auto)
#   --fresh              Disable resume: ignore cached plans and re-run already-committed sessions
#   -h, --help           Show this help

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${BLUE}[epic]${NC} $*"; }
ok()   { echo -e "${GREEN}[epic]${NC} $*"; }
warn() { echo -e "${YELLOW}[epic]${NC} $*"; }
err()  { echo -e "${RED}[epic]${NC} $*" >&2; }
dim()  { echo -e "${DIM}$*${NC}"; }

usage() {
  sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- Parse arguments ---
SESSIONS_DIR=""
START_FROM=1
END_AT=999
MAX_PARALLEL=4
STRICT=false
SEQUENTIAL=false
SHOW_DAG=false
DRY_RUN=false
BRANCH=""
BASE_BRANCH=""
MODEL="sonnet"
AUTO_COMMIT=true
AUTO_PR=true
AUTO_REBASE=true              # Rebase epic onto origin/<default> before PR (auto-resolves .wolf/ conflicts)
SKIP_PLAN=false
USE_WORKTREE=true
KEEP_WORKTREE=false
KEEP_SESSION_WORKTREES=false
KEEP_SESSION_DOCS=false       # When true, skip removing session prompts+handoffs from the epic branch
FRESH=false  # When true, ignore cached plans and previously-committed sessions
CLI_OVERRIDE=""
TIMEOUT=0
RETRY=0
# Wave-level ceiling. 0 = auto-derive per-wave (see wave loop).
# Explicit --wave-timeout overrides auto-derive.
WAVE_TIMEOUT_MINUTES=0
WAVE_TIMEOUT_USER_SET=false

# Track which flags were explicitly set by the user so config loading
# can distinguish "user passed the default value" from "user didn't pass it".
TIMEOUT_USER_SET=false
RETRY_USER_SET=false
MODEL_USER_SET=false
MAX_PARALLEL_USER_SET=false

# Guard value-bearing flags against a missing `$2`. Without this, running
# the script with a value-bearing flag as the LAST argument (e.g.
# `run-sessions.sh foo/ --start`, or `--start --end 5` where the user
# forgot the `--start` value and `$2` lands on the next flag — only the
# truly-last-arg case is fatal here) crashes with `$2: unbound variable`
# under the runner-wide `set -u`, far from a meaningful diagnostic. The
# bash error names a positional parameter index, not the flag the user
# typed, so the user has no signal that they forgot a value. Same audit
# class as bug-194/198 (numeric-flag UX), now extended to argv-shape: a
# clear "missing value for --flag" message names both the cause and the
# remediation. Apply at every value-bearing case branch BEFORE the bare
# `$2` reference. `(( $# < 2 ))` is true when only the flag itself
# remains — exactly the crash precondition.
require_flag_value() {
  if (( $# < 2 )); then
    err "Missing value for $1"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)                    require_flag_value "$@"; START_FROM="$2"; shift 2 ;;
    --end)                      require_flag_value "$@"; END_AT="$2"; shift 2 ;;
    --max-parallel)             require_flag_value "$@"; MAX_PARALLEL="$2"; MAX_PARALLEL_USER_SET=true; shift 2 ;;
    --strict)                   STRICT=true; shift ;;
    --sequential)               SEQUENTIAL=true; shift ;;
    --show-dag)                 SHOW_DAG=true; shift ;;
    --dry-run)                  DRY_RUN=true; shift ;;
    --branch)                   require_flag_value "$@"; BRANCH="$2"; shift 2 ;;
    --base)                     require_flag_value "$@"; BASE_BRANCH="$2"; shift 2 ;;
    --model)                    require_flag_value "$@"; MODEL="$2"; MODEL_USER_SET=true; shift 2 ;;
    --cli)                      require_flag_value "$@"; CLI_OVERRIDE="$2"; shift 2 ;;
    --timeout)                  require_flag_value "$@"; TIMEOUT="$2"; TIMEOUT_USER_SET=true; shift 2 ;;
    --retry)                    require_flag_value "$@"; RETRY="$2"; RETRY_USER_SET=true; shift 2 ;;
    --no-commit)                AUTO_COMMIT=false; shift ;;
    --no-pr)                    AUTO_PR=false; shift ;;
    --no-rebase)                AUTO_REBASE=false; shift ;;
    --skip-plan)                SKIP_PLAN=true; shift ;;
    --no-worktree)              USE_WORKTREE=false; shift ;;
    --keep-worktree)            KEEP_WORKTREE=true; shift ;;
    --keep-session-worktrees)   KEEP_SESSION_WORKTREES=true; shift ;;
    --keep-session-docs)        KEEP_SESSION_DOCS=true; shift ;;
    --wave-timeout)             require_flag_value "$@"; WAVE_TIMEOUT_MINUTES="$2"; WAVE_TIMEOUT_USER_SET=true; shift 2 ;;
    --fresh)                    FRESH=true; shift ;;
    --help|-h)                  usage ;;
    *)
      if [[ -z "$SESSIONS_DIR" ]]; then SESSIONS_DIR="$1"; shift
      else err "Unknown argument: $1"; usage; fi
      ;;
  esac
done

# Validate numeric arguments
for _arg_name in "START_FROM" "END_AT" "MAX_PARALLEL" "TIMEOUT" "RETRY" "WAVE_TIMEOUT_MINUTES"; do
  _val="${!_arg_name}"
  if ! [[ "$_val" =~ ^[0-9]+$ ]]; then
    err "$_arg_name must be a non-negative integer (got '$_val')"
    exit 1
  fi
  # Normalize to base-10 so leading-zero values produce the user's apparent
  # decimal intent rather than being silently bash-octal-decoded by downstream
  # arithmetic. The validation regex `^[0-9]+$` accepts `08`, `09`, `010`,
  # `019`, etc.; bash arithmetic context (`[[ x -OP y ]]`, `(( ))`, array
  # subscripts) then treats the value as octal:
  #   • `--max-parallel 08` / `09` → `[[ 08 -lt 1 ]]` raises `value too great
  #     for base` to stderr and returns false; the bug-194 / bug-108 guards
  #     never fire, the wave loop's throttle `[[ ${#JOB_PIDS[@]} -ge $MAX_
  #     PARALLEL ]]` ALSO raises the same error on every iteration and
  #     returns false, so the throttle never engages and ALL sessions fan
  #     out concurrently regardless of the cap the user asked for, with the
  #     bash error spammed to stderr on every wave-fanout iteration.
  #   • `--max-parallel 010` → silently re-interpreted as decimal 8; the
  #     user gets ⅕ less parallelism than they asked for with no diagnostic.
  #   • `--wave-timeout 08` → at line ~1119, `wave_timeout=$((_effective_wtm
  #     * 60))` triggers `value too great for base`, the assignment fails,
  #     `$wave_timeout` stays unbound, and the next `[[ $wave_timeout -gt 0
  #     ]]` raises `wave_timeout: unbound variable` under `set -u` and
  #     crashes the entire runner mid-wave.
  #   • `--start 08` / `--end 09` → range filters silently no-op (bash
  #     error → false → no skip); user's resume-from-N intent is silently
  #     ignored.
  #   • `--timeout 010` / `--retry 010` → silent decimal-8 reinterpretation.
  # Same audit class as bug-194 (numeric flag the validator accepts but the
  # consumer can't interpret correctly) and bug-193/196 (bash arithmetic-as-
  # int narrowing on producer-emitted scalars) — every numeric value that
  # later flows into bash arithmetic context must be normalized here so the
  # consumer sees what the user wrote, not what bash's octal heuristic
  # invents. `printf -v VAR '%d' VAL` works on bash 3.2+ and reassigns the
  # named variable; `10#$_val` forces base-10 interpretation regardless of
  # leading zeros (`10#08` = 8, `10#010` = 10, `10#0` = 0).
  printf -v "$_arg_name" '%d' "$((10#$_val))"
done

if [[ -z "$SESSIONS_DIR" ]]; then
  err "Missing required argument: <sessions-dir>"
  usage
fi
if [[ ! -d "$SESSIONS_DIR" ]]; then
  err "Directory not found: $SESSIONS_DIR"
  exit 1
fi
SESSIONS_DIR="$(cd "$SESSIONS_DIR" && pwd)"

# Get repo root early for config file loading
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  err "Not inside a git repository."
  exit 1
fi
REPO_ROOT="$(cd "$(git rev-parse --show-toplevel)" && pwd)"

# --- Load .epic-config.json configuration ---
CONFIG_FILE="$REPO_ROOT/.epic-config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  log "Loading configuration from ${CONFIG_FILE/#$HOME/~}"

  # Extract config values using bash regex (Bash 3.2+ compatible)
  if config_content="$(cat "$CONFIG_FILE" 2>/dev/null)"; then
    # Only override defaults if CLI didn't specify the value. Use _USER_SET
    # flags (not sentinel comparisons) for flags whose default value is also
    # a valid explicit user choice (e.g. --timeout 0, --model sonnet).
    # Same `10#` normalization as the cmdline validator above — JSON forbids
    # leading zeros in numeric literals, but the bash regex `[0-9]+` accepts
    # them, so a hand-edited config (`"timeout": 010`) would otherwise
    # silently bash-octal-decode to decimal 8 (or crash with `08`/`09`'s
    # `value too great for base`) at every downstream arithmetic site.
    # (bug-197)
    if ! $TIMEOUT_USER_SET && [[ "$config_content" =~ \"timeout\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      TIMEOUT=$((10#${BASH_REMATCH[1]}))
    fi
    if ! $RETRY_USER_SET && [[ "$config_content" =~ \"retry\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      RETRY=$((10#${BASH_REMATCH[1]}))
    fi
    if [[ -z "$CLI_OVERRIDE" && "$config_content" =~ \"cli\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      CLI_OVERRIDE="${BASH_REMATCH[1]}"
    fi
    if ! $MODEL_USER_SET && [[ "$config_content" =~ \"model\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      MODEL="${BASH_REMATCH[1]}"
    fi
    if ! $MAX_PARALLEL_USER_SET && [[ "$config_content" =~ \"maxParallel\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      MAX_PARALLEL=$((10#${BASH_REMATCH[1]}))
    fi
    if [[ "$AUTO_COMMIT" == "true" && "$config_content" =~ \"autoCommit\"[[:space:]]*:[[:space:]]*false ]]; then
      AUTO_COMMIT=false
    fi
    if [[ "$AUTO_PR" == "true" && "$config_content" =~ \"autoPr\"[[:space:]]*:[[:space:]]*false ]]; then
      AUTO_PR=false
    fi
    if [[ "$SKIP_PLAN" == "false" && "$config_content" =~ \"skipPlan\"[[:space:]]*:[[:space:]]*true ]]; then
      SKIP_PLAN=true
    fi
    if [[ "$KEEP_WORKTREE" == "false" && "$config_content" =~ \"keepWorktree\"[[:space:]]*:[[:space:]]*true ]]; then
      KEEP_WORKTREE=true
    fi
    if ! $WAVE_TIMEOUT_USER_SET && [[ "$config_content" =~ \"waveTimeout\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      WAVE_TIMEOUT_MINUTES=$((10#${BASH_REMATCH[1]}))
      WAVE_TIMEOUT_USER_SET=true
    fi
  else
    warn "Could not read configuration file: $CONFIG_FILE"
  fi
fi

# Reject MAX_PARALLEL=0 explicitly. The earlier numeric validation accepts 0
# because `^[0-9]+$` includes the zero case, and the same regex in the config
# loader above (`"maxParallel"\s*:\s*([0-9]+)`) accepts `"maxParallel": 0` too.
# But the throttle loop in the wave fan-out is `while [[ ${#JOB_PIDS[@]} -ge
# $MAX_PARALLEL ]]; do reap_finished_jobs; sleep 1; done` — with MAX_PARALLEL=0
# the predicate `array_length >= 0` is ALWAYS true (every non-negative array
# length satisfies it, including the empty-array starting state), so the loop
# never exits, no session ever spawns, and the runner hangs forever consuming
# the wave-timeout's idle minutes before SIGKILL ends the wait. The other
# zero-sentinel flags (`--timeout 0`, `--retry 0`, `--wave-timeout 0`) all
# have well-defined "disabled / auto" semantics in the runner; MAX_PARALLEL=0
# is the only one that's pathologically broken because the code path expects
# a positive concurrency ceiling. Validate after config load so a bad
# `.epic-config.json "maxParallel": 0` is caught too. (bug-194)
if [[ "$MAX_PARALLEL" -lt 1 ]]; then
  err "MAX_PARALLEL must be >= 1 (got '$MAX_PARALLEL'). 0 would hang the throttle loop indefinitely; use 1 for serial execution."
  exit 1
fi

# --- Detect CLI ---
# Prefer --cli override, then the invoking tool's env var, then PATH fallback.
# OPENCODE_SESSION_ID is set by OpenCode; CLAUDECODE is set by Claude Code.
#
# Whitelist CLI_OVERRIDE before the PATH check. epic-dag.py's load_sessions
# already rejects non-{claude,opencode} values for the per-session `cli:`
# frontmatter (line 503-507), but the same defence was missing on the
# command-line / config-file path: `--cli foo` (or a `.epic-config.json`
# `"cli": "foo"`) was taken verbatim, and as long as `foo` resolved on PATH
# the runner accepted it. run_cli's `if [[ "$session_cli" == "claude" ]]`
# branch (epic-session.sh:208) treats EVERY non-claude string as opencode,
# so `foo` got invoked as `foo run --format json --dangerously-skip-permissions`
# AND `map_model_shorthand` (line 248) silently passed through unmapped because
# its `[[ "$cli" == "opencode" ]]` test failed. Same audit class as bug-138 —
# epic-dag.py was the only fix site; here is the symmetric one. (bug-147)
if [[ -n "$CLI_OVERRIDE" && "$CLI_OVERRIDE" != "claude" && "$CLI_OVERRIDE" != "opencode" ]]; then
  err "--cli / .epic-config.json cli must be 'claude' or 'opencode' (got '$CLI_OVERRIDE')."
  exit 1
fi
CLI_CMD=""
if [[ -n "$CLI_OVERRIDE" ]]; then
  CLI_CMD="$CLI_OVERRIDE"
  if ! command -v "$CLI_CMD" &>/dev/null; then
    err "Forced CLI '$CLI_CMD' not found on PATH."
    exit 1
  fi
elif [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then
  CLI_CMD=opencode
elif [[ -n "${CLAUDECODE:-}" ]]; then
  CLI_CMD=claude
fi
if [[ -z "$CLI_CMD" ]]; then
  if command -v opencode &>/dev/null; then
    CLI_CMD=opencode
  elif command -v claude &>/dev/null; then
    CLI_CMD=claude
  else
    err "Neither opencode nor claude CLI found on PATH. Use --cli to force one."
    exit 1
  fi
fi
log "Using CLI: $CLI_CMD"

# --- Map model shorthand to CLI-specific model IDs ---
# Claude accepts bare names (sonnet, opus, haiku).  OpenCode needs fully
# qualified IDs in provider/model format (opencode/claude-sonnet-4).
# If the user passed a slash-containing ID (e.g. opencode/glm-5.1) we
# leave it untouched — it's already a full ID.
# Kept here (not in a lib) because it is called at line 246, before sourcing.
map_model_shorthand() {
  local model="$1"
  local cli="$2"
  if [[ "$cli" == "opencode" && "$model" != */* ]]; then
    case "$model" in
      sonnet)   echo "opencode/claude-sonnet-4" ;;
      sonnet4)  echo "opencode/claude-sonnet-4" ;;
      opus)     echo "opencode/claude-opus-4-7" ;;
      haiku)    echo "opencode/claude-haiku-4-5" ;;
      gpt5)     echo "opencode/gpt-5" ;;
      gpt5nano) echo "opencode/gpt-5-nano" ;;
      gemini)   echo "opencode/gemini-3-flash" ;;
      glm)      echo "opencode/glm-5.1" ;;
      # Redirect the diagnostic to stderr so it does NOT leak into the
      # captured stdout when callers wrap this function in `$(...)` —
      # which is every call site (run-sessions.sh:288 global,
      # epic-session.sh:174/184 per-session). `log` writes to stdout, so
      # the previous form `log "..."; echo "$model"` captured BOTH lines
      # — `$session_model` ended up as the ANSI-coloured "[epic] Model
      # 'foo' is not a known OpenCode shorthand — using as-is\n<model>",
      # which then flowed verbatim into `model_flag=(-m "$session_model")`
      # / `(--model "$session_model")` (epic-session.sh:208/210). claude
      # / opencode rejected the multi-line argument with an opaque
      # "unknown model id" error, far from the YAML / CLI cause. Fires
      # for any non-shorthand model name on `--cli opencode` — including
      # legitimate fully-qualified ids that happen not to match the
      # `*/*` slash test (e.g. a user typo like `claude-sonnet-4-5`
      # instead of `opencode/claude-sonnet-4-5`), AND for any session-
      # level `model:` override that isn't in the case list. (bug-181)
      *)        log "Model '$model' is not a known OpenCode shorthand — using as-is" >&2; echo "$model" ;;
    esac
  else
    echo "$model"
  fi
}

# Preserve the user-supplied (un-mapped) model so per-session cli overrides
# can re-derive the correct CLI-specific id. Without this, a session that
# overrides `cli: claude` on a global `--cli opencode --model sonnet` run
# inherits the already-mapped `opencode/claude-sonnet-4` and passes it to
# Claude, which rejects the unknown model id. map_model_shorthand is a
# one-way transform once `model != */*` no longer holds.
MODEL_RAW="$MODEL"
MODEL="$(map_model_shorthand "$MODEL" "$CLI_CMD")"

# Resolve python interpreter. On Windows, `python3` is often a Microsoft Store
# stub that satisfies `command -v` but errors on actual invocation, so we
# probe with --version instead of trusting PATH lookup alone.
PYTHON_CMD=""
if command -v python3 &>/dev/null && python3 --version &>/dev/null; then
  PYTHON_CMD=python3
elif command -v python &>/dev/null && python --version &>/dev/null; then
  PYTHON_CMD=python
else
  err "python3 (or python) not found on PATH (required for DAG scheduler)."
  exit 1
fi
# Force UTF-8 stdio so the DAG renderer's box-drawing characters don't crash
# on Windows consoles that default to cp1252.
export PYTHONIOENCODING=utf-8

# Resolve plugin root — works in both Claude Code (CLAUDE_PLUGIN_ROOT) and
# OpenCode (no env var; derive from script location).
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CLAUDE_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
  unset _SCRIPT_DIR
fi

# --- Source library modules ---
_LIB_DIR="$CLAUDE_PLUGIN_ROOT/scripts/lib"
# shellcheck source=lib/epic-git.sh
source "$_LIB_DIR/epic-git.sh"
# shellcheck source=lib/epic-session.sh
source "$_LIB_DIR/epic-session.sh"
# shellcheck source=lib/epic-result.sh
source "$_LIB_DIR/epic-result.sh"
# shellcheck source=lib/epic-wave.sh
source "$_LIB_DIR/epic-wave.sh"
unset _LIB_DIR

# Resolve canonical real paths now that _realpath is available.
# See epic-git.sh for the rationale on why _realpath is necessary.
REPO_ROOT="$(_realpath "$(cd "$(git rev-parse --show-toplevel)" && pwd)")"
ORIG_REPO_ROOT="$REPO_ROOT"
ORIG_SESSIONS_DIR="$(_realpath "$SESSIONS_DIR")"

# The runner mutates the repo selected by the current working directory
# (branches, worktrees, OpenWolf provisioning). Refuse a sessions directory
# from another repo before any of those side effects can happen.
if [[ "$ORIG_SESSIONS_DIR" != "$ORIG_REPO_ROOT"/* ]]; then
  err "Sessions dir is not under the current git repo.
  repo root    : $ORIG_REPO_ROOT
  sessions dir : $ORIG_SESSIONS_DIR
Run the command from the repository that owns the sessions directory, or pass a sessions path inside this repo."
  exit 1
fi
ORIG_SESSIONS_REL="${ORIG_SESSIONS_DIR#$ORIG_REPO_ROOT/}"

# Auto-provision .wolf/ merge auto-resolution if the repo uses OpenWolf.
# Preview modes must stay read-only; dry-run/show-dag exit before worktree
# setup, so provisioning is only needed for real execution.
if ! $DRY_RUN && ! $SHOW_DAG; then
  provision_wolf_merge "$REPO_ROOT"
fi
EPIC_NAME_SLUG="$(basename "$SESSIONS_DIR")"

if [[ -z "$BRANCH" ]]; then
  BRANCH="epic/${EPIC_NAME_SLUG}"
fi
# sed (not tr): tr maps SET1 chars to SET2 chars positionally, so
# `tr '/' '--'` only uses the first '-' and silently produces a single-dash
# output ('epic/foo' → 'epic-foo') — diverging from the documented
# 'epic--<name>' worktree layout in the header. (bug-091)
BRANCH_SANITIZED="$(echo "$BRANCH" | sed 's|/|--|g')"

# --no-worktree forces sequential — can't safely parallelize in one CWD.
if ! $USE_WORKTREE && [[ "$MAX_PARALLEL" -gt 1 ]]; then
  warn "--no-worktree forces --max-parallel 1"
  MAX_PARALLEL=1
fi
if $SEQUENTIAL; then
  MAX_PARALLEL=1
fi
# Clamp MAX_PARALLEL to at least 1. The numeric validator (lines 141-147)
# accepts 0 because `^[0-9]+$` allows it, but the wave throttle at lines ~874
# is `while [[ ${#JOB_PIDS[@]} -ge $MAX_PARALLEL ]]; do reap; sleep 1; done` —
# with MAX_PARALLEL=0 even an empty JOB_PIDS satisfies `0 -ge 0`, so the loop
# spins forever before launching any session and the runner silently hangs.
# Same defensive-numeric class as bug-062 / bug-092. (bug-108)
if [[ "$MAX_PARALLEL" -lt 1 ]]; then
  warn "--max-parallel must be at least 1; clamping (was $MAX_PARALLEL)"
  MAX_PARALLEL=1
fi

DAG_SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/epic-dag.py"
PROGRESS_SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/epic-progress.py"
UI_SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/epic-ui.py"

# --- Build the DAG plan ---
DAG_TMP="$(mktemp)"

# Global arrays declared before the EXIT trap so the handler can always see them,
# even when the script aborts before the wave loop initialises them per-wave.
JOB_PIDS=()
JOB_SIDS=()

# EXIT handler — cleans up in-flight session subshells, UI, and temp files.
# Uses kill_tree (epic-wave.sh) for a recursive SIGKILL walk so that --timeout
# wrapper grandchildren (timeout → claude) don't leak as orphans when the
# runner aborts mid-wave via set -e, SIGINT, or external kill. The earlier
# `pkill -9 -P` only walked one level and left `claude` reparented to PID 1
# whenever --timeout MINS was set. (bug-063, bug-065, bug-073)
_on_exit() {
  local _rc=$?
  for _tp in "${JOB_PIDS[@]:-}"; do
    [[ -n "$_tp" ]] || continue
    kill_tree "$_tp"
  done
  [[ -n "${UI_PID:-}" ]] && kill "${UI_PID}" 2>/dev/null || true
  rm -f "${DAG_TMP:-}"
  exit "$_rc"
}
trap '_on_exit' EXIT

DAG_ARGS=()
$STRICT && ! $SEQUENTIAL && DAG_ARGS+=(--strict)

if [[ ${#DAG_ARGS[@]} -gt 0 ]]; then
  "$PYTHON_CMD" "$DAG_SCRIPT" "$SESSIONS_DIR" --bash "${DAG_ARGS[@]}" > "$DAG_TMP" || {
    err "DAG validation failed"; exit 1; }
else
  "$PYTHON_CMD" "$DAG_SCRIPT" "$SESSIONS_DIR" --bash > "$DAG_TMP" || {
    err "DAG validation failed"; exit 1; }
fi

OPERATOR_PATH=""
ANY_FRONTMATTER="false"
declare -a WAVE_IDS              # WAVE_IDS[$wave_num]="1 2 3"
declare -a SESSION_FILE_BASENAME # by id
declare -a SESSION_SLUG_BY_ID    # by id
declare -a SESSION_DEPS_BY_ID    # by id ("a,b,c" or "-")
declare -a SESSION_PARALLEL      # by id ("1"/"0")
declare -a SESSION_WAVE_OF       # by id
declare -a SESSION_MODEL_BY_ID   # by id
declare -a SESSION_CLI_BY_ID     # by id

WAVE_COUNT=0

# META values can legitimately contain spaces (operator_path is an absolute
# filesystem path), so they must NOT be tokenized via `set -- $line`. Strip
# the "META <key>=" prefix and take the rest verbatim. SESSION rows continue
# to use word-splitting because their fields are space-free by construction
# (numeric ids, comma-separated deps, regex-derived slug, 0/1 flags).
while IFS= read -r line; do
  case "$line" in
    "META operator_path="*)   OPERATOR_PATH="${line#META operator_path=}" ;;
    "META any_frontmatter="*) ANY_FRONTMATTER="${line#META any_frontmatter=}" ;;
    "META wave_count="*)
      # Validate at parse time — the value flows verbatim into the arithmetic
      # contexts `[[ "$WAVE_COUNT" -eq 0 ]]` (line ~534) and `for (( wn=1;
      # wn<=WAVE_COUNT; wn++ ))` (wave loop), and bash treats a non-numeric
      # operand as a variable-name reference. Under the runner's `set -u`, a
      # corrupted `META wave_count=garbage` line crashes the entire runner
      # with `garbage: unbound variable` BEFORE the existing zero-check at
      # line 534 can fire — the user sees a cryptic bash error rather than
      # the intended "DAG plan is empty or malformed" diagnostic. Same
      # producer-emittable corruption modes as bug-192/193 (partial-flush
      # from a SIGKILL'd `cp`, NFS read racing the write, schema drift,
      # hand-edit for debugging) and same audit class: every consumer of
      # producer-emitted data must reject inputs the producer can emit but
      # the consumer can't interpret, AND that audit must extend to every
      # narrowing predicate the consumer applies — bash arithmetic-as-int
      # is a string→int narrowing on the WAVE_COUNT field too. Reject
      # non-numeric values silently (leave WAVE_COUNT at its default 0);
      # the existing line-534 guard then exits with the proper diagnostic.
      _wc_raw="${line#META wave_count=}"
      if [[ "$_wc_raw" =~ ^[0-9]+$ ]]; then
        # `10#` normalization — bug-196 patched the non-numeric crash but
        # left the leading-zero silent-octal hole. A producer-emittable
        # corruption (partial-flush, NFS read race, schema drift, hand-
        # edit) lands `META wave_count=010` and the wave loop's `for ((
        # wn=1; wn<=WAVE_COUNT; wn++ ))` arithmetic-decodes the value as
        # octal 8, silently truncating a 10-wave plan to 8 waves with no
        # diagnostic. Same audit class as bug-194/196/197. (bug-197)
        WAVE_COUNT=$((10#$_wc_raw))
      fi
      unset _wc_raw
      ;;
    "META "*) : ;;  # unrecognised META key — ignore
    "WAVE "*) : ;;  # WAVE <num> <size> — informational only
    "SESSION "*)
      # SESSION <wave> <id> <file> <deps> <slug> <parallel> [<model> <cli>]
      # Empty model/cli are emitted as the sentinel `-` by epic-dag.py so
      # `set -- $_rest`'s whitespace-collapse can't shift cli into the
      # model slot when model is empty. Translate the sentinel back here.
      # (bug-076)
      _rest="${line#SESSION }"
      set -- $_rest
      sw="${1:-}"; sid="${2:-}"; sfile="${3:-}"; sdeps="${4:-}"; sslug="${5:-}"; sparallel="${6:-}"
      smodel="${7:-}"; scli="${8:-}"
      # Skip malformed SESSION rows whose wave/id fields aren't numeric.
      # Symmetric bash-side defence to bug-192's Python-side guard. Both
      # consumers (this loop and the status-init heredoc / parse_bash_plan)
      # read the SAME plan file, so the same producer-emittable corruption
      # modes apply: a partial-flush from a SIGKILL'd `cp` mid-write, an
      # NFS read racing the write, schema drift from a future writer, or
      # a hand-edit for debugging. The bash side runs FIRST (line 455-484)
      # and uses `$sw`/`$sid` directly as numeric array subscripts at
      # `WAVE_IDS[$sw]`, `SESSION_FILE_BASENAME[$sid]`, etc. — bash treats
      # subscripts as arithmetic expressions, and a non-numeric subscript
      # like `WAVE_IDS[garbage]` looks up a variable named `garbage`,
      # which under the runner's `set -u` is unbound: bash exits the
      # entire runner with `garbage: unbound variable` BEFORE bug-192's
      # heredoc fix ever gets a chance to run. The user sees a cryptic
      # bash error and the epic never starts. Same audit class as bug-192:
      # every consumer of producer-emitted data must reject inputs the
      # producer can emit but the consumer can't interpret, and the audit
      # must extend to every narrowing predicate the consumer applies —
      # here, bash array-subscript-as-arithmetic is a string→int narrowing
      # that crashes on every shape outside the numeric subspace. Mirror
      # bug-192's coerce-and-skip: the well-formed lines around the
      # malformed one still register, so the runner degrades gracefully
      # (dropping ONLY the malformed sessions) instead of failing wholesale.
      # Also reject empty truncated rows (fewer than 6 fields after split)
      # for parity with the heredoc's `if len(parts) < 6: continue`. (bug-193)
      if ! [[ "$sw" =~ ^[0-9]+$ && "$sid" =~ ^[0-9]+$ ]]; then
        continue
      fi
      # `10#` normalization — bug-193 patched the non-numeric subscript
      # crash but left the leading-zero silent-octal hole. A producer-
      # emittable corruption (partial-flush, NFS read race, schema drift,
      # hand-edit) lands `SESSION 010 5 ...` (wave field with leading
      # zero) and bash arithmetic-as-subscript decodes `WAVE_IDS[010]` as
      # octal 8 — the session intended for wave 10 silently registers in
      # wave 8 instead, silently corrupting the DAG with no diagnostic.
      # Same hole on `SESSION 1 010 ...` for the sid → SESSION_*[010] sites.
      # Same audit class as bug-194/196/197. (bug-197)
      sw=$((10#$sw))
      sid=$((10#$sid))
      # bug-193's stated intent included this length check ("Also reject
      # empty truncated rows ... for parity with the heredoc's `if
      # len(parts) < 6: continue`"), but the implementation only added
      # field-defaulting via `${N:-}` plus the numeric guard on sw/sid.
      # The length check itself was never written, so a truncated row
      # like `SESSION 1 5` (only 3 fields after SESSION; sw=1, sid=5
      # both numeric, but sfile/sdeps/sslug/sparallel all empty) passed
      # the numeric check and registered a session entry with empty file
      # and empty slug. Downstream the wave loop fanned the session out
      # with `fname=""`, run_one_session built `session_path="$TRUNK_
      # SESSIONS_DIR/"` (just the directory), `extract_prompt` ran awk
      # against a directory and returned empty, and the session failed
      # with "ERROR: could not extract prompt from <directory>" — a
      # symptom-level error pointing at the (perfectly valid) prompt-
      # extraction code instead of naming the malformed plan as the
      # cause. Same producer-emittable corruption modes as bug-192/193
      # (partial-flush from a SIGKILL'd `cp`, NFS read racing the
      # write, schema drift, hand-edit). Mirror the heredoc's check
      # explicitly so the bash side rejects the same shapes the Python
      # consumer already rejects — `set -- $_rest` exposes `$#` for the
      # field count after splitting. (bug-195)
      if [[ $# -lt 6 ]]; then
        continue
      fi
      [[ "$smodel" == "-" ]] && smodel=""
      [[ "$scli"   == "-" ]] && scli=""
      WAVE_IDS[$sw]="${WAVE_IDS[$sw]:-} $sid"
      SESSION_FILE_BASENAME[$sid]="$sfile"
      SESSION_SLUG_BY_ID[$sid]="$sslug"
      SESSION_DEPS_BY_ID[$sid]="$sdeps"
      SESSION_PARALLEL[$sid]="$sparallel"
      SESSION_WAVE_OF[$sid]="$sw"
      SESSION_MODEL_BY_ID[$sid]="$smodel"
      SESSION_CLI_BY_ID[$sid]="$scli"
      ;;
  esac
done < "$DAG_TMP"
unset _rest

if [[ -z "$OPERATOR_PATH" || "$WAVE_COUNT" -eq 0 ]]; then
  err "DAG plan is empty or malformed"
  exit 1
fi

# --sequential means one session per merge boundary, not just one process at a
# time. Rewriting the effective plan keeps the wave loop unchanged while making
# each session branch from trunk after the previous synthetic wave has merged.
show_effective_dag() {
  local _show_wn _show_ids _show_sid
  if ! $SEQUENTIAL; then
    "$PYTHON_CMD" "$DAG_SCRIPT" "$SESSIONS_DIR" --show
    return
  fi

  echo "Sessions: ${#SESSION_SLUG_BY_ID[@]} across $WAVE_COUNT wave(s)"
  for (( _show_wn=1; _show_wn<=WAVE_COUNT; _show_wn++ )); do
    _show_ids="${WAVE_IDS[$_show_wn]:-}"
    _show_ids="$(echo "$_show_ids" | xargs)"
    [[ -z "$_show_ids" ]] && continue
    for _show_sid in $_show_ids; do
      printf "  ║ Wave %d: [%02d %s]\n" \
        "$_show_wn" "$_show_sid" "${SESSION_SLUG_BY_ID[$_show_sid]}"
    done
  done
}

if $SEQUENTIAL; then
  _seq_tmp="$(mktemp)"
  _old_wave_count="$WAVE_COUNT"
  _new_wave=0
  declare -a _SEQ_WAVE_IDS
  declare -a _SEQ_SESSION_WAVE_OF
  {
    echo "META operator_path=$OPERATOR_PATH"
    echo "META operator_file=$(basename "$OPERATOR_PATH")"
    echo "META wave_count=${#SESSION_SLUG_BY_ID[@]}"
    echo "META any_frontmatter=$ANY_FRONTMATTER"
    for (( _old_wn=1; _old_wn<=_old_wave_count; _old_wn++ )); do
      _ids="${WAVE_IDS[$_old_wn]:-}"
      _ids="$(echo "$_ids" | xargs)"
      [[ -z "$_ids" ]] && continue
      for _sid in $_ids; do
        _new_wave=$((_new_wave + 1))
        _SEQ_WAVE_IDS[$_new_wave]="$_sid"
        _SEQ_SESSION_WAVE_OF[$_sid]="$_new_wave"
        # Mirror epic-dag.py emit_bash: empty model/cli become `-` so a
        # downstream re-parse via `set -- $line` can't shift cli into the
        # model slot. (bug-076)
        _seq_model="${SESSION_MODEL_BY_ID[$_sid]:-}"
        _seq_cli="${SESSION_CLI_BY_ID[$_sid]:-}"
        [[ -z "$_seq_model" ]] && _seq_model="-"
        [[ -z "$_seq_cli"   ]] && _seq_cli="-"
        echo "WAVE $_new_wave 1"
        printf 'SESSION %s %s %s %s %s %s %s %s\n' \
          "$_new_wave" "$_sid" "${SESSION_FILE_BASENAME[$_sid]}" \
          "${SESSION_DEPS_BY_ID[$_sid]}" "${SESSION_SLUG_BY_ID[$_sid]}" \
          "${SESSION_PARALLEL[$_sid]}" "$_seq_model" "$_seq_cli"
      done
    done
  } > "$_seq_tmp"
  mv "$_seq_tmp" "$DAG_TMP"
  WAVE_COUNT="$_new_wave"
  unset WAVE_IDS SESSION_WAVE_OF
  declare -a WAVE_IDS
  declare -a SESSION_WAVE_OF
  for (( _seq_wn=1; _seq_wn<=WAVE_COUNT; _seq_wn++ )); do
    WAVE_IDS[$_seq_wn]="${_SEQ_WAVE_IDS[$_seq_wn]}"
  done
  for _seq_sid in "${!_SEQ_SESSION_WAVE_OF[@]}"; do
    SESSION_WAVE_OF[$_seq_sid]="${_SEQ_SESSION_WAVE_OF[$_seq_sid]}"
  done
  unset _seq_tmp _old_wave_count _new_wave _ids _sid _seq_wn _seq_sid _seq_model _seq_cli
  unset _SEQ_WAVE_IDS _SEQ_SESSION_WAVE_OF
fi

OPERATOR_PROMPT="$(extract_prompt "$OPERATOR_PATH")"
if [[ -z "$OPERATOR_PROMPT" ]]; then
  err "Could not extract operator prompt from $OPERATOR_PATH"
  exit 1
fi

# --- Show DAG and exit if requested ---
if $SHOW_DAG; then
  show_effective_dag
  exit 0
fi

# --- Dry-run: print plan and exit BEFORE any side effects (worktree, branches) ---
if $DRY_RUN; then
  log "${BOLD}DRY RUN${NC} — no worktrees, no branches, no commits will be created."
  show_effective_dag
  echo ""
  for (( wn=1; wn<=WAVE_COUNT; wn++ )); do
    ids="${WAVE_IDS[$wn]:-}"
    ids="$(echo "$ids" | xargs)"
    [[ -z "$ids" ]] && continue
    IFS=' ' read -ra IDS_ARR <<< "$ids"
    in_range=()
    for sid in "${IDS_ARR[@]}"; do
      [[ "$sid" -lt "$START_FROM" ]] && continue
      [[ "$sid" -gt "$END_AT" ]]    && continue
      in_range+=("$sid")
    done
    [[ ${#in_range[@]} -eq 0 ]] && continue
    if [[ ${#in_range[@]} -gt 1 ]]; then
      log "Wave $wn: ${#in_range[@]} sessions in parallel (max $MAX_PARALLEL)"
    else
      log "Wave $wn: 1 session (serial)"
    fi
    for sid in "${in_range[@]}"; do
      dim "  [DRY] would run session $(printf '%02d' "$sid") — ${SESSION_SLUG_BY_ID[$sid]} (deps: ${SESSION_DEPS_BY_ID[$sid]})"
    done
  done
  echo ""
  ok "Dry-run complete. Re-run without --dry-run to execute."
  exit 0
fi

# --- Trunk worktree setup ---
WORKTREE_BASE="$(dirname "$ORIG_REPO_ROOT")/.epic-worktrees/$(basename "$ORIG_REPO_ROOT")"
TRUNK_WORKTREE_DIR=""

# Clean up stale session worktrees from previous runs.
# IMPORTANT: scope by ${BRANCH_SANITIZED}-- so multi-epic repos don't
# cross-purge each other's worktrees. WORKTREE_BASE is shared across all
# epics in a repo, so an unscoped `*--sNN-*` glob would match (and delete)
# sibling epics' per-session worktrees whose ids happen not to be in the
# *current* epic's DAG — including ones holding uncommitted work.
if [[ -d "$WORKTREE_BASE" ]]; then
  log "Scanning for stale session worktrees..."

  # Get list of current session IDs from DAG
  current_session_ids=""
  while IFS= read -r line; do
    # Skip empty/blank lines BEFORE `set -- $line`. With an empty $line, the
    # `set --` (no args) clears positional params, and the next `case "$1"`
    # references an unset positional under the runner-wide `set -u` —
    # raising `$1: unbound variable` and crashing the entire runner with
    # rc=1 before any worktree is touched.
    #
    # epic-dag.py emit_bash never emits blank lines under happy path, but
    # the same producer-emittable corruption modes bug-192/193/195/196
    # already enumerate (partial-flush from a SIGKILL'd `cp` mid-write of
    # the plan file, NFS read racing the write, schema drift from a future
    # writer that adds blank-line padding for readability, hand-edit for
    # debugging) all leave a blank line in the otherwise well-formed
    # plan file. The two PYTHON consumers of the same plan file
    # (parse_bash_plan in epic-ui.py and the status-init heredoc in
    # run-sessions.sh) both `line.strip()` before any startswith check, so
    # blank lines are skipped cleanly there. The bash-side SESSION-row
    # parser at line ~474 also handles blank lines cleanly via `case
    # "$line" in "META "*) ... "WAVE "*) ... "SESSION "*) ...` (none of
    # which match an empty pattern, so the whole case falls through). This
    # cleanup loop was the only consumer that ran with `set -- $line`
    # AHEAD of any whitespace/non-empty check — same audit class as
    # bug-192/193/195/196 (every consumer of producer-emitted plan-file
    # data must reject inputs the consumer can't interpret), and the only
    # bash-side reader still vulnerable to the corruption shapes those
    # bugs already documented. (bug-198)
    [[ -z "$line" ]] && continue
    set -- $line
    # Default `$3` via `${3:-}` so a truncated `SESSION` / `SESSION 1`
    # row (only 1-2 fields after split) doesn't trip `set -u` on bare
    # `$3` BEFORE the loop continues. bug-199 patched the same loop's
    # blank-line crash, but the truncated-row case was missed: a
    # producer-emittable corruption (partial-flush from a SIGKILL'd
    # `cp` mid-write of the plan file, NFS read racing the write,
    # schema drift from a future writer, hand-edit for debugging) can
    # leave a SESSION line with fewer than 3 fields, and the bare `$3`
    # access raises `$3: unbound variable` under the runner-wide
    # `set -u`, crashing the entire runner with rc=1 BEFORE any
    # worktree is touched. Same audit class as bug-193/195/199 — every
    # bash-side consumer of producer-emitted plan-file data must
    # reject inputs the consumer can't interpret. The well-formed
    # SESSION rows in the same file still register their sid, so the
    # cleanup loop degrades gracefully (an empty default for the
    # truncated row is a no-op for the regex match at the stale-id
    # comparison below) instead of failing wholesale.
    case "$1" in
      SESSION)
        # Normalize the sid via `10#` so a producer-emittable corruption
        # like `SESSION 1 010 ...` (leading-zero sid from a partial-flush,
        # NFS read race, schema drift, or hand-edit — same modes the
        # rest of the bug-192/193/195/196/197/199/200 audit chain
        # enumerates) registers as the integer 10 here too. Without
        # normalization, `current_session_ids` accumulates the raw
        # ` 010` token, while the per-worktree `stale_id` below at
        # line ~851 IS already `10#`-normalized via `$((10#$stale_id))`
        # — the substring regex match `[[ " 010 " =~ " 10 " ]]` then
        # silently fails (the pattern ` 10 ` requires a space before
        # `10`, but in ` 010 ` the `10` is preceded by `0`), the cleanup
        # loop classifies the corresponding worktree as orphaned even
        # though it belongs to the current run's DAG, and the safety
        # guards (is_worktree_in_use, has_unmerged) gate whether
        # `git worktree remove --force` proceeds — risking silent
        # destruction of a worktree the runner is about to recreate.
        # Symmetric audit gap to bug-197's bash-side parser fix at line
        # 616-617 (which `10#`-normalized the SAME field for the array-
        # subscript consumer at SESSION_FILE_BASENAME[$sid] but not
        # for this cleanup-loop consumer). Numeric guard mirrors the
        # bug-193 SESSION-row regex check so a non-numeric corruption
        # falls through cleanly instead of letting `$((10#abc))` raise
        # under `set -e`. (bug-203)
        if [[ "${3:-}" =~ ^[0-9]+$ ]]; then
          current_session_ids="$current_session_ids $((10#${3}))"
        fi
        ;;
    esac
  done < "$DAG_TMP"

  cleaned_count=0
  skipped_count=0
  for stale_wt in "$WORKTREE_BASE/${BRANCH_SANITIZED}--s"[0-9]*-*; do
    [[ ! -d "$stale_wt" ]] && continue

    stale_basename="$(basename "$stale_wt")"
    # Extract session ID from worktree name; [0-9]+ matches 2- and 3-digit ids.
    if [[ "$stale_basename" =~ --s([0-9]+)- ]]; then
      stale_id="${BASH_REMATCH[1]}"
      # Remove leading zero for comparison
      stale_id="$((10#$stale_id))"

      # Skip session IDs that are still part of the current DAG — those are
      # handled (with their own safety guards) by the per-wave cleanup loop.
      [[ " $current_session_ids " =~ " $stale_id " ]] && continue

      # Apply the same safety guards the per-wave cleanup uses (lines ~850-868).
      # Without these, removing a session from the epic and re-running silently
      # destroys uncommitted/unmerged work in that session's worktree, and a
      # sibling concurrent runner can have its in-flight worktree ripped out
      # from under it. The per-wave path exits 1 on guard failure (user
      # explicitly opted into the run); the startup-stale path warns + skips
      # so a leftover orphan never blocks subsequent epics. (bug-096)
      if is_worktree_in_use "$stale_wt"; then
        warn "  ⚠ stale worktree for session $stale_id is in use by another process — skipping: $stale_basename"
        warn "    Stop the other runner or remove manually if truly orphaned."
        skipped_count=$((skipped_count + 1))
        continue
      fi

      # Reconstruct the per-session branch name from the worktree dirname.
      # The worktree was created as ${BRANCH_SANITIZED}--s${padded}-${slug};
      # the matching branch was ${BRANCH}--s${padded}-${slug}. Replacing the
      # sanitized prefix with the real branch name inverts the BRANCH_SANITIZED
      # transformation without having to re-derive padding/slug separately.
      stale_branch=""
      if [[ "$stale_basename" == "${BRANCH_SANITIZED}"* ]]; then
        stale_branch="${BRANCH}${stale_basename#${BRANCH_SANITIZED}}"
      fi
      stale_has_unmerged=false
      if [[ -n "$stale_branch" ]] \
         && git show-ref --verify --quiet "refs/heads/$stale_branch"; then
        ahead="$(git rev-list --count "$BRANCH..$stale_branch" 2>/dev/null || echo 0)"
        [[ "$ahead" -gt 0 ]] && stale_has_unmerged=true
      fi
      if $stale_has_unmerged; then
        warn "  ⚠ stale worktree for session $stale_id has unmerged commits on '$stale_branch' — skipping: $stale_basename"
        # Use ORIG_REPO_ROOT (set at startup) rather than TRUNK_WORKTREE_DIR;
        # the trunk worktree isn't created until later in the script, so it
        # is empty here on the very first run of an epic.
        warn "    Inspect with: git -C $ORIG_REPO_ROOT log $BRANCH..$stale_branch --oneline"
        warn "    Then delete manually if no longer needed."
        skipped_count=$((skipped_count + 1))
        continue
      fi

      log "  ↻ removing stale worktree for session $stale_id: $stale_basename"
      git worktree remove "$stale_wt" --force 2>/dev/null || rm -rf "$stale_wt"
      cleaned_count=$((cleaned_count + 1))
    fi
  done

  [[ $cleaned_count -gt 0 ]] && log "Cleaned $cleaned_count stale session worktrees"
  [[ $skipped_count -gt 0 ]] && warn "Skipped $skipped_count stale worktree(s) for safety — see warnings above"
fi

# BASE_BRANCH default-resolution must run in BOTH worktree and --no-worktree
# modes. session_completed_on_branch (epic-git.sh) scopes its rev range to
# `${BASE_BRANCH}..${branch}` only when BASE_BRANCH is non-empty; otherwise it
# falls back to a bare `git log HEAD` walk that includes main's history, so a
# prior epic's `feat: Session N — ...` commit on main makes EVERY session
# false-positive as "already committed" on a fresh resume. Previously this
# default was nested inside `if $USE_WORKTREE`, leaving --no-worktree mode
# without an effective base ref and re-introducing the bug-080 scoping
# regression for the non-worktree code path. (bug-113)
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
  [[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="main"
fi

if $USE_WORKTREE; then
  TRUNK_WORKTREE_DIR="$WORKTREE_BASE/$BRANCH_SANITIZED"
  if [[ -d "$TRUNK_WORKTREE_DIR" ]]; then
    log "Reusing trunk worktree: $TRUNK_WORKTREE_DIR"
  else
    mkdir -p "$WORKTREE_BASE"
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      log "Creating trunk worktree on existing branch: $BRANCH"
      git worktree add "$TRUNK_WORKTREE_DIR" "$BRANCH"
    else
      log "Creating trunk worktree with new branch: $BRANCH (base: $BASE_BRANCH)"
      git worktree add -b "$BRANCH" "$TRUNK_WORKTREE_DIR" "$BASE_BRANCH"
    fi
  fi

  cd "$TRUNK_WORKTREE_DIR"
  REPO_ROOT="$TRUNK_WORKTREE_DIR"

  # Mirror sessions dir into trunk if absent (uncommitted-source case).
  TRUNK_SESSIONS_REL="$ORIG_SESSIONS_REL"
  # Guard: if the strip was a no-op, the paths didn't share a prefix — almost
  # always a case mismatch on a case-insensitive filesystem (macOS). Fail fast
  # with a clear message rather than building a malformed //abs/path/inside/dir.
  if [[ "$TRUNK_SESSIONS_REL" == "$ORIG_SESSIONS_DIR" ]]; then
    err "Sessions dir is not under repo root after path canonicalization.
  repo root    : $ORIG_REPO_ROOT
  sessions dir : $ORIG_SESSIONS_DIR
Possible cause: case mismatch on a case-insensitive filesystem (macOS APFS/HFS+).
Install GNU coreutils ('brew install coreutils') to enable reliable realpath resolution,
or ensure the sessions dir path uses the same case as the repo root."
    exit 1
  fi
  TRUNK_SESSIONS_DIR="$TRUNK_WORKTREE_DIR/$TRUNK_SESSIONS_REL"
  # Always sync session files from the source — overwrite stale copies that
  # may exist from a prior run with different filenames (e.g. after regenerating
  # session prompts). Remove old session-*.md files that no longer exist in the
  # source so awk's prompt-extraction never picks up a stale session file.
  mkdir -p "$TRUNK_SESSIONS_DIR"
  log "Syncing session files into trunk worktree..."
  # Remove session files present in trunk but absent from source
  for f in "$TRUNK_SESSIONS_DIR"/session-*.md; do
    [[ -e "$f" ]] || continue
    [[ -e "$ORIG_SESSIONS_DIR/$(basename "$f")" ]] || rm -f "$f"
  done
  # `-p` preserves source mtime so the plan-cache freshness check in
  # run_one_session (`[[ "$plan_file" -nt "$session_path" ]]`) only invalidates
  # when the user actually edits the session prompt. Without -p, every run
  # resets the destination's mtime to "now", so any cached plan from a prior
  # run looks older than the freshly-copied prompt and the plan phase
  # re-executes on every resume — exactly the scenario the cache exists for.
  # (bug-075)
  cp -p "$ORIG_SESSIONS_DIR"/session-*.md "$TRUNK_SESSIONS_DIR/" 2>/dev/null || true

  # Bootstrap commit so per-session worktrees inherit the session files.
  if ! git diff --quiet HEAD -- "$TRUNK_SESSIONS_DIR" 2>/dev/null \
     || [[ -n "$(git ls-files --others --exclude-standard "$TRUNK_SESSIONS_DIR")" ]]; then
    git add "$TRUNK_SESSIONS_DIR"
    git commit -q -m "chore: bootstrap epic session prompts

Sync session prompt files onto the epic trunk so per-session worktrees
inherit them when fanning out parallel waves.

Co-Authored-By: AI <noreply@ai>" || true
    log "Bootstrapped session prompts onto trunk"
  fi

  ok "Trunk worktree: $TRUNK_WORKTREE_DIR"
else
  CURRENT_BRANCH="$(git branch --show-current)"
  if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git checkout "$BRANCH"
    else
      git checkout -b "$BRANCH"
    fi
  fi
  TRUNK_WORKTREE_DIR="$REPO_ROOT"
  TRUNK_SESSIONS_DIR="$SESSIONS_DIR"
  TRUNK_SESSIONS_REL="$ORIG_SESSIONS_REL"
fi

# --- Run mode ---
if $SKIP_PLAN; then EXEC_MODE="execute-only"; else EXEC_MODE="plan+execute"; fi

# --- Banner ---
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${BOLD}Epic Runner — DAG mode${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Sessions dir : ${TRUNK_SESSIONS_DIR/#$HOME/~}"
log "Operator     : $(basename "$OPERATOR_PATH")"
log "Waves        : $WAVE_COUNT"
log "Range        : $START_FROM → $END_AT"
log "Model        : $MODEL"
log "Mode         : $EXEC_MODE"
log "Max parallel : $MAX_PARALLEL"
[[ "$TIMEOUT" -gt 0 ]] && log "Timeout      : ${TIMEOUT}m per session"
[[ "$RETRY" -gt 0 ]] && log "Retry        : up to $RETRY attempts per session"
log "Frontmatter  : $ANY_FRONTMATTER"
log "Branch       : $BRANCH (trunk)"
[[ -n "$TRUNK_WORKTREE_DIR" && "$TRUNK_WORKTREE_DIR" != "$ORIG_REPO_ROOT" ]] \
  && log "Trunk wt     : ${TRUNK_WORKTREE_DIR/#$HOME/~}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
show_effective_dag
echo ""

# --- Live UI setup ---
STATUS_FILE="${TRUNK_SESSIONS_DIR}/.epic-status.json"
DAG_PLAN_FILE="${TRUNK_SESSIONS_DIR}/.epic-dag-plan.bash"
UI_PID=""
LIVE_UI=false

# Copy the dag plan to a stable path (DAG_TMP is deleted on EXIT)
cp "$DAG_TMP" "$DAG_PLAN_FILE"

# Initialize shared status JSON (all sessions start as "pending").
# Skip malformed SESSION lines (truncation from a partial-flush, non-numeric
# wave/id from schema drift or a hand-edit) instead of crashing the heredoc
# with an unhandled IndexError/ValueError. The shell side does not check
# this Python's exit code, so a single bad line previously left the status
# file uninitialized — every session displayed as 'pending' forever in the
# UI even after completion, defeating the live progress feature for the
# whole run with no diagnostic. Symmetric to the parse_bash_plan fix in
# epic-ui.py; same audit class as bug-185/186/188/189.
"$PYTHON_CMD" - "$STATUS_FILE" "$EPIC_NAME_SLUG" "$DAG_PLAN_FILE" <<'PYEOF_INIT'
import sys, json, time
sf, epic, pf = sys.argv[1], sys.argv[2], sys.argv[3]
sessions = {}
with open(pf, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line.startswith('SESSION '): continue
        parts = line.split(None, 6)
        if len(parts) < 6: continue
        try:
            wn = int(parts[1])
            int(parts[2])  # validate sid is numeric for parity with the UI consumer
        except ValueError:
            continue
        # Normalize sid via int → str round-trip to strip leading zeros.
        # Bug-197 patched the bash-side parser at line 569-651 to `10#`-
        # normalize sw/sid (so a producer-emittable corruption like
        # `SESSION 1 010 ...` registers in WAVE_IDS[1] / SESSION_*[10]
        # instead of WAVE_IDS[1] / SESSION_*[8]) and the .epic-config.json
        # / META wave_count / cmdline numeric flags. This heredoc init
        # was the symmetric audit gap: parts[2] is read verbatim as the
        # status-file key, so a `010` corruption lands `sessions["010"]`
        # while every subsequent mark_session call writes `sessions["10"]`
        # (mark_session uses `str(session_id)` where session_id is the
        # already-`10#`-normalized bash int). The status file ends up
        # with both keys — `"010"` (pending forever, orphaned by every
        # consumer that round-trips the sid through `int`) and `"10"`
        # (the live entry). The dashboard's parse_bash_plan keys via
        # `int(parts[2])` and looks up via `str(int(parts[2]))="10"`, so
        # it never sees the orphan; the pollution survives across the
        # entire run, the cleanup at the success path's tearstdown
        # removes only `${STATUS_FILE}` itself but the orphan key already
        # corrupted any external watcher reading the file mid-run. Same
        # producer-corruption modes as bug-192/193/195/196/197/199/200
        # (partial-flush from a SIGKILL'd `cp` mid-write, NFS read race,
        # schema drift from a future writer, hand-edit for debugging).
        # The `int(parts[2])` validation above already guarantees the
        # value is parseable as a base-10 integer; the round-trip here
        # is purely a string-canonicalisation step. (bug-202)
        sid, slug = str(int(parts[2])), parts[5]
        sessions[sid] = {
            'status': 'pending', 'slug': slug, 'wave': wn,
            'title': slug.replace('-', ' ').title(),
            'step': 0, 'tool': '', 'target': '', 'elapsed': 0.0,
        }
with open(sf, 'w', encoding='utf-8') as f:
    json.dump({'epic': epic, 'started_at': time.time(), 'sessions': sessions}, f, indent=2)
PYEOF_INIT

# Launch live dashboard only when stderr is a real TTY (cursor-up redraws work).
# In Claude Code / piped contexts isatty() is false — shell's existing colored
# output handles progress there; no background watcher needed.
if [[ -f "$UI_SCRIPT" && -t 2 ]]; then
  "$PYTHON_CMD" "$UI_SCRIPT" \
    --plan-bash "$DAG_PLAN_FILE" \
    --status-file "$STATUS_FILE" \
    --epic "$EPIC_NAME_SLUG" &
  UI_PID=$!
  LIVE_UI=true
  sleep 0.3   # brief pause so initial panel renders before wave messages
fi

# ---------------------------------------------------------------------------
# Wave loop — fans out sessions per wave, merges successes into trunk
# ---------------------------------------------------------------------------
declare -a SESSION_STATUS         # by id: pending|done|failed|skipped
declare -a SESSION_BRANCH_BY_ID   # by id
declare -a SESSION_WT_BY_ID       # by id
declare -a SESSION_START_TS       # by id (epoch seconds)
declare -a SESSION_ELAPSED_BY_ID  # by id (seconds, populated on reap)
declare -a SESSION_EXIT_BY_ID     # by id (exit code, populated on reap)
declare -a MERGED_SESSIONS        # ids merged into trunk

EPIC_FAILED=false
FIRST_FAILED_ID=""
EPIC_START_TS="$(date +%s)"

for (( wn=1; wn<=WAVE_COUNT; wn++ )); do
  ids="${WAVE_IDS[$wn]:-}"
  ids="$(echo "$ids" | xargs)"   # trim
  [[ -z "$ids" ]] && continue

  # Filter by --start/--end
  IFS=' ' read -ra ALL_IN_WAVE <<< "$ids"
  IN_RANGE=()
  for sid in "${ALL_IN_WAVE[@]}"; do
    if [[ "$sid" -lt "$START_FROM" ]]; then
      SESSION_STATUS[$sid]="skipped"
      mark_session "${STATUS_FILE:-}" "$sid" "skipped"
      continue
    fi
    if [[ "$sid" -gt "$END_AT" ]]; then
      SESSION_STATUS[$sid]="skipped"
      mark_session "${STATUS_FILE:-}" "$sid" "skipped"
      continue
    fi
    IN_RANGE+=("$sid")
  done

  if [[ ${#IN_RANGE[@]} -eq 0 ]]; then
    dim "  skip wave $wn (all sessions outside range)"
    continue
  fi

  # Wave banner (suppressed when live UI owns the display)
  if ! $LIVE_UI; then
    echo ""
    log "┌─────────────────────────────────────────────────────"
    if [[ ${#IN_RANGE[@]} -gt 1 ]]; then
      log "│ ${BOLD}Wave $wn / $WAVE_COUNT${NC}  (${MAGENTA}${#IN_RANGE[@]} sessions in parallel${NC})"
    else
      log "│ ${BOLD}Wave $wn / $WAVE_COUNT${NC}  (1 session, serial)"
    fi
    for sid in "${IN_RANGE[@]}"; do
      log "│   • session $(printf '%02d' "$sid") — ${SESSION_SLUG_BY_ID[$sid]}  (deps: ${SESSION_DEPS_BY_ID[$sid]})"
    done
    log "└─────────────────────────────────────────────────────"
  fi

  # Make sure trunk is checked out at TRUNK_WORKTREE_DIR (so siblings branch off it)
  if $USE_WORKTREE; then
    git -C "$TRUNK_WORKTREE_DIR" checkout -q "$BRANCH"
  fi

  # --- Spawn wave sessions ---
  declare -a JOB_PIDS=()
  declare -a JOB_SIDS=()

  for sid in "${IN_RANGE[@]}"; do
    # Throttle to MAX_PARALLEL
    while [[ ${#JOB_PIDS[@]} -ge $MAX_PARALLEL ]]; do
      reap_finished_jobs
      [[ ${#JOB_PIDS[@]} -ge $MAX_PARALLEL ]] && sleep 1
    done

    slug="${SESSION_SLUG_BY_ID[$sid]}"
    friendly="${slug//-/ }"
    # Use "--" not "/" as the trunk→session separator so per-session branch
    # names don't try to nest under the trunk's ref path. Git rejects creating
    # `epic/shipment-io/s01-charter` while `epic/shipment-io` already exists
    # as a leaf branch (ref-directory conflict).
    sess_branch="${BRANCH}--s$(printf '%02d' "$sid")-${slug}"
    sess_wt_dir_name="${BRANCH_SANITIZED}--s$(printf '%02d' "$sid")-${slug}"
    SESSION_BRANCH_BY_ID[$sid]="$sess_branch"

    if $USE_WORKTREE; then
      sess_wt="$WORKTREE_BASE/$sess_wt_dir_name"
      # Wipe stale worktree from a prior failed run, but only if safe:
      # 1. No process has a CWD inside it (concurrent runner)
      # 2. No unmerged commits beyond the trunk branch (uncaptured work)
      if [[ -d "$sess_wt" ]]; then
        if is_worktree_in_use "$sess_wt"; then
          err "  ✗ worktree for session $sid is in use by another process: $sess_wt"
          err "    refusing to delete; aborting. Stop the other runner or remove manually."
          exit 1
        fi
        has_unmerged=false
        if git show-ref --verify --quiet "refs/heads/$sess_branch"; then
          ahead="$(git rev-list --count "$BRANCH..$sess_branch" 2>/dev/null || echo 0)"
          [[ "$ahead" -gt 0 ]] && has_unmerged=true
        fi
        if $has_unmerged; then
          err "  ✗ session $sid branch '$sess_branch' has unmerged commits ahead of $BRANCH"
          err "    refusing to delete; aborting. Inspect, merge, or remove the branch manually:"
          err "    git -C $TRUNK_WORKTREE_DIR log $BRANCH..$sess_branch --oneline"
          exit 1
        fi
        log "  ↻ removing stale worktree for session $sid: $sess_wt"
        git worktree remove "$sess_wt" --force 2>/dev/null || rm -rf "$sess_wt"
      fi
      if git show-ref --verify --quiet "refs/heads/$sess_branch"; then
        git branch -D "$sess_branch" 2>/dev/null || true
      fi
      git -C "$TRUNK_WORKTREE_DIR" worktree add -b "$sess_branch" "$sess_wt" "$BRANCH"
    else
      # No worktree → commit directly to trunk; no per-session branch.
      sess_wt="$TRUNK_WORKTREE_DIR"
      SESSION_BRANCH_BY_ID[$sid]="$BRANCH"
    fi
    SESSION_WT_BY_ID[$sid]="$sess_wt"

    handoff_text="$(build_handoff_section "${SESSION_DEPS_BY_ID[$sid]}")"

    quiet="false"
    [[ ${#IN_RANGE[@]} -gt 1 ]] && quiet="true"

    ! $LIVE_UI && log "  ▶ session $(printf '%02d' "$sid") (${slug}) starting → branch $sess_branch"

    SESSION_STATUS[$sid]="running"
    SESSION_START_TS[$sid]=$(date +%s)
    mark_session "${STATUS_FILE:-}" "$sid" "running"
    (
      run_one_session "$sid" "$sess_wt" "$friendly" "$handoff_text" "$quiet"
    ) &
    pid=$!
    JOB_PIDS+=("$pid")
    JOB_SIDS+=("$sid")
  done

  # Wait for all jobs in this wave with timeout protection.
  # Compute effective wave ceiling per-wave so --timeout is never silently
  # overridden by a hardcoded global. When --wave-timeout was not explicitly
  # set, auto-derive: ceil(wave_size / MAX_PARALLEL) serial batches × per-session
  # timeout + 10 min buffer, with a 240-min floor. (bug-083)
  wave_start=$(date +%s)
  _wave_size="${#IN_RANGE[@]}"
  if $WAVE_TIMEOUT_USER_SET; then
    _effective_wtm="$WAVE_TIMEOUT_MINUTES"
  else
    _effective_wtm=240
    if [[ "$TIMEOUT" -gt 0 ]]; then
      _batches=$(( (_wave_size + MAX_PARALLEL - 1) / MAX_PARALLEL ))
      _needed=$(( _batches * TIMEOUT + 10 ))
      [[ "$_needed" -gt "$_effective_wtm" ]] && _effective_wtm="$_needed"
    fi
  fi
  wave_timeout=$((_effective_wtm * 60))
  if ! $LIVE_UI; then
    if [[ $wave_timeout -gt 0 ]]; then
      log "  ⏳ Wave $wn: awaiting ${#JOB_PIDS[@]} session(s) (timeout ${_effective_wtm}m)"
    else
      log "  ⏳ Wave $wn: awaiting ${#JOB_PIDS[@]} session(s) (no wave timeout)"
    fi
  fi
  heartbeat_iters=0
  while [[ ${#JOB_PIDS[@]} -gt 0 ]]; do
    wave_elapsed=$(($(date +%s) - wave_start))
    # Treat wave_timeout=0 as DISABLED (consistent with --timeout 0 = disabled
    # per session). Without this gate, an explicit `--wave-timeout 0` (or a
    # `.epic-config.json` `"waveTimeout": 0`) sets WAVE_TIMEOUT_USER_SET=true,
    # bypasses auto-derive, lands wave_timeout=0, and the comparison
    # `$wave_elapsed -gt 0` fires after the first 2-second sleep — killing
    # every in-flight session before it can do any real work and reporting
    # the epic as failed. (bug-153)
    if [[ $wave_timeout -gt 0 && $wave_elapsed -gt $wave_timeout ]]; then
      err "Wave timeout after $((wave_elapsed / 60)) minutes; killing hung jobs"
      # Kill, reap, and mark each in-flight session as failed. Without this
      # the merge phase finds status='running' (neither 'done' nor 'failed'),
      # falls through silently, EPIC_FAILED stays false, and the epic is
      # falsely reported as successful at end-of-run.
      for _ti in "${!JOB_PIDS[@]}"; do
        _tpid="${JOB_PIDS[$_ti]}"
        _tsid="${JOB_SIDS[$_ti]}"
        # Recursive process-tree kill — covers --timeout wrapper grandchildren
        # (subshell → `timeout` → `claude`) that pkill -P alone would leave
        # orphaned at PID 1. See kill_tree in epic-wave.sh. (bug-073)
        kill_tree "$_tpid"
        wait "$_tpid" 2>/dev/null || true
        _telapsed=$(( $(date +%s) - ${SESSION_START_TS[$_tsid]:-0} ))
        SESSION_STATUS[$_tsid]="failed"
        SESSION_ELAPSED_BY_ID[$_tsid]=$_telapsed
        SESSION_EXIT_BY_ID[$_tsid]=137
        mark_session "${STATUS_FILE:-}" "$_tsid" "failed" "$_telapsed"
        ! $LIVE_UI && err "  ✗ session $(printf '%02d' "$_tsid") (${SESSION_SLUG_BY_ID[$_tsid]}) KILLED by wave timeout after $(format_elapsed "$_telapsed")"
        [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$_tsid"
      done
      JOB_PIDS=()
      JOB_SIDS=()
      EPIC_FAILED=true
      unset _ti _tpid _tsid _telapsed
      break
    fi
    reap_finished_jobs
    if [[ ${#JOB_PIDS[@]} -gt 0 ]]; then
      sleep 2
      heartbeat_iters=$((heartbeat_iters + 1))
      # Heartbeat every ~60s (30 × 2s) so the runner doesn't look dead when
      # a long session is in flight. Suppressed under LIVE_UI; the dashboard
      # already shows per-session progress there.
      if ! $LIVE_UI && (( heartbeat_iters % 30 == 0 )); then
        running_list=""
        for psid in "${JOB_SIDS[@]}"; do
          running_list+=" s$(printf '%02d' "$psid")"
        done
        log "  ⏳ Wave $wn still running:${running_list} (elapsed $(format_elapsed "$wave_elapsed"))"
      fi
    fi
  done
  ! $LIVE_UI && log "  ✔ Wave $wn: all sessions reaped — beginning merge"

  # --- Merge successful wave children into trunk ---
  if $USE_WORKTREE; then
    git -C "$TRUNK_WORKTREE_DIR" checkout -q "$BRANCH"
  fi

  any_failed=false
  for sid in "${IN_RANGE[@]}"; do
    case "${SESSION_STATUS[$sid]:-}" in
      done)
        slug="${SESSION_SLUG_BY_ID[$sid]}"
        if $USE_WORKTREE; then
          sess_branch="${SESSION_BRANCH_BY_ID[$sid]}"
          if git -C "$TRUNK_WORKTREE_DIR" merge --no-ff -q \
              -m "Merge session $(printf '%02d' "$sid") (${slug}) into ${BRANCH}" \
              "$sess_branch"
          then
            ! $LIVE_UI && ok "  ⇢ merged session $(printf '%02d' "$sid") into trunk"
            add_merged_session "$sid"
          else
            # Wave merge conflict. Try auto-resolving if conflicts are
            # .wolf/-only (append-only metadata; theirs = session = winner).
            # Capture return code explicitly: 0=all-wolf resolved,
            # 1=non-wolf conflicts exist, 2=no conflict markers at all
            # (git merge failed for a non-conflict reason such as an
            # index.lock or dirty tree). Treating 2 the same as 1 used to
            # run `merge --abort` on a merge that was never started, print
            # a misleading "MERGE CONFLICT" message, and falsely abort the
            # entire epic. (bug-087)
            _resolve_rc=0
            auto_resolve_wolf_conflicts "$TRUNK_WORKTREE_DIR" "theirs" || _resolve_rc=$?
            if [[ $_resolve_rc -eq 0 ]]; then
              warn "  ⚠ auto-resolving .wolf/ conflicts for session $(printf '%02d' "$sid") (metadata files only)"
              # Wrap the auto-resolve commit in an `if` so a hook failure,
              # GPG signing failure, or index lock contention does not abort
              # the runner mid-wave under `set -e` — that path skipped
              # write_epic_result and left external watchers polling for a
              # result file that was never written. (bug-077)
              if git -C "$TRUNK_WORKTREE_DIR" commit -q \
                  -m "Merge session $(printf '%02d' "$sid") (${slug}) into ${BRANCH} [wolf auto-resolved]

Co-Authored-By: AI <noreply@ai>" 2>/dev/null; then
                ! $LIVE_UI && ok "  ⇢ merged session $(printf '%02d' "$sid") into trunk (wolf conflicts auto-resolved)"
                add_merged_session "$sid"
              else
                err "  ⇢ MERGE COMMIT FAILED after wolf auto-resolve for session $(printf '%02d' "$sid")"
                err "      Trunk worktree: $TRUNK_WORKTREE_DIR"
                err "      Common causes: failing pre-commit hook, GPG signing failure, index lock"
                err "      Inspect, then resume with --start $((sid + 1))"
                git -C "$TRUNK_WORKTREE_DIR" merge --abort 2>/dev/null || true
                EPIC_FAILED=true
                [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$sid"
                break
              fi
            elif [[ $_resolve_rc -eq 2 ]]; then
              # No conflict markers found, but git merge still returned
              # non-zero. Most likely cause: index.lock held by another
              # process, or a dirty/staged state that prevented the merge
              # from starting. A merge-in-progress state does not exist,
              # so `merge --abort` must NOT be called here (it would fail
              # on a non-existent merge and produce a confusing extra error).
              err "  ⇢ MERGE FAILED for session $(printf '%02d' "$sid") — no conflict markers found"
              err "      Likely cause: git index.lock contention or dirty working tree"
              err "      Trunk worktree: $TRUNK_WORKTREE_DIR"
              err "      Inspect, then resume with --start $sid"
              unset _resolve_rc
              EPIC_FAILED=true
              [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$sid"
              break
            else
              err "  ⇢ MERGE CONFLICT merging session $(printf '%02d' "$sid") into trunk"
              err "      Trunk worktree: $TRUNK_WORKTREE_DIR"
              err "      Resolve, commit, and resume with --start $((sid + 1))"
              git -C "$TRUNK_WORKTREE_DIR" merge --abort 2>/dev/null || true
              unset _resolve_rc
              EPIC_FAILED=true
              [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$sid"
              break
            fi
            unset _resolve_rc
          fi
        else
          # Session committed directly to trunk; no merge required.
          add_merged_session "$sid"
        fi
        ;;
      failed)
        any_failed=true
        EPIC_FAILED=true
        [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$sid"
        ;;
    esac
  done

  if $EPIC_FAILED; then
    err "Wave $wn had failures — halting before subsequent waves."
    break
  fi

  # Remove successful per-session worktrees and branches (keep on failure for inspection)
  if $USE_WORKTREE && ! $KEEP_SESSION_WORKTREES; then
    for sid in "${IN_RANGE[@]}"; do
      if [[ "${SESSION_STATUS[$sid]:-}" == "done" ]]; then
        sess_wt="${SESSION_WT_BY_ID[$sid]}"
        if [[ -d "$sess_wt" ]]; then
          git -C "$TRUNK_WORKTREE_DIR" worktree remove "$sess_wt" --force 2>/dev/null || true
        fi
        # Delete the per-session branch — it's fully merged into trunk
        _sb="${SESSION_BRANCH_BY_ID[$sid]:-}"
        if [[ -n "$_sb" && "$_sb" != "$BRANCH" ]]; then
          git branch -D "$_sb" 2>/dev/null || true
        fi
      fi
    done
    git worktree prune 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------------------
# Shut down live UI and print final summary
# ---------------------------------------------------------------------------
if [[ -n "$UI_PID" ]] && kill -0 "$UI_PID" 2>/dev/null; then
  sleep 0.5    # allow one last redraw to show final state
  kill "$UI_PID" 2>/dev/null || true
  wait "$UI_PID" 2>/dev/null || true
fi
echo ""
if ! $EPIC_FAILED; then
  write_epic_result "success"
  ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ok "${BOLD}Epic completed successfully${NC}"
  ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ ${#MERGED_SESSIONS[@]} -gt 0 ]]; then
    ok ""
    ok "Sessions merged into ${BRANCH}:"
    for entry in "${MERGED_SESSIONS[@]}"; do
      ok "  $entry"
    done
  fi
  ok ""
  if [[ "$TIMEOUT" -gt 0 || "$RETRY" -gt 0 ]]; then
    ok "Runtime settings:"
    [[ "$TIMEOUT" -gt 0 ]] && ok "  Timeout: ${TIMEOUT}m per session"
    [[ "$RETRY" -gt 0 ]] && ok "  Retry: up to $RETRY attempts per session"
    ok ""
  fi
  ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # --- Verify the epic *actually* succeeded across every session ---
  # `! $EPIC_FAILED` only confirms no session FAILED in this run — it stays
  # false when sessions are skipped via --start/--end (partial run) or when
  # the user resumed a prior run. Cleanup deletes the session prompt files
  # and roadmap handoffs, so doing it on a partial epic destroys scaffolding
  # the user still needs. Delegate per-session detection to the helper so
  # AI subject variation (em-dash vs hyphen) and Git Bash on Windows locale
  # quirks don't false-negative an actually-complete epic.
  ALL_SESSIONS_DONE=true
  INCOMPLETE_SESSIONS=()
  for sid in "${!SESSION_SLUG_BY_ID[@]}"; do
    if ! session_completed_on_branch "$sid" "$BRANCH" "$TRUNK_WORKTREE_DIR"; then
      ALL_SESSIONS_DONE=false
      INCOMPLETE_SESSIONS+=("session-$(printf '%02d' "$sid") (${SESSION_STATUS[$sid]:-not-run})")
    fi
  done

  if ! $ALL_SESSIONS_DONE; then
    warn "Skipping scaffolding cleanup — ${#INCOMPLETE_SESSIONS[@]} session(s) without a success commit on $BRANCH:"
    for _s in "${INCOMPLETE_SESSIONS[@]}"; do
      warn "  - $_s"
    done
    unset _s
    warn "Re-run to finish the remaining sessions; cleanup runs only when every session has its merge or 'feat: Session N' commit."
    AUTO_PR=false
  else
    # --- Cleanup: orchestrator artifacts + session scaffolding ---
    # Remove everything that isn't actual product code from the epic branch so
    # the final PR diff is clean: dotfile artefacts, session prompt files, and
    # the per-epic roadmap/handoff directory. Use --keep-session-docs to skip.
    log "Cleaning up session scaffolding..."
    cd "$REPO_ROOT"

    # 1. Dotfile artefacts (.session-*-plan.md, .epic-*.json, etc.)
    CLEANED=0
    for f in "$TRUNK_SESSIONS_DIR"/.session-* \
              "${STATUS_FILE:-}" "${DAG_PLAN_FILE:-}" \
              "${STATUS_FILE:-}.lock" "${STATUS_FILE:-}.tmp"; do
      [[ -f "$f" ]] && rm -f "$f" && CLEANED=$((CLEANED + 1))
    done
    [[ $CLEANED -gt 0 ]] && git add -A 2>/dev/null || true

    # 2. Session prompt files and handoffs (scaffolding, not product code)
    _EPIC_SLUG="$(basename "$TRUNK_SESSIONS_REL")"
    _ROADMAP_REL="docs/roadmap/$_EPIC_SLUG"
    if ! $KEEP_SESSION_DOCS; then
      # Remove docs/claude-sessions/<epic-name>/ — git rm for tracked files,
      # then rm -rf to catch untracked stragglers (logs the AI wrote outside
      # the bootstrap commit, files added but never committed, etc.) before
      # the worktree teardown might silently leak them.
      if git ls-files --error-unmatch "$TRUNK_SESSIONS_REL" &>/dev/null 2>&1; then
        git rm -r -q "$TRUNK_SESSIONS_REL" 2>/dev/null || true
      fi
      rm -rf "$REPO_ROOT/$TRUNK_SESSIONS_REL" 2>/dev/null || true
      # Same dual-removal for docs/roadmap/<epic-name>/.
      if git ls-files --error-unmatch "$_ROADMAP_REL" &>/dev/null 2>&1; then
        git rm -r -q "$_ROADMAP_REL" 2>/dev/null || true
      fi
      rm -rf "$REPO_ROOT/$_ROADMAP_REL" 2>/dev/null || true
    fi

    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -q -m "chore: remove epic session scaffolding

Removes docs/claude-sessions/${_EPIC_SLUG}/ and any per-epic roadmap
handoffs. These files served as AI orchestration scaffolding during the
run; they do not belong in the final PR diff or repository history.

Co-Authored-By: AI <noreply@ai>" 2>/dev/null || true
      if $KEEP_SESSION_DOCS; then
        ok "Cleaned orchestrator artefacts (session docs preserved via --keep-session-docs)"
      else
        ok "Cleaned session scaffolding — PR diff contains only product code"
      fi
    fi
  fi

  # --- Pre-PR rebase: replay epic onto latest origin/<default> with .wolf/ auto-resolve ---
  # This makes the GitHub PR fast-forward-mergeable even if main has advanced
  # while the epic ran. Conflicts in .wolf/ paths are auto-resolved (theirs);
  # any non-.wolf/ conflict aborts the rebase cleanly and the unrebased branch
  # is pushed as-is for manual conflict resolution on GitHub.
  REBASE_RESULT="skipped"
  if $AUTO_REBASE && command -v gh &>/dev/null; then
    REBASE_DEFAULT="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
    log "Fetching origin/${REBASE_DEFAULT} for pre-PR rebase..."
    if git -C "$REPO_ROOT" fetch -q origin "$REBASE_DEFAULT" 2>/dev/null; then
      log "Rebasing $BRANCH onto origin/${REBASE_DEFAULT} (auto-resolving .wolf/)..."
      if rebase_with_wolf_resolve "$REPO_ROOT" "origin/${REBASE_DEFAULT}"; then
        REBASE_RESULT="ok"
        ok "Rebased onto origin/${REBASE_DEFAULT} — PR will be fast-forward-mergeable"
      else
        REBASE_RESULT="conflict"
        warn "Rebase aborted — non-.wolf/ conflicts require manual resolution on the PR"
      fi
    else
      REBASE_RESULT="fetch-failed"
      warn "Could not fetch origin/${REBASE_DEFAULT} — skipping rebase, pushing as-is"
    fi
  fi

  # --- Auto-PR ---
  if $AUTO_PR && command -v gh &>/dev/null; then
    CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
    DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
    if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
      EXISTING_PR="$(gh pr view "$CURRENT_BRANCH" --json url -q '.url' 2>/dev/null || true)"
      if [[ -n "$EXISTING_PR" ]]; then
        ok "PR already exists: $EXISTING_PR"
        # Even if PR exists, push the rebased history so the PR becomes mergeable
        if [[ "$REBASE_RESULT" == "ok" ]]; then
          log "Force-pushing rebased history to existing PR..."
          git -C "$REPO_ROOT" push --force-with-lease 2>&1 | tail -5 || warn "Force-push failed; PR may still show conflicts"
        fi
      else
        log "Creating pull request..."
        # If we rebased, the local branch has diverged from any remote tracking ref;
        # use force-with-lease to update. For a brand-new branch, plain push -u.
        if ! git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
          git -C "$REPO_ROOT" push -u origin "$CURRENT_BRANCH"
        elif [[ "$REBASE_RESULT" == "ok" ]]; then
          git -C "$REPO_ROOT" push --force-with-lease 2>&1 | tail -5 || git -C "$REPO_ROOT" push
        elif [[ -n "$(git -C "$REPO_ROOT" log '@{u}..HEAD' --oneline 2>/dev/null)" ]]; then
          git -C "$REPO_ROOT" push
        fi

        EPIC_NAME="$(basename "$TRUNK_SESSIONS_DIR" | tr '-' ' ')"
        SESSION_LIST=""
        if [[ ${#MERGED_SESSIONS[@]} -gt 0 ]]; then
          for entry in "${MERGED_SESSIONS[@]}"; do
            SESSION_LIST="${SESSION_LIST}
- ${entry}"
          done
        else
          SESSION_LIST="
(No sessions were merged in this run)"
        fi
        # Prefer `origin/<default>` over the local `<default>` ref for the PR
        # diff stats. `git fetch --prune` (cleanup_merged_epic_branches at the
        # tail of the run) updates the remote-tracking ref but does NOT
        # fast-forward the local one, AND the auto-rebase at line 1589 just
        # rebased HEAD onto `origin/$REBASE_DEFAULT` — so any time the user's
        # local `<default>` lags behind origin (very common in worktree
        # workflows), `<local>...HEAD` walks the merge-base back to the
        # local tip and the shortstat absorbs every commit that landed on
        # origin between the two — inflating the PR body's "Stats" section
        # with churn that isn't part of this epic. Same audit pattern as
        # cleanup_merged_epic_branches in epic-git.sh:255-258 where the
        # local-vs-origin lag was already documented; this is the symmetric
        # site that was missed.
        DEFAULT_REF="$DEFAULT_BRANCH"
        if git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
          DEFAULT_REF="origin/$DEFAULT_BRANCH"
        fi
        DIFF_STATS="$(git -C "$REPO_ROOT" diff --shortstat "${DEFAULT_REF}...HEAD" 2>/dev/null || echo "")"

        PR_TITLE="feat: ${EPIC_NAME}"
        PR_BODY="## Summary

Automated DAG epic: **${EPIC_NAME}**

Executed ${WAVE_COUNT} wave(s) across the parallel scheduler using \`${MODEL}\`.

### Sessions${SESSION_LIST}

### Stats

${DIFF_STATS}

🤖 Generated with DAG epic runner"

        PR_URL="$(gh pr create --title "$PR_TITLE" --body "$PR_BODY" 2>&1)" || true
        if [[ "$PR_URL" == http* ]]; then
          ok "Pull request created: $PR_URL"
        else
          warn "Could not create PR: $PR_URL"
        fi
      fi
    else
      warn "On default branch ($DEFAULT_BRANCH) — skipping PR creation"
    fi
  elif $AUTO_PR; then
    warn "gh CLI not found — skipping PR creation"
  fi

  # --- Trunk worktree + stale ref cleanup ---
  cd "$ORIG_REPO_ROOT"
  if $USE_WORKTREE && [[ -n "$TRUNK_WORKTREE_DIR" ]]; then
    if $KEEP_WORKTREE; then
      log "Keeping trunk worktree: $TRUNK_WORKTREE_DIR"
    else
      # Try git's worktree remove first, then plain rm -rf. On Windows,
      # `git worktree remove --force` regularly fails when antivirus, an
      # IDE, or another shell holds a handle inside the worktree — and
      # silently swallowing that error left users with a half-cleaned
      # scaffolding dir. Surface the failure so they know to retry rather
      # than wonder why session files persisted on a "successful" run.
      _wt_err="$(mktemp 2>/dev/null || echo "/tmp/wt-rm.$$")"
      if git worktree remove "$TRUNK_WORKTREE_DIR" --force 2>"$_wt_err"; then
        :
      elif rm -rf "$TRUNK_WORKTREE_DIR" 2>/dev/null && [[ ! -d "$TRUNK_WORKTREE_DIR" ]]; then
        warn "Trunk worktree removed via rm -rf fallback (git worktree remove failed): $TRUNK_WORKTREE_DIR"
      else
        warn "Could not remove trunk worktree: $TRUNK_WORKTREE_DIR"
        [[ -s "$_wt_err" ]] && warn "  git worktree said: $(head -n 3 "$_wt_err" | tr '\n' ' ')"
        warn "  Common causes on Windows: antivirus scanning, IDE/editor handles, another shell with cwd inside."
        warn "  Retry manually: git worktree remove --force '$TRUNK_WORKTREE_DIR' && git worktree prune"
      fi
      rm -f "$_wt_err"
      unset _wt_err
      # Sweep any empty leftover scaffolding under the worktree base
      # (handles both this run's parent dir and stale dirs from old runs).
      _wt_base="$(dirname "$TRUNK_WORKTREE_DIR")"
      if [[ -d "$_wt_base" ]]; then
        # Remove empty dirs depth-first (-empty + -delete is safe — won't touch non-empty)
        find "$_wt_base" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
      fi
      # Climb upward removing empty parents (e.g. the per-repo or top-level base)
      _wt_parent="$_wt_base"
      while [[ -d "$_wt_parent" ]] && rmdir "$_wt_parent" 2>/dev/null; do
        _wt_parent="$(dirname "$_wt_parent")"
      done
      unset _wt_base _wt_parent
    fi
  fi
  git worktree prune 2>/dev/null || true

  # Surface any per-session worktree leaks (silently swallowed during the
  # wave loop's per-session removal). On Windows these can pile up across
  # runs because file locks block `git worktree remove` and we don't notice.
  if $USE_WORKTREE && ! $KEEP_SESSION_WORKTREES \
     && [[ -n "${WORKTREE_BASE:-}" && -d "$WORKTREE_BASE" ]]; then
    _leaked=0
    for _d in "$WORKTREE_BASE/${BRANCH_SANITIZED}--s"*; do
      [[ -d "$_d" ]] && _leaked=$((_leaked + 1))
    done
    if [[ $_leaked -gt 0 ]]; then
      warn "$_leaked per-session worktree(s) could not be removed: $WORKTREE_BASE"
      warn "  Inspect, then: git worktree prune (and rm -rf <leftovers> if needed)"
    fi
    unset _leaked _d
  fi

  # --- Post-merge stale-branch cleanup ---
  # Sweep merged epic branches whose PRs are closed/merged. This catches
  # both this epic (if user merged the PR before script exit) and any
  # leftover branches from previous runs.
  cleanup_merged_epic_branches "$ORIG_REPO_ROOT"

  ok ""
  ok "Branch ready: $BRANCH"
  # Use the resolved BASE_BRANCH (line 943-945 detects origin/HEAD or falls
  # back to "main") rather than hardcoding `main`. On a repo whose default
  # branch is `master` / `develop` / `trunk`, the previous form silently
  # printed an unrunnable `gh pr create --base main` — the user copy-pasted
  # it and got "branch main does not exist on remote", with no signal that
  # the script's own advice was wrong. BASE_BRANCH is always resolved by
  # the time we reach this success-path tail (the resolution block at line
  # 943 runs unconditionally before any worktree setup).
  ok "Next step  : gh pr create --base $BASE_BRANCH --head $BRANCH"
else
  write_epic_result "failed"
  err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  err "${BOLD}Epic stopped${NC}"
  err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ -n "$FIRST_FAILED_ID" ]]; then
    err "First failure: session $(printf '%02d' "$FIRST_FAILED_ID")"
    err "Resume with: $(basename "$0") $ORIG_SESSIONS_DIR --start $FIRST_FAILED_ID --branch $BRANCH"
  fi
  if $USE_WORKTREE; then
    err "Trunk worktree preserved : $TRUNK_WORKTREE_DIR"
    err "Failed session worktrees : $WORKTREE_BASE/${BRANCH_SANITIZED}--s*-* (inspect, then re-run)"
  fi
  err "Detailed results: ${EPIC_RESULT_FILE/#$HOME/~}"
  exit 1
fi
