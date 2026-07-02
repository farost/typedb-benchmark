//! 30-minute verification mode summarizer. Run AFTER the timed test
//! completes (each client process exits on a `--duration` flag, then the
//! operator runs this on the workdir to render a pass/fail summary).

use std::{collections::BTreeMap, fs, path::Path};

use anyhow::Result;
use serde_json::Value;

use crate::{config::Topology, state::State};

pub struct ModeReport {
    pub mode_name: String,
    pub state: Option<State>,
    pub failures: Vec<Value>,
    pub commits_per_min: f64,
    pub pass_min_commits: bool,
    pub pass_no_failures: bool,
}

pub fn render(
    topo: &Topology,
    workdir_root: &Path,
    duration_secs: u64,
    min_commits_per_min: u64,
) -> Result<Vec<ModeReport>> {
    let mut reports = Vec::new();
    for mode_name in topo.modes.keys() {
        let modedir = workdir_root.join(mode_name);
        let state_path = modedir.join("STATE");
        let failures_path = modedir.join("FAILURES.log");

        let state: Option<State> = fs::read_to_string(&state_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok());
        let failures: Vec<Value> = fs::read_to_string(&failures_path)
            .ok()
            .map(|s| {
                s.lines()
                    .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                    .collect()
            })
            .unwrap_or_default();

        let commits_per_min = state
            .as_ref()
            .map(|s| (s.total_commits_ok as f64) * 60.0 / (duration_secs.max(1) as f64))
            .unwrap_or(0.0);
        let pass_min_commits = commits_per_min >= (min_commits_per_min as f64);
        // For chaos modes, "server_unreachable" failures are expected. We
        // report counts of each kind; pass requires NO `count_mismatch`
        // entries (those are real consistency bugs).
        let pass_no_failures = failures.iter().all(|f| {
            f.get("kind").and_then(Value::as_str).map(|k| k != "count_mismatch").unwrap_or(true)
        });

        reports.push(ModeReport {
            mode_name: mode_name.clone(),
            state,
            failures,
            commits_per_min,
            pass_min_commits,
            pass_no_failures,
        });
    }
    Ok(reports)
}

pub fn print_summary(reports: &[ModeReport], min_commits_per_min: u64) {
    println!("=== verification report ===");
    let mut overall_pass = true;
    for r in reports {
        println!();
        println!("--- mode: {} ---", r.mode_name);
        if let Some(s) = &r.state {
            println!(
                "  commits_ok={} commits_err={} verifies_err={} reconciliations={}",
                s.total_commits_ok, s.total_commits_err, s.total_verifies_err, s.total_reconciliations
            );
            println!("  commits/min = {:.1} (min required: {})", r.commits_per_min, min_commits_per_min);
        } else {
            println!("  (no STATE file — client may not have started or crashed before write)");
        }
        let mut by_kind: BTreeMap<&str, usize> = BTreeMap::new();
        for f in &r.failures {
            let k = f.get("kind").and_then(Value::as_str).unwrap_or("?");
            *by_kind.entry(k).or_default() += 1;
        }
        if by_kind.is_empty() {
            println!("  failures: none");
        } else {
            println!("  failures by kind:");
            for (k, n) in &by_kind {
                println!("    {k}: {n}");
            }
            // Print all count_mismatch entries (real consistency bugs).
            for f in &r.failures {
                if f.get("kind").and_then(Value::as_str) == Some("count_mismatch") {
                    println!("    !! count_mismatch: {}", serde_json::to_string(f).unwrap_or_default());
                }
            }
        }
        let pass = r.pass_min_commits && r.pass_no_failures;
        println!("  pass: throughput={} consistency={}", r.pass_min_commits, r.pass_no_failures);
        if !pass {
            overall_pass = false;
        }
    }
    println!();
    println!("=== overall: {} ===", if overall_pass { "PASS" } else { "FAIL" });
}
