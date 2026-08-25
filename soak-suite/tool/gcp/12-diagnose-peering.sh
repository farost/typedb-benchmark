#!/usr/bin/env bash
# Bootstrap/peering diagnostic. Use when 06-bootstrap hangs on
# "await peer N clustering <host>:<port> reachable": a node's gRPC (*1729) can
# be up (so it reports [READY]) while its peering/clustering port (*1730) never
# binds — the registrar then waits forever. For each server VM this shows:
#   - which clustering (*1730) and gRPC (*1729) ports are actually listening
#   - each mode's server.log lines about version / peering / bind / resolve
#   - the built binary commit (to catch a stale/wrong-version binary)
#
# Read: a node with *1729 listening but its matching *1730 missing has a
# peering server that failed or is stuck binding — see its server.log below.
#
# Usage:
#   PROJECT=... ZONE=... tool/gcp/12-diagnose-peering.sh
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

for M in "${SERVERS[@]}"; do
    LABEL="$(vm_label "$M")"
    step "$M"
    gc_ssh "$M" '
        LABEL='"$LABEL"'
        echo "-- listening gRPC (*1729) + clustering/peering (*1730) ports --"
        ss -ltn 2>/dev/null | grep -oE ":[1-3]1(729|730)" | sort -u \
            || netstat -ltn 2>/dev/null | grep -oE ":[1-3]1(729|730)" | sort -u \
            || echo "  (ss/netstat unavailable)"
        echo "-- per-mode server.log: version + peering/bind/resolve issues --"
        for f in /var/lib/typedb-soak/$LABEL/mode_*/node*/server.log; do
            [ -f "$f" ] || continue
            echo "  $f:"
            grep -iE "Running TypeDB|Serving|peering|clustering|resolve|bind|Connection refused|AddressResolution|panic|Exited with error" "$f" 2>/dev/null \
                | tail -8 | sed "s/^/    /"
        done
        echo "-- built binary commit --"
        cat ~/bin/.typedb-built-from 2>/dev/null | sed "s/^/  /" || echo "  (no marker)"
    ' || true
done

echo
ok "Done. A node listening on *1729 but NOT its matching *1730 = peering server failed/stuck to bind; check its server.log lines above for a resolve/bind error."
