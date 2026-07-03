#!/usr/bin/env bash
# Patch soak-suite/config/topology.toml on each VM: bin paths + hostnames.
#
# Idempotent — sed is safe to re-run.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

configure_one() {
    local vm="$1"
    gc_ssh "$vm" '
        cd ~/typedb-benchmark/soak-suite && \
        sed -i \
            -e "s|server_bin = .*|server_bin = \"$HOME/bin/typedb_server_bin\"|" \
            -e "s|admin_bin = .*|admin_bin = \"$HOME/bin/typedb_admin_bin\"|" \
            -e "s|hostname = \"soak-m1.internal\"|hostname = \"soak-m1\"|" \
            -e "s|hostname = \"soak-m2.internal\"|hostname = \"soak-m2\"|" \
            -e "s|hostname = \"soak-m3.internal\"|hostname = \"soak-m3\"|" \
            -e "s|hostname = \"soak-client.internal\"|hostname = \"soak-client\"|" \
            config/topology.toml && \
        IFACE_=$(ip -o -4 route show default | awk "{print \$5}" | head -1) && \
        sed -i "s|^interface\s*=.*|interface = \"$IFACE_\"|" config/topology.toml && \
        grep -c -E "^hostname|^server_bin|^admin_bin" config/topology.toml
    ' | tail -1
}

for VM in "${ALL_VMS[@]}"; do
    n="$(configure_one "$VM")"
    if [ "$n" != "6" ]; then
        error "$VM: expected 6 substitutions to survive (server_bin + admin_bin + 4 hostnames), got '$n'"
        exit 1
    fi
    ok "$VM: topology configured"
done
