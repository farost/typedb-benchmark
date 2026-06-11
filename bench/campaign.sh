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
#   bench/campaign.sh                                # full campaign (test1, test2, test3) × 5 reps each
#   bench/campaign.sh --reps 3                       # smaller campaign for a quick pass
#   bench/campaign.sh --only test1-c1-w4             # just one test
#   bench/campaign.sh --mode cluster-feature-3n \    # top up a single mode (e.g. when a flaky
#                    --only test3-c16-w8 --reps 3    # mode failed reps in a prior campaign)
#
# Tests defined inline below. Edit TESTS=(...) to add/remove configurations.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_DIR/lib/common.sh"

REPS=5
ONLY=""
ONLY_MODE=""
BASE_CONFIG="$BENCH_DIR/config.yml"

while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --mode) ONLY_MODE="$2"; shift 2 ;;
        --config) BASE_CONFIG="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# config_get reads $BENCH_CONFIG. If the user passed --config, point at that
# instead of the default — otherwise `workspace` etc. resolve from the wrong
# file (silent misconfiguration; the error symptom shows up far away as a
# missing venv).
export BENCH_CONFIG="$BASE_CONFIG"

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

# Validate base config exists before doing anything destructive.
if [ ! -f "$BASE_CONFIG" ]; then
    error "base config not found: $BASE_CONFIG"
    exit 1
fi

# Validate --mode early — typos here would silently turn the campaign into
# a no-op (run.sh would error per rep, the aggregate would have zero runs).
if [ -n "$ONLY_MODE" ]; then
    if ! mode_get "$ONLY_MODE" >/dev/null 2>&1; then
        error "unknown --mode '$ONLY_MODE' (not in $BASE_CONFIG)"
        exit 1
    fi
fi

# Validate at least one test is selected (catches typos in --only).
selected_count=0
for test_def in "${TESTS[@]}"; do
    IFS=: read -r tname _ <<<"$test_def"
    if [ -z "$ONLY" ] || [ "$ONLY" = "$tname" ]; then
        selected_count=$((selected_count + 1))
    fi
done
if [ "$selected_count" -eq 0 ]; then
    error "no test matched --only='$ONLY' (available: $(printf '%s ' "${TESTS[@]%%:*}"))"
    exit 1
fi

# Per-test summary tracked across the whole campaign — printed at the end.
declare -a CAMPAIGN_SUMMARY=()

# Drop campaign with a clear final summary even on Ctrl-C.
print_final_summary() {
    echo >&2
    step "Campaign summary"
    if [ "${#CAMPAIGN_SUMMARY[@]}" -eq 0 ]; then
        warn "no tests completed"
    else
        for line in "${CAMPAIGN_SUMMARY[@]}"; do echo "  $line" >&2; done
    fi
    log "Reports root: $REPORTS_DIR/"
}
trap print_final_summary EXIT

for test_def in "${TESTS[@]}"; do
    IFS=: read -r tname tW tSF tC tDur <<<"$test_def"
    if [ -n "$ONLY" ] && [ "$ONLY" != "$tname" ]; then
        continue
    fi

    step "=== campaign test: $tname  (W=$tW SF=$tSF C=$tC dur=${tDur}s × $REPS reps) ==="

    # Generate a config override for this test (inherits driver, fixtures,
    # seed, modes, smoke from base). Crashes hard with a clear message if
    # the base config can't be parsed — that's a config bug worth seeing.
    test_dir="$REPORTS_DIR/$tname"
    mkdir -p "$test_dir"
    test_config="$test_dir/config.yml"
    if ! "$PY" - "$BASE_CONFIG" "$tW" "$tSF" "$tC" "$tDur" "$test_config" <<'PY'
import sys, yaml
try:
    base, W, SF, C, D, out = sys.argv[1:]
    with open(base) as f:
        cfg = yaml.safe_load(f)
    if not isinstance(cfg, dict):
        sys.stderr.write(f"config_override: {base} did not parse as a mapping\n")
        sys.exit(1)
    cfg.setdefault('benchmark', {})
    cfg['benchmark']['warehouses'] = int(W)
    cfg['benchmark']['scalefactor'] = int(SF)
    cfg['benchmark']['clients'] = int(C)
    cfg['benchmark']['duration_seconds'] = int(D)
    with open(out, 'w') as f:
        yaml.safe_dump(cfg, f, sort_keys=False)
except Exception as e:
    sys.stderr.write(f"config_override failed: {type(e).__name__}: {e}\n")
    sys.exit(1)
PY
    then
        error "config generation failed for $tname; skipping test"
        CAMPAIGN_SUMMARY+=("✗ $tname  — config generation failed")
        continue
    fi

    # Run the reps. Each invocation creates a new run dir under bench/results/.
    # We snapshot the dir listing before/after to capture this rep's run_id.
    run_ids=()
    fail_count=0
    for rep in $(seq 1 "$REPS"); do
        log ""
        log "--- $tname rep $rep / $REPS ---"
        before_listing="$(ls -1 "$BENCH_DIR/results/" 2>/dev/null || true)"
        # Don't abort campaign on a single failed rep — aggregator tolerates gaps.
        rep_rc=0
        run_args=(--config "$test_config" --skip-setup --skip-smoke)
        # --mode forwards to run.sh so the user can top up a single mode
        # (typically cluster-feature-3n) without re-running the others.
        # NB: when --mode is set, this rep's run_id will only contain that
        # mode's result.json; aggregate the new run_ids together with the
        # prior all-mode run_ids manually via `bench/lib/aggregate.py`.
        if [ -n "$ONLY_MODE" ]; then
            run_args+=(--mode "$ONLY_MODE")
        fi
        bash "$BENCH_DIR/run.sh" "${run_args[@]}" || rep_rc=$?
        if [ "$rep_rc" -ne 0 ]; then
            warn "$tname rep $rep exited rc=$rep_rc; continuing"
            fail_count=$((fail_count + 1))
        fi
        after_listing="$(ls -1 "$BENCH_DIR/results/" 2>/dev/null || true)"
        new_id="$(comm -13 <(printf '%s' "$before_listing" | sort) \
                              <(printf '%s' "$after_listing" | sort) 2>/dev/null | tail -1)"
        if [ -n "$new_id" ]; then
            run_ids+=("$new_id")
            log "  → run id: $new_id"
        else
            warn "  → no new run id detected after rep $rep (rc=$rep_rc)"
        fi
    done

    # Aggregate the reps for this test → emits summary.md + runs.tsv.
    # Aggregator failure does NOT abort campaign; later tests keep running.
    # When --mode is set we deliberately skip aggregation: these run_ids only
    # contain that one mode, and re-aggregating with just them would overwrite
    # the existing all-mode summary. The user must run aggregate.py manually
    # with the union of these new run_ids and the prior all-mode run_ids.
    agg_status="skipped"
    if [ -n "$ONLY_MODE" ]; then
        log ""
        warn "Skipping aggregation (--mode $ONLY_MODE): partial run_ids would clobber prior all-mode summary."
        warn "New run_ids saved to $test_dir/run_ids.new — combine with existing $test_dir/runs.tsv run_ids and run:"
        warn "    bench/lib/aggregate.py $tname $test_dir <id1> <id2> ..."
        printf '%s\n' "${run_ids[@]}" > "$test_dir/run_ids.new"
        agg_status="mode-only"
    elif [ "${#run_ids[@]}" -gt 0 ]; then
        log ""
        log "Aggregating $tname (${#run_ids[@]} runs)..."
        if "$PY" "$BENCH_DIR/lib/aggregate.py" "$tname" "$test_dir" "${run_ids[@]}"; then
            log "Report ready: $test_dir/summary.md"
            log "TSV ready:    $test_dir/runs.tsv"
            agg_status="ok"
        else
            error "aggregator failed for $tname (run_ids preserved at $test_dir for manual re-aggregation)"
            # Save the run_ids so the user can re-aggregate manually.
            printf '%s\n' "${run_ids[@]}" > "$test_dir/run_ids.txt"
            agg_status="agg-failed"
        fi
    else
        warn "$tname produced no runs; skipping aggregation"
        agg_status="no-runs"
    fi

    case "$agg_status" in
        ok)          status_icon="✓" ;;
        mode-only)   status_icon="+" ;;
        agg-failed)  status_icon="!" ;;
        no-runs|skipped) status_icon="✗" ;;
    esac
    CAMPAIGN_SUMMARY+=("$status_icon $tname  ${#run_ids[@]}/$REPS reps produced runs, $fail_count rc-failures, aggregate=$agg_status")
done
