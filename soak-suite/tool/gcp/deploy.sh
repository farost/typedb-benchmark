#!/usr/bin/env bash
# One-shot deploy: 00 → 06 in sequence, then wait for a "PASS" READY signal.
# Doesn't kick off verification (call 07-verify-short.sh separately so you can
# pick DURATION and detach the session).
#
# Env:
#   PROJECT, ZONE           (required)
#   NETWORK, SUBNET         (default "default")
#   TYPEDB_TAG              (default 3.12.0-beta-1)
#   TYPEDB_REPO             (default typedb/typedb-cluster)
#   GITHUB_TOKEN            (required)
#   SIZING                  (verification | long-soak — default verification)
#
# Idempotent at every step. Safe to re-run after any hiccup.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE GITHUB_TOKEN

HERE="$(dirname "$0")"

echo "${BOLD}==============================================================================${NC}"
echo "${BOLD} soak deploy: $SIZING sizing → $TYPEDB_TAG on $PROJECT/$ZONE${NC}"
echo "${BOLD}==============================================================================${NC}"

bash "$HERE/00-create-vms.sh"
bash "$HERE/01-install-prereqs.sh"
bash "$HERE/02-ship-suite.sh"
bash "$HERE/03-build-binaries.sh"
bash "$HERE/04-configure.sh"
bash "$HERE/05-build-soak.sh"
bash "$HERE/06-bootstrap.sh"

ok "deploy done — fleet is READY."
echo
echo "Next:"
echo "  Short verification: DURATION=1800 tool/gcp/07-verify-short.sh"
echo "  Long soak:          tool/gcp/08-start-long-soak.sh"
