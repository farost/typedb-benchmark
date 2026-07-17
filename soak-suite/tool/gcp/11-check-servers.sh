#!/usr/bin/env bash
# One-shot fleet health check, safe to run any time against a live soak.
# Complements the client-side health-snapshot with the server-side signals it
# cannot see: process counts, panic markers, and the apply-failure WARN marker
# ("Local failure while applying replicated ...") introduced in 3.12.0-beta-2.
#
# Interpretation:
#   panics             — must stay 0; any hit means a node is crash-looping.
#   local-failure warns — each hit is a replica-local apply failure worth a
#                         look (benign DatabaseNotFound during boot replay of
#                         a later-deleted database is the known exception).
#
# Usage:
#   PROJECT=... ZONE=... tool/gcp/11-check-servers.sh
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

step "Client-side snapshot"
gc_ssh "$CLIENT" 'cd ~/typedb-benchmark/soak-suite && tool/health-snapshot.sh' || true

for M in "${SERVERS[@]}"; do
    LABEL="$(vm_label "$M")"
    step "$M"
    gc_ssh "$M" '
        LABEL='"$LABEL"'
        echo "-- typedb server processes --"
        n=$(pgrep -cf typedb_server_bin 2>/dev/null)
        echo "running: ${n:-0} (expected: M1=3, M2/M3=2 for the standard 3-mode topology)"
        echo "-- per-mode log markers --"
        found_any=0
        for f in /var/lib/typedb-soak/$LABEL/mode_*/node*/server.log; do
            [ -f "$f" ] || continue
            found_any=1
            panics=$(grep -c "panic occurred\|panicked at" "$f" 2>/dev/null)
            warns=$(grep -c "Local failure while applying replicated" "$f" 2>/dev/null)
            echo "$f: panics=${panics:-0} local_failure_warns=${warns:-0}"
            if [ "${warns:-0}" -gt 0 ]; then
                echo "  last local-failure warn:"
                grep "Local failure while applying replicated" "$f" | tail -1 | sed "s/^/    /"
            fi
        done
        [ "$found_any" = 1 ] || echo "(no server logs under /var/lib/typedb-soak/$LABEL)"
        echo "-- disk --"
        df -h /var/lib/typedb-soak | tail -1
    ' || true
done

echo
ok "Done. For the deep chaos-mode check (byte-identical replica WALs), run:"
echo "  soak-suite/tool/collect-chaos-wals.sh && soak-suite/tool/dump-chaos-wals.sh <out-dir> --read-wal <typedb-repo>/target/release/read_wal"
