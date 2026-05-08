#!/usr/bin/env bash
# Idempotently register the OpenWolf JSON merge driver in the local git config.
# Safe to run on every session start — git config writes are cheap and atomic.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
DRIVER="$REPO_ROOT/.wolf/scripts/merge-wolf-json.py"
[[ -x "$DRIVER" ]] || chmod +x "$DRIVER" 2>/dev/null || exit 0

# Reject paths with shell metacharacters before they're baked into the
# git-config value below. Git invokes merge drivers via /bin/sh, so a
# repo root containing `"`, `\`, `$`, backtick, or a newline can break
# out of the surrounding double quotes and chain arbitrary commands on
# every `.wolf/*.json` merge. Real filesystem paths never contain these.
case "$DRIVER" in
  *'"'*|*'\'*|*'$'*|*'`'*|*$'\n'*|*$'\r'*)
    echo "install-merge-driver: repo path contains shell metacharacters; merge driver not registered: $REPO_ROOT" >&2
    exit 1
    ;;
esac

# Probe with --version — Windows `python3` can be a non-functional MS Store stub.
PY_CMD=""
if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  PY_CMD=python3
elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
  PY_CMD=python
else
  exit 0
fi

# Register the driver. %O=ancestor %A=ours %B=theirs %P=pathname
git -C "$REPO_ROOT" config merge.wolf-json.name "OpenWolf JSON union merge"
git -C "$REPO_ROOT" config merge.wolf-json.driver "$PY_CMD \"$DRIVER\" %O %A %B %P"
git -C "$REPO_ROOT" config merge.wolf-json.recursive binary
