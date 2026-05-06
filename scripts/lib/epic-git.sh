#!/usr/bin/env bash
# epic-git.sh — Git/repo utility functions for the epic runner.
# Sourced by run-sessions.sh; all functions share its global scope.

# Portable realpath that works on macOS (no GNU coreutils by default) and
# Git Bash on Windows (where paths can be mixed-style).
#
# `git rev-parse --show-toplevel` on Git Bash returns Windows-style paths
# (`C:/foo/bar`) while `pwd` and SESSIONS_DIR use MSYS-style (`/c/foo/bar`).
# Mixing these silently breaks the `${SESSIONS_DIR#$REPO_ROOT/}` prefix strip
# downstream. On macOS case-insensitive APFS/HFS+, `pwd` preserves typed case
# so REPO_ROOT and SESSIONS_DIR can differ only in case, causing a malformed
# nested-absolute `//…` path. This normalises via grealpath → realpath → python.
_realpath() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo "$1"
  elif command -v grealpath >/dev/null 2>&1; then
    grealpath "$1" 2>/dev/null || echo "$1"
  else
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
  fi
}

# Auto-provision .wolf/ merge auto-resolution for a consuming repo.
#
# If the repo has a .wolf/ directory (uses OpenWolf), this function:
#   1. Syncs bundled scripts from the toolkit into .wolf/scripts/ and scripts/
#   2. Idempotently appends merge directives to .gitattributes
#   3. Registers the wolf-json merge driver in local git config
#
# All operations are idempotent and silent on no-change. Logs only when
# new files are written or .gitattributes is updated. Drift is corrected
# automatically on every epic run (toolkit is the source of truth).
#
# Args:
#   $1 = repo root
provision_wolf_merge() {
  local repo_root="$1"
  local wolf_dir="$repo_root/.wolf"
  [[ -d "$wolf_dir" ]] || return 0  # not an OpenWolf repo, no-op

  local toolkit_assets="$CLAUDE_PLUGIN_ROOT/scripts/wolf-merge"
  [[ -d "$toolkit_assets" ]] || return 0  # toolkit not bundled correctly, skip

  local provisioned=0
  mkdir -p "$wolf_dir/scripts" "$repo_root/scripts"

  # Sync each bundled asset; only log when contents actually change.
  _wolf_sync_file() {
    local src="$1" dst="$2"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      chmod +x "$dst"
      provisioned=$((provisioned + 1))
      return 0
    fi
    return 1
  }

  _wolf_sync_file "$toolkit_assets/merge-wolf-json.py" "$wolf_dir/scripts/merge-wolf-json.py" || true
  _wolf_sync_file "$toolkit_assets/install-merge-driver.sh" "$wolf_dir/scripts/install-merge-driver.sh" || true
  _wolf_sync_file "$toolkit_assets/resolve-wolf.sh" "$repo_root/scripts/resolve-wolf.sh" || true

  # Idempotently merge .gitattributes. Skip if any wolf-json driver
  # directive is already present (managed-block marker OR manual entry).
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

  # Register the wolf-json driver in local git config (idempotent, fast).
  if [[ -x "$wolf_dir/scripts/install-merge-driver.sh" ]]; then
    bash "$wolf_dir/scripts/install-merge-driver.sh" 2>/dev/null || true
  fi

  if [[ $provisioned -gt 0 ]]; then
    log "Provisioned OpenWolf merge auto-resolution ($provisioned file(s) updated)"
  fi
  unset -f _wolf_sync_file
}

# Auto-resolve OpenWolf metadata conflicts in the current working dir.
# .wolf/ files are append-mostly logs (anatomy.md, memory.md, buglog.json)
# and per-session state (token-ledger.json, hooks/_session.json) — safe to
# resolve to whichever side the caller prefers.
#
# Args:
#   $1 = working directory (git checkout root)
#   $2 = preferred side: "ours" or "theirs"
# Returns:
#   0 — all conflicts were .wolf/-only and have been resolved+staged
#   1 — non-.wolf/ conflicts exist (caller must handle)
#   2 — no conflicts at all
auto_resolve_wolf_conflicts() {
  local workdir="$1" side="$2"
  local conflicted non_wolf
  conflicted="$(git -C "$workdir" diff --name-only --diff-filter=U 2>/dev/null || true)"
  [[ -z "$conflicted" ]] && return 2
  non_wolf="$(printf '%s\n' "$conflicted" | grep -Ev '^\.wolf/' | grep -v '^$' || true)"
  [[ -n "$non_wolf" ]] && return 1
  # All conflicts are .wolf/-only. Resolve each.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git -C "$workdir" checkout "--$side" -- "$f" 2>/dev/null || true
    git -C "$workdir" add -- "$f" 2>/dev/null || true
  done <<< "$conflicted"
  return 0
}

# Rebase the current branch onto a target ref, auto-resolving any
# conflicts that fall entirely within .wolf/ paths. Aborts cleanly if
# real code conflicts arise.
#
# During `git rebase`:
#   "ours"   = the rebase base (target ref, e.g. origin/main)
#   "theirs" = the commit being replayed (the epic's commit)
# We want the epic's wolf state to win, so we use "theirs" for .wolf/.
#
# Args:
#   $1 = working directory
#   $2 = target ref (e.g. origin/main)
# Returns:
#   0 — rebase succeeded (no-op, fast-forward, or with .wolf/ auto-resolve)
#   1 — rebase aborted due to non-.wolf/ conflicts (workdir restored)
#   2 — fetch/setup failure (no rebase attempted)
rebase_with_wolf_resolve() {
  local workdir="$1" target="$2"
  # Already a descendant of target? No-op.
  if git -C "$workdir" merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
    return 0
  fi
  # Try clean rebase first
  if git -C "$workdir" -c core.editor=true rebase -q "$target" 2>/dev/null; then
    return 0
  fi
  # Rebase paused on conflict. Iterate, resolving .wolf/ conflicts.
  local max_iters=50 i=0
  while git -C "$workdir" rev-parse --git-path rebase-merge 2>/dev/null | xargs -I{} test -d {} \
       || git -C "$workdir" rev-parse --git-path rebase-apply 2>/dev/null | xargs -I{} test -d {}; do
    i=$((i + 1))
    if [[ $i -gt $max_iters ]]; then
      git -C "$workdir" rebase --abort 2>/dev/null || true
      return 1
    fi
    auto_resolve_wolf_conflicts "$workdir" "theirs"
    case $? in
      0) # All-wolf resolved; continue rebase
        if ! git -C "$workdir" -c core.editor=true rebase --continue 2>/dev/null; then
          # Continue may have triggered a new conflict — loop will catch it
          # If there's no new conflict and continue still failed, abort.
          if ! git -C "$workdir" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            git -C "$workdir" rebase --abort 2>/dev/null || true
            return 1
          fi
        fi
        ;;
      1) # Non-wolf conflicts present; bail
        git -C "$workdir" rebase --abort 2>/dev/null || true
        return 1
        ;;
      2) # No conflicts but rebase still in progress — empty commit?
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

# Sweep stale `epic/*` branches whose PRs have been merged or closed.
# After a PR is merged on GitHub, the local epic branch lingers forever
# unless explicitly cleaned. This runs on every successful epic completion
# (including this very epic, in case the user merged the PR mid-run).
#
# Args:
#   $1 = repo root
cleanup_merged_epic_branches() {
  local repo_root="$1"
  command -v gh &>/dev/null || return 0
  # Fetch with prune so origin/epic/* refs disappear when the remote branch is gone.
  git -C "$repo_root" fetch --prune --quiet origin 2>/dev/null || true
  local default_branch
  default_branch="$(gh -R "$(git -C "$repo_root" remote get-url origin 2>/dev/null)" repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
  local removed=0 br pr_state
  while IFS= read -r br; do
    [[ -z "$br" ]] && continue
    # Skip if branch is currently checked out somewhere
    if git -C "$repo_root" worktree list --porcelain 2>/dev/null | grep -qF "branch refs/heads/$br"; then
      continue
    fi
    # Query PR state (MERGED or CLOSED is safe to delete; OPEN/DRAFT we keep)
    pr_state="$(gh -R "$(git -C "$repo_root" remote get-url origin 2>/dev/null)" pr list --head "$br" --state all --json state -q '.[0].state' 2>/dev/null || true)"
    case "$pr_state" in
      MERGED|CLOSED)
        if git -C "$repo_root" branch -D "$br" &>/dev/null; then
          removed=$((removed + 1))
          log "  Pruned merged/closed epic branch: $br"
        fi
        ;;
      "")
        # No PR exists. Only delete if the branch is fully merged into default.
        if git -C "$repo_root" merge-base --is-ancestor "$br" "$default_branch" 2>/dev/null; then
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

# Returns 0 if session $1 has evidence of completion on branch $2 within
# repo $3. Combines three signals so prior-run history and AI subject
# variation don't leave stale scaffolding behind:
#
#   1. SESSION_STATUS[$1] == "done" — this run completed it (covers fresh
#      runs and resume early-returns).
#   2. Wave merge commit "Merge session NN (slug) into BRANCH" — script-
#      generated, deterministic; present on every prior run that used
#      worktree mode (the default). Survives across runs.
#   3. AI feat commit "feat: Session N <sep>..." with sep matched as any
#      non-alphanumeric byte. The character class avoids hard-coding
#      multibyte separators (em-dash, en-dash) which behave differently
#      across grep locales — Git Bash on Windows often runs grep in the C
#      locale where a literal em-dash inside a regex character class is
#      compared byte-by-byte and produces inconsistent matches. Excludes
#      "feat(partial):" subjects since the auto-commit fallback uses that
#      prefix when work was recovered but the session didn't actually
#      finish.
session_completed_on_branch() {
  local sid="$1" branch="$2" repo="$3"
  if [[ "${SESSION_STATUS[$sid]:-}" == "done" ]]; then
    return 0
  fi
  local padded subjects
  padded="$(printf '%02d' "$sid")"
  subjects="$(git -C "$repo" log --format='%s' "$branch" 2>/dev/null || true)"
  if grep -qE "^Merge session ${padded} \(" <<<"$subjects"; then
    return 0
  fi
  if grep -qE "^feat: Session ${sid}([^[:alnum:]]|$)" <<<"$subjects"; then
    return 0
  fi
  return 1
}
