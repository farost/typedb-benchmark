#!/usr/bin/env bash
# One-shot runner: cleans up prior debug state, wipes bazel caches so the
# freshly-patched MODULE.bazel takes effect, and runs setup + campaign.
#
# Usage:
#   bench/run-benches.sh                   # setup + campaign, 3 reps, all modes
#   REPS=2 bench/run-benches.sh            # smaller campaign
#   ONLY_MODE=cluster-master-1n bench/run-benches.sh   # single-mode probe
#
# Logs land at /tmp/bench-setup.log and /tmp/bench-campaign.log so you can
# tail them from another shell.

set -euo pipefail

REPS="${REPS:-3}"
ONLY_MODE="${ONLY_MODE:-}"
WORKSPACE="${HOME}/typedb-bench-work"
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$BENCH_DIR/.." && pwd)"

echo "==> [$(date -u +%FT%TZ)] run-benches: reps=$REPS mode='${ONLY_MODE:-<all>}' repo=$REPO_DIR"

# ---------------------------------------------------------------------------
# 1. Undo any leftover .bazelrc overrides from prior debug sessions.
# ---------------------------------------------------------------------------
if grep -q 'incompatible_autoload_externally' ~/.bazelrc 2>/dev/null; then
    sed -i.bak '/incompatible_autoload_externally/d' ~/.bazelrc
    echo "  removed 'incompatible_autoload_externally' from ~/.bazelrc (backup at ~/.bazelrc.bak)"
fi

# ---------------------------------------------------------------------------
# 2. Wipe bazel state and prior extracts. checkout.sh will re-patch any
#    already-cloned repo's MODULE.bazel on next setup pass (idempotent).
# ---------------------------------------------------------------------------
CACHE_DIR="$HOME/.cache/bazel/_bazel_$USER"
if [ -d "$CACHE_DIR" ]; then
    echo "  wiping $CACHE_DIR"
    rm -rf "$CACHE_DIR"
fi
if [ -d "$WORKSPACE/extracts" ]; then
    echo "  wiping $WORKSPACE/extracts"
    rm -rf "$WORKSPACE/extracts"
fi

# ---------------------------------------------------------------------------
# 3. Also patch any repo that was ALREADY cloned by a previous attempt. The
#    checkout.sh path only appends on fresh clones or when it fetches a new
#    commit, so existing checkouts at their current commit may not go through
#    the append path.
# ---------------------------------------------------------------------------
BENCH_PIN_MARKER="# ---- bench harness: single_version_override pins ----"
if compgen -G "$WORKSPACE/repos/*/MODULE.bazel" > /dev/null 2>&1; then
    for f in "$WORKSPACE"/repos/*/MODULE.bazel; do
        if ! grep -qF "$BENCH_PIN_MARKER" "$f"; then
            echo "  appending pins to already-cloned $f"
            cat >> "$f" <<PINS

$BENCH_PIN_MARKER
single_version_override(module_name = "protobuf", version = "29.3")
single_version_override(module_name = "rules_java", version = "8.6.2")
single_version_override(module_name = "platforms", version = "0.0.10")
single_version_override(module_name = "bazel_skylib", version = "1.7.1")
single_version_override(module_name = "rules_jvm_external", version = "6.6")
single_version_override(module_name = "rules_python", version = "1.0.0")
single_version_override(module_name = "rules_kotlin", version = "2.0.0")
PINS
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. Run setup, then campaign. Setup logs to /tmp/bench-setup.log;
#    campaign to /tmp/bench-campaign.log.
# ---------------------------------------------------------------------------
cd "$REPO_DIR"

setup_args=(--smoke-only)
[ -n "$ONLY_MODE" ] && setup_args+=(--mode "$ONLY_MODE")

echo
echo "==> [$(date -u +%FT%TZ)] setup: bash bench/run.sh ${setup_args[*]}"
bash bench/run.sh "${setup_args[@]}" 2>&1 | tee /tmp/bench-setup.log

# If the user asked to probe a single mode, skip the campaign — the smoke
# outcome is the answer they wanted.
if [ -n "$ONLY_MODE" ]; then
    echo
    echo "==> single-mode probe done. Review /tmp/bench-setup.log"
    exit 0
fi

echo
echo "==> [$(date -u +%FT%TZ)] campaign: bash bench/campaign.sh --skip-preflight --reps $REPS"
bash bench/campaign.sh --skip-preflight --reps "$REPS" 2>&1 | tee /tmp/bench-campaign.log

echo
echo "==> [$(date -u +%FT%TZ)] done"
echo "  reports at: $REPO_DIR/bench/reports/"
echo "  setup log:  /tmp/bench-setup.log"
echo "  bench log:  /tmp/bench-campaign.log"
