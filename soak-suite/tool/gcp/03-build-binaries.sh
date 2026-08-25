#!/usr/bin/env bash
# Clone typedb-cluster on M1, checkout $TYPEDB_TAG, cargo build --release the
# server + admin binaries, then scp to M2/M3.
#
# Env:
#   TYPEDB_TAG (default 3.12.0-beta-1) — tag or SHA to build
#   GITHUB_TOKEN — required (for HTTPS clone of the private repo)
#   TYPEDB_REPO  — default typedb/typedb-cluster; override for a fork
#
# Idempotent — if ~/bin/typedb_server_bin already exists AND its git rev matches
# the tag, skips the rebuild.
source "$(dirname "$0")/lib.sh"
require_env PROJECT ZONE GITHUB_TOKEN GITHUB_USER

: "${TYPEDB_REPO:=typedb/typedb-cluster}"

step "Building typedb $TYPEDB_TAG on M1"

# Sanitize token echoes in logs.
SAFE_CMD="
set -e
if [ ! -d ~/typedb-cluster/.git ]; then
    git clone --quiet https://__USER__:__TOKEN__@github.com/${TYPEDB_REPO}.git ~/typedb-cluster
fi
cd ~/typedb-cluster
# A cached clone keeps the URL it was cloned with — repoint it so a
# TYPEDB_REPO override (e.g. building a fork-only SHA) and a fresh token
# actually take effect instead of silently fetching the old remote.
git remote set-url origin https://__USER__:__TOKEN__@github.com/${TYPEDB_REPO}.git
git fetch --tags --quiet origin '$TYPEDB_TAG' 2>/dev/null || git fetch --tags --quiet origin
git checkout --quiet '$TYPEDB_TAG'
actual=\$(git rev-parse HEAD)
expected='$TYPEDB_TAG'
case \"\$expected\" in
    *[!0-9a-f]*) : ;;   # tag name, not a sha — checkout already validated it
    *) if [ \${#expected} -eq 40 ] && [ \"\$actual\" != \"\$expected\" ]; then
           echo \"HEAD=\$actual but expected \$expected — refusing to build\"; exit 1
       fi ;;
esac
mkdir -p ~/bin
marker=~/bin/.typedb-built-from
if [ -f \"\$marker\" ] && [ \"\$(cat \"\$marker\")\" = \"\$actual\" ] && [ -x ~/bin/typedb_server_bin ] && [ -x ~/bin/typedb_admin_bin ]; then
    echo BUILD_CACHE_HIT
else
    source ~/.cargo/env
    cargo build --release -p typedb_server_bin -p typedb_admin_bin
    cp target/release/typedb_server_bin target/release/typedb_admin_bin ~/bin/
    echo \"\$actual\" > \"\$marker\"
    echo BUILD_DONE
fi
# Always refresh config.yml — runs on both cache-hit and rebuild paths.
# Without this, a second invocation (cache-hit) leaves ~/bin/config.yml stale
# or missing, and the server panics at startup with '[CFG1] Error reading config file'.
cp cluster_server/config.yml ~/bin/config.yml
tar czf /tmp/typedb-bins.tar.gz -C ~/bin typedb_server_bin typedb_admin_bin config.yml .typedb-built-from
echo READY
"

# Substitute token client-side; the remote sees the literal token in the
# command but not through our logs (both invocations of gc_ssh below
# capture output; we only surface the last line).
CMD="${SAFE_CMD//__USER__/$GITHUB_USER}"; CMD="${CMD//__TOKEN__/$GITHUB_TOKEN}"
LOGFILE=/tmp/m1-build.log
echo "  streaming M1 build output here; full log at $LOGFILE"
gc_ssh "${SERVERS[0]}" "$CMD" 2>&1 | tee "$LOGFILE"
last_line="$(tail -1 "$LOGFILE")"
if [ "$last_line" != "READY" ]; then
    error "M1 build did not report READY (last line: $last_line)"
    exit 1
fi
ok "M1 build ready"

step "Distributing binaries to M2, M3"
gc_scp "${SERVERS[0]}:/tmp/typedb-bins.tar.gz" "/tmp/typedb-bins.tar.gz" >/dev/null

distribute() {
    local vm="$1"
    gc_scp /tmp/typedb-bins.tar.gz "$vm:/tmp/typedb-bins.tar.gz" >/dev/null
    gc_ssh "$vm" "mkdir -p ~/bin && tar xzf /tmp/typedb-bins.tar.gz -C ~/bin && chmod +x ~/bin/typedb_server_bin ~/bin/typedb_admin_bin && echo DIST_OK" | tail -1
}

for M in "${SERVERS[@]:1}"; do
    result="$(distribute "$M")"
    if [ "$result" != "DIST_OK" ]; then
        error "$M: distribution failed"
        exit 1
    fi
    ok "$M: binaries in place"
done
