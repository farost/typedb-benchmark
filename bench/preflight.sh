#!/usr/bin/env bash
# Pre-flight verifier: assert every mode in bench/config.yml is wired up
# correctly before kicking off a long campaign.
#
# For each mode:
#   (1) parse the pinned commit from bench/config.yml
#   (2) assert the harness's cloned repo HEAD matches the pinned commit
#   (3) confirm the extracted binary dir exists and contains a launcher
#   (4) boot the launcher for ~12s in an isolated dir and classify the log
#       format (tracing / slog / mixed / silent) against expectations
#   (5) print the commit's subject line so the operator sees what they're
#       about to benchmark ("Use tracing logging" vs "Update Cargo files")
#
# Exit 0 only if every mode passes; exit 1 with a clear summary otherwise.
#
# Run after `bench/run.sh --smoke-only` (which builds + extracts each mode).
# `bench/campaign.sh` runs this automatically unless --skip-preflight is set.
#
# Usage:
#   bench/preflight.sh                  # use the default config
#   bench/preflight.sh --config <path>  # use an alternate config
#
# Format expectations per mode-name prefix:
#   cluster-feature-*  → tracing-only (post-migration; slog records bridged)
#   cluster-master-*   → mixed-or-slog (master is pre-migration; slog raft + tracing core)
#   typedb-core, typedb-* → tracing-only (typedb-core uses tracing exclusively)
#
# Format detection is based on log-line shape:
#   slog    : `Jun 11 20:05:01.140 DEBG ...`   (slog-term default fmt)
#   tracing : `2026-06-11T20:05:01.140Z INFO ...` (tracing-subscriber fmt)

set -uo pipefail   # NOT -e — run every mode's checks before reporting

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source common.sh for config_get / log / error / step helpers.
# shellcheck disable=SC1091
source "$BENCH_DIR/lib/common.sh"

# ---- args ---------------------------------------------------------------
CONFIG="$BENCH_DIR/config.yml"
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ -f "$CONFIG" ] || { error "config not found: $CONFIG"; exit 1; }
export BENCH_CONFIG="$CONFIG"

workspace="$(config_get workspace)"
venv_py="$workspace/venv/bin/python"
[ -x "$venv_py" ] || { error "venv python missing at $venv_py — run bench/run.sh --smoke-only first"; exit 1; }

# ---- parse modes --------------------------------------------------------
# Lines of `name<TAB>commit<TAB>server_type<TAB>nodes`. We use the same
# python+yaml that the rest of the harness uses, not awk on YAML.
MODES_TSV=$("$venv_py" - "$CONFIG" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
for m in cfg.get('modes', []):
    print(f"{m['name']}\t{m['commit']}\t{m['server_type']}\t{m['nodes']}")
PYEOF
)
[ -n "$MODES_TSV" ] || { error "no modes parsed from $CONFIG"; exit 1; }

step "Pre-flight: configured modes (from $CONFIG)"
echo "$MODES_TSV" | awk -F'\t' '{printf "  %-22s commit=%s  type=%s  nodes=%s\n", $1, substr($2,1,12), $3, $4}' >&2

# Per-mode log-format expectation. Conservative: only the cluster-feature
# branches must be strictly tracing-only (post-migration). master is mixed.
expected_format_for() {
    case "$1" in
        cluster-feature-*) echo "tracing-only" ;;
        cluster-master-*)  echo "any-output"    ;;  # mixed acceptable
        *)                 echo "tracing-only" ;;   # typedb-core et al.
    esac
}

# ---- helpers ------------------------------------------------------------

# Boot a binary briefly in an isolated dir, parse log format counts.
# Sets globals: OLD_COUNT NEW_COUNT BOOT_LOG (path)
probe_binary() {
    local binary="$1"
    local tag="$2"
    local dir="/tmp/preflight-$tag"
    BOOT_LOG="$dir/server.log"
    rm -rf "$dir"
    mkdir -p "$dir"

    # Single-node config is fine even for the cluster-3n binary — we're
    # only checking log format, not multi-node behavior.
    "$binary" server \
        --server.listen-address=127.0.0.1:19999 \
        --server.advertise-address=127.0.0.1:19999 \
        --server.http.enabled=false \
        --server.admin.enabled=true \
        --server.admin.socket-path="$dir/admin.sock" \
        --storage.data-directory="$dir/data" \
        --diagnostics.deployment-id=preflight \
        --diagnostics.monitoring.enabled=false \
        --diagnostics.reporting.metrics=false \
        --diagnostics.reporting.errors=false \
        --server.encryption.enabled=false \
        --server.clustering.id=1 \
        --server.clustering.address=127.0.0.1:19998 \
        --storage.clustering-directory="$dir/clustering" \
        --server.clustering.encryption.enabled=false \
        > "$BOOT_LOG" 2>&1 &
    local pid=$!
    sleep 12
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    OLD_COUNT=$(grep -cE '^[A-Z][a-z]{2} [0-9]+ [0-9]+:[0-9]+:[0-9]+\.[0-9]+ (DEBG|INFO|WARN|ERRO)' "$BOOT_LOG" 2>/dev/null || echo 0)
    NEW_COUNT=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$BOOT_LOG" 2>/dev/null || echo 0)
}

# Best-effort: launcher path. The harness writes per-mode extract paths to
# $workspace/extracts/<mode>.path; fall back to the {mode}-{shortsha} dir.
extract_launcher_for() {
    local name="$1" commit="$2"
    local path_file="$workspace/extracts/${name}.path"
    if [ -s "$path_file" ]; then
        echo "$(cat "$path_file")/typedb"
    else
        echo "$workspace/extracts/${name}-${commit:0:12}/typedb"
    fi
}

# Check one mode end-to-end. Appends report lines + sets MODE_OK.
check_mode() {
    local name="$1" commit="$2" server_type="$3"
    local short="${commit:0:12}"
    local repo_dir="$workspace/repos/$name"
    local launcher; launcher=$(extract_launcher_for "$name" "$commit")
    local expected; expected=$(expected_format_for "$name")
    local actual_short="—" subj="" format_observed="—" issues=()
    MODE_OK=1

    # (1) repo HEAD assertion
    if [ -d "$repo_dir/.git" ]; then
        local actual; actual=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
        actual_short="${actual:0:12}"
        if [ -n "$actual" ] && [ "$actual" != "$commit" ]; then
            issues+=("repo HEAD=$actual_short, expected=$short")
            MODE_OK=0
        fi
        subj=$(git -C "$repo_dir" log -1 --format='%s (authored %ad)' --date=short HEAD 2>/dev/null || echo "")
    else
        issues+=("no harness checkout at $repo_dir")
        MODE_OK=0
    fi

    # (2) launcher exists
    if [ ! -x "$launcher" ]; then
        issues+=("missing launcher at $launcher")
        MODE_OK=0
    fi

    # (3) boot probe + (4) format classification
    if [ -x "$launcher" ]; then
        pkill -KILL -f typedb_server_bin 2>/dev/null || true; sleep 1
        probe_binary "$launcher" "$name"

        if [ "${NEW_COUNT:-0}" -gt 0 ] && [ "${OLD_COUNT:-0}" -eq 0 ]; then
            format_observed="tracing-only (new=$NEW_COUNT old=0)"
        elif [ "${OLD_COUNT:-0}" -gt 0 ] && [ "${NEW_COUNT:-0}" -eq 0 ]; then
            format_observed="slog-only (old=$OLD_COUNT new=0)"
        elif [ "${OLD_COUNT:-0}" -gt 0 ] && [ "${NEW_COUNT:-0}" -gt 0 ]; then
            format_observed="mixed (old=$OLD_COUNT new=$NEW_COUNT)"
        else
            format_observed="SILENT (no parseable lines — boot may have failed)"
            issues+=("boot probe produced no log lines — check $BOOT_LOG")
            MODE_OK=0
        fi

        case "$expected" in
            tracing-only)
                if [ "${OLD_COUNT:-0}" -gt 0 ]; then
                    issues+=("expected tracing-only, found $OLD_COUNT old-slog lines (binary likely pre-migration)")
                    MODE_OK=0
                fi
                if [ "${NEW_COUNT:-0}" -eq 0 ]; then
                    issues+=("expected tracing output, but got 0 tracing lines")
                    MODE_OK=0
                fi ;;
            any-output) : ;;  # already handled by silent check above
        esac
    fi

    # ---- emit report row ----
    local icon; if [ "$MODE_OK" -eq 1 ]; then icon="OK "; else icon="FAIL"; fi
    MODE_REPORT_LINES+=("$(printf '  [%s] %-22s  pinned=%-12s  HEAD=%-12s  log=%s' \
        "$icon" "$name" "$short" "$actual_short" "$format_observed")")
    if [ -n "$subj" ]; then
        MODE_REPORT_LINES+=("         commit: $subj")
    fi
    for i in "${issues[@]}"; do MODE_REPORT_LINES+=("         ! $i"); done
    if [ "$MODE_OK" -eq 0 ] && [ -f "${BOOT_LOG:-}" ]; then
        MODE_REPORT_LINES+=("         boot-log tail ($BOOT_LOG):")
        while IFS= read -r line; do
            MODE_REPORT_LINES+=("           | $line")
        done < <(tail -3 "$BOOT_LOG")
    fi
}

# ---- main loop ----------------------------------------------------------
MODE_REPORT_LINES=()
FAIL_COUNT=0
TOTAL_COUNT=0

step "Per-mode boot probes (~12s each)"
while IFS=$'\t' read -r name commit server_type nodes; do
    [ -n "$name" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    log "→ $name ($server_type, $nodes node$([ "$nodes" -gt 1 ] && echo s))"
    check_mode "$name" "$commit" "$server_type"
    if [ "$MODE_OK" -eq 0 ]; then FAIL_COUNT=$((FAIL_COUNT + 1)); fi
done <<< "$MODES_TSV"

step "Pre-flight summary  ($((TOTAL_COUNT - FAIL_COUNT))/$TOTAL_COUNT passed)"
for line in "${MODE_REPORT_LINES[@]}"; do echo "$line" >&2; done
echo >&2

if [ "$FAIL_COUNT" -eq 0 ]; then
    log "ALL MODES PASS pre-flight."
    exit 0
else
    error "$FAIL_COUNT mode(s) failed pre-flight — DO NOT launch the campaign"
    error "  resolve the issues above (likely wrong commit, missing binary, or stale extract)"
    exit 1
fi
