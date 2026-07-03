#!/usr/bin/env bash
# Create the 4 VMs + firewall rule. Sizing controlled by env:
#   SIZING=verification  — n2-standard-4 servers, e2-standard-2 client, boot disk only (cheap smoke)
#   SIZING=long-soak     — n2-standard-8 servers with 500 GB pd-ssd data disks, e2-standard-4 client
#
# Usage:
#   PROJECT=my-proj ZONE=us-central1-a SIZING=verification tool/gcp/00-create-vms.sh
#
# Idempotent — skips VMs that already exist (checked by name).
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

step "Creating VMs (sizing: $SIZING)"

exists() {
    gcloud compute instances describe "$1" --project="$PROJECT" --zone="$ZONE" \
        --format='value(name)' 2>/dev/null | grep -qx "$1"
}

case "$SIZING" in
    verification)
        SERVER_TYPE=n2-standard-4
        SERVER_BOOT=100GB
        CLIENT_TYPE=e2-standard-2
        CLIENT_BOOT=30GB
        ATTACH_DATA=0
        ;;
    long-soak)
        SERVER_TYPE=n2-standard-8
        SERVER_BOOT=50GB
        CLIENT_TYPE=e2-standard-4
        CLIENT_BOOT=100GB
        ATTACH_DATA=1
        DATA_SIZE=500GB
        ;;
    *)
        error "unknown SIZING='$SIZING' (want: verification | long-soak)"
        exit 2
        ;;
esac

# ---------- Servers ----------
for M in "${SERVERS[@]}"; do
    if exists "$M"; then
        log "$M: already exists — skipping create"
    else
        log "$M: creating ($SERVER_TYPE, ${SERVER_BOOT} boot)"
        gcloud compute instances create "$M" \
            --project="$PROJECT" --zone="$ZONE" \
            --machine-type="$SERVER_TYPE" \
            --network="$NETWORK" --subnet="$SUBNET" \
            --image-family=debian-12 --image-project=debian-cloud \
            --boot-disk-size="$SERVER_BOOT" --boot-disk-type=pd-ssd \
            --tags=soak-server >/dev/null
        ok "$M: created"
    fi

    # Long-soak: attach a dedicated data disk if not already attached.
    if [ "$ATTACH_DATA" = "1" ]; then
        DISK_NAME="${M}-data"
        if ! gcloud compute disks describe "$DISK_NAME" --project="$PROJECT" --zone="$ZONE" \
             --format='value(name)' 2>/dev/null | grep -qx "$DISK_NAME"; then
            log "$M: creating data disk $DISK_NAME ($DATA_SIZE pd-ssd)"
            gcloud compute disks create "$DISK_NAME" \
                --project="$PROJECT" --zone="$ZONE" \
                --size="$DATA_SIZE" --type=pd-ssd >/dev/null
        fi
        # Attach if not already attached.
        already_attached="$(gcloud compute instances describe "$M" --project="$PROJECT" --zone="$ZONE" \
            --format='value(disks[].deviceName)' 2>/dev/null | grep -c "$DISK_NAME" || true)"
        if [ "$already_attached" -eq 0 ]; then
            log "$M: attaching $DISK_NAME"
            gcloud compute instances attach-disk "$M" \
                --project="$PROJECT" --zone="$ZONE" \
                --disk="$DISK_NAME" >/dev/null
        fi
    fi
done

# ---------- Client ----------
if exists "$CLIENT"; then
    log "$CLIENT: already exists — skipping create"
else
    log "$CLIENT: creating ($CLIENT_TYPE, ${CLIENT_BOOT} boot)"
    gcloud compute instances create "$CLIENT" \
        --project="$PROJECT" --zone="$ZONE" \
        --machine-type="$CLIENT_TYPE" \
        --network="$NETWORK" --subnet="$SUBNET" \
        --image-family=debian-12 --image-project=debian-cloud \
        --boot-disk-size="$CLIENT_BOOT" \
        --tags=soak-client >/dev/null
    ok "$CLIENT: created"
fi

# ---------- Firewall ----------
if gcloud compute firewall-rules describe soak-internal --project="$PROJECT" \
    --format='value(name)' 2>/dev/null | grep -qx soak-internal; then
    log "firewall soak-internal: already exists"
else
    log "creating firewall rule soak-internal"
    gcloud compute firewall-rules create soak-internal \
        --project="$PROJECT" --network="$NETWORK" \
        --direction=INGRESS --action=ALLOW \
        --source-tags=soak-server,soak-client \
        --target-tags=soak-server \
        --rules=tcp:11729-11732,tcp:21729-21732,tcp:31729-31732 >/dev/null
    ok "firewall created"
fi

step "Waiting up to 60s for SSH readiness on all VMs"
for VM in "${ALL_VMS[@]}"; do
    for i in 1 2 3 4 5 6; do
        if gcloud compute ssh "$VM" --project="$PROJECT" --zone="$ZONE" --command='echo ready' 2>/dev/null | grep -qx ready; then
            ok "$VM: SSH ready"
            break
        fi
        if [ "$i" -eq 6 ]; then
            error "$VM: SSH not ready after 60s"
            exit 1
        fi
        sleep 10
    done
done

ok "all VMs created + reachable"
