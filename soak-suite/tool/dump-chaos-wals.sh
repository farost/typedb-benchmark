#!/usr/bin/env bash
# Dump the pulled mode_3n_chaos WALs with typedb's read_wal, then run the
# skip/collision analysis (analyze-chaos-wals.py) on the dumps.
#
# Usage:
#   dump-chaos-wals.sh <collected-dir> [--read-wal PATH] [--db soak_3n_chaos] [--no-analyze]
#
# <collected-dir> is the output directory of collect-chaos-wals.sh
# (contains soak-m1/node1/data/<db>/wal, soak-m2/node2/..., soak-m3/node3/...).
#
# read_wal resolution order: --read-wal PATH, $READ_WAL, `read_wal` on $PATH.
# Build it with:  cd <typedb-repo> && cargo build --release -p database-tools
#                 -> <typedb-repo>/target/release/read_wal
#
# Writes <collected-dir>/m1.waldump, m2.waldump, m3.waldump (one per machine)
# and prints the analysis verdict.

set -euo pipefail

COLLECTED=""
READ_WAL_BIN="${READ_WAL:-}"
DB=soak_3n_chaos
ANALYZE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --read-wal) READ_WAL_BIN="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --no-analyze) ANALYZE=0; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *)
      if [[ -z "$COLLECTED" ]]; then COLLECTED="$1"; shift
      else echo "unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

[[ -n "$COLLECTED" && -d "$COLLECTED" ]] || { echo "usage: $0 <collected-dir> [--read-wal PATH]" >&2; exit 2; }

if [[ -z "$READ_WAL_BIN" ]]; then
  READ_WAL_BIN="$(command -v read_wal || true)"
fi
if [[ -z "$READ_WAL_BIN" || ! -x "$READ_WAL_BIN" ]]; then
  echo "read_wal binary not found. Build it in the typedb repo:" >&2
  echo "    cargo build --release -p database-tools" >&2
  echo "then pass it via --read-wal <typedb-repo>/target/release/read_wal (or export READ_WAL=...)" >&2
  exit 2
fi

log() { echo "[$(date -u +%FT%TZ)] $*"; }

DUMPS=()
for machine_dir in "$COLLECTED"/soak-m*/; do
  machine="$(basename "$machine_dir")"          # soak-m1
  short="${machine#soak-}"                      # m1
  db_dir="$(find "$machine_dir" -maxdepth 3 -type d -path "*/data/$DB" | head -1)"
  if [[ -z "$db_dir" ]]; then
    log "$machine: no data/$DB directory found — skipping"
    continue
  fi
  if [[ ! -d "$db_dir/wal" ]]; then
    log "$machine: $db_dir has no wal/ subdirectory — skipping"
    continue
  fi
  dump="$COLLECTED/$short.waldump"
  log "$machine: dumping $db_dir -> $dump"
  "$READ_WAL_BIN" "$db_dir" print-range 0 > "$dump"
  log "$machine: $(grep -c '^commit data @' "$dump" || true) commit records, $(wc -l < "$dump") lines"
  DUMPS+=("$dump")
done

if [[ ${#DUMPS[@]} -lt 2 ]]; then
  log "fewer than 2 dumps produced — nothing to compare"
  exit 1
fi

if [[ "$ANALYZE" == 1 ]]; then
  log "running analysis..."
  echo
  python3 "$(dirname "$0")/analyze-chaos-wals.py" "${DUMPS[@]}"
else
  log "dumps ready: ${DUMPS[*]}"
  log "analyze with: python3 $(dirname "$0")/analyze-chaos-wals.py ${DUMPS[*]}"
fi
