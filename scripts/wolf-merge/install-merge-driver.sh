#!/usr/bin/env bash
# Idempotently register the OpenWolf JSON merge driver in the local git config.
# Safe to run on every session start — git config writes are cheap and atomic.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
DRIVER="$REPO_ROOT/.wolf/scripts/merge-wolf-json.py"
[[ -x "$DRIVER" ]] || chmod +x "$DRIVER" 2>/dev/null || exit 0

# Resolve a working python interpreter. Hardcoding "python3" silently breaks
# the merge driver on Windows where `python3` is often a Microsoft Store stub
# that satisfies `command -v` but errors on actual invocation, and on systems
# where only `python` exists. Probe both with --version (matches the same
# detection in run-sessions.sh) so the registered driver string actually runs.
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
