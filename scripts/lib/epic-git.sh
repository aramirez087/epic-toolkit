#!/usr/bin/env bash
# epic-git.sh — Git/repo utility functions for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

# Portable realpath: macOS lacks GNU coreutils; Git Bash on Windows mixes
# Windows- and MSYS-style paths which break downstream prefix strips.
_realpath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo "$1"
  elif command -v grealpath >/dev/null 2>&1; then
    grealpath "$1" 2>/dev/null || echo "$1"
  else
    if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
      python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
    elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
      python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
    else
      echo "$1"
    fi
  fi
}

# Sync .wolf/ merge auto-resolution into a consuming repo. Idempotent;
# the toolkit is source of truth, so drift is corrected every epic run.
provision_wolf_merge() {
  local repo_root="$1"
  local wolf_dir="$repo_root/.wolf"
  [[ -d "$wolf_dir" ]] || return 0

  local toolkit_assets="$CLAUDE_PLUGIN_ROOT/scripts/wolf-merge"
  [[ -d "$toolkit_assets" ]] || return 0

  local provisioned=0
  mkdir -p "$wolf_dir/scripts" "$repo_root/scripts"

  # chmod runs unconditionally — archive extraction can strip the +x bit
  # even when content matches.
  _wolf_sync_file() {
    local src="$1" dst="$2"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      provisioned=$((provisioned + 1))
    fi
    chmod +x "$dst" 2>/dev/null || true
  }

  _wolf_sync_file "$toolkit_assets/merge-wolf-json.py" "$wolf_dir/scripts/merge-wolf-json.py" || true
  _wolf_sync_file "$toolkit_assets/install-merge-driver.sh" "$wolf_dir/scripts/install-merge-driver.sh" || true
  _wolf_sync_file "$toolkit_assets/resolve-wolf.sh" "$repo_root/scripts/resolve-wolf.sh" || true

  local gitattrs="$repo_root/.gitattributes"
  local snippet="$toolkit_assets/gitattributes-snippet"
  if [[ -f "$snippet" ]]; then
    local has_managed_block=false has_manual_entry=false
    if [[ -f "$gitattrs" ]]; then
      grep -q "BEGIN openwolf merge drivers" "$gitattrs" 2>/dev/null && has_managed_block=true
      grep -qE '^\.wolf/.*merge=(wolf-json|union)' "$gitattrs" 2>/dev/null && has_manual_entry=true
    fi
    if ! $has_managed_block && ! $has_manual_entry; then
      [[ -f "$gitattrs" ]] && [[ -s "$gitattrs" ]] && echo "" >> "$gitattrs"
      cat "$snippet" >> "$gitattrs"
      provisioned=$((provisioned + 1))
    fi
  fi

  # -f not -x: bash can read scripts without the exec bit and chmod may
  # not have run if content was unchanged but git config drifted.
  if [[ -f "$wolf_dir/scripts/install-merge-driver.sh" ]]; then
    bash "$wolf_dir/scripts/install-merge-driver.sh" 2>/dev/null || true
  fi

  if [[ $provisioned -gt 0 ]]; then
    log "Provisioned OpenWolf merge auto-resolution ($provisioned file(s) updated)"
  fi
  unset -f _wolf_sync_file
}

# Auto-resolve .wolf/ conflicts in $1 to side $2 (ours|theirs).
# Returns: 0 = wolf-only resolved+staged, 1 = non-wolf conflicts present, 2 = no conflicts.
auto_resolve_wolf_conflicts() {
  local workdir="$1" side="$2"
  local conflicted non_wolf
  # core.quotePath=false: default quoting wraps non-ASCII paths as `"…"`,
  # which fails the `^\.wolf/` filter and silently misclassifies them. (bug-213)
  conflicted="$(git -C "$workdir" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null || true)"
  [[ -z "$conflicted" ]] && return 2
  non_wolf="$(printf '%s\n' "$conflicted" | grep -Ev '^\.wolf/' | grep -v '^$' || true)"
  [[ -n "$non_wolf" ]] && return 1
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git -C "$workdir" checkout "--$side" -- "$f" 2>/dev/null || true
    git -C "$workdir" add -- "$f" 2>/dev/null || true
  done <<< "$conflicted"
  return 0
}

# Rebase $1 onto $2, auto-resolving conflicts confined to .wolf/ paths.
# During rebase, "theirs" = the replayed epic commit, which is what we want
# .wolf/ state to follow. Returns 0 ok, 1 real conflict / fast-fail, 2 unused.
rebase_with_wolf_resolve() {
  local workdir="$1" target="$2"
  if git -C "$workdir" merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
    return 0
  fi
  if git -C "$workdir" -c core.editor=true rebase -q "$target" 2>/dev/null; then
    return 0
  fi
  # Distinguish "paused on conflict" from "fast-fail without state" — the
  # previous bare-fallthrough returned 0 and force-pushed un-rebased history. (bug-074)
  local _rmerge _rapply
  _rmerge="$(git -C "$workdir" rev-parse --git-path rebase-merge 2>/dev/null)"
  _rapply="$(git -C "$workdir" rev-parse --git-path rebase-apply 2>/dev/null)"
  if [[ ! -d "$_rmerge" && ! -d "$_rapply" ]]; then
    return 1
  fi
  local max_iters=50 i=0
  while [[ -d "$_rmerge" || -d "$_rapply" ]]; do
    i=$((i + 1))
    if [[ $i -gt $max_iters ]]; then
      git -C "$workdir" rebase --abort 2>/dev/null || true
      return 1
    fi
    auto_resolve_wolf_conflicts "$workdir" "theirs"
    case $? in
      0)
        if ! git -C "$workdir" -c core.editor=true rebase --continue 2>/dev/null; then
          if ! git -C "$workdir" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            git -C "$workdir" rebase --abort 2>/dev/null || true
            return 1
          fi
        fi
        ;;
      1)
        git -C "$workdir" rebase --abort 2>/dev/null || true
        return 1
        ;;
      2)
        if ! git -C "$workdir" -c core.editor=true rebase --skip 2>/dev/null \
            && ! git -C "$workdir" -c core.editor=true rebase --continue 2>/dev/null; then
          git -C "$workdir" rebase --abort 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  done
  return 0
}

# Sweep stale epic/* branches whose PRs are merged/closed.
cleanup_merged_epic_branches() {
  local repo_root="$1"
  command -v gh &>/dev/null || return 0
  git -C "$repo_root" fetch --prune --quiet origin 2>/dev/null || true
  local default_branch
  # `gh repo view` doesn't accept -R; cd into the repo so auto-detect
  # picks the right one. Without this, default_branch silently fell back
  # to "main" for master/develop/trunk repos. (bug-122)
  default_branch="$( (cd "$repo_root" && gh repo view --json defaultBranchRef -q '.defaultBranchRef.name') 2>/dev/null || echo main)"
  local removed=0 br pr_state origin_url has_open
  origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null)"
  while IFS= read -r br; do
    [[ -z "$br" ]] && continue
    # -Fx (whole-line) — plain -F substring-matches and `epic/foo` would
    # falsely match `epic/foo-bar`.
    if git -C "$repo_root" worktree list --porcelain 2>/dev/null | grep -qFx "branch refs/heads/$br"; then
      continue
    fi
    # Check for ANY open PR before falling through to .[0].state, which
    # picks the most-recent PR by createdAt — a closed duplicate could
    # otherwise hide an older still-open PR on a different base. jq's
    # `length` yields "0" for the empty case; the regex below rejects it.
    has_open="$(gh -R "$origin_url" pr list --head "$br" --state open --json id -q 'length' 2>/dev/null || echo 0)"
    if [[ "$has_open" =~ ^[1-9][0-9]*$ ]]; then
      continue
    fi
    pr_state="$(gh -R "$origin_url" pr list --head "$br" --state all --json state -q '.[0].state' 2>/dev/null || true)"
    case "$pr_state" in
      MERGED|CLOSED)
        if git -C "$repo_root" branch -D "$br" &>/dev/null; then
          removed=$((removed + 1))
          log "  Pruned merged/closed epic branch: $br"
        fi
        ;;
      "")
        # Compare against origin/<default> — `fetch --prune` doesn't
        # fast-forward the local ref, so a lagging local `main` would
        # falsely report not-merged.
        local default_ref="$default_branch"
        if git -C "$repo_root" rev-parse --verify --quiet "origin/$default_branch" >/dev/null 2>&1; then
          default_ref="origin/$default_branch"
        fi
        if git -C "$repo_root" merge-base --is-ancestor "$br" "$default_ref" 2>/dev/null; then
          if git -C "$repo_root" branch -d "$br" &>/dev/null; then
            removed=$((removed + 1))
            log "  Pruned merged epic branch (no PR): $br"
          fi
        fi
        ;;
    esac
  done < <(git -C "$repo_root" branch --format='%(refname:short)' 2>/dev/null | grep -E '^epic/' | grep -v -- '--s[0-9]')
  [[ $removed -gt 0 ]] && ok "Cleaned up $removed stale epic branch(es)"
  return 0
}

# Returns 0 if session $1 is already committed on branch $2 in repo $3.
# $4 is the epic name slug (used to scope detection to the current epic;
# without it an unrelated epic on the same branch whose session numbers
# happen to overlap would falsely skip sessions — cross-epic false positive).
#
# Signals checked, most-specific first:
#   (a) in-memory SESSION_STATUS (same-run short-circuit)
#   (b) new-format merge commit:  "Merge session NN (slug) into BRANCH [epic: SLUG]"
#   (c) new-format feat commit:   "feat: Session N ... [epic: SLUG]"
#   (d) old-format merge fallback: "Merge session NN (session_slug) ..."
#       — matched by session slug so two different epics with the same
#       session number but different slug are correctly distinguished.
#   (e) old-format feat fallback: "feat: Session N" (no disambiguation
#       signal; accepted for backward compat with --no-worktree runs
#       from before the [epic:] tag was introduced)
# Excludes `feat(partial):` since that prefix means recovered-but-unfinished.
session_completed_on_branch() {
  local sid="$1" branch="$2" repo="$3" epic_slug="${4:-}"
  if [[ "${SESSION_STATUS[$sid]:-}" == "done" ]]; then
    return 0
  fi
  local padded subjects rev_range session_slug
  padded="$(printf '%02d' "$sid")"
  session_slug="${SESSION_SLUG_BY_ID[$sid]:-}"

  # Scope to ${BASE_BRANCH}..${branch}. An unscoped log walks back into
  # main's history and any prior epic's `feat: Session N` subject would
  # falsely match, silently skipping every session this run. (bug-080)
  local base_ref=""
  if [[ -n "${BASE_BRANCH:-}" ]]; then
    # Prefer origin/<base> over the local ref — auto-rebase lands HEAD
    # on origin's tip and `fetch --prune` doesn't fast-forward the local
    # branch, so a lagging local `main` would re-introduce bug-080.
    if git -C "$repo" rev-parse --verify --quiet "origin/$BASE_BRANCH" >/dev/null 2>&1; then
      base_ref="origin/$BASE_BRANCH"
    elif git -C "$repo" rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null 2>&1; then
      base_ref="$BASE_BRANCH"
    fi
  fi
  # Audit-gap closure for bug-080: when BOTH origin/$BASE_BRANCH AND
  # local $BASE_BRANCH fail to resolve (no `origin` remote / no
  # `origin/HEAD` symbolic ref AND `BASE_BRANCH` defaulted to "main"
  # but the repo uses `master`/`develop`/`trunk`; or a typo'd `--base
  # nonexistent-branch`), the previous code degraded `rev_range` back
  # to a bare `$branch` walk — which IS the exact shape bug-080 was
  # patched against. A prior epic's `feat: Session N` commit on base
  # history then falsely matches, silently skipping every session this
  # run while the runner reports "merged" for empty no-op merges.
  # Treat unresolvable base_ref as "not completed" so the session
  # re-runs — wasting work is recoverable; silently skipping a never-
  # executed session is data loss. The in-memory `SESSION_STATUS[$sid]
  # == done` check above still short-circuits sessions completed in
  # THIS run, so the only sessions affected are those claimed-done by
  # a previous run on a now-broken base setup.
  if [[ -z "$base_ref" ]]; then
    return 1
  fi
  rev_range="${base_ref}..${branch}"

  subjects="$(git -C "$repo" log --format='%s' "$rev_range" 2>/dev/null || true)"

  # (b) new-format merge commit: scoped by [epic: SLUG] tag.
  if [[ -n "$epic_slug" ]] && \
     grep -qE "^Merge session ${padded} \([^)]*\) into .*\[epic: $(printf '%s' "$epic_slug" | sed 's/[.[\*^$]/\\&/g')\]" <<<"$subjects"; then
    return 0
  fi

  # (c) new-format feat commit: scoped by [epic: SLUG] tag.
  if [[ -n "$epic_slug" ]] && \
     grep -qE "^feat: Session ${sid}([^[:alnum:]]|$).*\[epic: $(printf '%s' "$epic_slug" | sed 's/[.[\*^$]/\\&/g')\]" <<<"$subjects"; then
    return 0
  fi

  # (d) old-format merge fallback: match by session slug in parens.
  # Two different epics that share a session number will have different
  # slugs, so this correctly distinguishes same-epic from cross-epic.
  if [[ -n "$session_slug" ]] && \
     grep -qE "^Merge session ${padded} \($(printf '%s' "$session_slug" | sed 's/[.[\*^$]/\\&/g')\) " <<<"$subjects"; then
    return 0
  fi

  # (e) old-format feat fallback: no disambiguation signal available.
  # Accepted for backward compat with pre-[epic:] runs. The risk of a
  # cross-epic false positive here is low in practice (feat-only sessions
  # are --no-worktree mode, which is uncommon), and --fresh bypasses it.
  if grep -qE "^feat: Session ${sid}([^[:alnum:]]|$)" <<<"$subjects"; then
    return 0
  fi
  return 1
}
