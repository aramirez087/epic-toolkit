#!/usr/bin/env bash
# Idempotently register the OpenWolf JSON merge driver in the local git config.
# Safe to run on every session start — git config writes are cheap and atomic.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
DRIVER="$REPO_ROOT/.wolf/scripts/merge-wolf-json.py"
[[ -x "$DRIVER" ]] || chmod +x "$DRIVER" 2>/dev/null || exit 0

# Register the driver. %O=ancestor %A=ours %B=theirs %P=pathname
git -C "$REPO_ROOT" config merge.wolf-json.name "OpenWolf JSON union merge"
git -C "$REPO_ROOT" config merge.wolf-json.driver "python3 \"$DRIVER\" %O %A %B %P"
git -C "$REPO_ROOT" config merge.wolf-json.recursive binary
