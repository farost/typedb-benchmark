#!/usr/bin/env bash
# Stop the running soak in place and archive its state, leaving the fleet
# ready for a fresh `deploy.sh` (03 rebuild + 06 bootstrap) with a new tag.
#
# Steps:
#   1. Record a final health snapshot (client STATE + per-server panic scan)
#      into ./soak-final-health-<ts>.txt locally.
#   2. Archive the client workdir to a tarball on the client VM.
#   3. Stop client tmux sessions, the periodic reporter, server runners, and
#      any leftover typedb processes.
#   4. Move every workdir aside to /var/lib/typedb-soak/archive-<ts>/ so
#      bootstrap's empty-workdir check passes. Nothing is deleted.
#
# Refuses to run unless CONFIRM=yes.
#
# Usage:
#   PROJECT=... ZONE=... CONFIRM=yes tool/gcp/10-stop-and-reset.sh
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

if [ "${CONFIRM:-}" != "yes" ]; then
    echo "This stops the running soak on all VMs and archives the workdirs."
    echo "To proceed:  CONFIRM=yes $0"
    exit 2
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
HEALTH_FILE="./soak-final-health-$TS.txt"

step "1/4 Final health record → $HEALTH_FILE"
{
    echo "=== soak final health record @ $TS ==="
    echo
    echo "===== client health-snapshot ====="
    gc_ssh "$CLIENT" 'cd ~/typedb-benchmark/soak-suite && tool/health-snapshot.sh' || true
    for M in "${SERVERS[@]}"; do
        LABEL="$(vm_label "$M")"
        echo
        echo "===== $M ====="
        gc_ssh "$M" '
            LABEL='"$LABEL"'
            echo "-- typedb processes --"
            pgrep -laf typedb_server_bin || echo "(none)"
            echo "-- panic markers per mode --"
            for f in /var/lib/typedb-soak/$LABEL/mode_*/node*/server.log; do
                [ -f "$f" ] || continue
                echo "$f: $(grep -c "panic occurred\|panicked at" "$f" 2>/dev/null) panics, $(grep -c "Local failure while applying replicated" "$f" 2>/dev/null) local-failure warns"
            done
            echo "-- disk --"
            df -h /var/lib/typedb-soak | tail -1
        ' || true
    done
} | tee "$HEALTH_FILE"
ok "health record written: $HEALTH_FILE"

step "2/4 Archiving client workdir on $CLIENT"
gc_ssh "$CLIENT" "
    mkdir -p /var/lib/typedb-soak-archives
    tar czf /var/lib/typedb-soak-archives/client-$TS.tar.gz -C /var/lib/typedb-soak client 2>/dev/null || true
    ls -lh /var/lib/typedb-soak-archives/client-$TS.tar.gz
" | tail -1

step "3/4 Stopping clients, reporters, runners, servers"
gc_ssh "$CLIENT" '
    cd ~/typedb-benchmark/soak-suite && tool/stop-clients.sh 2>/dev/null || true
    for s in soak-reporter soak-verify; do
        tmux has-session -t "$s" 2>/dev/null && tmux kill-session -t "$s" && echo "killed $s"
    done
    echo CLIENT_STOPPED
' | tail -3

stop_server() {
    local vm="$1"
    gc_ssh "$vm" '
        tmux has-session -t soak-runner 2>/dev/null && tmux kill-session -t soak-runner
        pkill -f typedb_server_bin 2>/dev/null
        pkill -f typedb_admin_bin 2>/dev/null
        sleep 3
        if pgrep -f typedb_server_bin >/dev/null; then
            pkill -9 -f typedb_server_bin
            sleep 2
        fi
        if pgrep -f typedb_server_bin >/dev/null; then
            echo STILL_RUNNING
        else
            echo STOPPED
        fi
    ' | tail -1
}

for M in "${SERVERS[@]}"; do
    result="$(stop_server "$M")"
    if [ "$result" != "STOPPED" ]; then
        error "$M: servers still running after pkill -9 — investigate manually"
        exit 1
    fi
    ok "$M: stopped"
done

step "4/4 Moving workdirs aside (archive-$TS)"
reset_one() {
    local vm="$1"
    gc_ssh "$vm" '
        set -e
        ARCHIVE=/var/lib/typedb-soak/archive-'"$TS"'
        mkdir -p "$ARCHIVE"
        moved=0
        for d in /var/lib/typedb-soak/M1 /var/lib/typedb-soak/M2 /var/lib/typedb-soak/M3 /var/lib/typedb-soak/client /var/lib/typedb-soak/reports; do
            if [ -d "$d" ]; then
                mv "$d" "$ARCHIVE/"
                moved=$((moved+1))
            fi
        done
        echo "MOVED_$moved"
        df -h /var/lib/typedb-soak | tail -1
    ' | tail -2
}

for VM in "${ALL_VMS[@]}"; do
    log "$VM:"
    reset_one "$VM"
done

ok "Fleet is stopped and reset. Old data preserved under /var/lib/typedb-soak/archive-$TS/ on each VM."
echo
echo "Next (from your laptop, repo root):"
echo "  export PROJECT=$PROJECT ZONE=$ZONE GITHUB_TOKEN=... GITHUB_USER=..."
echo "  SIZING=long-soak TYPEDB_TAG=3.12.0-beta-2 soak-suite/tool/gcp/deploy.sh"
echo "  DURATION=1800 FOLLOW=1 soak-suite/tool/gcp/07-verify-short.sh"
echo "  soak-suite/tool/gcp/08-start-long-soak.sh"
