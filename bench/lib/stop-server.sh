#!/usr/bin/env bash
# Stop all servers (idempotent). Used between modes and on exit traps.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Stopping any running typedb servers..."
kill_servers
