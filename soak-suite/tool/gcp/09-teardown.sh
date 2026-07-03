#!/usr/bin/env bash
# Nuke the fleet: delete VMs + firewall + any data disks.
#
# Refuses to run unless CONFIRM=yes.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

if [ "${CONFIRM:-}" != "yes" ]; then
    echo "This deletes all soak-* VMs + soak-internal firewall + data disks in $PROJECT/$ZONE."
    echo "To proceed:  CONFIRM=yes $0"
    exit 2
fi

step "Deleting VMs"
for M in "${ALL_VMS[@]}"; do
    gcloud compute instances delete "$M" --project="$PROJECT" --zone="$ZONE" --quiet 2>/dev/null || warn "$M: delete failed (maybe already gone)"
done

step "Deleting firewall rule"
gcloud compute firewall-rules delete soak-internal --project="$PROJECT" --quiet 2>/dev/null || warn "soak-internal: delete failed"

step "Deleting long-soak data disks (if any)"
for M in "${SERVERS[@]}"; do
    gcloud compute disks delete "${M}-data" --project="$PROJECT" --zone="$ZONE" --quiet 2>/dev/null || true
done

ok "Teardown complete"
