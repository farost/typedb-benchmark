# typedb-cluster soak suite

A long-running correctness + survivability test harness for typedb-cluster.

## What it tests

Three modes run in parallel against ONE typedb-cluster fleet:

| Mode             | Nodes | Chaos                  | Pass criteria                       |
| ---------------- | ----- | ---------------------- | ----------------------------------- |
| `mode_1n_steady` | 1     | none                   | no `count_mismatch`; throughput ≥ N |
| `mode_3n_steady` | 3     | none                   | no `count_mismatch`; throughput ≥ N |
| `mode_3n_chaos`  | 3     | kills + network errors | no `count_mismatch`; cluster always recovers |

Each mode runs its own client process that loops `insert → commit → match-count → verify`. A mismatch is logged to `FAILURES.log` as a `count_mismatch` record — those are real consistency bugs. Connection errors during chaos windows are logged as `server_unreachable` (expected; informational).

## Topology

4 machines:

| Machine  | Runs (server side)                                         |
| -------- | ---------------------------------------------------------- |
| `M1`     | 1n node 1, 3n steady node 1, 3n chaos node 1               |
| `M2`     | 3n steady node 2, 3n chaos node 2                          |
| `M3`     | 3n steady node 3, 3n chaos node 3                          |
| `client` | 3 tmux client sessions (one per mode), plus monitor session |

Port assignments are EXPLICIT in `config/topology.toml`. The loader validates that no two ports collide on the same machine.

Chaos in `mode_3n_chaos` is scoped to that mode's clustering ports — packets on the steady-mode ports are not affected, even though both modes share the same physical machines.

## Architecture

```
soak-suite/
├── Cargo.toml
├── src/
│   ├── lib.rs                  module index
│   ├── config.rs               TOML topology + validation
│   ├── binary.rs               local OR cloudsmith download (with auth)
│   ├── cluster.rs              spawn/wait/register Raft cluster
│   ├── chaos.rs                kill loop per chaos mode
│   ├── network_chaos.rs        iptables + tc/netem: drop/delay/partition/asymmetric
│   ├── disk.rs                 disk watchdog (warn loudly, never halt)
│   ├── diagnostics.rs          TCP + /diagnostics?format=json poller
│   ├── state.rs                STATE + FAILURES.log
│   ├── log.rs                  timestamped logger
│   ├── verification.rs         30-min report renderer
│   └── bin/
│       ├── runner.rs           per-machine server-side binary
│       ├── client.rs           per-mode client-side binary
│       └── verify-report.rs    print pass/fail summary
├── config/
│   ├── topology.toml           4-machine fleet config (with hostnames)
│   └── topology.localhost.toml single-host smoke config
├── tool/
│   ├── bootstrap.sh            multi-step bring-up
│   ├── start-servers-on-machine.sh
│   ├── start-clients.sh        creates 4 tmux sessions on the client machine
│   ├── stop-clients.sh
│   ├── monitor.sh              5s-refresh dashboard
│   └── verify-report.sh        pretty pass/fail
└── examples/
    └── run-local-test.sh       loopback smoke test
```

## Bootstrap (4-machine deploy)

### Prereqs on each server machine (M1/M2/M3)

```bash
# Rust toolchain (or pre-build & scp the binary)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.85.0

# System tools
sudo apt-get install -y iptables iproute2 tmux jq

# Soak working dir
sudo mkdir -p /var/lib/typedb-soak && sudo chown $USER /var/lib/typedb-soak
```

For network chaos to work without prompting, drop a sudoers fragment in `/etc/sudoers.d/typedb-soak` (replace `$USER` with the runner's user):

```
$USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/tc
```

Validate with `sudo -n iptables -L OUTPUT -n` — should succeed silently.

### Per-machine setup

1. Clone this repo onto the machine.
2. Either build typedb locally and point `[binary]` at the binaries, or set `source = "download"` with a cloudsmith URL + token in `$CLOUDSMITH_TOKEN`.
3. Adjust the `[machines.M1]`, `[machines.M2]`, `[machines.M3]`, `[machines.client]` hostnames in `config/topology.toml` to whatever address those machines advertise to each other (GCP internal DNS, IPs, whatever).
4. Run bootstrap:

```bash
# On each server machine
tool/bootstrap.sh M1   # on M1
tool/bootstrap.sh M2   # on M2
tool/bootstrap.sh M3   # on M3
```

Each runner spawns its assigned nodes; the runner on M1 then registers nodes 2 and 3 as peers via its local node 1's admin socket (per mode) and waits for primary election. All three runners block in the foreground; ^C to stop everything cleanly.

The runner logs the address list each client should use, e.g.:

```
[READY] [mode_1n_steady] client addrs: M1:11729 (chaos=false)
[READY] [mode_3n_steady] client addrs: M1:21729,M2:21729,M3:21729 (chaos=false)
[READY] [mode_3n_chaos]  client addrs: M1:31729,M2:31729,M3:31729 (chaos=true)
```

### Client machine

```bash
# (Optional) 30-min verification first
tool/start-clients.sh --verify

# Wait ~31 minutes, then:
tool/verify-report.sh

# If the report says PASS, kick off the real run:
tool/start-clients.sh

# Monitor:
tool/monitor.sh

# Or attach to a single client:
tmux attach -t soak-3n-chaos
```

## What the operator sees during chaos

Every chaos action is loud:

```
[KILL-CHAOS] kill mode_3n_chaos/node2 (will stay dead for some time)
[KILL-CHAOS] restart mode_3n_chaos/node2 after 17s downtime
[NET-CHAOS]  STARTING delay on mode_3n_chaos/node1 (clustering port 31730) for 45s — SNEAKY THINGS HAPPENING
[NET-CHAOS]  STOPPING delay on mode_3n_chaos/node1 (port 31730) — restoring clean state
[NET-CHAOS]  CLEAN on mode_3n_chaos/node1
```

A real failure stands out:

```
!!!!! ERROR [KILL-CHAOS] WARN mode_3n_chaos/node3 died outside chaos (real crash); restarting
!!!!! ERROR [DISK]       Disk usage HIGH on /var/lib/typedb-soak: 84% (warn at 80%) — investigate, free space, or expect a crash soon
```

## Local single-host smoke test

```bash
# Build typedb locally first:
cd /opt/project/repositories/typedb-cluster && cargo build --release

# Run a 5-min smoke; reports at the end.
examples/run-local-test.sh

# Override duration:
DURATION=60 examples/run-local-test.sh
```

The smoke uses `config/topology.localhost.toml` — same shape as the production topology but with all machines mapped to 127.0.0.1 and chaos applied to `lo`.

## Recovery from a crashed runner

If a runner crashes mid-chaos, the iptables/tc rules may be left in place. On runner startup the next bootstrap will fail to apply rules but won't make things worse. To clean up by hand:

```bash
sudo iptables -S OUTPUT | grep soak-net-chaos | sed 's/^-A/-D/' | xargs -L1 sudo iptables
sudo iptables -S INPUT  | grep soak-net-chaos | sed 's/^-A/-D/' | xargs -L1 sudo iptables
sudo tc qdisc del dev eth0 root 2>/dev/null || true   # may fail if no qdisc
```

## Files written during a run

Per server machine (e.g. M1):
```
/var/lib/typedb-soak/M1/
  runner.log
  mode_1n_steady/node1/{server.log,data/,clustering/,logs/}
  mode_3n_steady/node1/{server.log,data/,clustering/,logs/}
  mode_3n_chaos/node1/{server.log,data/,clustering/,logs/}
```

Per client mode (on the client machine):
```
/var/lib/typedb-soak/client/mode_3n_chaos/
  STATE              # current expected counter + cumulative metrics (atomic JSON)
  FAILURES.log       # append-only JSONL: count_mismatch, server_unreachable
  client.log         # human-readable status lines
  diagnostics.log    # diagnostics poller events (UNREACHABLE / RECOVERED)
```

## Known untested aspects

The single-host smoke covers everything that doesn't actually require a 4-machine deploy. The following were NOT exercised end-to-end here and should be verified on first deployment:

- Cross-machine peer registration with non-loopback addresses (hostname/IP resolution between GCP machines).
- Network chaos on a real `eth0` (vs `lo`). The same iptables/tc commands apply, but BPF/kernel features differ; verify `apply_drop`, `apply_delay`, `apply_partition`, `apply_asymmetric` and their cleanup paths in a real cluster window.
- Cloudsmith download path with a real token (the curl + tar logic is identical to the prior bench harness; just exercise it once).
- Disk watchdog under a real near-full disk (the format string and df parsing are unit-trivial but should be visually confirmed once).

---

## GCP deploy — machine sizing

Both the short verification and the week+ soak use the **same 4-machine layout** (3 servers + 1 client). The only differences are (a) disk size and (b) how long you leave it running.

### Servers M1 / M2 / M3

**Verification (30 min – 2 hr):**

| Attribute | Value |
|---|---|
| Machine type | `n2-standard-4` (4 vCPU, 16 GB RAM) |
| Boot disk | 100 GB `pd-ssd` |
| Data disk | none (fits on boot) |
| Region | pick one, all 3 same zone |
| Tags | `soak-server` |

**Long soak (1–4 weeks):**

| Attribute | Value |
|---|---|
| Machine type | `n2-standard-8` (8 vCPU, 32 GB RAM) — the extra headroom masks noise from chaos threads |
| Boot disk | 50 GB `pd-ssd` (OS + logs) |
| Data disk | **500 GB `pd-ssd`** mounted at `/var/lib/typedb-soak` (data grows steadily; the disk watchdog warns at 80% but doesn't halt) |
| Region | same zone as verification |
| Tags | `soak-server` |

Why the bigger machine for the long run: chaos + steady modes run concurrently on the same box. Under a fast client, a 4-vCPU box will pin CPU during the 3n-chaos writes AND the 3n-steady writes at the same time, which turns "background chaos" into a real bottleneck and inflates commit_err noise. 8 vCPU keeps the two modes largely independent.

### Client

**Verification:**

| Attribute | Value |
|---|---|
| Machine type | `e2-standard-2` (2 vCPU, 8 GB RAM) |
| Boot disk | 30 GB `pd-standard` |
| Tags | `soak-client` |

**Long soak:**

| Attribute | Value |
|---|---|
| Machine type | `e2-standard-4` (4 vCPU, 16 GB RAM) — the driver keeps 3 gRPC connections warm continuously; e2-standard-2 saturates first |
| Boot disk | 100 GB `pd-standard` (STATE + FAILURES.log + client.log accumulate) |
| Tags | `soak-client` |

### Networking

- All 4 in the **same VPC subnet** so internal DNS resolves names automatically.
- Firewall rule allowing internal TCP between the tags `soak-server` ↔ `soak-server` and `soak-client` → `soak-server` on ports `11729–11732`, `21729–21732`, `31729–31732`.
- SSH from your laptop → all 4.

Estimated GCP cost (us-central1 pricing, rough):

| Run | Server × 3 | Client | Storage | Total |
|---|---|---|---|---|
| 30-min verification | ~$0.60 | ~$0.05 | ~$0.10 | **< $1** |
| 1 week soak | ~$100 | ~$15 | ~$25 | **~$140** |
| 4 week soak | ~$400 | ~$60 | ~$100 | **~$560** |

## Deploy runbook

Every command is one-line copy-paste. Substitute `$PROJECT`, `$ZONE`, `$NETWORK`, `$SUBNET`.

### 1. Create the 4 VMs (verification sizing)

```
for M in soak-m1 soak-m2 soak-m3; do gcloud compute instances create $M --project=$PROJECT --zone=$ZONE --machine-type=n2-standard-4 --network=$NETWORK --subnet=$SUBNET --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=100GB --boot-disk-type=pd-ssd --tags=soak-server; done
```

```
gcloud compute instances create soak-client --project=$PROJECT --zone=$ZONE --machine-type=e2-standard-2 --network=$NETWORK --subnet=$SUBNET --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=30GB --tags=soak-client
```

For the **long soak sizing**, run instead:

```
for M in soak-m1 soak-m2 soak-m3; do gcloud compute instances create $M --project=$PROJECT --zone=$ZONE --machine-type=n2-standard-8 --network=$NETWORK --subnet=$SUBNET --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=50GB --boot-disk-type=pd-ssd --tags=soak-server && gcloud compute disks create $M-data --project=$PROJECT --zone=$ZONE --size=500GB --type=pd-ssd && gcloud compute instances attach-disk $M --project=$PROJECT --zone=$ZONE --disk=$M-data; done
```

```
gcloud compute instances create soak-client --project=$PROJECT --zone=$ZONE --machine-type=e2-standard-4 --network=$NETWORK --subnet=$SUBNET --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=100GB --tags=soak-client
```

If you attached a data disk on each server, format + mount it:

```
for M in soak-m1 soak-m2 soak-m3; do gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='sudo mkfs.ext4 -F /dev/sdb && sudo mkdir -p /var/lib/typedb-soak && sudo mount /dev/sdb /var/lib/typedb-soak && echo "/dev/sdb /var/lib/typedb-soak ext4 defaults 0 2" | sudo tee -a /etc/fstab && sudo chown $USER /var/lib/typedb-soak'; done
```

### 2. Open the firewall

```
gcloud compute firewall-rules create soak-internal --project=$PROJECT --network=$NETWORK --direction=INGRESS --action=ALLOW --source-tags=soak-server,soak-client --target-tags=soak-server --rules=tcp:11729-11732,tcp:21729-21732,tcp:31729-31732
```

### 3. Per-machine prereqs

Run on each server (M1/M2/M3):

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='sudo apt-get update && sudo apt-get install -y build-essential pkg-config libssl-dev iptables iproute2 tmux jq git curl python3 python3-pip'
```

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.85.0 --profile minimal'
```

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='sudo mkdir -p /var/lib/typedb-soak && sudo chown $USER /var/lib/typedb-soak'
```

Drop the sudoers fragment so `iptables`/`tc` don't prompt for a password (required by network chaos):

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='echo "$USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/tc" | sudo tee /etc/sudoers.d/typedb-soak && sudo chmod 440 /etc/sudoers.d/typedb-soak && sudo -n iptables -L OUTPUT -n >/dev/null && sudo -n tc qdisc show dev eth0 >/dev/null && echo PREFLIGHT_OK'
```

Client machine — same but skip the iptables/tc bits:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='sudo apt-get update && sudo apt-get install -y build-essential pkg-config libssl-dev tmux jq git curl python3 python3-pip'
```

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.85.0 --profile minimal && sudo mkdir -p /var/lib/typedb-soak && sudo chown $USER /var/lib/typedb-soak'
```

### 4. Copy the soak-suite onto every VM

Tar the suite on your laptop / dev box:

```
tar czf /tmp/soak-suite.tar.gz -C ~/typedb-benchmark soak-suite
```

Push to all 4 VMs:

```
for M in soak-m1 soak-m2 soak-m3 soak-client; do gcloud compute scp /tmp/soak-suite.tar.gz $M:/tmp/ --project=$PROJECT --zone=$ZONE && gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='mkdir -p ~/typedb-benchmark && tar xzf /tmp/soak-suite.tar.gz -C ~/typedb-benchmark'; done
```

### 5. Get the `typedb_server_bin` + `typedb_admin_bin` onto each server

**Option A — build from cluster-support-feature-branch on M1, distribute:**

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='git clone https://github.com/farost/typedb-cluster.git ~/typedb-cluster && cd ~/typedb-cluster && git checkout <YOUR-3.12.0-beta-1-COMMIT-SHA> && cargo build --release -p typedb_server_bin -p typedb_admin_bin'
```

Set `$COMMIT_SHA` to whatever commit ships as 3.12.0-beta-1 — for reproducibility, tag it and use the tag.

Package + push to peers:

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='mkdir -p ~/bin && cp ~/typedb-cluster/target/release/typedb_server_bin ~/typedb-cluster/target/release/typedb_admin_bin ~/bin/ && tar czf /tmp/typedb-bins.tar.gz -C ~/bin .' && gcloud compute scp soak-m1:/tmp/typedb-bins.tar.gz /tmp/typedb-bins.tar.gz --project=$PROJECT --zone=$ZONE
```

```
for M in soak-m2 soak-m3; do gcloud compute scp /tmp/typedb-bins.tar.gz $M:/tmp/ --project=$PROJECT --zone=$ZONE && gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='mkdir -p ~/bin && tar xzf /tmp/typedb-bins.tar.gz -C ~/bin && chmod +x ~/bin/typedb_server_bin ~/bin/typedb_admin_bin'; done
```

**Option B — Cloudsmith `source = "download"`** in `config/topology.toml` with a Bearer token; the runner fetches the assembled tarball on first boot. Simpler for repeatable deploys.

### 6. Point `config/topology.toml` at the binaries and hostnames

One `sed` per machine — updates `server_bin`/`admin_bin` paths + machine hostnames:

```
for M in soak-m1 soak-m2 soak-m3 soak-client; do gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && sed -i "s|server_bin = .*|server_bin = \"$HOME/bin/typedb_server_bin\"|; s|admin_bin = .*|admin_bin = \"$HOME/bin/typedb_admin_bin\"|; s|hostname = \"soak-m1.internal\"|hostname = \"soak-m1\"|; s|hostname = \"soak-m2.internal\"|hostname = \"soak-m2\"|; s|hostname = \"soak-m3.internal\"|hostname = \"soak-m3\"|; s|hostname = \"soak-client.internal\"|hostname = \"soak-client\"|" config/topology.toml'; done
```

### 7. Build the soak-suite binaries on every VM

```
for M in soak-m1 soak-m2 soak-m3 soak-client; do gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && source ~/.cargo/env && cargo build --release --bins' & done; wait
```

### 8. Bootstrap the servers

Each server runs its own detached tmux session:

```
for M in soak-m1 soak-m2 soak-m3; do gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command="tmux new-session -d -s soak-runner \"cd ~/typedb-benchmark/soak-suite && tool/bootstrap.sh ${M#soak-} config/topology.toml /var/lib/typedb-soak/${M#soak-} 2>&1 | tee /var/lib/typedb-soak/${M#soak-}/bootstrap.tail\""; done
```

Wait ~60s, then confirm all three modes elected primaries:

```
for M in soak-m1 soak-m2 soak-m3; do echo "=== $M ==="; gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command="grep -E 'READY|ERROR|primary' /var/lib/typedb-soak/${M#soak-}/runner.log | tail -8"; done
```

## Run 1: 30-minute verification

On the client machine:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && DURATION=1800 tool/run-verify-short.sh'
```

This blocks for ~30 min + ~5 min shutdown, then prints a pass/fail report and packages an artifact bundle at `/var/lib/typedb-soak/reports/verify-short-*.tar.gz`.

Copy the bundle back:

```
gcloud compute scp soak-client:/var/lib/typedb-soak/reports/verify-short-\*.tar.gz . --project=$PROJECT --zone=$ZONE
```

The verification is judged by four criteria, **in order of severity**:

1. **`count_mismatch`** in any mode's FAILURES.log → **hard FAIL**: real consistency bug. Do not proceed to the long soak.
2. **`total_verifies_err`** > 5% of `total_verifies_ok` in `mode_1n_steady` or `mode_3n_steady` → **investigate**: steady modes shouldn't produce many verify errors. Likely a subtle server issue.
3. **Ops/s** below `min_commits_per_min` (config default 60/min, so ≥ 1/s) → **investigate**: performance regression.
4. **`server_unreachable`** in the two steady modes → **investigate**: non-chaos modes shouldn't lose reachability. Diagnose network / server crash.

`server_unreachable` in `mode_3n_chaos` is EXPECTED and does not affect pass/fail.

## Run 2: long soak (week+)

Same fleet, no CLI duration cap — clients run until killed:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/start-clients.sh'
```

Kick off a periodic health-snapshot reporter alongside so you can `tail -F` from home:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tmux new-session -d -s soak-reporter "INTERVAL=300 tool/periodic-report.sh"'
```

### Watching from home (proofreading channel)

Streamed compact status every 5 min:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='tail -F /var/lib/typedb-soak/reports/health.log'
```

Or one-shot on-demand:

```
gcloud compute ssh soak-client --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/health-snapshot.sh'
```

Chaos-server view (per-machine kill + network events):

```
gcloud compute ssh soak-m1 --project=$PROJECT --zone=$ZONE --command='grep -E "CHAOS|WATCHDOG|ERROR" /var/lib/typedb-soak/M1/runner.log | tail -60'
```

### End-of-run bundle

```
for M in soak-m1 soak-m2 soak-m3 soak-client; do gcloud compute ssh $M --project=$PROJECT --zone=$ZONE --command='cd ~/typedb-benchmark/soak-suite && tool/collect-artifacts.sh'; done
```

```
for M in soak-m1 soak-m2 soak-m3 soak-client; do gcloud compute scp $M:/tmp/soak-artifacts-\*.tar.gz . --project=$PROJECT --zone=$ZONE; done
```

## Failure taxonomy — what each `kind` in FAILURES.log means

Every entry in FAILURES.log is a JSON object with a `kind` field. The health-snapshot script groups by `kind`; the taxonomy below tells you what each one means and what to do.

| kind | severity | what it means | action |
|---|---|---|---|
| `count_mismatch` | **CRITICAL** | Read-back count differs from what the client committed. Real consistency violation. | Preserve artifacts and file a bug immediately. |
| `server_unreachable` (chaos mode) | expected | The diagnostics probe couldn't reach a node during a chaos window. | None — the recovery pattern within ~1 min tells you the cluster survived. |
| `server_unreachable` (steady mode) | high | A non-chaos node became unreachable. | Check the node's `server.log` for a crash; check `runner.log` for `[WATCHDOG]` restart events. |
| (empty FAILURES.log) | best | Everything worked. | Cross-check with STATE to confirm ops/s is healthy — silence can also mean the client stalled. |

## Green-path proofreading — how to tell a good run from a stalled one

A "good" run with no failures still needs a positive signal. Check any 2 of these:

1. **STATE.expected is growing** — snapshot at hour 0 and hour 24; the delta should be ~ops/s × 86400.
2. **STATE.last_ok_at is recent** — within the last minute for steady modes, within a few minutes for chaos mode.
3. **STATE.last_server_seen entries** — timestamps for each server refresh every diagnostics_poll_secs (default 30s). Stale entries mean the diagnostics thread died.
4. **runner.log has recent activity** — chaos mode should show new `[KILL-CHAOS]` or `[NET-CHAOS]` blocks every few minutes.
5. **Disk usage** — under `/var/lib/typedb-soak` grows over time; the disk watchdog logs `[DISK]` events at threshold. A frozen-forever disk usage suggests writes stopped.
