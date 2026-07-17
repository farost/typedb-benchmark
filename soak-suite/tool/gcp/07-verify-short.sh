#!/usr/bin/env bash
# Kick off the 30-min verification on the client and stream progress.
#
# Env:
#   DURATION (default 1800)  — seconds per client run
#   FOLLOW=1                 — tail the health log until it completes
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

: "${DURATION:=1800}"
: "${FOLLOW:=0}"

step "Starting verification on $CLIENT (duration ${DURATION}s)"
gc_ssh "$CLIENT" "
    if tmux has-session -t soak-verify 2>/dev/null; then
        echo SKIP_ALREADY_RUNNING
        exit 0
    fi
    tmux new-session -d -s soak-verify \"mkdir -p /var/lib/typedb-soak/reports && cd ~/typedb-benchmark/soak-suite && DURATION=$DURATION tool/run-verify-short.sh 2>&1 | tee /var/lib/typedb-soak/reports/verify-short.stdout\"
    echo STARTED
" | tail -1

if [ "$FOLLOW" = "1" ]; then
    step "Following /var/lib/typedb-soak/reports/verify-short.stdout (Ctrl-C to detach)"
    gc_ssh "$CLIENT" 'tail -F /var/lib/typedb-soak/reports/verify-short.stdout 2>/dev/null'
else
    log "Verification started under tmux session 'soak-verify' on $CLIENT."
    log "Attach:    gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE -- -t 'tmux attach -t soak-verify'"
    log "Watch log: gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='tail -F /var/lib/typedb-soak/reports/verify-short.stdout'"
    log "Health:    gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/health-snapshot.sh'"
fi
