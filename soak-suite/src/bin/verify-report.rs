//! Post-run summarizer. Run AFTER a `--duration-secs N` client run completes:
//! walks each mode's workdir, reads STATE + FAILURES.log, prints a pass/fail
//! report and all `count_mismatch` records (real consistency violations).

use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;

use typedb_soak_suite::{config, verification};

#[derive(Parser, Debug)]
#[command(version, about = "render the soak verification report")]
struct Args {
    #[arg(long)]
    config: PathBuf,
    /// The same workdir-root passed to the client (usually the parent of
    /// the per-mode dirs).
    #[arg(long)]
    workdir: PathBuf,
    #[arg(long, default_value = "1800")]
    duration_secs: u64,
    #[arg(long, default_value = "60")]
    min_commits_per_min: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let topo = config::load(&args.config)?;
    let reports = verification::render(&topo, &args.workdir, args.duration_secs, args.min_commits_per_min)?;
    verification::print_summary(&reports, args.min_commits_per_min);
    let any_fail = reports.iter().any(|r| !r.pass_min_commits || !r.pass_no_failures);
    if any_fail {
        std::process::exit(2);
    }
    Ok(())
}
