#!/usr/bin/env bash
# Localhost smoke test: brings up all three modes (1n, 3n, 3n chaos) on a
# single host using the localhost topology, drives clients for a few minutes,
# then prints the verification report. Useful for catching obvious breakage
# before deploying to a 4-machine fleet.
#
# Requires:
#   - typedb_server_bin + typedb_admin_bin built locally
#     (or change [binary] in config/topology.localhost.toml to "download")
#   - sudo for iptables/tc (or set use_sudo = false in network config)
#   - cargo on PATH
#   - tmux
#
# Usage:
#   examples/run-local-test.sh            # 5-minute soak then report
#   DURATION=60 examples/run-local-test.sh # 1-minute smoke
set -euo pipefail

DURATION="${DURATION:-300}"
SOAK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOPOLOGY="$SOAK_DIR/config/topology.localhost.toml"

WORK_ROOT="$(mktemp -d -t soak-local-XXXX)"
SERVER_WD="$WORK_ROOT/server-all"   # all 3 machines run in one runner process
CLIENT_WD="$WORK_ROOT/client"
mkdir -p "$SERVER_WD" "$CLIENT_WD"

echo "[smoke] workdir = $WORK_ROOT"
echo "[smoke] topology = $TOPOLOGY"
echo "[smoke] duration = ${DURATION}s"
echo "[smoke] building..."
(cd "$SOAK_DIR" && cargo build --release --bins)

RUNNER="$SOAK_DIR/target/release/runner"
CLIENT="$SOAK_DIR/target/release/client"
REPORT="$SOAK_DIR/target/release/verify-report"

# Localhost has only one physical machine, but the topology has 3 logical
# machine labels (M1/M2/M3) all mapped to 127.0.0.1. Run one runner process
# per label — they'll each spawn their own assigned nodes and (M1) register
# peers.
declare -a RUNNERS
cleanup() {
  echo "[smoke] cleanup: stopping clients + runners"
  for s in soak-1n soak-3n soak-3n-chaos soak-monitor; do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  for pid in "${RUNNERS[@]:-}"; do
    [[ -n "$pid" ]] && kill -INT "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "[smoke] done. logs under $WORK_ROOT"
}
trap cleanup EXIT INT TERM

for M in M1 M2 M3; do
  WD="$WORK_ROOT/server-$M"
  mkdir -p "$WD"
  echo "[smoke] starting runner for $M ($WD)"
  "$RUNNER" --config "$TOPOLOGY" --machine "$M" --workdir "$WD" \
    > "$WD/runner.stdout" 2>&1 &
  RUNNERS+=("$!")
done

echo "[smoke] waiting 20s for cluster bootstrap..."
sleep 20

echo "[smoke] starting clients (duration=${DURATION}s each)"
for mode in mode_1n_steady mode_3n_steady mode_3n_chaos; do
  CMD="'$CLIENT' --config '$TOPOLOGY' --mode '$mode' --workdir '$CLIENT_WD/$mode' --duration-secs $DURATION"
  case $mode in
    mode_1n_steady)   SES=soak-1n ;;
    mode_3n_steady)   SES=soak-3n ;;
    mode_3n_chaos)    SES=soak-3n-chaos ;;
  esac
  tmux has-session -t "$SES" 2>/dev/null && tmux kill-session -t "$SES"
  tmux new-session -d -s "$SES" -- bash -lc "$CMD; sleep 5"
done

echo "[smoke] tmux sessions: tmux ls"
echo "[smoke] monitor:        tmux attach -t soak-3n-chaos"
echo "[smoke] waiting ${DURATION}s for clients to finish..."
SECS=$((DURATION + 60))
END=$(( $(date +%s) + SECS ))
while (( $(date +%s) < END )); do
  if ! tmux ls 2>/dev/null | grep -qE 'soak-1n|soak-3n|soak-3n-chaos'; then
    break
  fi
  sleep 5
done

echo
echo "[smoke] === verification report ==="
"$REPORT" --config "$TOPOLOGY" --workdir "$CLIENT_WD" \
  --duration-secs "$DURATION" --min-commits-per-min 5 \
  || { echo "[smoke] report exit nonzero"; }

echo
echo "[smoke] artifacts: $WORK_ROOT"
