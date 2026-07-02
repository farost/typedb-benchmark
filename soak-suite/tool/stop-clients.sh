#!/usr/bin/env bash
# Kill the four tmux sessions. Server runners are unaffected.
set -euo pipefail
for s in soak-1n soak-3n soak-3n-chaos soak-monitor; do
  if tmux has-session -t "$s" 2>/dev/null; then
    echo "[soak] kill tmux session $s"
    tmux kill-session -t "$s"
  fi
done
