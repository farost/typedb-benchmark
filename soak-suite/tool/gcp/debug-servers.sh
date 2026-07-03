#!/usr/bin/env bash
# Snapshot every debug-relevant file across all 3 server VMs.
# Usage: bash soak-suite/tool/gcp/debug-servers.sh
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

REMOTE='
LABEL=$(hostname | tr a-z A-Z | sed s/SOAK-//)
echo "=== running server procs ==="
pgrep -laf typedb_server_bin || echo "(none)"
echo
echo "=== ~/bin ==="
ls -la ~/bin/ 2>&1
echo
echo "=== runner.log tail ==="
tail -30 /var/lib/typedb-soak/$LABEL/runner.log 2>&1 || echo "(no runner.log)"
echo
echo "=== server.log per mode ==="
for m in mode_1n_steady mode_3n_steady mode_3n_chaos; do
    echo "--- $m ---"
    for d in /var/lib/typedb-soak/$LABEL/$m/node*/server.log; do
        if [ -f "$d" ]; then
            echo "-- $d --"
            tail -20 "$d" 2>&1
        fi
    done
done
echo
echo "=== ports listening ==="
ss -tlnp 2>/dev/null | grep -E "11729|11730|11731|21729|21730|21731|31729|31730|31731" || echo "(no matching ports listening)"
'

for M in soak-m1 soak-m2 soak-m3; do
    step "$M"
    gc_ssh "$M" "$REMOTE"
    echo
done
