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

    local gport hport mport cport
    gport="$(grpc_port "$n")"
    hport="$(http_port "$n")"
    mport="$(monitoring_port "$n")"
    cport="$(clustering_port "$n")"

    local -a args=(
        server
        --diagnostics.deployment-id=bench
        "--server.listen-address=0.0.0.0:${gport}"
        "--server.advertise-address=127.0.0.1:${gport}"
        --server.http.enabled=true
        "--server.http.listen-address=0.0.0.0:${hport}"
        "--server.http.advertise-address=http://127.0.0.1:${hport}"
        --server.admin.enabled=true
        "--server.admin.socket-path=${data_dir}/admin.sock"
        "--storage.data-directory=${data_dir}"
        "--diagnostics.monitoring.port=${mport}"
        --diagnostics.monitoring.enabled=false
        --diagnostics.reporting.metrics=false
        --diagnostics.reporting.errors=false
        --development-mode.enabled=true
        --server.encryption.enabled=false
    )

    if [ "$server_type" = "typedb-cluster" ]; then
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
    if [ "$server_type" = "typedb-cluster" ]; then
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
    log "Registering ${nodes} replicas with node 1..."
    local_sock="$run_dir/1/server/data/admin.sock"
    for n in $(seq 2 "$nodes"); do
        "$launcher" admin --socket-path="$local_sock" \
            --command "servers register $n 127.0.0.1:$(clustering_port "$n")" >/dev/null
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

# Emit the addr list on stdout. Single source of truth for the tpcc config.
( IFS=','; echo "${addrs[*]}" )
