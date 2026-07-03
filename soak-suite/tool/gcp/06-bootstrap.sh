#!/usr/bin/env bash
# Boot the runner on each of M1/M2/M3 inside a detached tmux session, then
# poll runner.log until all three modes report READY (or fail).
#
# Idempotent-ish: if a soak-runner tmux session is already alive, we skip;
# otherwise we start fresh. Won't clobber an active run.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

start_one() {
    local vm="$1"
    local label
    label="$(vm_label "$vm")"
    gc_ssh "$vm" "
        if tmux has-session -t soak-runner 2>/dev/null; then
            echo SKIP_ALREADY_RUNNING
            exit 0
        fi
        tmux new-session -d -s soak-runner \"cd ~/typedb-benchmark/soak-suite && tool/bootstrap.sh $label config/topology.toml /var/lib/typedb-soak/$label 2>&1 | tee /var/lib/typedb-soak/$label/bootstrap.tail\"
        echo STARTED
    " | tail -1
}

for M in "${SERVERS[@]}"; do
    result="$(start_one "$M")"
    log "$M: $result"
done

step "Waiting up to 5 min for all READY signals"
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    all_ready=1
    for M in "${SERVERS[@]}"; do
        label="$(vm_label "$M")"
        n_ready="$(gc_ssh "$M" "grep -c '\\[READY\\]' /var/lib/typedb-soak/$label/runner.log 2>/dev/null || echo 0" | tail -1)"
        n_err="$(gc_ssh "$M" "grep -c 'ERROR' /var/lib/typedb-soak/$label/runner.log 2>/dev/null || echo 0" | tail -1)"
        if [ "$n_err" -gt 0 ]; then
            error "$M: runner.log has ERROR lines — bootstrap failed"
            gc_ssh "$M" "grep -E 'ERROR|BOOT' /var/lib/typedb-soak/$label/runner.log | tail -20"
            exit 1
        fi
        if [ "$n_ready" -lt 1 ]; then
            all_ready=0
        fi
    done
    if [ "$all_ready" = "1" ]; then
        ok "all machines reported READY"
        exit 0
    fi
    sleep 10
done

error "Not all machines READY within 5 min. Snapshot:"
for M in "${SERVERS[@]}"; do
    label="$(vm_label "$M")"
    echo "--- $M ---"
    gc_ssh "$M" "tail -15 /var/lib/typedb-soak/$label/runner.log 2>/dev/null"
done
exit 1
