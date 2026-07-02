//! Per-machine kill-chaos thread for chaos-enabled modes.
//!
//! Picks one of this machine's chaos-mode nodes every alive_period, kills,
//! waits dead_period, restarts. Loud start/stop logs to runner.log so a
//! later FAILURES.log entry can be correlated against chaos windows.

use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use rand::{Rng, thread_rng};

use crate::{
    cluster::Node,
    config::KillChaosConfig,
    log,
};

pub fn run_kill_loop(
    mode_name: String,
    nodes: Arc<Mutex<Vec<Node>>>,
    cfg: KillChaosConfig,
    runner_log: PathBuf,
) -> ! {
    log::tagged(
        &runner_log,
        "KILL-CHAOS",
        &format!(
            "thread started for mode='{mode_name}' alive={}-{}s dead={}-{}s",
            cfg.min_alive_secs, cfg.max_alive_secs, cfg.min_dead_secs, cfg.max_dead_secs
        ),
    );
    loop {
        let mut rng = thread_rng();
        let alive = rng.r#gen_range(cfg.min_alive_secs..=cfg.max_alive_secs);
        thread::sleep(Duration::from_secs(alive));

        // Index of our local node(s) belonging to this mode.
        let target_index = {
            let guard = nodes.lock().unwrap();
            let candidates: Vec<usize> = guard
                .iter()
                .enumerate()
                .filter(|(_, n)| n.mode_name == mode_name)
                .map(|(i, _)| i)
                .collect();
            if candidates.is_empty() {
                continue;
            }
            candidates[rng.r#gen_range(0..candidates.len())]
        };

        let label = {
            let guard = nodes.lock().unwrap();
            guard[target_index].label()
        };
        log::tagged(&runner_log, "KILL-CHAOS", &format!("kill {label} (will stay dead for some time)"));
        // Hold the lock only long enough to kill the child (fast).
        if let Err(e) = nodes.lock().unwrap()[target_index].kill() {
            log::loud_error(&runner_log, "KILL-CHAOS", &format!("kill {label} failed: {e}"));
        }

        let dead = rng.r#gen_range(cfg.min_dead_secs..=cfg.max_dead_secs);
        thread::sleep(Duration::from_secs(dead));

        log::tagged(&runner_log, "KILL-CHAOS", &format!("restart {label} after {dead}s downtime"));
        // spawn() does filesystem + Command::spawn — keep the lock short.
        if let Err(e) = nodes.lock().unwrap()[target_index].spawn() {
            log::loud_error(&runner_log, "KILL-CHAOS", &format!("restart {label} failed: {e}"));
        }

        // Out-of-cycle crash detection: any node in our mode that died
        // outside of a chaos kill = real bug. Snapshot the indices to
        // restart, then drop the lock before spawning each one.
        let to_restart: Vec<(usize, String)> = {
            let mut guard = nodes.lock().unwrap();
            let mut out = Vec::new();
            for (i, n) in guard.iter_mut().enumerate() {
                if i == target_index || n.mode_name != mode_name {
                    continue;
                }
                if !n.is_alive() {
                    out.push((i, n.label()));
                }
            }
            out
        };
        for (i, label) in to_restart {
            log::loud_error(
                &runner_log,
                "KILL-CHAOS",
                &format!("WARN {label} died outside chaos (real crash); restarting"),
            );
            if let Err(e) = nodes.lock().unwrap()[i].spawn() {
                log::loud_error(
                    &runner_log,
                    "KILL-CHAOS",
                    &format!("restart after real crash failed for {label}: {e}"),
                );
            }
        }
    }
}
