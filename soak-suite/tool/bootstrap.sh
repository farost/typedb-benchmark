#!/usr/bin/env bash
# Multi-step bootstrap, run ONCE per fleet on a brand-new cluster.
# Steps:
#   1. Confirm workdir on this machine is empty (refuses to nuke existing data).
#   2. Start the runner (which spawns nodes, waits for ports, registers peers
#      via node 1 of each multi-node mode, and waits for primary election).
#   3. Sit in the foreground; ^C to stop.
#
# Run this on each server machine (M1, M2, M3) in any order — node 1's machine
# performs the registration once everyone is reachable. The OTHER machines'
# runners just wait for the registration to land, which it will.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <machine-label> [topology.toml] [workdir]" >&2
  exit 2
fi
MACHINE="$1"
TOPOLOGY="${2:-$(dirname "$0")/../config/topology.toml}"
WORKDIR="${3:-/var/lib/typedb-soak/$MACHINE}"

if [[ -d "$WORKDIR" ]]; then
  # We allow re-bootstrap only if the dir is empty (or only contains
  # runner logs, no data dirs). Refuse otherwise so the operator decides.
  if find "$WORKDIR" -mindepth 1 -name 'data' -type d -print -quit | grep -q .; then
    echo "!!!!! ERROR: $WORKDIR contains existing data directories." >&2
    echo "             Remove or move it first; this script refuses to" >&2
    echo "             clobber an existing cluster." >&2
    exit 1
  fi
fi

mkdir -p "$WORKDIR"
echo "[bootstrap] $(date -u +%FT%TZ) machine=$MACHINE workdir=$WORKDIR empty=ok"
exec "$(dirname "$0")/start-servers-on-machine.sh" "$MACHINE" "$TOPOLOGY" "$WORKDIR"
