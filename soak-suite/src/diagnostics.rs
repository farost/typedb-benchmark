//! Client-side diagnostics scraper. Polls each server's `/diagnostics`
//! endpoint (Prometheus + JSON via `?format=json`) and one bare TCP connect
//! to the gRPC port to test reach. Records the last successful poll time
//! per server in STATE; logs unreachable transitions to FAILURES.log so
//! the operator can correlate with chaos windows.

use std::{
    net::TcpStream,
    path::Path,
    process::Command,
    sync::{Arc, Mutex},
    time::Duration,
};

use chrono::Utc;
use serde_json::Value;

use crate::{
    log,
    state::{FailureRecord, State, append_failure},
};

#[derive(Debug, Clone)]
pub struct ServerEndpoint {
    pub label: String,         // e.g., "M1/node1"
    pub host: String,          // hostname or IP
    pub grpc_port: u16,
    pub monitoring_port: u16,
}

pub fn run_diagnostics_loop(
    endpoints: Vec<ServerEndpoint>,
    state: Arc<Mutex<State>>,
    state_path: &Path,
    failures_path: &Path,
    diagnostics_log: &Path,
    poll_interval: Duration,
    shutdown: Arc<std::sync::atomic::AtomicBool>,
) {
    use std::sync::atomic::Ordering;
    log::tagged(
        diagnostics_log,
        "DIAG",
        &format!("polling {} endpoints every {poll_interval:?}", endpoints.len()),
    );
    // Track whether each server was up last cycle; log transitions only.
    let mut prev_up: std::collections::BTreeMap<String, bool> = endpoints.iter().map(|e| (e.label.clone(), true)).collect();
    while !shutdown.load(Ordering::Relaxed) {
        for ep in &endpoints {
            let grpc_ok = TcpStream::connect_timeout(
                &format!("{}:{}", ep.host, ep.grpc_port).parse().unwrap(),
                Duration::from_secs(5),
            )
            .is_ok();
            let diag = poll_diagnostics(&ep.host, ep.monitoring_port);
            let up = grpc_ok && diag.is_some();
            let was_up = *prev_up.get(&ep.label).unwrap_or(&true);
            if up {
                state.lock().unwrap().last_server_seen.insert(ep.label.clone(), Utc::now());
                if !was_up {
                    log::tagged(
                        diagnostics_log,
                        "DIAG",
                        &format!("server {} RECOVERED (grpc + diagnostics ok)", ep.label),
                    );
                }
            } else {
                if was_up {
                    log::tagged(
                        diagnostics_log,
                        "DIAG",
                        &format!(
                            "server {} UNREACHABLE (grpc={grpc_ok}, diag_ok={})",
                            ep.label,
                            diag.is_some()
                        ),
                    );
                    // Treat as informational, not a hard failure — chaos kills
                    // legitimately cause these. The operator's job is to spot
                    // patterns: did the client see recovery within ~minute?
                    append_failure(
                        failures_path,
                        FailureRecord {
                            at: Utc::now(),
                            kind: "server_unreachable".into(),
                            expected: -1,
                            observed: None,
                            details: serde_json::json!({
                                "server": ep.label,
                                "host": ep.host,
                                "grpc_port": ep.grpc_port,
                                "monitoring_port": ep.monitoring_port,
                                "grpc_ok": grpc_ok,
                                "diagnostics_ok": diag.is_some(),
                            }),
                        },
                    );
                }
            }
            prev_up.insert(ep.label.clone(), up);
        }
        // Save state after each pass so the operator sees the latest seens.
        let _ = state.lock().unwrap().save_atomic(state_path);
        std::thread::sleep(poll_interval);
    }
}

fn poll_diagnostics(host: &str, port: u16) -> Option<Value> {
    let url = format!("http://{host}:{port}/diagnostics?format=json");
    let out = Command::new("curl").args(["-sS", "--max-time", "5", &url]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}
