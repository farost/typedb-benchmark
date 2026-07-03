#!/usr/bin/env bash
# Kick off the forever-mode soak + a periodic health reporter on the client.
# Only run this AFTER the short verification passes.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

: "${REPORTER_INTERVAL:=300}"

step "Starting long soak on $CLIENT"
gc_ssh "$CLIENT" "
    if tmux has-session -t soak-clients 2>/dev/null; then
        echo SKIP_ALREADY_RUNNING
        exit 0
    fi
    cd ~/typedb-benchmark/soak-suite
    tool/start-clients.sh
    if ! tmux has-session -t soak-reporter 2>/dev/null; then
        tmux new-session -d -s soak-reporter \"INTERVAL=$REPORTER_INTERVAL tool/periodic-report.sh\"
    fi
    echo STARTED
" | tail -1

step "Long soak now running. Client sessions:"
gc_ssh "$CLIENT" 'tmux ls 2>/dev/null'

cat <<EOF
Watch health from home:
  gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='tail -F /var/lib/typedb-soak/reports/health.log'
One-shot status:
  gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/health-snapshot.sh'
Stop all clients (keeps servers running):
  gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/stop-clients.sh'
Collect artifacts for post-mortem (per machine):
  for M in soak-m1 soak-m2 soak-m3 $CLIENT; do gcloud compute ssh \$M --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/collect-artifacts.sh'; done
EOF
