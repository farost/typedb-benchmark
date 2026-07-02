//! Tiny logger: timestamped lines to a file + mirrored to stderr.

use std::{
    fs,
    io::Write,
    path::Path,
};

pub fn line(log_path: &Path, msg: &str) {
    let line = format!("{} {msg}\n", chrono::Utc::now().to_rfc3339());
    if let Some(parent) = log_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(log_path) {
        let _ = f.write_all(line.as_bytes());
    }
    eprint!("{line}");
}

/// Same as `line` but prefixed with a tag (e.g., "CHAOS", "DISK", "NET")
/// so a grep on the runner log finds all of a subsystem's events.
pub fn tagged(log_path: &Path, tag: &str, msg: &str) {
    line(log_path, &format!("[{tag}] {msg}"));
}

/// Loud error — prefixed with ERROR so it stands out in a tail.
pub fn loud_error(log_path: &Path, tag: &str, msg: &str) {
    line(log_path, &format!("!!!!! ERROR [{tag}] {msg}"));
}
