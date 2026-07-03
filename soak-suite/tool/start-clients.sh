#!/usr/bin/env bash
# Launch all three client processes on the client machine. Each runs in its
# own tmux session so the operator can `tmux attach -t soak-1n` etc. and
# follow the live log.
#
# Sessions: soak-1n, soak-3n, soak-3n-chaos, soak-monitor
#
# Usage:
#   tool/start-clients.sh                    # forever
#   tool/start-clients.sh --verify           # 30-min verification then exit
#   tool/start-clients.sh --duration 600     # custom duration (seconds)
set -euo pipefail

TOPOLOGY="$(dirname "$0")/../config/topology.toml"
WORKDIR_ROOT="${WORKDIR_ROOT:-/var/lib/typedb-soak/client}"
SOAK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DURATION=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)   DURATION=1800; shift ;;
    --duration) DURATION="$2"; shift 2 ;;
    --topology) TOPOLOGY="$2"; shift 2 ;;
    --workdir)  WORKDIR_ROOT="$2"; shift 2 ;;
    *)          echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }

CLIENT_BIN="$SOAK_DIR/target/release/client"
if [ ! -x "$CLIENT_BIN" ]; then
    echo "[soak] building client..."
    source "$HOME/.cargo/env" 2>/dev/null || true
    (cd "$SOAK_DIR" && cargo build --release --bin client)
fi

start_session() {
  local session="$1"; shift
  local mode="$1"; shift
  local wd="$WORKDIR_ROOT/$mode"
  mkdir -p "$wd"
  # Recreate if exists (kill old session, start new)
  tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session"
  echo "[soak] tmux session: $session  mode=$mode  workdir=$wd"
  tmux new-session -d -s "$session" -- bash -lc "
    cd '$SOAK_DIR' &&
    '$CLIENT_BIN' \
      --config '$TOPOLOGY' \
      --mode   '$mode' \
      --workdir '$wd' \
      --duration-secs $DURATION 2>&1 | tee -a '$wd/client.tail.log'
  "
}

start_session soak-1n        mode_1n_steady
start_session soak-3n        mode_3n_steady
start_session soak-3n-chaos  mode_3n_chaos

# Monitor session that tails everything.
if ! tmux has-session -t soak-monitor 2>/dev/null; then
  tmux new-session -d -s soak-monitor -- bash -lc "
    tail -F '$WORKDIR_ROOT'/mode_*/client.log '$WORKDIR_ROOT'/mode_*/FAILURES.log 2>/dev/null
  "
fi

echo
echo "Sessions started. Attach with:  tmux attach -t soak-1n  (or -t soak-3n, etc.)"
echo "Monitor all:                    tmux attach -t soak-monitor"
echo "Stop all:                       tool/stop-clients.sh"
