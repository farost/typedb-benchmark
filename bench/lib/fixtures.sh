#!/usr/bin/env bash
# Per-mode pre-loaded database fixtures.
#
# A fixture is a tarball of each node's `server/{data,clustering}` directories
# captured *after* a successful TPC-C load and *before* any execute traffic.
# Restoring a fixture is equivalent to running an honest load: the database
# is in the standard post-init TPC-C state.
#
# Cache key (per mode):
#   <mode>__<launcher_sha12>__W<W>_SF<SF>__sch<schema_sha8>
#
# Every component that could change the on-disk storage contributes to the
# key. Bump the binary, bump the schema, change warehouses or scalefactor →
# automatic invalidation, a fresh load runs.
#
# Fixtures live under `${workspace}/fixtures/<key>/{1,2,3}.tar.gz` and are
# safe to delete at any time: `rm -rf ${workspace}/fixtures` is the disable
# button. Or pass `--no-fixtures` to bench/run.sh for a single honest run.

if [ -n "${BENCH_FIXTURES_SH_LOADED:-}" ]; then return 0; fi
BENCH_FIXTURES_SH_LOADED=1

# Common helpers (config_get_optional, log, etc.) are already loaded by the
# caller; if not, source them now.
if [ -z "${BENCH_COMMON_SH_LOADED:-}" ]; then
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# Compute the cache key for a (mode, binary, params) tuple.
# Usage: fixture_key <mode_name> <launcher_path> <warehouses> <scalefactor>
fixture_key() {
    local mode_name="$1" launcher="$2" warehouses="$3" scalefactor="$4"
    local schema="$REPO_ROOT/tpcc/pytpcc/drivers/tql3/tpcc-schema.tql"

    local launcher_sha schema_sha
    launcher_sha="$(sha256sum "$launcher" 2>/dev/null | awk '{print substr($1,1,12)}')"
    schema_sha="$(sha256sum "$schema" 2>/dev/null | awk '{print substr($1,1,8)}')"

    if [ -z "$launcher_sha" ] || [ -z "$schema_sha" ]; then
        error "fixture_key: couldn't hash launcher ($launcher) or schema ($schema)"
        return 1
    fi
    echo "${mode_name}__${launcher_sha}__W${warehouses}_SF${scalefactor}__sch${schema_sha}"
}

# Resolve the fixture root directory (config override → workspace/fixtures).
fixture_root() {
    local override
    override="$(config_get_optional fixtures.cache_dir)"
    if [ -n "$override" ]; then
        echo "$override"
    else
        echo "$(config_get workspace)/fixtures"
    fi
}

# Absolute path to a fixture's dir, given the key.
fixture_dir() {
    local key="$1"
    echo "$(fixture_root)/$key"
}

# Check whether a complete fixture exists for (key, nodes). Returns 0 / 1.
# A fixture is considered complete only when *every* node tarball is present.
fixture_exists() {
    local key="$1" nodes="$2"
    local dir; dir="$(fixture_dir "$key")"
    [ -d "$dir" ] || return 1
    local n
    for n in $(seq 1 "$nodes"); do
        [ -s "$dir/$n.tar.gz" ] || return 1
    done
    return 0
}

# Save a fixture from a stopped-mode_run directory.
# Usage: fixture_save <key> <mode_run> <nodes>
#
# The caller MUST have stopped all servers for this mode before invoking;
# tarring up live RocksDB state can produce inconsistent snapshots.
fixture_save() {
    local key="$1" mode_run="$2" nodes="$3"
    local dir; dir="$(fixture_dir "$key")"
    rm -rf "$dir"; mkdir -p "$dir"
    log "Saving fixture $key (${nodes} node$([ "$nodes" -gt 1 ] && echo s))"
    local n
    for n in $(seq 1 "$nodes"); do
        local src="$mode_run/$n/server"
        if [ ! -d "$src/data" ]; then
            error "fixture_save: missing $src/data"
            return 1
        fi
        local -a parts=(data)
        [ -d "$src/clustering" ] && parts+=(clustering)
        ( cd "$src" && tar -czf "$dir/$n.tar.gz" "${parts[@]}" )
    done
    log "Fixture saved: $dir"
}

# Restore a fixture into a fresh mode_run directory.
# Usage: fixture_restore <key> <mode_run> <nodes>
fixture_restore() {
    local key="$1" mode_run="$2" nodes="$3"
    local dir; dir="$(fixture_dir "$key")"
    log "Restoring fixture $key (${nodes} node$([ "$nodes" -gt 1 ] && echo s))"
    local n
    for n in $(seq 1 "$nodes"); do
        local dst="$mode_run/$n/server"
        mkdir -p "$dst"
        if ! tar -xzf "$dir/$n.tar.gz" -C "$dst"; then
            error "fixture_restore: failed to extract $dir/$n.tar.gz"
            return 1
        fi
    done
}
