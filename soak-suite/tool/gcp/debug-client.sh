#!/usr/bin/env bash
# Snapshot every debug-relevant file on the client. Run from your Mac:
#   bash soak-suite/tool/gcp/debug-client.sh
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

REMOTE='
echo "=== tmux ==="; tmux ls 2>&1
echo
echo "=== health-verify log ==="
cat /var/lib/typedb-soak/reports/health-verify-short.log 2>/dev/null || echo "(no health log)"
echo
echo "=== verify stdout (if any) ==="
tail -60 /var/lib/typedb-soak/reports/verify-short.stdout 2>&1
echo
echo "=== client workdir tree ==="
ls -la /var/lib/typedb-soak/client/ 2>&1
echo
for m in mode_1n_steady mode_3n_steady mode_3n_chaos; do
    echo "=== $m/client.log (tail 30) ==="
    tail -30 /var/lib/typedb-soak/client/$m/client.log 2>&1 || echo "(missing)"
    echo
    echo "=== $m/STATE ==="
    cat /var/lib/typedb-soak/client/$m/STATE 2>/dev/null || echo "(no STATE)"
    echo
    echo "=== $m/FAILURES.log (tail 10) ==="
    tail -10 /var/lib/typedb-soak/client/$m/FAILURES.log 2>/dev/null || echo "(no failures)"
    echo
    echo "=== $m/client.tail.log (full stdout+stderr, tail 60) ==="
    tail -60 /var/lib/typedb-soak/client/$m/client.tail.log 2>/dev/null || echo "(no tail log)"
    echo
    echo "=== $m/diagnostics.log (tail 20) ==="
    tail -20 /var/lib/typedb-soak/client/$m/diagnostics.log 2>/dev/null || echo "(no diagnostics log)"
    echo
done
echo "=== connectivity from client to server ports ==="
for host in soak-m1 soak-m2 soak-m3; do
    for port in 11729 21729 31729; do
        printf "%s:%s " "$host" "$port"
        timeout 2 bash -c "cat < /dev/tcp/$host/$port 2>/dev/null && echo OPEN" || echo CLOSED/timeout
    done
done
echo "=== live client procs ==="
pgrep -laf target/release/client 2>&1 || echo "(none running)"
echo
echo "=== topology.toml (mode addrs) ==="
grep -E "^hostname|^\[modes|grpc_port|^interface" ~/typedb-benchmark/soak-suite/config/topology.toml 2>&1 | head -40
'

gc_ssh "$CLIENT" "$REMOTE"
