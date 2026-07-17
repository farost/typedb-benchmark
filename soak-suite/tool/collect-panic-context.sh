#!/usr/bin/env bash
# Pull panic context from every soak node into a local tarball.
#
# For each machine, greps every server.log under $WORKDIR for panic markers,
# and captures the panic backtrace + the last ~300 lines of activity BEFORE
# the panic (so we can see which raft entry / role transition / chaos event
# preceded it). Also pulls FAILURES.log tails and a snapshot of the WAL/data
# layout at each node.
#
# Usage:
#   PROJECT=<gcp-project> ZONE=<gcp-zone> tool/collect-panic-context.sh \
#       [--out DIR] [--workdir /var/lib/typedb-soak] \
#       [--machines "soak-m1 soak-m2 soak-m3"]
#
# Output layout (default OUT is /tmp/soak-panic-context-<UTC timestamp>/):
#   <out>/
#   ├── SUMMARY.txt              counts + list of panic files per machine
#   ├── soak-m1/
#   │   ├── panic-list.txt       server.log paths that contain a panic
#   │   ├── FAILURES.log         concatenated tails from every mode workdir
#   │   ├── data-layout.txt      ls -la of each node's data/ dir
#   │   └── panics/
#   │       └── <mode>__<node>__server.log.tail
#   ├── soak-m2/ ...
#   └── soak-m3/ ...
# ...and <out>.tar.gz alongside for easy transfer.

set -euo pipefail

: "${PROJECT:?set PROJECT to your GCP project id (env var)}"
: "${ZONE:?set ZONE to your GCP zone (env var)}"

WORKDIR_REMOTE=/var/lib/typedb-soak
MACHINES="soak-m1 soak-m2 soak-m3"
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --workdir) WORKDIR_REMOTE="$2"; shift 2 ;;
    --machines) MACHINES="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT" ]]; then
  OUT="/tmp/soak-panic-context-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT"
SUMMARY="$OUT/SUMMARY.txt"
: > "$SUMMARY"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SUMMARY"; }

log "workdir=$WORKDIR_REMOTE machines=[$MACHINES] out=$OUT"
log

# The remote command has to be self-contained. We build a quoted heredoc so
# no local expansion happens, then substitute the two operator-provided
# values (WORKDIR path and remote tarball path) via literal placeholders.
build_remote_script() {
  local workdir="$1"
  local remote_tar="$2"
  local script
  script="$(cat <<'REMOTE'
set -euo pipefail
WORKDIR="__WORKDIR_PLACEHOLDER__"
STAGE="$(mktemp -d /tmp/soak-panic-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/panics"
: > "$STAGE/panic-list.txt"
: > "$STAGE/FAILURES.log"
: > "$STAGE/data-layout.txt"

if [[ ! -d "$WORKDIR" ]]; then
  echo "(no workdir $WORKDIR on $(hostname))" > "$STAGE/panic-list.txt"
else
  # Every server.log under the workdir.
  while IFS= read -r log; do
    if grep -qE "panicked at|range start and end are equal" "$log" 2>/dev/null; then
      echo "$log" >> "$STAGE/panic-list.txt"
      base="$(echo "$log" | sed "s#^$WORKDIR/##" | tr '/' '_')"
      {
        echo "==== $log ===="
        echo "-- last 300 lines BEFORE first panic marker --"
        awk '/panicked at|range start and end are equal/{stop=1} !stop{buf[NR]=$0; if(NR>300)delete buf[NR-300]} END{for(i=NR-299;i<=NR;i++) if(buf[i]) print buf[i]}' "$log"
        echo
        echo "-- from first panic marker to end of file --"
        awk 'found || /panicked at|range start and end are equal/{found=1; print}' "$log"
      } > "$STAGE/panics/$base.tail" 2>/dev/null || true
    fi
  done < <(find "$WORKDIR" -type f -name server.log 2>/dev/null)

  # FAILURES.log from every mode.
  while IFS= read -r fail; do
    echo "==== $fail ====" >> "$STAGE/FAILURES.log"
    tail -100 "$fail" >> "$STAGE/FAILURES.log" 2>/dev/null || true
    echo >> "$STAGE/FAILURES.log"
  done < <(find "$WORKDIR" -type f -name 'FAILURES.log' 2>/dev/null)

  # data/ dir layout — segment counts + sizes hint at WAL / KV state.
  while IFS= read -r data; do
    echo "==== $data ====" >> "$STAGE/data-layout.txt"
    ls -la "$data" >> "$STAGE/data-layout.txt" 2>/dev/null || true
    echo >> "$STAGE/data-layout.txt"
  done < <(find "$WORKDIR" -type d -name data 2>/dev/null)
fi

n_panics="$(wc -l < "$STAGE/panic-list.txt" | tr -d ' ')"
echo "SUMMARY-LINE hostname=$(hostname) panics=$n_panics" > "$STAGE/summary-line.txt"

tar -C "$STAGE" -czf "__REMOTE_TAR_PLACEHOLDER__" .
REMOTE
)"
  script="${script//__WORKDIR_PLACEHOLDER__/$workdir}"
  script="${script//__REMOTE_TAR_PLACEHOLDER__/$remote_tar}"
  printf '%s' "$script"
}

pull_from_machine() {
  local machine="$1"
  local out_dir="$2"
  local remote_tar="/tmp/soak-panic-context-$machine.tar.gz"
  local remote_script
  remote_script="$(build_remote_script "$WORKDIR_REMOTE" "$remote_tar")"

  log "[$machine] collecting..."
  if ! gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" --command="$remote_script"; then
    log "[$machine] SSH/collection FAILED"
    return
  fi

  log "[$machine] pulling tarball..."
  if ! gcloud compute scp "$machine:$remote_tar" "$out_dir/$machine.tar.gz" \
        --project="$PROJECT" --zone="$ZONE"; then
    log "[$machine] scp FAILED"
    return
  fi

  mkdir -p "$out_dir/$machine"
  tar -C "$out_dir/$machine" -xzf "$out_dir/$machine.tar.gz"
  rm -f "$out_dir/$machine.tar.gz"

  gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" \
    --command="rm -f $remote_tar" 2>/dev/null || true

  if [[ -f "$out_dir/$machine/summary-line.txt" ]]; then
    tee -a "$SUMMARY" < "$out_dir/$machine/summary-line.txt"
  fi
  log "[$machine] panic-list.txt:"
  sed 's/^/    /' "$out_dir/$machine/panic-list.txt" | tee -a "$SUMMARY"
  log
}

for M in $MACHINES; do
  pull_from_machine "$M" "$OUT"
done

BUNDLE="${OUT%/}.tar.gz"
tar -C "$(dirname "$OUT")" -czf "$BUNDLE" "$(basename "$OUT")"
log "done. bundle: $BUNDLE  (raw dir: $OUT)"
