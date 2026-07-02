//! Per-machine subprocess management. Spawns the nodes assigned to this
//! machine across all modes, registers peers, supervises restart-on-crash
//! (in non-chaos modes).

use std::{
    fs,
    net::TcpStream,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};

use crate::{
    binary::Binaries,
    config::{NodeAssignment, NodeOnMachine, Topology},
    log,
};

#[derive(Debug)]
pub struct Node {
    pub mode_name: String,
    pub node_id: u32,
    pub work_dir: PathBuf,
    pub assignment: NodeAssignment,
    /// The hostname this machine advertises to peers (e.g. "soak-m1.internal").
    /// Used for --server.advertise-address and --server.clustering.address.
    pub advertise_host: String,
    pub binaries: Binaries,
    pub child: Option<Child>,
}

impl Node {
    pub fn data_dir(&self) -> PathBuf {
        self.work_dir.join("data")
    }
    pub fn clustering_dir(&self) -> PathBuf {
        self.work_dir.join("clustering")
    }
    pub fn log_dir(&self) -> PathBuf {
        self.work_dir.join("logs")
    }
    pub fn admin_socket(&self) -> PathBuf {
        self.data_dir().join("admin.sock")
    }
    pub fn server_stdout_log(&self) -> PathBuf {
        self.work_dir.join("server.log")
    }
    pub fn label(&self) -> String {
        format!("{}/node{}", self.mode_name, self.node_id)
    }

    pub fn is_alive(&mut self) -> bool {
        match &mut self.child {
            Some(c) => matches!(c.try_wait(), Ok(None)),
            None => false,
        }
    }

    pub fn spawn(&mut self) -> Result<()> {
        if self.is_alive() {
            return Ok(());
        }
        for d in [self.data_dir(), self.clustering_dir(), self.log_dir()] {
            fs::create_dir_all(&d).with_context(|| format!("mkdir {}", d.display()))?;
        }
        let server_log = self.server_stdout_log();
        let stdout = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&server_log)
            .with_context(|| format!("open {}", server_log.display()))?;
        let stderr = stdout.try_clone()?;

        let args = self.server_args();
        let child = Command::new(&self.binaries.server_bin)
            .args(&args)
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
            .with_context(|| format!("spawn {}", self.binaries.server_bin.display()))?;
        self.child = Some(child);
        Ok(())
    }

    pub fn kill(&mut self) -> Result<()> {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        Ok(())
    }

    fn server_args(&self) -> Vec<String> {
        let id = self.node_id;
        let a = &self.assignment;
        let host = &self.advertise_host;
        let data = self.data_dir().display().to_string();
        let clustering = self.clustering_dir().display().to_string();
        let admin = self.admin_socket().display().to_string();
        let log_dir = self.log_dir().display().to_string();
        vec![
            format!("--diagnostics.deployment-id=soak-{}", self.mode_name),
            format!("--server.listen-address=0.0.0.0:{}", a.grpc_port),
            format!("--server.advertise-address={host}:{}", a.grpc_port),
            "--server.http.enabled=true".to_string(),
            format!("--server.http.listen-address=0.0.0.0:{}", a.http_port),
            format!("--server.http.advertise-address=http://{host}:{}", a.http_port),
            "--server.admin.enabled=true".to_string(),
            format!("--server.admin.socket-path={admin}"),
            format!("--server.clustering.id={id}"),
            format!("--server.clustering.address={host}:{}", a.clustering_port),
            format!("--storage.data-directory={data}"),
            format!("--storage.clustering-directory={clustering}"),
            format!("--diagnostics.monitoring.port={}", a.monitoring_port),
            "--server.encryption.enabled=false".to_string(),
            "--server.clustering.encryption.enabled=false".to_string(),
            "--development-mode.enabled=true".to_string(),
            format!("--logging.directory={log_dir}"),
        ]
    }
}

pub fn build_nodes_for_machine(
    topo: &Topology,
    machine: &str,
    workdir_root: &Path,
    binaries: &Binaries,
) -> Result<Vec<Node>> {
    let advertise_host = topo
        .machines
        .get(machine)
        .ok_or_else(|| anyhow!("unknown machine '{machine}'"))?
        .hostname
        .clone();
    let mut nodes = Vec::new();
    for NodeOnMachine { mode_name, mode: _, node_id, node } in topo.nodes_on(machine) {
        let work_dir = workdir_root.join(mode_name).join(format!("node{node_id}"));
        nodes.push(Node {
            mode_name: mode_name.to_string(),
            node_id,
            work_dir,
            assignment: node.clone(),
            advertise_host: advertise_host.clone(),
            binaries: binaries.clone(),
            child: None,
        });
    }
    Ok(nodes)
}

pub fn await_port(host: &str, port: u16, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if TcpStream::connect((host, port)).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(200));
    }
    bail!("Timed out waiting for {host}:{port}");
}

pub fn await_path(path: &Path, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(200));
    }
    bail!("Timed out waiting for {}", path.display());
}

pub fn run_admin(admin_bin: &Path, socket: &Path, command: &str) -> Result<String> {
    let out = Command::new(admin_bin)
        .arg(format!("--socket-path={}", socket.display()))
        .arg("--command")
        .arg(command)
        .output()
        .with_context(|| format!("spawn admin: {}", admin_bin.display()))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    if !out.status.success() {
        bail!("admin failed (`{command}`): status={}, stdout={stdout}, stderr={stderr}", out.status);
    }
    Ok(format!("{stdout}{stderr}"))
}

pub fn wait_for_admin(admin_bin: &Path, socket: &Path, timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    let mut last_err = String::new();
    while Instant::now() < deadline {
        match run_admin(admin_bin, socket, "servers status") {
            Ok(_) => return Ok(()),
            Err(e) => last_err = e.to_string(),
        }
        thread::sleep(Duration::from_millis(500));
    }
    bail!("admin on {} did not respond in {timeout:?}: {last_err}", socket.display())
}

pub fn register_peer(
    admin_bin: &Path,
    via_socket: &Path,
    to_register_id: u32,
    to_register_clustering_address: &str,
    timeout: Duration,
) -> Result<()> {
    let cmd = format!("servers register {to_register_id} {to_register_clustering_address}");
    let deadline = Instant::now() + timeout;
    let mut last_err = String::new();
    while Instant::now() < deadline {
        match run_admin(admin_bin, via_socket, &cmd) {
            Ok(_) => return Ok(()),
            Err(e) => {
                last_err = e.to_string();
                // "already registered" / parse errors are terminal; everything
                // else (TCP reset, EOF, Unavailable, ADM2, transient admin
                // restart) is retried until the deadline.
                let lower = last_err.to_lowercase();
                if lower.contains("already") || lower.contains("invalid") || lower.contains("parse") {
                    return Err(anyhow!("register peer {to_register_id}: {last_err}"));
                }
            }
        }
        thread::sleep(Duration::from_secs(2));
    }
    Err(anyhow!("register peer {to_register_id} timed out after {timeout:?}: {last_err}"))
}

pub fn wait_for_primary(admin_bin: &Path, via_socket: &Path, timeout: Duration) -> Result<()> {
    // The admin output is a table like:
    //   id | address | role    | term | status
    //   1  | ...     | primary | ...  | available
    // We match the data-row pattern `| primary |` to avoid false-positives
    // on a header column literally named "primary".
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Ok(status) = run_admin(admin_bin, via_socket, "servers status")
            && status.contains("| primary |")
        {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(500));
    }
    bail!("no primary elected within {timeout:?}")
}

/// Per-machine helper that drives the bootstrap dance for the modes that
/// have multiple nodes here. We start every node, wait for ports, then
/// (on the machine holding node 1 of each mode) register peers via node 1.
pub fn bootstrap_machine(
    topo: &Topology,
    machine: &str,
    nodes: Arc<Mutex<Vec<Node>>>,
    runner_log: &Path,
) -> Result<()> {
    // Spawn everything first.
    {
        let mut guard = nodes.lock().unwrap();
        for n in guard.iter_mut() {
            log::tagged(runner_log, "BOOT", &format!("spawn {}", n.label()));
            n.spawn()?;
        }
    }

    // Wait for ports + admin socket per node.
    let snapshot: Vec<(String, u16, PathBuf)> = {
        let guard = nodes.lock().unwrap();
        guard
            .iter()
            .map(|n| (n.label(), n.assignment.grpc_port, n.admin_socket()))
            .collect()
    };
    for (label, grpc_port, sock) in &snapshot {
        log::tagged(runner_log, "BOOT", &format!("await grpc :{grpc_port} for {label}"));
        await_port("127.0.0.1", *grpc_port, Duration::from_secs(120))
            .with_context(|| format!("await grpc for {label}"))?;
        log::tagged(runner_log, "BOOT", &format!("await admin sock {} for {label}", sock.display()));
        await_path(sock, Duration::from_secs(120)).with_context(|| format!("await admin sock for {label}"))?;
    }

    // Per mode: register peers via node 1 IF this machine holds node 1.
    for (mode_name, mode) in &topo.modes {
        if mode.nodes.len() <= 1 {
            continue;
        }
        let node1_assign = mode
            .nodes
            .iter()
            .find(|(id, _)| id.as_str() == "1")
            .map(|(_, a)| a)
            .ok_or_else(|| anyhow!("mode '{mode_name}' has multiple nodes but no node id '1'"))?;
        if node1_assign.machine != machine {
            continue;
        }
        // Find node 1's admin socket in our local nodes.
        let (admin_bin, node1_sock) = {
            let guard = nodes.lock().unwrap();
            let local_n1 = guard
                .iter()
                .find(|n| n.mode_name == *mode_name && n.node_id == 1)
                .ok_or_else(|| anyhow!("could not find local node 1 for mode {mode_name}"))?;
            (local_n1.binaries.admin_bin.clone(), local_n1.admin_socket())
        };
        log::tagged(runner_log, "BOOT", &format!("[{mode_name}] wait_for_admin on node 1"));
        wait_for_admin(&admin_bin, &node1_sock, Duration::from_secs(120))?;
        // Before registering, make sure each peer's clustering port is
        // actually reachable from this machine. Without this probe, in a
        // multi-machine deploy where M2/M3 boot AFTER M1, register_peer
        // would succeed against unreachable peers and Raft would silently
        // wedge.
        for (id_str, node) in &mode.nodes {
            if id_str.as_str() == "1" {
                continue;
            }
            let machine_addr = &topo.machines[&node.machine].hostname;
            log::tagged(
                runner_log,
                "BOOT",
                &format!("[{mode_name}] await peer {id_str} clustering {machine_addr}:{} reachable", node.clustering_port),
            );
            await_port(machine_addr, node.clustering_port, Duration::from_secs(300))
                .with_context(|| format!("await peer clustering for {mode_name}/node{id_str}"))?;
        }
        for (id_str, node) in &mode.nodes {
            if id_str.as_str() == "1" {
                continue;
            }
            let machine_addr = &topo.machines[&node.machine].hostname;
            let clustering_address = format!("{}:{}", machine_addr, node.clustering_port);
            let id: u32 = id_str.parse().unwrap();
            log::tagged(
                runner_log,
                "BOOT",
                &format!("[{mode_name}] register peer {id} -> {clustering_address}"),
            );
            register_peer(&admin_bin, &node1_sock, id, &clustering_address, Duration::from_secs(120))?;
        }
        log::tagged(runner_log, "BOOT", &format!("[{mode_name}] wait_for_primary"));
        wait_for_primary(&admin_bin, &node1_sock, Duration::from_secs(180))?;
        log::tagged(runner_log, "BOOT", &format!("[{mode_name}] primary elected"));
    }
    Ok(())
}
