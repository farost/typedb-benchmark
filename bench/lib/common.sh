#!/usr/bin/env bash
# Shared helpers. Sourced by every other lib/*.sh and run.sh.
# Idempotent: safe to source multiple times.

if [ -n "${BENCH_COMMON_SH_LOADED:-}" ]; then return 0; fi
BENCH_COMMON_SH_LOADED=1

# Resolve paths relative to the repo root regardless of CWD.
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"
LIB_DIR="$BENCH_DIR/lib"

# Output styling — only colour when stdout is a tty so logs piped to files
# stay clean.
if [ -t 1 ]; then
    BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()   { echo -e "${GREEN}[bench]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[bench]${NC}  $*" >&2; }
error() { echo -e "${RED}[bench]${NC}  $*" >&2; }
step()  { echo -e "${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}" >&2; }

# Read a top-level scalar (driver.version, workspace, etc.) from config.yml
# using python3 + PyYAML if available, otherwise a minimal awk fallback.
config_get() {
    local key="$1"
    local config="${BENCH_CONFIG:-$BENCH_DIR/config.yml}"
    python3 - "$key" "$config" <<'PY'
import sys, os
key, path = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    sys.stderr.write("config_get requires PyYAML (pip install pyyaml)\n")
    sys.exit(2)
with open(path) as f:
    cfg = yaml.safe_load(f)
def walk(c, parts):
    for p in parts:
        c = c[p]
    return c
val = walk(cfg, key.split('.'))
if isinstance(val, str):
    val = os.path.expandvars(val)
print(val)
PY
}

# Emit `name|repo_url|commit|server_type|nodes` lines, one per mode.
# Pipe-friendly; consumers `while IFS='|' read ...`.
# (Keeps the legacy 5-column shape for older consumers. For local-source
# fields use `mode_field` instead — see below.)
modes_list() {
    local config="${BENCH_CONFIG:-$BENCH_DIR/config.yml}"
    python3 - "$config" <<'PY'
import sys, os
import yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
for m in cfg.get('modes', []):
    print('|'.join(str(m.get(k, '')) for k in
        ('name','repo_url','commit','server_type','nodes')))
PY
}

# Echo a single field of a named mode (env-expanded for path-like fields).
# Returns empty (success) if the field is unset or empty.
#
# Usage: mode_field <mode_name> <field_name>
#
# Useful for the optional local-source fields (`local_archive`, `local_repo`)
# without bloating modes_list's column count.
mode_field() {
    local want_name="$1" field="$2"
    local config="${BENCH_CONFIG:-$BENCH_DIR/config.yml}"
    python3 - "$want_name" "$field" "$config" <<'PY'
import os, sys, yaml
name, field, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = yaml.safe_load(f)
for m in cfg.get('modes', []):
    if m.get('name') == name:
        val = m.get(field, '')
        if isinstance(val, str):
            val = os.path.expandvars(val)
        if val is not None:
            print(val)
        break
PY
}

# Same as config_get but returns the empty string (success) on missing keys
# instead of raising. Used for optional fields like `driver.local_wheel`.
config_get_optional() {
    local key="$1"
    local config="${BENCH_CONFIG:-$BENCH_DIR/config.yml}"
    python3 - "$key" "$config" <<'PY'
import os, sys, yaml
key, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = yaml.safe_load(f)
parts = key.split('.')
val = cfg
for p in parts:
    if isinstance(val, dict) and p in val:
        val = val[p]
    else:
        val = ''
        break
if isinstance(val, str):
    val = os.path.expandvars(val)
print(val if val is not None else '')
PY
}

# Filter modes_list to a single name. Returns nonzero if not found.
mode_get() {
    local want="$1"
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local name="${line%%|*}"
        if [ "$name" = "$want" ]; then
            echo "$line"
            return 0
        fi
    done < <(modes_list)
    return 1
}

# Port allocation: each node N gets ports N1729 / N8000 / N1730 / N1731.
# Mirrors cluster-server.sh from the typedb-cluster orchestration tests.
grpc_port()       { echo "${1}1729"; }
http_port()       { echo "${1}8000"; }
clustering_port() { echo "${1}1730"; }
monitoring_port() { echo "${1}1731"; }

# Block until the given port accepts a TCP connection, or fail after `deadline_seconds`.
wait_for_port() {
    local port="$1" deadline_seconds="${2:-60}"
    local deadline=$(( $(date +%s) + deadline_seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    error "Timed out waiting for 127.0.0.1:$port after ${deadline_seconds}s"
    return 1
}

# Block until path exists (used for the admin UDS file).
wait_for_path() {
    local path="$1" deadline_seconds="${2:-60}"
    local deadline=$(( $(date +%s) + deadline_seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -e "$path" ]; then return 0; fi
        sleep 0.5
    done
    error "Timed out waiting for $path after ${deadline_seconds}s"
    return 1
}

# Kill anything matching the pattern. Used between mode switches to keep
# stale servers from claiming ports.
kill_servers() {
    pkill -KILL -f "typedb_server_bin"     >/dev/null 2>&1 || true
    pkill -KILL -f "typedb_admin_bin"      >/dev/null 2>&1 || true
    sleep 1
}

# Path to the cached extract dir for (mode, commit).
mode_extract_dir() {
    local mode_name="$1" commit="$2"
    local workspace
    workspace="$(config_get workspace)"
    echo "$workspace/extracts/${mode_name}-${commit:0:12}"
}

# Path to the shared `typedb` launcher inside an extract.
mode_launcher() {
    local extract_dir="$1"
    echo "$extract_dir/typedb"
}

# Architecture string used in archive filenames (linux-arm64 / linux-x86_64).
host_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "linux-x86_64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        *) error "unsupported arch: $(uname -m)"; return 1 ;;
    esac
}
