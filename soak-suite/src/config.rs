//! TOML topology config. One file shared across all machines; each machine
//! filters by its --machine label at runtime.

use std::{collections::BTreeMap, fs, path::Path};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Topology {
    pub binary: Binary,
    pub machines: BTreeMap<String, Machine>,
    pub modes: BTreeMap<String, Mode>,
    #[serde(default)]
    pub chaos: ChaosConfig,
    #[serde(default)]
    pub disk: DiskConfig,
    #[serde(default)]
    pub verification: VerificationConfig,
    #[serde(default)]
    pub client: ClientConfig,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Binary {
    /// "local" | "download"
    pub source: String,
    /// For local: path to typedb_server_bin
    pub server_bin: Option<String>,
    /// For local: path to typedb_admin_bin
    pub admin_bin: Option<String>,
    /// For download: tarball URL
    pub download_url: Option<String>,
    /// For download: where to cache the extracted archive
    pub download_cache_dir: Option<String>,
    /// For download: optional Authorization header value (literal, e.g.
    /// "Bearer XXX" or "Basic XXX"). Use env var like
    /// `${CLOUDSMITH_TOKEN}` — we substitute at load time.
    pub download_auth_header: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Machine {
    /// Hostname or IP, as seen from OTHER machines (advertise address).
    pub hostname: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Mode {
    /// Free-form label, e.g. "Single Node" — for logs/dashboards.
    pub description: Option<String>,
    /// Per-mode database name (defaults to the mode key if omitted).
    pub database: Option<String>,
    /// Per-(mode,node-id) port allocation + machine assignment.
    pub nodes: BTreeMap<String, NodeAssignment>,
    /// When true, the runner spawns chaos + network_chaos threads on this
    /// mode's local nodes.
    #[serde(default)]
    pub chaos_enabled: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct NodeAssignment {
    pub machine: String,
    pub grpc_port: u16,
    pub clustering_port: u16,
    pub monitoring_port: u16,
    pub http_port: u16,
}

#[derive(Debug, Deserialize, Serialize, Clone, Default)]
pub struct ChaosConfig {
    pub kill: KillChaosConfig,
    pub network: NetworkChaosConfig,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct KillChaosConfig {
    pub min_alive_secs: u64,
    pub max_alive_secs: u64,
    pub min_dead_secs: u64,
    pub max_dead_secs: u64,
}

impl Default for KillChaosConfig {
    fn default() -> Self {
        Self { min_alive_secs: 60, max_alive_secs: 300, min_dead_secs: 5, max_dead_secs: 30 }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct NetworkChaosConfig {
    pub min_clean_secs: u64,
    pub max_clean_secs: u64,
    pub min_dirty_secs: u64,
    pub max_dirty_secs: u64,
    /// Network interface to apply tc rules to (e.g. "lo" for local testing,
    /// "eth0" for typical Linux deployments).
    pub interface: String,
    /// Min/max packet drop probability when DROP is selected.
    pub drop_probability: (f64, f64),
    /// Min/max delay (ms) for DELAY impairment.
    pub delay_ms: (u64, u64),
    /// Min/max jitter (ms) for DELAY impairment.
    pub jitter_ms: (u64, u64),
    /// Whether the sudo helper is needed for iptables/tc (true in production;
    /// false if the user is root / capabilities are granted).
    #[serde(default)]
    pub use_sudo: bool,
}

impl Default for NetworkChaosConfig {
    fn default() -> Self {
        Self {
            min_clean_secs: 60,
            max_clean_secs: 300,
            min_dirty_secs: 10,
            max_dirty_secs: 60,
            interface: "lo".to_string(),
            drop_probability: (0.05, 0.30),
            delay_ms: (50, 500),
            jitter_ms: (10, 100),
            use_sudo: true,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DiskConfig {
    pub warn_percent: u8,
    pub check_interval_secs: u64,
}

impl Default for DiskConfig {
    fn default() -> Self {
        Self { warn_percent: 80, check_interval_secs: 60 }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct VerificationConfig {
    pub duration_secs: u64,
    pub min_commits_per_min: u64,
}

impl Default for VerificationConfig {
    fn default() -> Self {
        Self { duration_secs: 1800, min_commits_per_min: 60 }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ClientConfig {
    pub diagnostics_poll_secs: u64,
    pub status_log_every_secs: u64,
    pub max_reconnect_backoff_ms: u64,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self { diagnostics_poll_secs: 30, status_log_every_secs: 60, max_reconnect_backoff_ms: 5000 }
    }
}

pub fn load(path: &Path) -> Result<Topology> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut topo: Topology = toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))?;
    // Resolve env-var substitutions in download_auth_header.
    if let Some(h) = topo.binary.download_auth_header.as_mut() {
        *h = substitute_env(h);
    }
    validate(&topo)?;
    Ok(topo)
}

fn substitute_env(s: &str) -> String {
    // Replace ${VAR} with env lookup. Missing vars → empty string (logged).
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let var = &after[..end];
        match std::env::var(var) {
            Ok(v) => out.push_str(&v),
            Err(_) => eprintln!("[soak] config: env var ${{{var}}} not set; substituting empty string"),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

fn validate(t: &Topology) -> Result<()> {
    // Every mode's node must reference a known machine; ports must be unique
    // within each machine across modes.
    let mut port_owners: BTreeMap<(String, u16), String> = BTreeMap::new(); // (machine, port) -> label
    for (mode_name, mode) in &t.modes {
        for (node_id, node) in &mode.nodes {
            if !t.machines.contains_key(&node.machine) {
                bail!("mode '{mode_name}' node '{node_id}' references unknown machine '{}'", node.machine);
            }
            for (port, role) in [
                (node.grpc_port, "grpc"),
                (node.clustering_port, "clustering"),
                (node.monitoring_port, "monitoring"),
                (node.http_port, "http"),
            ] {
                let key = (node.machine.clone(), port);
                let label = format!("{mode_name}/node{node_id}/{role}");
                if let Some(existing) = port_owners.get(&key) {
                    bail!(
                        "port conflict on machine '{}': port {port} claimed by both '{}' and '{}'",
                        node.machine,
                        existing,
                        label
                    );
                }
                port_owners.insert(key, label);
            }
        }
    }
    if t.binary.source != "local" && t.binary.source != "download" {
        bail!("binary.source must be \"local\" or \"download\" (got {:?})", t.binary.source);
    }
    if t.binary.source == "local" {
        if t.binary.server_bin.is_none() || t.binary.admin_bin.is_none() {
            bail!("binary.source = \"local\" requires server_bin and admin_bin paths");
        }
    } else if t.binary.download_url.is_none() {
        bail!("binary.source = \"download\" requires download_url");
    }
    Ok(())
}

impl Topology {
    /// All (mode, node_id) pairs that should run on `machine`.
    pub fn nodes_on(&self, machine: &str) -> Vec<NodeOnMachine<'_>> {
        let mut out = Vec::new();
        for (mode_name, mode) in &self.modes {
            for (node_id, node) in &mode.nodes {
                if node.machine == machine {
                    out.push(NodeOnMachine {
                        mode_name: mode_name.as_str(),
                        mode,
                        node_id: node_id.parse::<u32>().unwrap_or_else(|_| {
                            panic!("node id '{node_id}' for mode {mode_name} is not a u32")
                        }),
                        node,
                    });
                }
            }
        }
        out
    }

    pub fn database_name<'a>(&'a self, mode_name: &'a str) -> &'a str {
        self.modes
            .get(mode_name)
            .and_then(|m| m.database.as_deref())
            .unwrap_or(mode_name)
    }

    pub fn client_addresses(&self, mode_name: &str) -> Vec<String> {
        let mode = self.modes.get(mode_name).expect("mode exists");
        mode.nodes
            .values()
            .map(|n| {
                let machine = self.machines.get(&n.machine).expect("machine exists");
                format!("{}:{}", machine.hostname, n.grpc_port)
            })
            .collect()
    }
}

#[derive(Debug)]
pub struct NodeOnMachine<'a> {
    pub mode_name: &'a str,
    pub mode: &'a Mode,
    pub node_id: u32,
    pub node: &'a NodeAssignment,
}
