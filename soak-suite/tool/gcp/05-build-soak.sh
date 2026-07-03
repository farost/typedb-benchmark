#!/usr/bin/env bash
# Build the soak-suite runner + client + verify-report binaries on every VM
# in parallel.
#
# Idempotent — cargo already caches; a re-run is a fast rebuild-if-dirty.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

build_one() {
    local vm="$1"
    gc_ssh "$vm" 'set -e; source ~/.cargo/env; cd ~/typedb-benchmark/soak-suite && cargo build --release --bins 2>&1 | tail -3'
}

foreach_vm_parallel ALL_VMS[@] "Building soak-suite" build_one
