#!/usr/bin/env bash
# TPC-C benchmark orchestrator.
#
# Pipeline (defaults to ALL modes from config.yml):
#   1. setup        — clone repos at pinned commits, build server archives,
#                     create a python venv with the configured driver
#   2. smoke phase  — start each mode in turn, run a 15s tpcc burst, verify
#                     it survives load + execute. Any failure aborts.
#   3. bench phase  — for each mode, run the full tpcc load + duration_seconds
#                     execute. Result.json saved per mode.
#   4. compare      — markdown table comparing tpmc + latency across modes.
#
# Usage:
#   bench/run.sh                          # full pipeline, every mode
#   bench/run.sh --mode <name>            # single mode (setup+smoke+bench+compare-against-self)
#   bench/run.sh --smoke-only             # phases 1+2; useful on a new VM
#   bench/run.sh --skip-smoke             # phases 1+3+4 (use after smokes have already proven)
#   bench/run.sh --skip-setup             # phases 2+3+4 (reuse cached extracts)
#   bench/run.sh --config <path>          # use an alternate config file
#
# Required env (when cloning private repos on a fresh VM):
#   GITHUB_TOKEN     personal access token with repo read

set -euo pipefail

# --- Defaults / args ---------------------------------------------------------

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_CONFIG="$BENCH_DIR/config.yml"
SINGLE_MODE=""
DO_SETUP=1; DO_SMOKE=1; DO_BENCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --config) export BENCH_CONFIG="$2"; shift 2 ;;
        --mode) SINGLE_MODE="$2"; shift 2 ;;
        --smoke-only) DO_BENCH=0; shift ;;
        --skip-smoke) DO_SMOKE=0; shift ;;
        --skip-setup) DO_SETUP=0; shift ;;
        -h|--help)
            sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

source "$BENCH_DIR/lib/common.sh"

# --- Discover modes ----------------------------------------------------------

if [ -n "$SINGLE_MODE" ]; then
    if ! mode_get "$SINGLE_MODE" >/dev/null; then
        error "no such mode '$SINGLE_MODE' in $BENCH_CONFIG"
        exit 1
    fi
    selected_modes=("$SINGLE_MODE")
else
    selected_modes=()
    while IFS='|' read -r name _; do
        [ -n "$name" ] && selected_modes+=("$name")
    done < <(modes_list)
fi

# --- Workspace + run dir -----------------------------------------------------

workspace="$(config_get workspace)"
mkdir -p "$workspace/repos" "$workspace/extracts" "$workspace/venv"

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$BENCH_DIR/results/$run_id"
mkdir -p "$run_dir/smoke" "$run_dir/bench"
cp "$BENCH_CONFIG" "$run_dir/config-snapshot.yml"

step "Run id: $run_id"
log  "  results dir: $run_dir"
log  "  modes: ${selected_modes[*]}"
log  "  workspace: $workspace"

# Always tear down whatever we start, even on error / interrupt. Idempotent.
cleanup() { bash "$BENCH_DIR/lib/stop-server.sh" || true; }
trap cleanup EXIT INT TERM

# --- Phase 1: setup ----------------------------------------------------------

if [ "$DO_SETUP" -eq 1 ]; then
    step "Phase 1/4 — setup"

    # --- Driver venv ---------------------------------------------------------
    # Priority: local_wheel > local_repo > version (PyPI).
    # The venv gets recreated whenever the EFFECTIVE source signature changes
    # (we stamp a marker file inside it).
    venv="$workspace/venv"
    driver_wheel="$(config_get_optional driver.local_wheel)"
    driver_repo="$(config_get_optional driver.local_repo)"
    driver_version="$(config_get driver.version)"
    extra_index="$(config_get_optional driver.extra_index_url)"

    if [ -n "$driver_wheel" ]; then
        sig="local_wheel:$driver_wheel:$(stat -c %Y "$driver_wheel" 2>/dev/null || echo 0)"
    elif [ -n "$driver_repo" ]; then
        sig="local_repo:$driver_repo:$(git -C "$driver_repo" rev-parse HEAD 2>/dev/null || echo wip)"
    else
        sig="pypi:$driver_version:$extra_index"
    fi
    cur_sig=""
    [ -f "$venv/.bench-driver-sig" ] && cur_sig="$(cat "$venv/.bench-driver-sig")"

    if [ "$sig" != "$cur_sig" ]; then
        log "Driver source changed (was: ${cur_sig:-none}); rebuilding venv"
        rm -rf "$venv"
        python3 -m venv "$venv"
        "$venv/bin/pip" install --quiet --upgrade pip pyyaml

        if [ -n "$driver_wheel" ]; then
            log "  installing local wheel: $driver_wheel"
            "$venv/bin/pip" install --quiet "$driver_wheel"
        elif [ -n "$driver_repo" ]; then
            py_ver="$("$venv/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
            log "  building wheel from $driver_repo for Python $py_ver"
            wheel="$(bash "$BENCH_DIR/lib/build-driver.sh" "$driver_repo" "$py_ver")"
            "$venv/bin/pip" install --quiet "$wheel"
        else
            log "  pip install typedb-driver==$driver_version"
            if [ -n "$extra_index" ]; then
                "$venv/bin/pip" install --quiet "typedb-driver==$driver_version" --extra-index-url "$extra_index"
            else
                "$venv/bin/pip" install --quiet "typedb-driver==$driver_version"
            fi
        fi
        echo "$sig" > "$venv/.bench-driver-sig"
    else
        log "Driver venv up to date ($sig)"
    fi

    # --- Per-mode server extracts -------------------------------------------
    # Priority per mode: local_archive > local_repo > (repo_url + commit).
    for mode in "${selected_modes[@]}"; do
        line="$(mode_get "$mode")"
        IFS='|' read -r _name repo_url commit server_type _nodes <<<"$line"
        local_archive="$(mode_field "$mode" local_archive)"
        local_repo="$(mode_field "$mode" local_repo)"

        if [ -n "$local_archive" ]; then
            # Hash the archive's mtime+size into the cache key so picking up a
            # rebuilt archive at the same path re-extracts.
            sig="$(stat -c '%Y-%s' "$local_archive" 2>/dev/null || echo unknown)"
            extract_dir="$workspace/extracts/${mode}-archive-${sig}"
            log "Mode '$mode' from local_archive=$local_archive"
            bash "$BENCH_DIR/lib/build.sh" --archive "$local_archive" "$extract_dir"
        elif [ -n "$local_repo" ]; then
            # Use a HEAD-based key for committed state; uncommitted edits get
            # a fresh extract every run (--force) so we don't see stale builds.
            head="$(git -C "$local_repo" rev-parse HEAD 2>/dev/null || echo wip)"
            dirty=""
            if ! git -C "$local_repo" diff --quiet 2>/dev/null; then dirty="-dirty"; fi
            extract_dir="$workspace/extracts/${mode}-local-${head:0:12}${dirty}"
            log "Mode '$mode' from local_repo=$local_repo (HEAD=${head:0:12}${dirty})"
            if [ -n "$dirty" ]; then
                bash "$BENCH_DIR/lib/build.sh" --force --repo "$server_type" "$local_repo" "$extract_dir"
            else
                bash "$BENCH_DIR/lib/build.sh" --repo "$server_type" "$local_repo" "$extract_dir"
            fi
        else
            repo_dir="$workspace/repos/${mode}"
            extract_dir="$(mode_extract_dir "$mode" "$commit")"
            log "Mode '$mode' from remote ($server_type @ ${commit:0:12})"
            bash "$BENCH_DIR/lib/checkout.sh" "$repo_url" "$commit" "$repo_dir"
            bash "$BENCH_DIR/lib/build.sh" --repo "$server_type" "$repo_dir" "$extract_dir"
        fi

        # Remember where the launcher lives so start-server.sh can find it.
        # We re-derive the extract dir in start-server.sh today; cache it as
        # a sibling file so the local-source extract dirs stay discoverable.
        mkdir -p "$workspace/extracts"
        printf '%s\n' "$extract_dir" > "$workspace/extracts/${mode}.path"
    done
fi

# --- Phase 2: smoke ----------------------------------------------------------

run_phase() {
    local phase="$1"
    local subdir="$run_dir/$phase"
    local pass=()
    local fail=()
    for mode in "${selected_modes[@]}"; do
        step "$phase :: $mode"
        local mode_dir="$subdir/$mode"
        mkdir -p "$mode_dir"
        local mode_run="$workspace/run/${run_id}-${phase}-${mode}"
        rm -rf "$mode_run"; mkdir -p "$mode_run"
        local addrs
        if ! addrs="$(bash "$BENCH_DIR/lib/start-server.sh" "$mode" "$mode_run" 2>"$mode_dir/server-start.log")"; then
            error "[$phase/$mode] server failed to start; see $mode_dir/server-start.log"
            fail+=("$mode")
            bash "$BENCH_DIR/lib/stop-server.sh" >/dev/null 2>&1 || true
            continue
        fi
        if bash "$BENCH_DIR/lib/run-tpcc.sh" "$phase" "$mode" "$addrs" "$mode_dir"; then
            pass+=("$mode")
        else
            error "[$phase/$mode] tpcc failed; see $mode_dir/load.log / execute.log"
            fail+=("$mode")
        fi
        bash "$BENCH_DIR/lib/stop-server.sh" >/dev/null 2>&1 || true
    done
    log "$phase: passed=${#pass[@]}/${#selected_modes[@]} (${pass[*]:-none})"
    [ "${#fail[@]}" -eq 0 ] || { error "$phase: failed: ${fail[*]}"; return 1; }
}

if [ "$DO_SMOKE" -eq 1 ]; then
    step "Phase 2/4 — smoke (verify every mode boots + serves)"
    run_phase smoke || { error "Smoke phase failed — aborting before bench."; exit 1; }
fi

# --- Phase 3: bench ----------------------------------------------------------

if [ "$DO_BENCH" -eq 1 ]; then
    step "Phase 3/4 — bench (full duration per mode)"
    run_phase bench || warn "Some modes failed; comparison will still run for the ones that completed."
fi

# --- Phase 4: compare --------------------------------------------------------

if [ "$DO_BENCH" -eq 1 ]; then
    step "Phase 4/4 — comparison"
    "$workspace/venv/bin/python" "$BENCH_DIR/lib/compare.py" "$run_dir"
    log "Done. See $run_dir/comparison.md"
fi
