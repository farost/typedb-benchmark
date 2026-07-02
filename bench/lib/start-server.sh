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

# Detect a fixture-restored run: if node 1's data dir is already populated,
# the cluster topology is encoded in its raft log and we should skip the
# `servers register` dance — the nodes will self-form from their persistent
# state when started.
restored_from_fixture=false
if [ -d "$run_dir/1/server/data" ] && [ -n "$(ls -A "$run_dir/1/server/data" 2>/dev/null)" ]; then
    restored_from_fixture=true
    log "Detected pre-populated data — treating as fixture restore (skipping peer registration)"
fi

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

    # `--development-mode.enabled=true` disables telemetry/reporting side-channels
    # so the benchmark isn't measuring background Sentry / metrics work.
    #
    # The flag is `hide = true` in clap (server/parameters/cli.rs:119), so
    # `has_flag` (which greps --help output) returns false even when the flag
    # IS accepted. We therefore pass it unconditionally for all cluster/core
    # server binaries. Two possible states in the underlying server:
    #   - `--features published` build (bazel opt release): CLI value wins.
    #   - non-`published` build: `development_mode.enabled |= true` — always on.
    # Either way, passing the flag is safe and produces the intended behaviour.
    args+=( --development-mode.enabled=true )
    diag_state="reporting=off + development-mode=on (unconditional)"

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
        # Newer cluster-feature-branch (typedb-cluster 19bb35d9+) requires
        # `--server.clustering.init=true` on node 1 to allow initial cluster
        # bootstrap. The flag is idempotent on subsequent boots (acts only
        # when the storage dir is pre-bootstrap) but only pass it on node 1
        # per its docstring. Older builds don't have the flag — guard with
        # has_flag so we don't break them.
        if [ "$n" = "1" ] && has_flag server.clustering.init; then
            args+=( --server.clustering.init=true )
        fi
    fi

    log "Starting node $n ($server_type) -> $log_file"
    log "  diagnostics: $diag_state"
    # Echo the exact launcher invocation so users can verify what's running.
    log "  + $launcher ${args[*]}"
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
    admin_deadline=$(( $(date +%s) + 120 ))
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
        error "Admin service on node 1 did not become ready within 120s"
        exit 1
    fi

    if [ "$restored_from_fixture" = "true" ]; then
        log "Skipping peer registration (restored from fixture — raft state preserved)"
    else
        log "Registering ${nodes} replicas with node 1..."
        # `servers status` (read) responds before `servers register` (write) does,
        # because writes need a raft commit. Retry on `[ADM2] Unavailable`.
        for n in $(seq 2 "$nodes"); do
            reg_deadline=$(( $(date +%s) + 60 ))
            while :; do
                out="$("$launcher" admin --socket-path="$local_sock" \
                        --command "servers register $n 127.0.0.1:$(clustering_port "$n")" 2>&1 || true)"
                if [[ "$out" != *ADM2* && "$out" != *Unavailable* ]]; then
                    break
                fi
                if [ "$(date +%s)" -ge "$reg_deadline" ]; then
                    error "register $n failed after 60s: $out"
                    exit 1
                fi
                sleep 1
            done
        done
    fi

    # Spin until `servers status` shows a primary. Election in a freshly-formed
    # local cluster usually completes in <2s, but for a 3n fixture-restored
    # cluster the primary can take longer to stabilise (raft log replay must
    # finish before a candidate gets enough votes). 180s gives W=8 fixtures
    # headroom without masking genuine failures.
    log "Waiting for primary election..."
    local_deadline=$(( $(date +%s) + 180 ))
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
        error "No primary elected within 180s. Last status:"
        echo "$status" >&2
        exit 1
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
    # The probe code USED to be a heredoc-inside-command-substitution-inside-if,
    # which silently failed in production: the loop ran the full deadline with
    # neither successes nor failure output (consecutive never incremented and
    # last_err stayed empty). Rewriting as: write the probe to a temp .py once,
    # then run it via `timeout` in the loop. No heredoc inside the if-condition.
    probe_py="$(mktemp)"
    cat > "$probe_py" <<'PYEOF'
import os
from typedb.driver import TypeDB, Credentials, DriverOptions, DriverTlsConfig
addrs = os.environ["ADDR_CSV"].split(",")
target = addrs[0] if len(addrs) == 1 else addrs
d = TypeDB.driver(target, Credentials("admin", "password"),
                  DriverOptions(DriverTlsConfig.disabled()))
d.databases.contains("__healthcheck__")
d.close()
PYEOF

    # Require TWO consecutive successful probes — guards against a momentary
    # primary changeover during raft heartbeat reshuffle, which can happen
    # in the first seconds after restoring a 3-node cluster from fixture.
    # 240s: a W=8 fixture-restored 3n cluster spends most of its boot inside
    # raft log replay; the gRPC port opens early but `databases.contains`
    # blocks until the apply queue catches up. Observed flake at 120s on
    # test3-c16-w8; quadrupling absorbs the long tail without masking
    # genuine startup failures (the 2-consecutive gate would still catch them).
    ready_deadline=$(( $(date +%s) + 240 ))
    consecutive=0
    last_err=""
    while [ "$(date +%s)" -lt "$ready_deadline" ]; do
        probe_err="$(mktemp)"
        if ADDR_CSV="$addr_csv" timeout 10 "$venv/bin/python" "$probe_py" >/dev/null 2>"$probe_err"; then
            consecutive=$((consecutive + 1))
            if [ "$consecutive" -ge 2 ]; then
                log "Server is ready (2 consecutive successful probes)."
                ready_ok=1
                rm -f "$probe_err"
                break
            fi
        else
            consecutive=0
            last_err="$(cat "$probe_err")"
        fi
        rm -f "$probe_err"
        sleep 1
    done
    rm -f "$probe_py"
    if [ "${ready_ok:-0}" != "1" ]; then
        error "Server did not stabilise within 240s (driver probe). Last error:"
        echo "${last_err:-<no probe ever produced stderr — check ${venv}/bin/python and driver install>}" >&2
        exit 1
    fi
fi

# Emit the addr list on stdout. Single source of truth for the tpcc config.
( IFS=','; echo "${addrs[*]}" )
