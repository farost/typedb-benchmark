//! STATE (live, atomic-rewritten per iteration) + FAILURES.log (append-only,
//! JSONL, one record per consistency violation or environmental issue).

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    pub mode: String,
    pub started_at: DateTime<Utc>,
    pub last_ok_at: Option<DateTime<Utc>>,
    pub expected: i64,
    pub total_commits_ok: u64,
    pub total_commits_err: u64,
    pub total_verifies_ok: u64,
    pub total_verifies_err: u64,
    pub total_reconciliations: u64,
    /// Liveness summary updated by the diagnostics poller. Map of
    /// "addr" -> last successful poll time.
    #[serde(default)]
    pub last_server_seen: std::collections::BTreeMap<String, DateTime<Utc>>,
}

impl State {
    pub fn new(mode: &str) -> Self {
        Self {
            mode: mode.to_string(),
            started_at: Utc::now(),
            last_ok_at: None,
            expected: 0,
            total_commits_ok: 0,
            total_commits_err: 0,
            total_verifies_ok: 0,
            total_verifies_err: 0,
            total_reconciliations: 0,
            last_server_seen: Default::default(),
        }
    }

    pub fn load_or_new(path: &Path, mode: &str) -> Self {
        match fs::read_to_string(path) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_else(|err| {
                eprintln!("[soak] STATE at {} unreadable ({err}); starting fresh", path.display());
                Self::new(mode)
            }),
            Err(_) => Self::new(mode),
        }
    }

    /// Atomic rewrite via tempfile + rename. POSIX rename is atomic on same fs.
    /// Uses a per-thread, unique tmp name so concurrent writers (e.g., main
    /// loop + diagnostics thread) don't truncate each other's tmp file.
    pub fn save_atomic(&self, path: &Path) -> std::io::Result<()> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let pid = std::process::id();
        let tid = COUNTER.fetch_add(1, Ordering::Relaxed);
        let tmp = path.with_file_name(format!(
            "{}.tmp.{pid}.{tid}",
            path.file_name().and_then(|s| s.to_str()).unwrap_or("STATE")
        ));
        let mut f = fs::File::create(&tmp)?;
        let s = serde_json::to_string_pretty(self).expect("state json");
        f.write_all(s.as_bytes())?;
        f.write_all(b"\n")?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FailureRecord {
    pub at: DateTime<Utc>,
    pub kind: String,
    pub expected: i64,
    pub observed: Option<i64>,
    pub details: serde_json::Value,
}

pub fn append_failure(failures_path: &Path, record: FailureRecord) {
    if let Some(parent) = failures_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let line = serde_json::to_string(&record).expect("failure json");
    match fs::OpenOptions::new().create(true).append(true).open(failures_path) {
        Ok(mut f) => {
            let _ = writeln!(f, "{line}");
            let _ = f.sync_all();
        }
        Err(e) => {
            eprintln!("[soak] FAILED to append to {} ({e}): {line}", failures_path.display());
        }
    }
}

pub fn workdir_paths(workdir: &Path) -> WorkdirPaths {
    WorkdirPaths {
        state: workdir.join("STATE"),
        failures: workdir.join("FAILURES.log"),
        client_log: workdir.join("client.log"),
        diagnostics_log: workdir.join("diagnostics.log"),
    }
}

pub struct WorkdirPaths {
    pub state: PathBuf,
    pub failures: PathBuf,
    pub client_log: PathBuf,
    pub diagnostics_log: PathBuf,
}
