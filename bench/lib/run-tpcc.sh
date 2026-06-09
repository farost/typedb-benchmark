#!/usr/bin/env bash
# Run tpcc against an already-running mode.
#
# Usage: run-tpcc.sh [--load-only|--execute-only] <phase> <mode_name> <addrs> <out_dir>
#
#   --load-only:    only --reset --no-execute (populate). For the fixture flow.
#   --execute-only: only --no-load --duration. Use after a restored fixture.
#   (default):      both, the original flow.
#
#   phase:    "smoke" or "bench"
#   mode_name: from config.yml
#   addrs:    comma-separated host:port list (output of start-server.sh)
#   out_dir:  per-mode results dir; load.log, execute.log, result.json land here
#
# Reads tpcc params from config (smoke.* vs benchmark.*), invokes tpcc.py,
# parses the final summary into result.json.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

step_mode="both"
case "${1:-}" in
    --load-only)    step_mode="load";    shift ;;
    --execute-only) step_mode="execute"; shift ;;
esac

phase="$1"
mode_name="$2"
addrs="$3"
out_dir="$4"

case "$phase" in
    smoke|bench) ;;
    *) error "phase must be 'smoke' or 'bench'"; exit 1 ;;
esac

mkdir -p "$out_dir"

# Pull mode metadata so we know which tpcc edition string to write.
line="$(mode_get "$mode_name" || true)"
IFS='|' read -r _name _repo _commit _server_type nodes <<<"$line"

# 1 node → Core (single addr); >1 node → Cluster (multi addr).
# The driver accepts both via the same `addresses` arg; tpcc just needs to
# know the right `edition` string for its enum dispatch.
case "$nodes" in
    1) edition="Core" ;;
    *) edition="Cluster" ;;
esac

# Pull tpcc params for the requested phase. The phase name `bench` is the
# CLI/directory label; the config section for the full run is `benchmark`.
case "$phase" in
    bench)  section=benchmark ;;
    *)      section="$phase" ;;
esac
warehouses="$(config_get "${section}.warehouses")"
scalefactor="$(config_get "${section}.scalefactor")"
clients="$(config_get "${section}.clients")"
duration="$(config_get "${section}.duration_seconds")"

# Optional --seed pin: makes load data + query stream deterministic so two
# modes run bit-identical workloads. Empty → pytpcc picks a fresh seed.
seed="$(config_get_optional seed)"
seed_args=()
if [ -n "$seed" ]; then
    seed_args=(--seed="$seed")
fi

# Use a per-mode database name so reruns against the same server (smoke-then-
# bench is common) don't bleed into each other.
db_name="tpcc_${mode_name//-/_}_${phase}"

# tpcc.py reads a flat INI; this is the file consumed via `--config`.
cfg="$out_dir/tpcc.cfg"
cat > "$cfg" <<EOF
[typedb3]
database = $db_name
addr = $addrs
edition = $edition
user = admin
password = password
schema = tql3/tpcc-schema.tql
debug = 0
EOF

# venv with the configured driver lives in workspace/venv.
workspace="$(config_get workspace)"
venv="$workspace/venv"
PY="$venv/bin/python"
if [ ! -x "$PY" ]; then
    error "venv at $venv missing — did you run bench/run.sh's setup phase?"
    exit 1
fi

cd "$REPO_ROOT/tpcc/pytpcc"

if [ "$step_mode" != "execute" ]; then
    step "[$phase/$mode_name] LOAD  W=$warehouses SF=$scalefactor C=$clients seed=${seed:-rand} addr=$addrs"
    "$PY" tpcc.py --config="$cfg" \
        --warehouses="$warehouses" --scalefactor="$scalefactor" \
        --clients="$clients" --reset --no-execute "${seed_args[@]}" typedb3 \
        > "$out_dir/load.log" 2>&1
    log "  load done"
fi

if [ "$step_mode" != "load" ]; then
    step "[$phase/$mode_name] EXEC  duration=${duration}s seed=${seed:-rand}"
    "$PY" tpcc.py --config="$cfg" \
        --warehouses="$warehouses" --scalefactor="$scalefactor" \
        --clients="$clients" --no-load --duration="$duration" "${seed_args[@]}" typedb3 \
        > "$out_dir/execute.log" 2>&1
    log "  execute done"

    # tpcc.py prints a Python dict literal at the end of execute. Extract it into
    # JSON so downstream comparison code doesn't have to re-parse human output.
    "$PY" "$LIB_DIR/parse-result.py" "$out_dir/execute.log" > "$out_dir/result.json"
    log "  result.json written"
fi
