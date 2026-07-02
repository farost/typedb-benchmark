//! Disk-space watchdog. Warns loudly when any monitored path's filesystem
//! crosses the warn threshold. Never halts — we want a full week of data
//! even if the disk is filling up. Operator decides what to do with the
//! ERROR lines.

use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::{Arc, atomic::{AtomicBool, Ordering}},
    thread,
    time::Duration,
};

use crate::log;

pub struct DiskWatchdog {
    pub paths: Vec<PathBuf>,
    pub warn_percent: u8,
    pub interval: Duration,
    pub runner_log: PathBuf,
}

impl DiskWatchdog {
    pub fn spawn(self, shutdown: Arc<AtomicBool>) {
        thread::spawn(move || self.run(shutdown));
    }
    fn run(self, shutdown: Arc<AtomicBool>) {
        // Track most-recent warn state per path so we don't spam every
        // interval; re-warn only when usage climbs further.
        let mut last_warned_pct: std::collections::BTreeMap<PathBuf, u8> = Default::default();
        log::tagged(
            &self.runner_log,
            "DISK",
            &format!("watchdog started: warn={}%, paths={:?}", self.warn_percent, self.paths),
        );
        while !shutdown.load(Ordering::Relaxed) {
            for path in &self.paths {
                if !path.exists() {
                    continue;
                }
                match used_percent(path) {
                    Some(pct) => {
                        if pct >= self.warn_percent {
                            let bump = last_warned_pct.get(path).copied().unwrap_or(0);
                            if pct > bump || (pct >= self.warn_percent && bump < self.warn_percent) {
                                log::loud_error(
                                    &self.runner_log,
                                    "DISK",
                                    &format!(
                                        "Disk usage HIGH on {}: {}% (warn at {}%) — investigate, free space, or expect a crash soon",
                                        path.display(),
                                        pct,
                                        self.warn_percent
                                    ),
                                );
                                last_warned_pct.insert(path.clone(), pct);
                            }
                        }
                    }
                    None => {
                        // df failed; not fatal but worth noting.
                        log::tagged(
                            &self.runner_log,
                            "DISK",
                            &format!("could not read disk usage for {}", path.display()),
                        );
                    }
                }
            }
            thread::sleep(self.interval);
        }
        log::tagged(&self.runner_log, "DISK", "watchdog shutting down");
    }
}

fn used_percent(path: &Path) -> Option<u8> {
    // Use `df --output=pcent` for portability; parse the integer percentage.
    let out = Command::new("df").args(["--output=pcent", &path.display().to_string()]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut lines = s.lines();
    let _header = lines.next();
    let pct_line = lines.next()?.trim().trim_end_matches('%');
    pct_line.parse().ok()
}
