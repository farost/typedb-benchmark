#!/usr/bin/env bash
# Install OS packages, Rust toolchain, per-machine workdir, and (servers only)
# the sudoers fragment that lets iptables/tc run without a password prompt.
# Long-soak: also format+mount the /dev/sdb data disk at /var/lib/typedb-soak.
#
# Idempotent — safe to re-run.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE

server_prereqs() {
    local vm="$1"
    # long-soak: format+mount /dev/sdb if present and unmounted.
    local mount_hook=""
    if [ "$SIZING" = "long-soak" ]; then
        mount_hook='if [ -b /dev/sdb ] && ! mount | grep -q "/var/lib/typedb-soak"; then sudo mkdir -p /var/lib/typedb-soak; if ! blkid /dev/sdb >/dev/null 2>&1; then sudo mkfs.ext4 -F /dev/sdb; fi; sudo mount /dev/sdb /var/lib/typedb-soak && grep -q "/dev/sdb /var/lib/typedb-soak" /etc/fstab || echo "/dev/sdb /var/lib/typedb-soak ext4 defaults 0 2" | sudo tee -a /etc/fstab; sudo chown $USER /var/lib/typedb-soak; fi;'
    fi
    gc_ssh "$vm" "
        set -e
        sudo apt-get update -qq
        sudo apt-get install -y -qq build-essential pkg-config libssl-dev iptables iproute2 tmux jq git curl python3 python3-pip
        if [ ! -f \$HOME/.cargo/env ]; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.90.0 --profile minimal >/dev/null
        fi
        $mount_hook
        sudo mkdir -p /var/lib/typedb-soak
        sudo chown \$USER /var/lib/typedb-soak
        if [ ! -f /etc/sudoers.d/typedb-soak ]; then
            echo \"\$USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/tc\" | sudo tee /etc/sudoers.d/typedb-soak >/dev/null
            sudo chmod 440 /etc/sudoers.d/typedb-soak
        fi
        sudo -n iptables -L OUTPUT -n >/dev/null
        IFACE_=\$(ip -o -4 route show default | awk '{print \$5}' | head -1); sudo -n tc qdisc show dev \$IFACE_ >/dev/null
        echo PREFLIGHT_OK
    " | tail -3
}

client_prereqs() {
    local vm="$1"
    gc_ssh "$vm" "
        set -e
        sudo apt-get update -qq
        sudo apt-get install -y -qq build-essential pkg-config libssl-dev tmux jq git curl python3 python3-pip
        if [ ! -f \$HOME/.cargo/env ]; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.90.0 --profile minimal >/dev/null
        fi
        sudo mkdir -p /var/lib/typedb-soak
        sudo chown \$USER /var/lib/typedb-soak
        echo CLIENT_PREFLIGHT_OK
    " | tail -1
}

foreach_vm_parallel SERVERS[@] "Installing server prereqs" server_prereqs
client_prereqs "$CLIENT"
ok "$CLIENT: done"
