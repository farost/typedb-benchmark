#!/usr/bin/env bash
# Second-pass collector for WAL-drift forensics on a soak fleet that has
# panic'd into a crash loop. `collect-panic-context.sh` shows the crash loop;
# THIS script goes after the pre-crash-loop history and the WAL state on disk.
#
# For each machine, pulls:
#   - Every rotated server.log (server.log.*, *.gz).
#   - journalctl unit output for the typedb-server systemd unit (if present)
#     going back 48h — many rotation setups keep only 1-2 server.log.N files
#     and the rest is in journal.
#   - The full WAL directory listing (file sizes tell us how many CR segments
#     exist and whether any got truncated on crash-recovery).
#   - client.log / diagnostics.log / chaos.log tails from the client machine
#     if available (may live under /var/lib/typedb-soak/client/<mode>/).
#   - The soak-suite orchestration log if it exists.
#
# Usage:
#   PROJECT=<gcp-project> ZONE=<gcp-zone> tool/collect-drift-forensics.sh \
#       [--out DIR] [--workdir /var/lib/typedb-soak] \
#       [--machines "soak-m1 soak-m2 soak-m3"] \
#       [--client-machine soak-client] \
#       [--journal-unit typedb-server] [--journal-since "48 hours ago"]
#
# Output layout:
#   <out>/
#   ├── SUMMARY.txt
#   ├── soak-m1/
#   │   ├── server-log-listing.txt        every file under each node's log/ dir
#   │   ├── rotated-logs/                 gzipped rotated server.logs (verbatim)
#   │   ├── journal.txt                   journalctl since <since>
#   │   ├── wal-layout.txt                ls -la of every WAL / RocksDB dir per db
#   │   ├── first-nontrivial-lines.txt    first ~200 non-panic lines of live log
#   │   └── panic-cluster-timing.txt      timestamp of every panic marker
#   ├── ...
#   └── soak-client/
#       ├── FAILURES.log
#       ├── client-logs.txt
#       ├── diagnostics.log
#       └── chaos.log (if the soak-suite writes one)

set -euo pipefail

: "${PROJECT:?set PROJECT to your GCP project id (env var)}"
: "${ZONE:?set ZONE to your GCP zone (env var)}"

WORKDIR_REMOTE=/var/lib/typedb-soak
MACHINES="soak-m1 soak-m2 soak-m3"
CLIENT_MACHINE="soak-client"
JOURNAL_UNIT="typedb-server"
JOURNAL_SINCE="48 hours ago"
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --workdir) WORKDIR_REMOTE="$2"; shift 2 ;;
    --machines) MACHINES="$2"; shift 2 ;;
    --client-machine) CLIENT_MACHINE="$2"; shift 2 ;;
    --journal-unit) JOURNAL_UNIT="$2"; shift 2 ;;
    --journal-since) JOURNAL_SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT" ]]; then
  OUT="/tmp/soak-drift-forensics-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT"
SUMMARY="$OUT/SUMMARY.txt"
: > "$SUMMARY"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SUMMARY"; }
log "workdir=$WORKDIR_REMOTE machines=[$MACHINES] client=$CLIENT_MACHINE out=$OUT"
log "journal-unit=$JOURNAL_UNIT journal-since=\"$JOURNAL_SINCE\""

# --- Write the remote-side scripts to temp files. Writing them via a
#     top-level heredoc (not inside a $(...) or `` `` ``) avoids the bash 3.2
#     (macOS default) parser quirk where a heredoc nested in command
#     substitution can be miscounted. Placeholders get substituted per-machine
#     when we build the actual --command argument.
SERVER_TEMPLATE="$(mktemp -t soak-server-tmpl.XXXXXX)"
CLIENT_TEMPLATE="$(mktemp -t soak-client-tmpl.XXXXXX)"
trap 'rm -f "$SERVER_TEMPLATE" "$CLIENT_TEMPLATE"' EXIT

cat > "$SERVER_TEMPLATE" <<'REMOTE_SERVER'
set -euo pipefail
WORKDIR="__WORKDIR_PLACEHOLDER__"
JOURNAL_UNIT="__JOURNAL_UNIT_PLACEHOLDER__"
JOURNAL_SINCE="__JOURNAL_SINCE_PLACEHOLDER__"
STAGE="$(mktemp -d /tmp/soak-drift-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

: > "$STAGE/server-log-listing.txt"
: > "$STAGE/wal-layout.txt"
: > "$STAGE/first-nontrivial-lines.txt"
: > "$STAGE/panic-cluster-timing.txt"
mkdir -p "$STAGE/rotated-logs"

if [[ -d "$WORKDIR" ]]; then
  while IFS= read -r logdir; do
    echo "==== $logdir ====" >> "$STAGE/server-log-listing.txt"
    ls -la "$logdir" >> "$STAGE/server-log-listing.txt" 2>/dev/null || true
    echo >> "$STAGE/server-log-listing.txt"
  done < <(find "$WORKDIR" -type d -name log -o -type d -name logs 2>/dev/null)

  while IFS= read -r nodedir; do
    echo "==== $nodedir  top-level ====" >> "$STAGE/server-log-listing.txt"
    ls -la "$nodedir" >> "$STAGE/server-log-listing.txt" 2>/dev/null || true
    echo >> "$STAGE/server-log-listing.txt"
  done < <(find "$WORKDIR" -maxdepth 4 -type d -name 'node*' 2>/dev/null)

  while IFS= read -r rot; do
    dest_name="$(echo "$rot" | sed "s#^$WORKDIR/##" | tr '/' '_')"
    cp -a "$rot" "$STAGE/rotated-logs/$dest_name" 2>/dev/null || true
  done < <(find "$WORKDIR" -type f \( -name 'server.log.*' -o -name '*.log.gz' -o -name '*.log.[0-9]*' \) 2>/dev/null)

  while IFS= read -r log; do
    echo "==== $log ====" >> "$STAGE/first-nontrivial-lines.txt"
    grep -viE "panicked at|range start and end are equal|note: run with .RUST_BACKTRACE|thread .(main|<unnamed>). panicked|A panic occurred panic\.payload" "$log" | head -200 >> "$STAGE/first-nontrivial-lines.txt" 2>/dev/null || true
    echo >> "$STAGE/first-nontrivial-lines.txt"
  done < <(find "$WORKDIR" -type f -name server.log 2>/dev/null)

  while IFS= read -r log; do
    echo "==== $log ====" >> "$STAGE/panic-cluster-timing.txt"
    grep -oE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" "$log" 2>/dev/null | head -10 >> "$STAGE/panic-cluster-timing.txt" || true
    echo "  ...  total panic markers: $(grep -c 'panicked at' "$log" 2>/dev/null || echo 0)" >> "$STAGE/panic-cluster-timing.txt"
    echo "  ...  last panic timestamps:" >> "$STAGE/panic-cluster-timing.txt"
    grep -B1 "panicked at" "$log" 2>/dev/null | grep -oE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -10 >> "$STAGE/panic-cluster-timing.txt" || true
    echo >> "$STAGE/panic-cluster-timing.txt"
  done < <(find "$WORKDIR" -type f -name server.log 2>/dev/null)

  while IFS= read -r datadir; do
    echo "==== $datadir ====" >> "$STAGE/wal-layout.txt"
    find "$datadir" -maxdepth 4 -printf '%TY-%Tm-%TdT%TH:%TM:%TS %10s %p\n' 2>/dev/null | sort >> "$STAGE/wal-layout.txt"
    echo >> "$STAGE/wal-layout.txt"
  done < <(find "$WORKDIR" -maxdepth 6 -type d \( -name data -o -name wal \) 2>/dev/null)
fi

if command -v journalctl >/dev/null 2>&1; then
  journalctl -u "$JOURNAL_UNIT" --since "$JOURNAL_SINCE" --no-pager > "$STAGE/journal.txt" 2>&1 || \
    journalctl --since "$JOURNAL_SINCE" --no-pager > "$STAGE/journal.txt" 2>&1 || \
    echo "(journalctl unavailable or empty)" > "$STAGE/journal.txt"
else
  echo "(journalctl not present on this host)" > "$STAGE/journal.txt"
fi

echo "hostname=$(hostname) rotated_logs=$(ls "$STAGE/rotated-logs" 2>/dev/null | wc -l)" > "$STAGE/summary-line.txt"

tar -C "$STAGE" -czf "__REMOTE_TAR_PLACEHOLDER__" .
REMOTE_SERVER

cat > "$CLIENT_TEMPLATE" <<'REMOTE_CLIENT'
set -euo pipefail
WORKDIR="__WORKDIR_PLACEHOLDER__"
STAGE="$(mktemp -d /tmp/soak-client-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

: > "$STAGE/FAILURES.log"
: > "$STAGE/client-logs.txt"
: > "$STAGE/diagnostics.log"

if [[ -d "$WORKDIR" ]]; then
  while IFS= read -r fail; do
    echo "==== $fail ====" >> "$STAGE/FAILURES.log"
    cat "$fail" >> "$STAGE/FAILURES.log" 2>/dev/null || true
    echo >> "$STAGE/FAILURES.log"
  done < <(find "$WORKDIR" -type f -name 'FAILURES.log' 2>/dev/null)

  while IFS= read -r cli; do
    echo "==== $cli (tail -500) ====" >> "$STAGE/client-logs.txt"
    tail -500 "$cli" >> "$STAGE/client-logs.txt" 2>/dev/null || true
    echo >> "$STAGE/client-logs.txt"
  done < <(find "$WORKDIR" -type f -name 'client.log' 2>/dev/null)

  while IFS= read -r diag; do
    echo "==== $diag (tail -500) ====" >> "$STAGE/diagnostics.log"
    tail -500 "$diag" >> "$STAGE/diagnostics.log" 2>/dev/null || true
    echo >> "$STAGE/diagnostics.log"
  done < <(find "$WORKDIR" -type f -name 'diagnostics.log' 2>/dev/null)

  while IFS= read -r c; do
    echo "==== $c (tail -500) ====" >> "$STAGE/chaos.log"
    tail -500 "$c" >> "$STAGE/chaos.log" 2>/dev/null || true
    echo >> "$STAGE/chaos.log"
  done < <(find "$WORKDIR" -type f -iname '*chaos*' 2>/dev/null)
fi

echo "hostname=$(hostname)" > "$STAGE/summary-line.txt"
tar -C "$STAGE" -czf "__REMOTE_TAR_PLACEHOLDER__" .
REMOTE_CLIENT

# --- Build the actual remote script for a given machine by substituting
#     placeholders in the appropriate template.
render_server_script() {
  local remote_tar="$1"
  sed \
    -e "s#__WORKDIR_PLACEHOLDER__#$WORKDIR_REMOTE#g" \
    -e "s#__JOURNAL_UNIT_PLACEHOLDER__#$JOURNAL_UNIT#g" \
    -e "s#__JOURNAL_SINCE_PLACEHOLDER__#$JOURNAL_SINCE#g" \
    -e "s#__REMOTE_TAR_PLACEHOLDER__#$remote_tar#g" \
    "$SERVER_TEMPLATE"
}

render_client_script() {
  local remote_tar="$1"
  sed \
    -e "s#__WORKDIR_PLACEHOLDER__#$WORKDIR_REMOTE#g" \
    -e "s#__REMOTE_TAR_PLACEHOLDER__#$remote_tar#g" \
    "$CLIENT_TEMPLATE"
}

pull() {
  local machine="$1"
  local out_dir="$2"
  local script="$3"
  local remote_tar="/tmp/soak-drift-forensics-$machine.tar.gz"

  log "[$machine] collecting..."
  if ! gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" --command="$script"; then
    log "[$machine] ssh FAILED"; return
  fi
  log "[$machine] pulling tarball..."
  if ! gcloud compute scp "$machine:$remote_tar" "$out_dir/$machine.tar.gz" \
        --project="$PROJECT" --zone="$ZONE"; then
    log "[$machine] scp FAILED"; return
  fi
  mkdir -p "$out_dir/$machine"
  tar -C "$out_dir/$machine" -xzf "$out_dir/$machine.tar.gz"
  rm -f "$out_dir/$machine.tar.gz"
  gcloud compute ssh "$machine" --project="$PROJECT" --zone="$ZONE" \
    --command="rm -f $remote_tar" 2>/dev/null || true

  if [[ -f "$out_dir/$machine/summary-line.txt" ]]; then
    tee -a "$SUMMARY" < "$out_dir/$machine/summary-line.txt"
  fi
  log
}

for M in $MACHINES; do
  pull "$M" "$OUT" "$(render_server_script "/tmp/soak-drift-forensics-$M.tar.gz")"
done

if [[ -n "$CLIENT_MACHINE" ]]; then
  pull "$CLIENT_MACHINE" "$OUT" "$(render_client_script "/tmp/soak-drift-forensics-$CLIENT_MACHINE.tar.gz")"
fi

BUNDLE="${OUT%/}.tar.gz"
tar -C "$(dirname "$OUT")" -czf "$BUNDLE" "$(basename "$OUT")"
log "done. bundle: $BUNDLE  (raw dir: $OUT)"
