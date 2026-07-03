# GCP deploy scripts

End-to-end wrappers around `gcloud compute` for the 4-machine soak fleet.

Every script is **idempotent** — safe to re-run after a hiccup, skips work that's already done. Every script logs to stderr with green ✓ / yellow ! / red ✗ markers.

## Prerequisites (on your workstation)

- `gcloud` CLI, authenticated, with permission to create VMs + firewall rules in `$PROJECT`.
- The soak-suite tarballed from this repo checkout (`tool/gcp/02-ship-suite.sh` does this).
- A GitHub PAT with read access to `typedb/typedb-cluster` (only needed for `03-build-binaries.sh`).

## Env vars

Set once at the top of your shell:

```
export PROJECT=<gcp-project>
export ZONE=us-central1-a
export NETWORK=default        # optional (default: default)
export SUBNET=default         # optional
export TYPEDB_TAG=3.12.0-beta-1   # or a SHA; default 3.12.0-beta-1
export TYPEDB_REPO=typedb/typedb-cluster   # optional; override for a fork
export GITHUB_TOKEN=<pat>
export SIZING=verification    # or "long-soak"; default "verification"
```

## The scripts

| # | Script | Purpose | Roughly |
|---|---|---|---|
| 00 | `00-create-vms.sh` | Create 4 VMs + firewall rule (idempotent) | 30 s |
| 01 | `01-install-prereqs.sh` | apt + rustup + sudoers + (long-soak) mount data disk | 4–5 min |
| 02 | `02-ship-suite.sh` | tar this checkout's `soak-suite/` to all VMs | 30 s |
| 03 | `03-build-binaries.sh` | Clone typedb-cluster on M1 at `$TYPEDB_TAG`, cargo build, distribute | 20–30 min |
| 04 | `04-configure.sh` | Patch `config/topology.toml` on each VM | 15 s |
| 05 | `05-build-soak.sh` | cargo build soak-suite bins on every VM | 5–10 min |
| 06 | `06-bootstrap.sh` | Start runners under tmux, poll until READY | 1–2 min |
| 07 | `07-verify-short.sh` | Kick off 30-min verification on the client | starts async |
| 08 | `08-start-long-soak.sh` | Kick off forever-mode soak + periodic reporter | starts async |
| 09 | `09-teardown.sh` | Delete VMs + firewall + data disks (needs `CONFIRM=yes`) | 30 s |
| — | `deploy.sh` | Run 00 → 06 in sequence | ~40 min |

## Recommended sequence

**First time on a fresh GCP project:**

```
tool/gcp/deploy.sh
```

That's the whole setup. When it says "fleet is READY", pick your run type:

**Short verification (30 min):**

```
FOLLOW=1 tool/gcp/07-verify-short.sh
```

`FOLLOW=1` tails the stdout live; drop it to detach. Verification produces a PASS/FAIL summary + artifact bundle at `/var/lib/typedb-soak/reports/verify-short-*.tar.gz` on the client.

**Long soak (week+):**

Only after short verification passes.

```
tool/gcp/08-start-long-soak.sh
```

Watch from home:

```
gcloud compute ssh $CLIENT --project=$PROJECT --zone=$ZONE --command='tail -F /var/lib/typedb-soak/reports/health.log'
```

**Teardown:**

```
CONFIRM=yes tool/gcp/09-teardown.sh
```

## Re-running a single step

Every step is idempotent. If prereqs installed but the build failed, just:

```
tool/gcp/03-build-binaries.sh
```

If the config drifted:

```
tool/gcp/04-configure.sh && tool/gcp/06-bootstrap.sh
```

## Sizing

Set `SIZING=verification` (default) or `SIZING=long-soak` before running `00-create-vms.sh`. Full sizing table in `soak-suite/README.md`.

| | Verification | Long soak |
|---|---|---|
| Server type | n2-standard-4 (4 vCPU / 16 GB) | n2-standard-8 (8 vCPU / 32 GB) |
| Server boot | 100 GB pd-ssd | 50 GB pd-ssd |
| Server data | — | 500 GB pd-ssd @ /var/lib/typedb-soak |
| Client type | e2-standard-2 | e2-standard-4 |
| Cost, 30 min | < $1 | — |
| Cost, 1 week | — | ~$140 |
| Cost, 4 weeks | — | ~$560 |
