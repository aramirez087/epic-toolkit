#!/usr/bin/env bash
# resolve-wolf.sh — One-shot resolver for in-progress merge/rebase conflicts
# in .wolf/ files. Use when a conflict arose before the auto-driver was
# installed, or for an ad-hoc fix.
#
# Usage:
#   scripts/resolve-wolf.sh           # auto-detect merge vs rebase, pick right side
#   scripts/resolve-wolf.sh --ours    # force keep current side
#   scripts/resolve-wolf.sh --theirs  # force keep incoming side
#
# Exits 0 if all conflicts resolved (and merge/rebase continued), non-zero
# if non-.wolf/ conflicts remain.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GIT_DIR="$(git rev-parse --git-dir)"

# Detect operation in progress and choose default side accordingly:
#   merge in progress  -> "ours" (keep local)
#   rebase in progress -> "theirs" (keep replayed-commit, i.e. epic's wolf state)
SIDE=""
case "${1:-}" in
  --ours)   SIDE="ours";   shift ;;
  --theirs) SIDE="theirs"; shift ;;
  "")       : ;;
  *)        echo "Unknown arg: $1" >&2; exit 2 ;;
esac

if [[ -z "$SIDE" ]]; then
  if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    SIDE="ours"
  elif [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; then
    SIDE="theirs"
  else
    echo "No merge or rebase in progress." >&2
    exit 0
  fi
fi

CONFLICTED="$(git diff --name-only --diff-filter=U)"
if [[ -z "$CONFLICTED" ]]; then
  echo "No conflicts to resolve."
  exit 0
fi

NON_WOLF="$(printf '%s\n' "$CONFLICTED" | grep -Ev '^\.wolf/' | grep -v '^$' || true)"
if [[ -n "$NON_WOLF" ]]; then
  echo "Refusing to auto-resolve: non-.wolf/ conflicts present:" >&2
  printf '  %s\n' $NON_WOLF >&2
  echo "" >&2
  echo "Resolve those manually first, then re-run this script." >&2
  exit 1
fi

# Resolve each .wolf/ file
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  git checkout "--$SIDE" -- "$f"
  git add -- "$f"
  echo "  resolved $f (kept $SIDE)"
done <<< "$CONFLICTED"

# Continue the merge/rebase
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
  git -c core.editor=true commit --no-edit
  echo "✓ merge committed"
elif [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; then
  git -c core.editor=true rebase --continue
  echo "✓ rebase continued"
fi
