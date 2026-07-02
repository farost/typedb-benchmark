#!/usr/bin/env bash
# Render the verification report from a completed 30-min run. Reads STATE +
# FAILURES.log from each mode's client workdir and prints pass/fail.
set -euo pipefail

TOPOLOGY="${1:-$(dirname "$0")/../config/topology.toml}"
WORKDIR_ROOT="${2:-/var/lib/typedb-soak/client}"
DURATION_SECS="${3:-1800}"
MIN_COMMITS="${4:-60}"

SOAK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$SOAK_DIR" && cargo build --release --bin verify-report 2>/dev/null) || true

# The verify-report binary is generated on demand; if not yet built we fall
# back to a portable shell summary.
if [[ -x "$SOAK_DIR/target/release/verify-report" ]]; then
  exec "$SOAK_DIR/target/release/verify-report" \
    --config "$TOPOLOGY" --workdir "$WORKDIR_ROOT" \
    --duration-secs "$DURATION_SECS" --min-commits-per-min "$MIN_COMMITS"
fi

echo "verify-report binary not available; falling back to shell summary"
echo "================================================================="
shopt -s nullglob
overall_pass=1
for state in "$WORKDIR_ROOT"/mode_*/STATE; do
  mode="$(basename "$(dirname "$state")")"
  failures="$(dirname "$state")/FAILURES.log"
  count_mismatch=0
  if [[ -s "$failures" ]]; then
    count_mismatch=$(grep -c '"kind":"count_mismatch"' "$failures" || true)
  fi
  echo
  echo "--- $mode ---"
  cat "$state" | sed 's/^/  /'
  echo "  count_mismatch failures: $count_mismatch"
  if (( count_mismatch > 0 )); then
    overall_pass=0
  fi
done
echo
if (( overall_pass == 1 )); then
  echo "=== overall: PASS (no count_mismatch failures observed) ==="
else
  echo "=== overall: FAIL (count_mismatch failures present — see FAILURES.log) ==="
fi
