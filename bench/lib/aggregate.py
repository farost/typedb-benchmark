#!/usr/bin/env python3
"""Aggregate result.json files across multiple runs of the same test.

Usage:
    aggregate.py <test_name> <out_dir> <run_id> [<run_id> ...]

For each run_id, scans `bench/results/<run_id>/bench/<mode>/result.json`,
groups by mode, and emits:

    <out_dir>/summary.md   — per-mode means / std across reps, vs typedb-core baseline
    <out_dir>/runs.tsv     — one row per (rep, mode) matching the master TSV schema

Tolerates per-rep failures: a missing result.json for a (run, mode) pair is
silently skipped and surfaced in the report as a reduced n.
"""

import json
import math
import statistics
import sys
from pathlib import Path

BENCH_RESULTS = Path(__file__).resolve().parents[1] / "results"
WORKLOADS = ["NEW_ORDER", "PAYMENT", "ORDER_STATUS", "DELIVERY", "STOCK_LEVEL"]
WL_PREFIX = {"NEW_ORDER": "NO", "PAYMENT": "PAY", "ORDER_STATUS": "OS",
             "DELIVERY": "DEL", "STOCK_LEVEL": "SL"}


def mean_std(xs):
    if not xs:
        return (math.nan, math.nan)
    if len(xs) == 1:
        return (xs[0], 0.0)
    return (statistics.mean(xs), statistics.stdev(xs))


def fmt(x, prec=1):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "—"
    return f"{x:.{prec}f}"


def load_run(run_id, mode):
    """Returns the parsed result.json dict, or None if missing/unreadable."""
    p = BENCH_RESULTS / run_id / "bench" / mode / "result.json"
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def discover_modes(run_ids):
    """Order-preserving set of all modes seen across the given runs."""
    seen = []
    for rid in run_ids:
        d = BENCH_RESULTS / rid / "bench"
        if not d.is_dir():
            continue
        for m in sorted(d.iterdir()):
            if m.is_dir() and m.name not in seen:
                seen.append(m.name)
    return seen


def summarise(test_name, run_ids):
    modes = discover_modes(run_ids)
    if not modes:
        sys.stderr.write(f"aggregate: no modes found across runs {run_ids}\n")
        sys.exit(1)

    # Per (mode, metric) collect a list of per-rep values.
    per_mode = {m: {"runs": []} for m in modes}
    for rid in run_ids:
        for m in modes:
            r = load_run(rid, m)
            if r is not None:
                per_mode[m]["runs"].append((rid, r))

    return modes, per_mode


def write_summary(test_name, out_dir, modes, per_mode):
    lines = [f"# {test_name}", ""]

    # Pull tpcc params from any one result (they're identical across reps for a test).
    # The result.json doesn't include W/SF/C/duration explicitly, but the per-rep
    # config-snapshot.yml does. We'll print what we know from the data.
    n_reps = max(len(per_mode[m]["runs"]) for m in modes) if modes else 0
    lines.append(f"_{n_reps} rep(s) per mode; modes: {', '.join(modes)}_")
    lines.append("")

    # --- Throughput table -------------------------------------------------
    lines.append("## Throughput (tpmC)")
    lines.append("")
    lines.append("| Mode | n | mean ± std | min | max | aborts (mean rate) | vs Core |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")

    # Core mean tpmC for the vs-core ratio.
    core_tpmc_mean = math.nan
    if "typedb-core" in per_mode and per_mode["typedb-core"]["runs"]:
        core_tpmcs = [r["tpmc"] for _, r in per_mode["typedb-core"]["runs"]]
        core_tpmc_mean = statistics.mean(core_tpmcs)

    for m in modes:
        runs = per_mode[m]["runs"]
        n = len(runs)
        if n == 0:
            lines.append(f"| `{m}` | 0 | (no data) | — | — | — | — |")
            continue
        tpmcs = [r["tpmc"] for _, r in runs]
        totals = [r["total"] for _, r in runs]
        aborts = [r["aborts"] for _, r in runs]
        tpmc_mean, tpmc_std = mean_std(tpmcs)
        abort_rate = [a / max(t, 1) for a, t in zip(aborts, totals)]
        ar_mean, ar_std = mean_std(abort_rate)
        vs_core = (tpmc_mean / core_tpmc_mean) if not math.isnan(core_tpmc_mean) else math.nan
        lines.append(
            f"| `{m}` | {n} | {fmt(tpmc_mean,1)} ± {fmt(tpmc_std,1)} | "
            f"{fmt(min(tpmcs),1)} | {fmt(max(tpmcs),1)} | "
            f"{fmt(statistics.mean(aborts),0)} ({fmt(ar_mean*100,1)}% ± {fmt(ar_std*100,1)}%) | "
            f"{fmt(vs_core,3)}× |"
        )
    lines.append("")

    # --- Per-workload latency tables -------------------------------------
    for wl in WORKLOADS:
        lines.append(f"## {wl} latency (ms)")
        lines.append("")
        lines.append("| Mode | n | mean p50 ± std | mean p95 ± std | mean p99 ± std | mean max |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for m in modes:
            runs = per_mode[m]["runs"]
            p50s = [r[wl]["latency"]["p50"] for _, r in runs if wl in r]
            p95s = [r[wl]["latency"]["p95"] for _, r in runs if wl in r]
            p99s = [r[wl]["latency"]["p99"] for _, r in runs if wl in r]
            maxs = [r[wl]["latency"]["max"] for _, r in runs if wl in r]
            if not p50s:
                lines.append(f"| `{m}` | 0 | — | — | — | — |")
                continue
            p50m, p50s_ = mean_std(p50s)
            p95m, p95s_ = mean_std(p95s)
            p99m, p99s_ = mean_std(p99s)
            lines.append(
                f"| `{m}` | {len(p50s)} | "
                f"{fmt(p50m)} ± {fmt(p50s_)} | "
                f"{fmt(p95m)} ± {fmt(p95s_)} | "
                f"{fmt(p99m)} ± {fmt(p99s_)} | "
                f"{fmt(statistics.mean(maxs))} |"
            )
        lines.append("")

    # --- Raw per-rep table (the receipts) --------------------------------
    lines.append("## Per-rep raw tpmC")
    lines.append("")
    lines.append("| Mode | " + " | ".join(f"rep {i+1}" for i in range(n_reps)) + " |")
    lines.append("|---|" + "---:|" * n_reps)
    for m in modes:
        runs = per_mode[m]["runs"]
        cells = []
        for i in range(n_reps):
            if i < len(runs):
                cells.append(fmt(runs[i][1]["tpmc"], 1))
            else:
                cells.append("—")
        lines.append(f"| `{m}` | " + " | ".join(cells) + " |")
    lines.append("")

    return "\n".join(lines)


TSV_HEADER = (
    "run_id\trun_date_utc\ttest_name\tmode\tduration_s\ttotal\ttpmc\ttpmc_vs_core_in_rep"
    "\taborts\tabort_rate\tretries"
)
for _wl in WORKLOADS:
    _p = WL_PREFIX[_wl]
    TSV_HEADER += f"\t{_p}_total\t{_p}_p50\t{_p}_p75\t{_p}_p90\t{_p}_p95\t{_p}_p99\t{_p}_max"


def write_tsv(test_name, out_dir, modes, per_mode):
    rows = [TSV_HEADER]
    # Build {run_id: {mode: result_dict}} for in-rep core tpmc lookup
    by_run = {}
    for m in modes:
        for rid, r in per_mode[m]["runs"]:
            by_run.setdefault(rid, {})[m] = r

    for rid in sorted(by_run):
        core_in_rep = by_run[rid].get("typedb-core", {}).get("tpmc", math.nan)
        date = rid[:8]
        date = f"{date[:4]}-{date[4:6]}-{date[6:8]}"
        for m in modes:
            r = by_run[rid].get(m)
            if r is None:
                continue
            tpmc = r["tpmc"]
            vs_core = (tpmc / core_in_rep) if core_in_rep else math.nan
            row = [
                rid, date, test_name, m,
                f"{r['duration']:.1f}", str(r["total"]), f"{tpmc:.2f}",
                f"{vs_core:.3f}", str(r["aborts"]),
                f"{r['aborts']/max(r['total'],1):.4f}", str(r.get("total_retries", 0)),
            ]
            for wl in WORKLOADS:
                lat = r[wl]["latency"]
                row += [str(r[wl]["total"]),
                        f"{lat['p50']:.1f}", f"{lat['p75']:.1f}", f"{lat['p90']:.1f}",
                        f"{lat['p95']:.1f}", f"{lat['p99']:.1f}", f"{lat['max']:.1f}"]
            rows.append("\t".join(row))
    return "\n".join(rows) + "\n"


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__ or "")
        sys.exit(2)
    test_name = sys.argv[1]
    out_dir = Path(sys.argv[2])
    run_ids = sys.argv[3:]
    out_dir.mkdir(parents=True, exist_ok=True)

    modes, per_mode = summarise(test_name, run_ids)
    md = write_summary(test_name, out_dir, modes, per_mode)
    tsv = write_tsv(test_name, out_dir, modes, per_mode)

    (out_dir / "summary.md").write_text(md)
    (out_dir / "runs.tsv").write_text(tsv)
    sys.stderr.write(f"aggregate: wrote {out_dir / 'summary.md'} and {out_dir / 'runs.tsv'}\n")


if __name__ == "__main__":
    main()
