#!/usr/bin/env bash
# Start the server(s) for a mode. Returns the address list to stdout
# (comma-separated, ready to drop into tpcc config `addr =`).
#
# Usage: start-server.sh <mode_name> <run_dir>
#
#   mode_name: one of the names defined in config.yml
#   run_dir:   per-run scratch dir; node data lives in $run_dir/{1,2,3}/...
#
# Output (stdout): one line, the addr list (e.g. "127.0.0.1:11729,127.0.0.1:21729,127.0.0.1:31729")
# Output (stderr): human-readable progress

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mode_name="$1"
run_dir="$2"

line="$(mode_get "$mode_name" || true)"
if [ -z "$line" ]; then error "unknown mode: $mode_name"; exit 1; fi
IFS='|' read -r _name repo_url commit server_type nodes <<<"$line"

# The setup phase records the extract dir per mode (covers local_archive /
# local_repo cases whose dir name isn't derivable from `commit` alone).
workspace="$(config_get workspace)"
path_file="$workspace/extracts/${mode_name}.path"
if [ -s "$path_file" ]; then
    extract_dir="$(cat "$path_file")"
else
    extract_dir="$(mode_extract_dir "$mode_name" "$commit")"
fi
launcher="$(mode_launcher "$extract_dir")"

if [ ! -x "$launcher" ]; then
    error "no launcher at $launcher — did the setup phase run for this mode?"
    error "  expected dir: $extract_dir"
    exit 1
fi

kill_servers

mkdir -p "$run_dir"
addrs=()

# typedb-cluster needs --server.clustering.{id,address} on every invocation.
# typedb (Core) doesn't accept those flags. Branch on server_type.
start_node() {
    local n="$1"
    local node_dir="$run_dir/$n"
    local data_dir="$node_dir/server/data"
    local clustering_dir="$node_dir/server/clustering"
    local log_file="$node_dir/server.log"

    mkdir -p "$data_dir" "$clustering_dir"

    local gport hport mport cport aport
    gport="$(grpc_port "$n")"
    hport="$(http_port "$n")"
    mport="$(monitoring_port "$n")"
    cport="$(clustering_port "$n")"
    aport="$(admin_port "$n")"

    # The CLI surface drifts between typedb / typedb-cluster master / feature
    # branches (some require --diagnostics.deployment-id, some don't have
    # --development-mode.enabled, etc.). Probe --help once and only pass flags
    # the binary recognises.
    local help; help="$("$launcher" server --help 2>&1 || true)"
    has_flag() { grep -q -- "--$1" <<<"$help"; }

    local -a args=( server )
    has_flag diagnostics.deployment-id && args+=( --diagnostics.deployment-id=bench )

    args+=(
        "--server.listen-address=0.0.0.0:${gport}"
        "--server.advertise-address=127.0.0.1:${gport}"
        --server.http.enabled=true
        "--server.http.listen-address=0.0.0.0:${hport}"
        "--server.http.advertise-address=http://127.0.0.1:${hport}"
        --server.admin.enabled=true
        "--storage.data-directory=${data_dir}"
        "--diagnostics.monitoring.port=${mport}"
        --diagnostics.monitoring.enabled=false
        --diagnostics.reporting.metrics=false
        --diagnostics.reporting.errors=false
        --server.encryption.enabled=false
    )

    # Admin transport: prefer UDS where supported; fall back to TCP port.
    if has_flag server.admin.socket-path; then
        args+=( "--server.admin.socket-path=${data_dir}/admin.sock" )
    else
        args+=( "--server.admin.port=${aport}" )
    fi

    has_flag development-mode.enabled && args+=( --development-mode.enabled=true )

    # Clustering flags only if the binary supports them. cluster-master may
    # not yet have the clustering surface — that mode will then behave like
    # a Core baseline with UDS admin.
    if has_flag server.clustering.id; then
        args+=(
            "--server.clustering.id=${n}"
            "--server.clustering.address=127.0.0.1:${cport}"
            "--storage.clustering-directory=${clustering_dir}"
            --server.clustering.encryption.enabled=false
        )
    fi

    log "Starting node $n ($server_type) -> $log_file"
    nohup "$launcher" "${args[@]}" > "$log_file" 2>&1 &
    disown

    wait_for_port "$gport" 60 || { tail -20 "$log_file" >&2; return 1; }
    if has_flag server.admin.socket-path; then
        wait_for_path "${data_dir}/admin.sock" 60 || return 1
    fi
}

# Start every node sequentially. Sequential keeps log timestamps clean and
# avoids file-handle races when bazel's mtime-based filewatch is involved.
for n in $(seq 1 "$nodes"); do
    start_node "$n"
    addrs+=("127.0.0.1:$(grpc_port "$n")")
done

# Multi-node: register peers via admin RPC, then wait for primary election.
if [ "$nodes" -gt 1 ]; then
    local_sock="$run_dir/1/server/data/admin.sock"

    # The admin socket file appears before the admin service is ready to
    # accept RPCs — the first call after socket creation returns
    # `[ADM2] Unavailable`. Poll a cheap command until it succeeds.
    log "Waiting for node 1 admin service to accept RPCs..."
    admin_deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$admin_deadline" ]; do
        if "$launcher" admin --socket-path="$local_sock" \
              --command 'servers status' >/dev/null 2>&1; then
            log "Admin service ready."
            break
        fi
        sleep 1
    done
    if ! "$launcher" admin --socket-path="$local_sock" \
            --command 'servers status' >/dev/null 2>&1; then
        error "Admin service on node 1 did not become ready within 60s"
        return 1
    fi

    log "Registering ${nodes} replicas with node 1..."
    # `servers status` (read) responds before `servers register` (write) does,
    # because writes need a raft commit. Retry on `[ADM2] Unavailable`.
    for n in $(seq 2 "$nodes"); do
        reg_deadline=$(( $(date +%s) + 30 ))
        while :; do
            out="$("$launcher" admin --socket-path="$local_sock" \
                    --command "servers register $n 127.0.0.1:$(clustering_port "$n")" 2>&1 || true)"
            if [[ "$out" != *ADM2* && "$out" != *Unavailable* ]]; then
                break
            fi
            if [ "$(date +%s)" -ge "$reg_deadline" ]; then
                error "register $n failed after 30s: $out"
                return 1
            fi
            sleep 1
        done
    done

    # Spin until `servers status` shows a primary. Quick poll because raft
    # election in a freshly-formed local cluster usually completes in <2s.
    log "Waiting for primary election..."
    local_deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$local_deadline" ]; do
        status="$("$launcher" admin --socket-path="$local_sock" \
                   --command 'servers status' 2>/dev/null || true)"
        if echo "$status" | grep -q "primary"; then
            log "Primary elected."
            break
        fi
        sleep 1
    done
    if ! echo "$status" | grep -q "primary"; then
        error "No primary elected within 60s. Last status:"
        echo "$status" >&2
        return 1
    fi
fi

# The gRPC port opens before the database engine is ready to serve queries
# (we hit `[CXN34] Server is not yet initialized` if we proceed too early).
# Probe via the driver since that's the actual client.
workspace="$(config_get workspace)"
venv="$workspace/venv"
addr_csv="$(IFS=','; echo "${addrs[*]}")"

if [ -x "$venv/bin/python" ]; then
    log "Verifying server accepts driver connections..."
    ready_deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$ready_deadline" ]; do
        if ADDR_CSV="$addr_csv" "$venv/bin/python" - <<'PYEOF' >/dev/null 2>&1
import os, sys
from typedb.driver import TypeDB, Credentials, DriverOptions, DriverTlsConfig
addrs = os.environ["ADDR_CSV"].split(",")
target = addrs[0] if len(addrs) == 1 else addrs
d = TypeDB.driver(target, Credentials("admin", "password"),
                  DriverOptions(DriverTlsConfig.disabled()))
d.close()
PYEOF
        then
            log "Server is ready."
            break
        fi
        sleep 1
    done
    # Re-run the probe once to make sure we exit non-zero on persistent failure.
    if ! ADDR_CSV="$addr_csv" "$venv/bin/python" - <<'PYEOF' >/dev/null 2>&1
import os, sys
from typedb.driver import TypeDB, Credentials, DriverOptions, DriverTlsConfig
addrs = os.environ["ADDR_CSV"].split(",")
target = addrs[0] if len(addrs) == 1 else addrs
d = TypeDB.driver(target, Credentials("admin", "password"),
                  DriverOptions(DriverTlsConfig.disabled()))
d.close()
PYEOF
    then
        error "Server did not become ready within 60s (driver probe)"
        return 1
    fi
fi

# Emit the addr list on stdout. Single source of truth for the tpcc config.
( IFS=','; echo "${addrs[*]}" )
