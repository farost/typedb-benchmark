#!/usr/bin/env python3
"""
Read every bench/<mode>/result.json under a run dir and write a single
markdown summary that compares them side-by-side.

The metric set is what tpcc.py emits per-workload:
  total transactions, tpmc, latency (p50/p75/p90/p95/p99/max), aborts, retries.

Usage: compare.py <run_dir>

Outputs to <run_dir>/comparison.md.
"""
import json
import sys
from pathlib import Path

# tpcc workload txn types we expect across the dict. Picked to match the
# uppercase keys tpcc.py produces.
WORKLOADS = ["NEW_ORDER", "PAYMENT", "ORDER_STATUS", "DELIVERY", "STOCK_LEVEL"]


def load_results(run_dir: Path):
    """Return list of (mode_name, result_dict). Modes with no result are skipped."""
    out = []
    bench_dir = run_dir / "bench"
    if not bench_dir.is_dir():
        return out
    for mode_dir in sorted(bench_dir.iterdir()):
        rj = mode_dir / "result.json"
        if rj.is_file():
            with rj.open() as f:
                out.append((mode_dir.name, json.load(f)))
    return out


def fmt_ms(v):
    if v is None:
        return "—"
    return f"{v:.1f}"


def summary_table(results):
    lines = []
    lines.append("| Mode | total | tpmc | aborts | retries | duration |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for name, r in results:
        lines.append(
            f"| `{name}` | {r.get('total','?')} | "
            f"{r.get('tpmc',0):.2f} | {r.get('aborts','?')} | "
            f"{r.get('total_retries','?')} | {r.get('duration',0):.1f}s |"
        )
    return "\n".join(lines)


def latency_table(results, workload):
    """Per-workload table: rows are modes, columns are p50..p99 ms."""
    lines = []
    lines.append(f"#### {workload}")
    lines.append("")
    lines.append("| Mode | total | p50 | p75 | p90 | p95 | p99 | max |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    saw_any = False
    for name, r in results:
        w = r.get(workload)
        if not w:
            continue
        saw_any = True
        lat = w.get("latency", {})
        lines.append(
            f"| `{name}` | {w.get('total','?')} | "
            f"{fmt_ms(lat.get('p50'))} | {fmt_ms(lat.get('p75'))} | "
            f"{fmt_ms(lat.get('p90'))} | {fmt_ms(lat.get('p95'))} | "
            f"{fmt_ms(lat.get('p99'))} | {fmt_ms(lat.get('max'))} |"
        )
    if not saw_any:
        return ""
    return "\n".join(lines)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: compare.py <run_dir>")
    run_dir = Path(sys.argv[1])
    results = load_results(run_dir)
    if not results:
        raise SystemExit(f"no bench results under {run_dir}/bench/")

    md = []
    md.append(f"# TPC-C benchmark comparison")
    md.append("")
    md.append(f"Run directory: `{run_dir}`")
    cfg_snapshot = run_dir / "config-snapshot.yml"
    if cfg_snapshot.is_file():
        md.append(f"Config used: [`config-snapshot.yml`](config-snapshot.yml)")
    md.append("")
    md.append("## Overall throughput")
    md.append("")
    md.append("`tpmc` = transactions completed per *measured minute* during execute. "
              "Higher is better. `aborts` and `total_retries` should be zero for a "
              "healthy run — non-zero values invalidate the latency numbers.")
    md.append("")
    md.append(summary_table(results))
    md.append("")
    md.append("## Latency by workload (ms)")
    md.append("")
    md.append("TPC-C runs 5 transaction types in a fixed mix (~45% NEW_ORDER, ~43% "
              "PAYMENT, ~4% each of the read-mostly ones). Per-workload p50/p99 "
              "tells you whether one mode degrades a specific path.")
    md.append("")
    for w in WORKLOADS:
        t = latency_table(results, w)
        if t:
            md.append(t)
            md.append("")

    out = run_dir / "comparison.md"
    out.write_text("\n".join(md))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
