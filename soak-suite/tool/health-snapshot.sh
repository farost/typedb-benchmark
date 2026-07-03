#!/usr/bin/env bash
# Print a compact "here's how everything is right now" snapshot. Safe to run
# every few seconds during a live run. Reads STATE + FAILURES.log per mode
# from the client workdir. No writes.
#
# Usage:
#   tool/health-snapshot.sh                              # defaults to /var/lib/typedb-soak/client
#   tool/health-snapshot.sh /path/to/client/workdir      # explicit
set -euo pipefail
CLIENT_WORKDIR="${1:-/var/lib/typedb-soak/client}"

if [ ! -d "$CLIENT_WORKDIR" ]; then
    echo "ERROR: client workdir not found: $CLIENT_WORKDIR" >&2
    exit 1
fi

now="$(date -u +%FT%TZ)"
printf '=== soak health snapshot @ %s ===\n' "$now"
printf '  workdir: %s\n' "$CLIENT_WORKDIR"

shopt -s nullglob
have_any=0
for state in "$CLIENT_WORKDIR"/mode_*/STATE; do
    have_any=1
    mode="$(basename "$(dirname "$state")")"
    failures="$(dirname "$state")/FAILURES.log"

    echo
    printf -- '--- %s ---\n' "$mode"

    if command -v jq >/dev/null 2>&1; then
        expected=$(jq -r '.expected // 0' "$state")
        commits_ok=$(jq -r '.total_commits_ok // 0' "$state")
        commits_err=$(jq -r '.total_commits_err // 0' "$state")
        verifies_ok=$(jq -r '.total_verifies_ok // 0' "$state")
        verifies_err=$(jq -r '.total_verifies_err // 0' "$state")
        reconciles=$(jq -r '.total_reconciliations // 0' "$state")
        started=$(jq -r '.started_at // "-"' "$state")
        last_ok=$(jq -r '.last_ok_at // "-"' "$state")
    else
        expected=$(grep -oE '"expected": *[0-9-]+' "$state" | head -1 | grep -oE '[0-9-]+')
        commits_ok=$(grep -oE '"total_commits_ok": *[0-9]+' "$state" | head -1 | grep -oE '[0-9]+')
        commits_err=$(grep -oE '"total_commits_err": *[0-9]+' "$state" | head -1 | grep -oE '[0-9]+')
        verifies_ok=$(grep -oE '"total_verifies_ok": *[0-9]+' "$state" | head -1 | grep -oE '[0-9]+')
        verifies_err=$(grep -oE '"total_verifies_err": *[0-9]+' "$state" | head -1 | grep -oE '[0-9]+')
        reconciles=$(grep -oE '"total_reconciliations": *[0-9]+' "$state" | head -1 | grep -oE '[0-9]+')
        started="(install jq for timestamps)"
        last_ok="(install jq for timestamps)"
    fi

    # Elapsed ops/s over the whole run
    if command -v python3 >/dev/null 2>&1 && [ "$started" != "-" ] && [ "$started" != "(install jq for timestamps)" ]; then
        ops_per_s=$(python3 -c "
import datetime
s = datetime.datetime.fromisoformat('$started'.replace('Z','+00:00'))
n = datetime.datetime.now(datetime.timezone.utc)
elapsed = (n - s).total_seconds()
print(f'{$commits_ok / elapsed:.1f}' if elapsed > 0 else '0.0')
" 2>/dev/null || echo "-")
    else
        ops_per_s="-"
    fi

    printf '  started            : %s\n' "$started"
    printf '  last_ok_at         : %s\n' "$last_ok"
    printf '  expected           : %s\n' "$expected"
    printf '  commits_ok         : %s  (~%s ops/s over run)\n' "$commits_ok" "$ops_per_s"
    printf '  commits_err        : %s\n' "$commits_err"
    printf '  verifies_ok        : %s\n' "$verifies_ok"
    printf '  verifies_err       : %s\n' "$verifies_err"
    printf '  reconciliations    : %s\n' "$reconciles"

    # Failures grouped by kind
    if [ -s "$failures" ]; then
        printf '  failures by kind   :\n'
        if command -v jq >/dev/null 2>&1; then
            jq -r '.kind' "$failures" | sort | uniq -c | awk '{printf "    %6d  %s\n", $1, $2}'
            # Highlight count_mismatch (real consistency bugs) prominently
            cm=$(jq -r '.kind' "$failures" | grep -c '^count_mismatch$' || true)
            if [ "$cm" -gt 0 ]; then
                printf '  \033[31m!! count_mismatch = %s — inspect FAILURES.log lines with this kind IMMEDIATELY\033[0m\n' "$cm"
            fi
        else
            grep -oE '"kind":"[a-z_]+"' "$failures" | sort | uniq -c | awk '{printf "    %6d  %s\n", $1, $2}'
        fi
    else
        printf '  failures           : none\n'
    fi

    # Last-seen per server (from diagnostics thread)
    if command -v jq >/dev/null 2>&1; then
        seen_json=$(jq -c '.last_server_seen // {}' "$state")
        if [ "$seen_json" != "{}" ] && [ "$seen_json" != "null" ]; then
            printf '  last_server_seen   :\n'
            echo "$seen_json" | jq -r 'to_entries[] | "    \(.key): \(.value)"' | sed 's/^/    /'
        fi
    fi
done

if [ "$have_any" -eq 0 ]; then
    echo "  (no mode dirs found under $CLIENT_WORKDIR — has the client started yet?)"
    exit 2
fi

echo
echo "=== end snapshot ==="
