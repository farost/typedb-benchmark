#!/usr/bin/env bash
# Run a sequence of TPC-C benchmark "tests", each N reps with different params.
# Aggregates after each test → reports land under bench/reports/<test>/ so you
# can analyse a finished test while later tests are still running.
#
# Pre-reqs:
#   1. Run `bench/run.sh --smoke-only` once first to do setup + verify modes.
#   2. Have your `bench/config.yml` driver / fixtures / modes section ready.
#      Seed is honoured (recommended: keep one seed for the whole campaign so
#      every rep runs bit-identical workload and variance is pure measurement).
#
# Usage:
#   bench/campaign.sh                    # full campaign (test1, test2, test3) × 5 reps each
#   bench/campaign.sh --reps 3           # smaller campaign for a quick pass
#   bench/campaign.sh --only test1-c1-w4 # just one test
#
# Tests defined inline below. Edit TESTS=(...) to add/remove configurations.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_DIR/lib/common.sh"

REPS=5
ONLY=""
BASE_CONFIG="$BENCH_DIR/config.yml"

while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --config) BASE_CONFIG="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Tests: <name>:<W>:<SF>:<C>:<duration_seconds>
# Order matters: tests that share fixtures should be adjacent so cache hits.
# test1 (C=1) and test2 (C=4) both use W=4 SF=10 → share fixtures.
# test3 uses W=8 → needs its own fixtures.
TESTS=(
    "test1-c1-w4:4:10:1:300"
    "test2-c4-w4:4:10:4:300"
    "test3-c16-w8:8:10:16:300"
)

REPORTS_DIR="$BENCH_DIR/reports"
mkdir -p "$REPORTS_DIR"

workspace="$(config_get workspace)"
PY="$workspace/venv/bin/python"
if [ ! -x "$PY" ]; then
    error "venv at $workspace/venv missing — run bench/run.sh --smoke-only once first"
    exit 1
fi

for test_def in "${TESTS[@]}"; do
    IFS=: read -r tname tW tSF tC tDur <<<"$test_def"
    if [ -n "$ONLY" ] && [ "$ONLY" != "$tname" ]; then
        continue
    fi

    step "=== campaign test: $tname  (W=$tW SF=$tSF C=$tC dur=${tDur}s × $REPS reps) ==="

    # Generate a config override for this test (inherits driver, fixtures,
    # seed, modes, smoke from base).
    test_dir="$REPORTS_DIR/$tname"
    mkdir -p "$test_dir"
    test_config="$test_dir/config.yml"
    "$PY" - "$BASE_CONFIG" "$tW" "$tSF" "$tC" "$tDur" "$test_config" <<'PY'
import sys, yaml
base, W, SF, C, D, out = sys.argv[1:]
with open(base) as f:
    cfg = yaml.safe_load(f)
cfg.setdefault('benchmark', {})
cfg['benchmark']['warehouses'] = int(W)
cfg['benchmark']['scalefactor'] = int(SF)
cfg['benchmark']['clients'] = int(C)
cfg['benchmark']['duration_seconds'] = int(D)
with open(out, 'w') as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PY

    # Run the reps. Each invocation creates a new run dir under bench/results/.
    # We snapshot the dir listing before/after to capture this rep's run_id.
    run_ids=()
    for rep in $(seq 1 "$REPS"); do
        log ""
        log "--- $tname rep $rep / $REPS ---"
        before_listing="$(ls -1 "$BENCH_DIR/results/" 2>/dev/null || true)"
        # Don't abort campaign on a single failed rep — aggregator tolerates gaps.
        bash "$BENCH_DIR/run.sh" --config "$test_config" --skip-setup --skip-smoke || \
            warn "$tname rep $rep had failures; continuing"
        after_listing="$(ls -1 "$BENCH_DIR/results/" 2>/dev/null || true)"
        new_id="$(comm -13 <(printf '%s' "$before_listing" | sort) \
                              <(printf '%s' "$after_listing" | sort) | tail -1)"
        if [ -n "$new_id" ]; then
            run_ids+=("$new_id")
            log "  → run id: $new_id"
        else
            warn "  → no new run id detected after rep $rep"
        fi
    done

    # Aggregate the reps for this test → emits summary.md + runs.tsv.
    if [ "${#run_ids[@]}" -gt 0 ]; then
        log ""
        log "Aggregating $tname (${#run_ids[@]} runs)..."
        "$PY" "$BENCH_DIR/lib/aggregate.py" "$tname" "$test_dir" "${run_ids[@]}"
        log "Report ready: $test_dir/summary.md"
        log "TSV ready:    $test_dir/runs.tsv"
    else
        warn "$tname produced no runs; skipping aggregation"
    fi
done

step "Campaign complete. Reports under $REPORTS_DIR/"
