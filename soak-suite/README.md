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
