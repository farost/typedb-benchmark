#!/usr/bin/env bash
# tar the current soak-suite/ from this checkout and scp to all 4 VMs, unpack.
#
# Usage: PROJECT=... ZONE=... tool/gcp/02-ship-suite.sh
#
# Idempotent — just overwrites the previous copy.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TAR=/tmp/soak-suite.tar.gz

step "Packing soak-suite/ from $REPO_ROOT"
tar czf "$TAR" -C "$REPO_ROOT" soak-suite
log "wrote $TAR ($(du -h "$TAR" | awk '{print $1}'))"

ship_one() {
    local vm="$1"
    gc_scp "$TAR" "$vm:/tmp/soak-suite.tar.gz" >/dev/null
    gc_ssh "$vm" "mkdir -p ~/typedb-benchmark && tar xzf /tmp/soak-suite.tar.gz -C ~/typedb-benchmark" >/dev/null
    echo "shipped to $vm"
}

foreach_vm_parallel ALL_VMS[@] "Shipping suite" ship_one
