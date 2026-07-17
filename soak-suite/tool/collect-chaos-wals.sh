#!/usr/bin/env bash
# Pull the mode_3n_chaos database WALs from every soak node into a local tarball,
# for offline analysis with typedb's read_wal tool.
#
# Copies (read-only) each node's data/<db>/wal directory. Never runs any typedb
# tool on the servers: read_wal's WAL::load opens a writer and can truncate a
# torn tail, so tools are only ever pointed at these pulled copies.
#
# The chaos servers may be crash-looping or serving; copying is safe either way
# (the WAL is append-only; a tail caught mid-write is trimmed by read_wal on the
# copy, not on the server).
#
# Usage:
#   PROJECT=<gcp-project> ZONE=<gcp-zone> tool/collect-chaos-wals.sh \
#       [--out DIR] [--workdir /var/lib/typedb-soak] [--mode mode_3n_chaos] \
#       [--db soak_3n_chaos] [--machines "soak-m1 soak-m2 soak-m3"]
#
# Output layout (default OUT is /tmp/soak-chaos-wals-<UTC timestamp>/):
#   <out>/
#   ├── SUMMARY.txt
#   ├── soak-m1/
#   │   ├── node1/data/soak_3n_chaos/wal/wal-...   the WAL files, verbatim
#   │   ├── node1/data/_system/wal/wal-...          system-db WAL (small, for completeness)
#   │   └── wal-inventory.txt                       sizes + mtimes + sha256 at capture time
#   ├── soak-m2/ ...  (node2)
#   └── soak-m3/ ...  (node3)
#   ...and <out>.tar.gz alongside for easy transfer.

set -euo pipefail

: "${PROJECT:?set PROJECT to your GCP project id (env var)}"
: "${ZONE:?set ZONE to your GCP zone (env var)}"

WORKDIR_REMOTE=/var/lib/typedb-soak
MACHINES="soak-m1 soak-m2 soak-m3"
MODE=mode_3n_chaos
DB=soak_3n_chaos
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --workdir) WORKDIR_REMOTE="$2"; shift 2 ;;
    --machines) MACHINES="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT" ]]; then
  OUT="/tmp/soak-chaos-wals-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT"
SUMMARY="$OUT/SUMMARY.txt"
: > "$SUMMARY"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SUMMARY"; }

log "workdir=$WORKDIR_REMOTE machines=[$MACHINES] mode=$MODE db=$DB out=$OUT"
log

# The remote script template is read into a variable via a plain heredoc: heredocs
# inside $(...) are re-parsed at expansion time by bash 3.2 (macOS) and choke on
# single quotes, so no command substitution is involved here. read -d '' returns
# non-zero at EOF, hence the guard.
read -r -d '' REMOTE_TEMPLATE <<'REMOTE' || true
set -euo pipefail
WORKDIR="__WORKDIR_PLACEHOLDER__"
MODE="__MODE_PLACEHOLDER__"
DB="__DB_PLACEHOLDER__"
STAGE="$(mktemp -d /tmp/soak-wal-stage.XXXXXX)"
trap "rm -rf $STAGE" EXIT

: > "$STAGE/wal-inventory.txt"

# Each machine soak-mK hosts node K of every mode: M<K>/<mode>/node<K>/.
# Multiple server processes run per machine (one per mode) - we only touch the
# requested mode's node directory, and only read from it.
for node_dir in "$WORKDIR"/M*/"$MODE"/node*; do
  [ -d "$node_dir" ] || continue
  node="$(basename "$node_dir")"
  for db_name in "$DB" _system; do
    wal_dir="$node_dir/data/$db_name/wal"
    if [ ! -d "$wal_dir" ]; then
      echo "MISSING $wal_dir" >> "$STAGE/wal-inventory.txt"
      continue
    fi
    dest="$STAGE/$node/data/$db_name/wal"
    mkdir -p "$dest"
    cp -p "$wal_dir"/wal-* "$dest"/ 2>/dev/null || echo "EMPTY $wal_dir" >> "$STAGE/wal-inventory.txt"
    {
      echo "==== $wal_dir ===="
      ls -la --time-style=full-iso "$wal_dir"
      sha256sum "$wal_dir"/wal-* 2>/dev/null || true
      echo
    } >> "$STAGE/wal-inventory.txt"
  done

  # The raft log (clustering/wal) is a typedb WAL of raft entries: index, term, payload, and
  # the per-propose req_id in the entry context. It discriminates duplicate-proposal vectors.
  raft_wal_dir="$node_dir/clustering/wal"
  if [ -d "$raft_wal_dir" ]; then
    dest="$STAGE/$node/clustering/wal"
    mkdir -p "$dest"
    cp -p "$raft_wal_dir"/wal-* "$dest"/ 2>/dev/null || echo "EMPTY $raft_wal_dir" >> "$STAGE/wal-inventory.txt"
    {
      echo "==== $raft_wal_dir ===="
      ls -la --time-style=full-iso "$raft_wal_dir"
      sha256sum "$raft_wal_dir"/wal-* 2>/dev/null || true
      echo
    } >> "$STAGE/wal-inventory.txt"
  else
    echo "MISSING $raft_wal_dir" >> "$STAGE/wal-inventory.txt"
  fi
done

echo "SUMMARY-LINE hostname=$(hostname) captured=$(find "$STAGE" -path "*/wal/wal-*" | wc -l) wal files" > "$STAGE/summary-line.txt"

tar -C "$STAGE" -czf "__REMOTE_TAR_PLACEHOLDER__" .
REMOTE

for machine in $MACHINES; do
  log "[$machine] collecting..."
  remote_tar="/tmp/soak-wals-$(date -u +%s).tar.gz"
  remote_script="${REMOTE_TEMPLATE//__WORKDIR_PLACEHOLDER__/$WORKDIR_REMOTE}"
  remote_script="${remote_script//__MODE_PLACEHOLDER__/$MODE}"
  remote_script="${remote_script//__DB_PLACEHOLDER__/$DB}"
  remote_script="${remote_script//__REMOTE_TAR_PLACEHOLDER__/$remote_tar}"
  gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" \
    --command="$remote_script"
  log "[$machine] pulling tarball..."
  mkdir -p "$OUT/$machine"
  gcloud compute scp --project="$PROJECT" --zone="$ZONE" \
    "$machine:$remote_tar" "$OUT/$machine.tar.gz"
  tar -C "$OUT/$machine" -xzf "$OUT/$machine.tar.gz"
  rm -f "$OUT/$machine.tar.gz"
  gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" \
    --command="rm -f $remote_tar"
  cat "$OUT/$machine/summary-line.txt" | tee -a "$SUMMARY"
  log
done

tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
log "done: $OUT (and $OUT.tar.gz)"
