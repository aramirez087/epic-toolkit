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
#   --strict             Fail when sibling sessions declare overlapping `touches` globs
#   --sequential         Force one-session-per-wave (treats DAG as a linear chain)
#   --show-dag           Print the planned waves and exit
#   --dry-run            Preview without executing
#   --branch NAME        Trunk branch (default: epic/<name>)
#   --base BRANCH        Base branch for trunk (default: repo default)
#   --model MODEL        Claude model: opus, sonnet (default), haiku
#   --no-commit          Skip auto-commit fallback
#   --no-pr              Skip auto-PR creation
#   --skip-plan          Single-pass mode (no separate plan phase)
#   --no-worktree        Run trunk in CWD (forces --max-parallel 1)
#   --keep-worktree      Retain trunk worktree on success
#   --keep-session-worktrees  Retain per-session worktrees on success
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
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
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
SKIP_PLAN=false
USE_WORKTREE=true
KEEP_WORKTREE=false
KEEP_SESSION_WORKTREES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)                    START_FROM="$2"; shift 2 ;;
    --end)                      END_AT="$2"; shift 2 ;;
    --max-parallel)             MAX_PARALLEL="$2"; shift 2 ;;
    --strict)                   STRICT=true; shift ;;
    --sequential)               SEQUENTIAL=true; shift ;;
    --show-dag)                 SHOW_DAG=true; shift ;;
    --dry-run)                  DRY_RUN=true; shift ;;
    --branch)                   BRANCH="$2"; shift 2 ;;
    --base)                     BASE_BRANCH="$2"; shift 2 ;;
    --model)                    MODEL="$2"; shift 2 ;;
    --no-commit)                AUTO_COMMIT=false; shift ;;
    --no-pr)                    AUTO_PR=false; shift ;;
    --skip-plan)                SKIP_PLAN=true; shift ;;
    --no-worktree)              USE_WORKTREE=false; shift ;;
    --keep-worktree)            KEEP_WORKTREE=true; shift ;;
    --keep-session-worktrees)   KEEP_SESSION_WORKTREES=true; shift ;;
    --help|-h)                  usage ;;
    *)
      if [[ -z "$SESSIONS_DIR" ]]; then SESSIONS_DIR="$1"; shift
      else err "Unknown argument: $1"; usage; fi
      ;;
  esac
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

# --- Validate environment ---
if ! command -v claude &>/dev/null; then
  err "claude CLI not found on PATH."
  exit 1
fi
# Python 3 detection. On Windows, `python3` may resolve to the Microsoft Store
# install stub which exits non-zero rather than executing Python. Probe for a
# working interpreter by actually running it.
PYTHON_BIN=""
for cand in python3 python; do
  if command -v "$cand" &>/dev/null \
     && "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' &>/dev/null; then
    PYTHON_BIN="$cand"
    break
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  err "Python 3 not found on PATH (tried: python3, python)."
  err "On Windows, the Microsoft Store \"python3\" stub does not count — install"
  err "real Python from python.org or disable the App Execution Alias for python3.exe."
  exit 1
fi
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  err "Not inside a git repository."
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
ORIG_REPO_ROOT="$REPO_ROOT"
ORIG_SESSIONS_DIR="$SESSIONS_DIR"
EPIC_NAME_SLUG="$(basename "$SESSIONS_DIR")"

if [[ -z "$BRANCH" ]]; then
  BRANCH="epic/${EPIC_NAME_SLUG}"
fi
BRANCH_SANITIZED="$(echo "$BRANCH" | tr '/' '--')"

# --no-worktree forces sequential — can't safely parallelize in one CWD.
if ! $USE_WORKTREE && [[ "$MAX_PARALLEL" -gt 1 ]]; then
  warn "--no-worktree forces --max-parallel 1"
  MAX_PARALLEL=1
fi
if $SEQUENTIAL; then
  MAX_PARALLEL=1
fi

DAG_SCRIPT="$(dirname "$0")/epic-dag.py"
PROGRESS_SCRIPT="$(dirname "$0")/epic-progress.py"

# --- Build the DAG plan ---
DAG_TMP="$(mktemp)"
trap 'rm -f "$DAG_TMP"' EXIT

DAG_ARGS=()
$STRICT && DAG_ARGS+=(--strict)

if [[ ${#DAG_ARGS[@]} -gt 0 ]]; then
  "$PYTHON_BIN" "$DAG_SCRIPT" "$SESSIONS_DIR" --bash "${DAG_ARGS[@]}" > "$DAG_TMP" || {
    err "DAG validation failed"; exit 1; }
else
  "$PYTHON_BIN" "$DAG_SCRIPT" "$SESSIONS_DIR" --bash > "$DAG_TMP" || {
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

WAVE_COUNT=0

while IFS= read -r line; do
  # Defensive: strip trailing CR in case Python emitted CRLF (Windows).
  line="${line%$'\r'}"
  set -- $line
  case "$1" in
    META)
      case "$2" in
        operator_path=*) OPERATOR_PATH="${2#*=}" ;;
        any_frontmatter=*) ANY_FRONTMATTER="${2#*=}" ;;
        wave_count=*) WAVE_COUNT="${2#*=}" ;;
      esac
      ;;
    WAVE)
      # WAVE <num> <size>
      :
      ;;
    SESSION)
      # SESSION <wave> <id> <file> <deps> <slug> <parallel>
      sw="$2"; sid="$3"; sfile="$4"; sdeps="$5"; sslug="$6"; sparallel="$7"
      WAVE_IDS[$sw]="${WAVE_IDS[$sw]:-} $sid"
      SESSION_FILE_BASENAME[$sid]="$sfile"
      SESSION_SLUG_BY_ID[$sid]="$sslug"
      SESSION_DEPS_BY_ID[$sid]="$sdeps"
      SESSION_PARALLEL[$sid]="$sparallel"
      SESSION_WAVE_OF[$sid]="$sw"
      ;;
  esac
done < "$DAG_TMP"

if [[ -z "$OPERATOR_PATH" || "$WAVE_COUNT" -eq 0 ]]; then
  err "DAG plan is empty or malformed"
  exit 1
fi

# --- Extract prompt from markdown code fence ---
extract_prompt() {
  local file="$1" content
  content="$(awk '
    /^```md$/ { capture=1; next }
    /^```$/   { if (capture) exit }
    capture   { print }
  ' "$file")"
  if [[ -z "$content" ]]; then
    # Strip frontmatter and the title line, return the rest.
    content="$(awk '
      BEGIN { in_fm=0; fm_done=0 }
      NR==1 && /^---$/ { in_fm=1; next }
      in_fm && /^---$/ { in_fm=0; fm_done=1; next }
      in_fm { next }
      fm_done && /^# / { fm_done=0; next }
      { print }
    ' "$file")"
  fi
  echo "$content"
}

OPERATOR_PROMPT="$(extract_prompt "$OPERATOR_PATH")"
if [[ -z "$OPERATOR_PROMPT" ]]; then
  err "Could not extract operator prompt from $OPERATOR_PATH"
  exit 1
fi

# --- Show DAG and exit if requested ---
if $SHOW_DAG; then
  "$PYTHON_BIN" "$DAG_SCRIPT" "$SESSIONS_DIR" --show
  exit 0
fi

# --- Dry-run: print plan and exit BEFORE any side effects (worktree, branches) ---
if $DRY_RUN; then
  log "${BOLD}DRY RUN${NC} — no worktrees, no branches, no commits will be created."
  "$PYTHON_BIN" "$DAG_SCRIPT" "$SESSIONS_DIR" --show
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

if $USE_WORKTREE; then
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
    [[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="main"
  fi

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
  TRUNK_SESSIONS_REL="${ORIG_SESSIONS_DIR#$ORIG_REPO_ROOT/}"
  TRUNK_SESSIONS_DIR="$TRUNK_WORKTREE_DIR/$TRUNK_SESSIONS_REL"
  if [[ ! -d "$TRUNK_SESSIONS_DIR" ]] || [[ -z "$(ls "$TRUNK_SESSIONS_DIR"/session-*.md 2>/dev/null)" ]]; then
    log "Syncing session files into trunk worktree..."
    mkdir -p "$TRUNK_SESSIONS_DIR"
    cp "$ORIG_SESSIONS_DIR"/session-*.md "$TRUNK_SESSIONS_DIR/" 2>/dev/null || true
  fi

  # Bootstrap commit so per-session worktrees inherit the session files.
  if ! git diff --quiet HEAD -- "$TRUNK_SESSIONS_DIR" 2>/dev/null \
     || [[ -n "$(git ls-files --others --exclude-standard "$TRUNK_SESSIONS_DIR")" ]]; then
    git add "$TRUNK_SESSIONS_DIR"
    git commit -q -m "chore: bootstrap epic session prompts

Sync session prompt files onto the epic trunk so per-session worktrees
inherit them when fanning out parallel waves.

Co-Authored-By: Claude <noreply@anthropic.com>" || true
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
log "Frontmatter  : $ANY_FRONTMATTER"
log "Branch       : $BRANCH (trunk)"
[[ -n "$TRUNK_WORKTREE_DIR" && "$TRUNK_WORKTREE_DIR" != "$ORIG_REPO_ROOT" ]] \
  && log "Trunk wt     : ${TRUNK_WORKTREE_DIR/#$HOME/~}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
"$PYTHON_BIN" "$DAG_SCRIPT" "$SESSIONS_DIR" --show
echo ""

# --- Helpers ---

format_elapsed() {
  local s=$1
  printf "%dm%02ds" $((s / 60)) $((s % 60))
}

# Look up a session id's handoff file under docs/roadmap/<epic>/
find_handoff_for() {
  local pid="$1" padded
  padded="$(printf "%02d" "$pid")"
  for cand in "$REPO_ROOT/docs/roadmap/"*"/session-${padded}-handoff.md"; do
    [[ -f "$cand" ]] && { echo "$cand"; return; }
  done
}

# Build the multi-parent handoff section for a session
build_handoff_section() {
  local deps_csv="$1"
  local out="" pid path
  [[ "$deps_csv" == "-" || -z "$deps_csv" ]] && return
  out="
---

## Previous Session Handoffs

These handoff documents come from your DAG parents. Treat their file paths as
the only memory of prior work — you have no other recollection.
"
  IFS=',' read -ra parents <<< "$deps_csv"
  for pid in "${parents[@]}"; do
    path="$(find_handoff_for "$pid")"
    if [[ -n "$path" ]]; then
      out+="
### From session $(printf '%02d' "$pid")  →  ${path/#$REPO_ROOT\//}

$(cat "$path")
"
    fi
  done
  echo "$out"
}

# Run a single claude pipe-invocation with optional progress stream.
# Args: <prompt_file> <log_file> <phase_label> <quiet:true|false>
DISALLOWED_TOOLS="EnterPlanMode,ExitPlanMode,AskUserQuestion,EnterWorktree"

run_claude() {
  local prompt_file="$1" log_file="$2" phase_label="$3" quiet="${4:-false}"

  set +e
  if [[ "$quiet" == "false" ]] && [[ -f "$PROGRESS_SCRIPT" ]]; then
    env -u CLAUDECODE claude -p \
      --model "$MODEL" \
      --dangerously-skip-permissions \
      --disallowedTools "$DISALLOWED_TOOLS" \
      --output-format stream-json \
      --verbose \
      < "$prompt_file" \
      2>"${log_file%.log}-stderr.tmp" \
      | "$PYTHON_BIN" "$PROGRESS_SCRIPT" --log "$log_file" --phase "$phase_label"
    local exit_code=${PIPESTATUS[0]}
    cat "${log_file%.log}-stderr.tmp" >> "$log_file" 2>/dev/null || true
    rm -f "${log_file%.log}-stderr.tmp"
  else
    env -u CLAUDECODE claude -p \
      --model "$MODEL" \
      --dangerously-skip-permissions \
      --disallowedTools "$DISALLOWED_TOOLS" \
      < "$prompt_file" > "$log_file" 2>&1
    local exit_code=$?
  fi
  set -e
  return $exit_code
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
  local plan_file="$TRUNK_SESSIONS_DIR/.session-${sid}-plan.md"
  local plan_log="$TRUNK_SESSIONS_DIR/.session-${sid}-plan.log"
  local exec_log="$TRUNK_SESSIONS_DIR/.session-${sid}-exec.log"
  local session_prompt
  session_prompt="$(extract_prompt "$session_path")"
  if [[ -z "$session_prompt" ]]; then
    echo "ERROR: could not extract prompt from $session_path" > "$exec_log"
    return 2
  fi

  local prev_cwd; prev_cwd="$(pwd)"
  cd "$wt_dir"

  local rc=0
  if $SKIP_PLAN; then
    local prompt; prompt="$(cat <<SINGLE_EOF
You are executing Session ${sid} of an automated multi-session epic.
Each session runs in a FRESH context — you have no memory of previous sessions.

=============================================
PHASE 1: OPERATOR RULES (always in effect)
=============================================

$OPERATOR_PROMPT

=============================================
PHASE 2: SESSION INSTRUCTIONS
=============================================

$session_prompt
$handoff_text
=============================================
PHASE 3: EXECUTION PROTOCOL
=============================================

1. PLAN: Read the referenced files and any handoff docs. Print a concise plan,
   then proceed immediately — do NOT wait for approval.
2. EXECUTE: Implement everything. No TBDs, no TODOs.
3. FINALIZE: Run any required CI commands. Create the handoff doc.
4. Stage and commit ALL changes:

   git add -A
   git commit -m "feat: Session ${sid} — ${friendly}

   <2-3 sentences>

   Co-Authored-By: Claude <noreply@anthropic.com>"

5. Print a brief completion summary.
SINGLE_EOF
)"
    local prompt_file; prompt_file="$(mktemp)"
    echo "$prompt" > "$prompt_file"
    run_claude "$prompt_file" "$exec_log" "S${sid}-EXEC" "$quiet" || rc=$?
    rm -f "$prompt_file"
  else
    # PLAN pass
    local plan_prompt; plan_prompt="$(cat <<PLAN_EOF
You are planning Session ${sid} of an automated multi-session epic.
Read-only exploration: do NOT modify any source code, tests, or docs.

=============================================
OPERATOR RULES (always in effect)
=============================================

$OPERATOR_PROMPT

=============================================
SESSION INSTRUCTIONS
=============================================

$session_prompt
$handoff_text
=============================================
PLANNING INSTRUCTIONS
=============================================

1. Read all files referenced in the session instructions above.
2. Inspect any handoff docs from DAG parents (file paths included above).
3. Write a detailed implementation plan to this EXACT path: ${plan_file}

The plan MUST include:
- Files to create/modify (full paths)
- Key design decisions and rationale
- Risks and mitigations
- Verification steps (tests, CI commands)
- Exact order of operations

Do NOT modify source. Do NOT wait for approval. Just write the plan and finish.
PLAN_EOF
)"
    local prompt_file; prompt_file="$(mktemp)"
    echo "$plan_prompt" > "$prompt_file"
    if ! run_claude "$prompt_file" "$plan_log" "S${sid}-PLAN" "$quiet"; then
      rm -f "$prompt_file"
      cd "$prev_cwd"
      return 1
    fi
    rm -f "$prompt_file"

    if [[ ! -f "$plan_file" ]]; then
      echo "ERROR: plan phase finished but plan file was not created: $plan_file" >> "$exec_log"
      cd "$prev_cwd"
      return 1
    fi
    local plan_contents; plan_contents="$(cat "$plan_file")"

    # EXECUTE pass
    local exec_prompt; exec_prompt="$(cat <<EXEC_EOF
You are executing Session ${sid} of an automated multi-session epic.
A planning phase has produced the implementation plan below. Implement it
fully — do not re-explore or second-guess.

=============================================
OPERATOR RULES (always in effect)
=============================================

$OPERATOR_PROMPT

=============================================
SESSION INSTRUCTIONS
=============================================

$session_prompt
$handoff_text
=============================================
IMPLEMENTATION PLAN
=============================================

$plan_contents

=============================================
EXECUTION INSTRUCTIONS
=============================================

1. Implement everything in the plan.
2. Run any CI checks the plan or session calls for.
3. Resolve all ambiguities — no TBDs, no TODOs.
4. Create the handoff doc if required by the session.
5. Stage and commit ALL changes:

   git add -A
   git commit -m "feat: Session ${sid} — ${friendly}

   <2-3 sentences>

   Co-Authored-By: Claude <noreply@anthropic.com>"

Do NOT wait for approval. Execute immediately.
EXEC_EOF
)"
    prompt_file="$(mktemp)"
    echo "$exec_prompt" > "$prompt_file"
    run_claude "$prompt_file" "$exec_log" "S${sid}-EXEC" "$quiet" || rc=$?
    rm -f "$prompt_file"
  fi

  # Auto-commit fallback inside the session worktree
  if [[ $rc -eq 0 ]] && $AUTO_COMMIT; then
    if ! git diff --quiet HEAD 2>/dev/null \
       || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
      git add -A
      git commit -q -m "feat: Session ${sid} — ${friendly}

Automated execution of $fname.

Co-Authored-By: Claude <noreply@anthropic.com>" || true
    fi
  fi

  cd "$prev_cwd"
  return $rc
}

# ---------------------------------------------------------------------------
# Wave loop
# ---------------------------------------------------------------------------
declare -a SESSION_STATUS         # by id: pending|done|failed|skipped
declare -a SESSION_BRANCH_BY_ID   # by id
declare -a SESSION_WT_BY_ID       # by id
declare -a SESSION_START_TS       # by id (epoch seconds)
declare -a SESSION_ELAPSED_BY_ID  # by id (seconds, populated on reap)
declare -a MERGED_SESSIONS        # ids merged into trunk

EPIC_FAILED=false
FIRST_FAILED_ID=""

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
      continue
    fi
    if [[ "$sid" -gt "$END_AT" ]]; then
      SESSION_STATUS[$sid]="skipped"
      continue
    fi
    IN_RANGE+=("$sid")
  done

  if [[ ${#IN_RANGE[@]} -eq 0 ]]; then
    dim "  skip wave $wn (all sessions outside range)"
    continue
  fi

  # Wave banner
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

  # Make sure trunk is checked out at TRUNK_WORKTREE_DIR (so siblings branch off it)
  if $USE_WORKTREE; then
    git -C "$TRUNK_WORKTREE_DIR" checkout -q "$BRANCH"
  fi

  # --- Spawn wave sessions ---
  declare -a JOB_PIDS=()
  declare -a JOB_SIDS=()

  reap_finished_jobs() {
    local i new_pids=() new_sids=()
    for i in "${!JOB_PIDS[@]}"; do
      if ! kill -0 "${JOB_PIDS[$i]}" 2>/dev/null; then
        local rc=0
        wait "${JOB_PIDS[$i]}" || rc=$?
        local sid="${JOB_SIDS[$i]}"
        local elapsed=$(( $(date +%s) - ${SESSION_START_TS[$sid]:-0} ))
        SESSION_ELAPSED_BY_ID[$sid]=$elapsed
        if [[ $rc -eq 0 ]]; then
          SESSION_STATUS[$sid]="done"
          ok "  ✓ session $(printf '%02d' "$sid") (${SESSION_SLUG_BY_ID[$sid]}) finished in $(format_elapsed "$elapsed")"
        else
          SESSION_STATUS[$sid]="failed"
          err "  ✗ session $(printf '%02d' "$sid") (${SESSION_SLUG_BY_ID[$sid]}) FAILED in $(format_elapsed "$elapsed") (exit $rc)"
        fi
      else
        new_pids+=("${JOB_PIDS[$i]}")
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

  for sid in "${IN_RANGE[@]}"; do
    # Throttle to MAX_PARALLEL
    while [[ ${#JOB_PIDS[@]} -ge $MAX_PARALLEL ]]; do
      reap_finished_jobs
      [[ ${#JOB_PIDS[@]} -ge $MAX_PARALLEL ]] && sleep 1
    done

    slug="${SESSION_SLUG_BY_ID[$sid]}"
    friendly="${slug//-/ }"
    sess_branch="${BRANCH}/s$(printf '%02d' "$sid")-${slug}"
    sess_wt_dir_name="${BRANCH_SANITIZED}--s$(printf '%02d' "$sid")-${slug}"
    SESSION_BRANCH_BY_ID[$sid]="$sess_branch"

    if $USE_WORKTREE; then
      sess_wt="$WORKTREE_BASE/$sess_wt_dir_name"
      # Wipe stale worktree from a prior failed run
      if [[ -d "$sess_wt" ]]; then
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

    log "  ▶ session $(printf '%02d' "$sid") (${slug}) starting → branch $sess_branch"

    SESSION_STATUS[$sid]="running"
    SESSION_START_TS[$sid]=$(date +%s)
    (
      run_one_session "$sid" "$sess_wt" "$friendly" "$handoff_text" "$quiet"
    ) &
    pid=$!
    JOB_PIDS+=("$pid")
    JOB_SIDS+=("$sid")
  done

  # Wait for all jobs in this wave
  while [[ ${#JOB_PIDS[@]} -gt 0 ]]; do
    reap_finished_jobs
    [[ ${#JOB_PIDS[@]} -gt 0 ]] && sleep 2
  done

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
            ok "  ⇢ merged session $(printf '%02d' "$sid") into trunk"
            MERGED_SESSIONS+=("$sid ${SESSION_FILE_BASENAME[$sid]}")
          else
            err "  ⇢ MERGE CONFLICT merging session $(printf '%02d' "$sid") into trunk"
            err "      Trunk worktree: $TRUNK_WORKTREE_DIR"
            err "      Resolve, commit, and resume with --start $((sid + 1))"
            git -C "$TRUNK_WORKTREE_DIR" merge --abort 2>/dev/null || true
            EPIC_FAILED=true
            [[ -z "$FIRST_FAILED_ID" ]] && FIRST_FAILED_ID="$sid"
          fi
        else
          # Session committed directly to trunk; no merge required.
          MERGED_SESSIONS+=("$sid ${SESSION_FILE_BASENAME[$sid]}")
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

  # Remove successful per-session worktrees (keep on failure for inspection)
  if $USE_WORKTREE && ! $KEEP_SESSION_WORKTREES; then
    for sid in "${IN_RANGE[@]}"; do
      if [[ "${SESSION_STATUS[$sid]:-}" == "done" ]]; then
        sess_wt="${SESSION_WT_BY_ID[$sid]}"
        if [[ -d "$sess_wt" ]]; then
          git -C "$TRUNK_WORKTREE_DIR" worktree remove "$sess_wt" --force 2>/dev/null || true
        fi
      fi
    done
  fi
done

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
if ! $EPIC_FAILED; then
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
  ok "Logs:  ${TRUNK_SESSIONS_DIR/#$HOME/~}/.session-*-{plan,exec}.log"
  ok "Plans: ${TRUNK_SESSIONS_DIR/#$HOME/~}/.session-*-plan.md"
  ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # --- Cleanup session artifacts before PR ---
  log "Cleaning up session artifacts..."
  CLEANED=0
  for f in "$TRUNK_SESSIONS_DIR"/.session-*; do
    [[ -f "$f" ]] && rm -f "$f" && CLEANED=$((CLEANED + 1))
  done
  for f in "$TRUNK_SESSIONS_DIR"/session-*.md; do
    [[ -f "$f" ]] && rm -f "$f" && CLEANED=$((CLEANED + 1))
  done
  rmdir "$TRUNK_SESSIONS_DIR" 2>/dev/null || true

  ROADMAP_DIR="$REPO_ROOT/docs/roadmap/$EPIC_NAME_SLUG"
  if [[ -d "$ROADMAP_DIR" ]]; then
    for f in "$ROADMAP_DIR"/session-*; do
      [[ -f "$f" ]] && rm -f "$f" && CLEANED=$((CLEANED + 1))
    done
    rmdir "$ROADMAP_DIR" 2>/dev/null || true
  fi

  if [[ $CLEANED -gt 0 ]]; then
    cd "$REPO_ROOT"
    git add -A
    git commit -q -m "chore: clean up session artifacts

Remove $CLEANED session files (prompts, plans, logs, handoffs).

Co-Authored-By: Claude <noreply@anthropic.com>" 2>/dev/null || true
    ok "Cleaned $CLEANED session artifacts"
  fi

  # --- Auto-PR ---
  if $AUTO_PR && command -v gh &>/dev/null; then
    CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
    DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
    if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
      EXISTING_PR="$(gh pr view "$CURRENT_BRANCH" --json url -q '.url' 2>/dev/null || true)"
      if [[ -n "$EXISTING_PR" ]]; then
        ok "PR already exists: $EXISTING_PR"
      else
        log "Creating pull request..."
        if ! git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
          git -C "$REPO_ROOT" push -u origin "$CURRENT_BRANCH"
        elif [[ -n "$(git -C "$REPO_ROOT" log '@{u}..HEAD' --oneline 2>/dev/null)" ]]; then
          git -C "$REPO_ROOT" push
        fi

        EPIC_NAME="$(basename "$TRUNK_SESSIONS_DIR" | tr '-' ' ')"
        SESSION_LIST=""
        for entry in "${MERGED_SESSIONS[@]}"; do
          SESSION_LIST="${SESSION_LIST}
- ${entry}"
        done
        DIFF_STATS="$(git -C "$REPO_ROOT" diff --shortstat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null || echo "")"

        PR_TITLE="feat: ${EPIC_NAME}"
        PR_BODY="## Summary

Automated DAG epic: **${EPIC_NAME}**

Executed ${WAVE_COUNT} wave(s) across the parallel scheduler using \`${MODEL}\`.

### Sessions${SESSION_LIST}

### Stats

${DIFF_STATS}

🤖 Generated with [Claude Code](https://claude.com/claude-code) DAG epic runner"

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

  # --- Trunk worktree cleanup ---
  if $USE_WORKTREE && [[ -n "$TRUNK_WORKTREE_DIR" ]]; then
    if $KEEP_WORKTREE; then
      log "Keeping trunk worktree: $TRUNK_WORKTREE_DIR"
    else
      cd "$ORIG_REPO_ROOT"
      log "Removing trunk worktree (work is on remote branch)..."
      git worktree remove "$TRUNK_WORKTREE_DIR" --force 2>/dev/null || true
      ok "Trunk worktree cleaned. Branch '$BRANCH' remains for the PR."
    fi
  fi
else
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
  exit 1
fi
