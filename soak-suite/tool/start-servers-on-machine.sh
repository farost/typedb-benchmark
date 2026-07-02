#!/usr/bin/env bash
# Launch the server-side runner on one machine. Runs in the foreground so
# the operator can ^C cleanly. For production, put it under systemd or
# detach with `tmux new-session -d -s soak-runner ./start-servers-on-machine.sh M1`.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <machine-label> [topology.toml] [workdir]" >&2
  echo "  machine-label must match a key under [machines.X] in the topology file" >&2
  exit 2
fi

MACHINE="$1"
TOPOLOGY="${2:-$(dirname "$0")/../config/topology.toml}"
WORKDIR="${3:-/var/lib/typedb-soak/$MACHINE}"

SOAK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$WORKDIR"
echo "[soak] machine=$MACHINE topology=$TOPOLOGY workdir=$WORKDIR"
echo "[soak] building runner if needed..."
(cd "$SOAK_DIR" && cargo build --release --bin runner)

exec "$SOAK_DIR/target/release/runner" \
  --config "$TOPOLOGY" \
  --machine "$MACHINE" \
  --workdir "$WORKDIR"
