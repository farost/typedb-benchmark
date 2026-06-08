# TPC-C benchmark suite

Runs TPC-C against multiple typedb / typedb-cluster builds in sequence and
emits a side-by-side comparison.

The orchestrator lives entirely in `bench/`. The `tpcc/` benchmark code
itself is unchanged.

## What it benchmarks

`bench/config.yml` defines a list of **modes**. Each mode pins:

| Field         | What it is                                       |
|---            |---                                               |
| `repo_url`    | git url (https or ssh+token)                     |
| `commit`      | pinned commit for that mode                      |
| `server_type` | `typedb` or `typedb-cluster` — picks bazel target|
| `nodes`       | 1 → tpcc edition `Core`; >1 → `Cluster`          |

Default modes (override in your own `config.yml`):

1. **`typedb-core`** — plain typedb master, 1 node. Baseline.
2. **`cluster-master-1n`** — typedb-cluster master, 1 node. Single-replica
   "cluster" wrapper for comparison with #1; same client edition.
3. **`cluster-feature-1n`** — `cluster-support-feature-branch`, 1 node.
4. **`cluster-feature-3n`** — `cluster-support-feature-branch`, 3 nodes,
   peers registered and primary elected before tpcc starts.

A single typedb-driver version (`driver.version`) is shared across all modes
— the point of the suite is to compare server code paths under an identical
client.

### Local sources (pre-built artifacts and uncommitted code)

You don't have to pull from a remote. Each mode also accepts:

* **`local_archive`** — absolute path to an already-built `*-all-*.tar.gz`/`.zip`.
  The orchestrator extracts it and skips build entirely. Use this when you
  have a binary from a CI/CD pipeline or a `bazel build` you already ran.

* **`local_repo`** — absolute path to a checked-out repo (possibly with
  uncommitted changes). The orchestrator runs `bazel build //:assemble-all-…`
  in place and extracts. Use this when you want to benchmark code that
  isn't pushed yet.

Priority is `local_archive > local_repo > (repo_url + commit)`. Whichever
field is non-empty first wins. Leave the local fields empty (`""`) to use
the remote path.

Same idea for the driver:

* **`driver.local_wheel`** — pre-built `.whl` path, `pip install <wheel>`.
* **`driver.local_repo`** — path to a typedb-driver checkout; the
  orchestrator builds `//python:assemble-pip<X>` for the active Python
  version and installs the resulting wheel.
* **`driver.version`** — fallback to PyPI (with optional snapshot index).

Cache awareness: extract dirs include the archive's mtime+size or the
checkout's `git HEAD` in their path, so changing the source forces a
fresh extract. Uncommitted edits (`git diff` non-empty) skip the cache
entirely — you always benchmark exactly what's in the working tree.

## TPC-C parameters

Two presets, both in `config.yml`:

* **`smoke`** — `warehouses=1 scalefactor=200 clients=1 duration=15s`.
  Total per mode ~30s. Quick sanity that the mode boots and serves any
  transactions. Runs before bench; if any smoke fails, bench is skipped.
* **`benchmark`** — `warehouses=4 scalefactor=10 clients=4 duration=300s`.
  Per-mode total ~10–15 min (load 3–10 min, execute 5 min). Whole pipeline
  (4 modes) ~50–70 min on a moderate GCP VM.

`scalefactor=10` ≈ 300 customers/district, 300 orders/district per
warehouse, 10000 items × `warehouses` STOCK rows. Not toy-scale, not the
official spec's hours-long full scale either.

## Usage

```bash
# Full pipeline (setup → smoke → bench → compare) for every mode.
bench/run.sh

# Just verify all modes boot and serve.
bench/run.sh --smoke-only

# Single mode (useful for debugging one config).
bench/run.sh --mode cluster-feature-3n

# Skip the smoke phase (you've already proved everything works).
bench/run.sh --skip-smoke

# Skip clone+build (artefacts already extracted to workspace/extracts/).
bench/run.sh --skip-setup

# Use an alternate config file (e.g. swap in different commits).
bench/run.sh --config bench/config-experiment.yml
```

## Output

Each run produces one timestamped subdirectory under `bench/results/`:

```
bench/results/20260608T154200Z/
├── config-snapshot.yml      # exactly the config used for this run
├── smoke/<mode>/
│   ├── load.log
│   └── execute.log
├── bench/<mode>/
│   ├── tpcc.cfg             # the INI written for this mode's run
│   ├── load.log
│   ├── execute.log
│   └── result.json          # parsed summary; consumed by compare.py
└── comparison.md            # side-by-side table across modes
```

`comparison.md` has:

* a top-level table — total transactions, tpmc, aborts, retries per mode
* per-workload latency tables (NEW_ORDER / PAYMENT / ORDER_STATUS /
  DELIVERY / STOCK_LEVEL) — p50, p75, p90, p95, p99, max

## Setting it up on a fresh GCP VM

1. **System packages.** Tested on Ubuntu 22.04 / Amazon Linux 2:
   ```bash
   sudo apt update && sudo apt install -y \
       python3 python3-venv python3-pip \
       openjdk-21-jdk git tar \
       libclang-dev curl
   # bazelisk (for cluster builds)
   curl -L https://github.com/bazelbuild/bazelisk/releases/download/v1.17.0/bazelisk-linux-arm64 \
       | sudo install /dev/stdin /usr/local/bin/bazel
   ```

2. **Clone the benchmark repo + checkout development:**
   ```bash
   git clone https://github.com/farost/typedb-benchmark.git
   cd typedb-benchmark
   git checkout development
   ```

3. **Provide GitHub access.** The orchestrator clones typedb / typedb-cluster
   from their repos. Cheapest path:
   ```bash
   export GITHUB_TOKEN=ghp_xxx    # PAT with `repo` read scope
   ```
   `lib/checkout.sh` rewrites `git@github.com:foo/bar.git` URLs in the config
   to `https://x-access-token:$GITHUB_TOKEN@github.com/foo/bar.git`.

4. **Run.**
   ```bash
   bench/run.sh                   # full pipeline
   ```

The first run clones all repos and builds each binary (cluster builds take
~10–20 min the first time because of rocksdb). Subsequent runs reuse the
extracts under `~/typedb-bench-work/extracts/`.

## Updating pins

To compare against a newer commit of any mode, edit its `commit:` field in
`config.yml` and rerun. The clone+build cache key includes the commit, so
existing builds aren't disturbed.

To bump the driver everywhere at once, change `driver.version`. The venv is
recreated automatically when the source signature differs (version,
wheel path, or repo HEAD).

### Benchmarking work-in-progress code

Two common shapes:

**You have a binary already on disk** (e.g. a CI artifact you scp'd to
the VM):

```yaml
- name: typedb-core-wip
  server_type: typedb
  nodes: 1
  local_archive: "/home/me/artifacts/typedb-all-linux-arm64.tar.gz"
  # repo_url/commit can stay; they're ignored when local_archive is set
```

**You have a checked-out source tree with uncommitted edits**:

```yaml
- name: cluster-feature-3n-wip
  server_type: typedb-cluster
  nodes: 3
  local_repo: "/home/me/work/typedb-cluster"
```

Same patterns work for the driver:

```yaml
driver:
  local_wheel: "/home/me/wheels/typedb_driver-3.12.0-py3-none-linux_aarch64.whl"
  # or
  # local_repo: "/home/me/work/typedb-driver"
```

## Footguns

* **Don't run `bench/run.sh` while another typedb is on `1729` / `*8000`.**
  The first thing the start-server step does is `pkill -KILL` everything
  matching `typedb_server_bin`. If you have an unrelated typedb you want
  to keep alive, run the suite on a separate machine.
* **`scalefactor` in pytpcc is a *divisor*, not a multiplier.** Smaller
  number = more data. `scalefactor=1` is the official full TPC-C dataset
  per warehouse (and takes >1 hour to load). Stick to ≥10 unless you've
  set aside the afternoon.
* **`aborts` or `total_retries` non-zero in the comparison table?** That
  invalidates the latency numbers — txns that aborted before commit don't
  contribute their latency. Look at the per-mode `execute.log` for the
  underlying error before quoting tpmc.

## Adding a new mode

Append to `modes:` in `config.yml`. The orchestrator iterates whatever is
listed there — no code changes needed unless you're adding a new
`server_type` (only `typedb` and `typedb-cluster` are supported today).
