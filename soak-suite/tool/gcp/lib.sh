# Common vars and helpers for the tool/gcp/*.sh scripts.
# Source this from any script: `source "$(dirname "$0")/lib.sh"`.

set -euo pipefail

# ---------- Required env ----------
require_env() {
    local missing=()
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: required env vars not set: ${missing[*]}" >&2
        echo "  export PROJECT=<gcp-project> ZONE=<zone> NETWORK=<net> SUBNET=<subnet>" >&2
        echo "  optional: TYPEDB_TAG (default 3.12.0-beta-1), GITHUB_TOKEN" >&2
        exit 2
    fi
}

# ---------- Defaults ----------
: "${NETWORK:=default}"
: "${SUBNET:=default}"
: "${TYPEDB_TAG:=3.12.0-beta-1}"
: "${SIZING:=verification}"   # verification | long-soak

# ---------- Machine names ----------
SERVERS=(soak-m1 soak-m2 soak-m3)
CLIENT=soak-client
ALL_VMS=("${SERVERS[@]}" "$CLIENT")

# ---------- Colored logging ----------
if [ -t 1 ]; then
    BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; NC=$'\e[0m'
else
    BOLD=; GREEN=; YELLOW=; RED=; NC=
fi
step()  { echo "${BOLD}==>${NC} ${BOLD}$*${NC}" >&2; }
log()   { echo "  $*" >&2; }
warn()  { echo "${YELLOW}  ! $*${NC}" >&2; }
error() { echo "${RED}  ✗ $*${NC}" >&2; }
ok()    { echo "${GREEN}  ✓ $*${NC}" >&2; }

# ---------- gcloud wrapper ----------
gc_ssh() {
    local vm="$1"; shift
    gcloud compute ssh "$vm" --project="$PROJECT" --zone="$ZONE" --command="$*" 2>&1
}

gc_scp() {
    local src="$1" dst="$2"
    gcloud compute scp "$src" "$dst" --project="$PROJECT" --zone="$ZONE" 2>&1
}

# Uppercased short label ("M1", "M2", "M3", "CLIENT") from full VM name.
vm_label() {
    local name="$1"
    echo "${name#soak-}" | tr '[:lower:]' '[:upper:]'
}

# For-each helper: run a command on every VM in parallel, wait, report failures.
foreach_vm_parallel() {
    local vms=("${!1}"); shift
    local label="$1"; shift
    local pids=() rcs=()
    step "$label — running on ${#vms[@]} VMs in parallel"
    for vm in "${vms[@]}"; do
        ( "$@" "$vm" ) &
        pids+=($!)
    done
    local fail=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            error "  ${vms[$i]}: failed (rc=$?)"
            fail=$((fail+1))
        else
            ok  "  ${vms[$i]}: done"
        fi
    done
    if [ "$fail" -gt 0 ]; then
        error "$fail / ${#vms[@]} VMs failed"
        return 1
    fi
    ok "$label — all ${#vms[@]} VMs succeeded"
}
