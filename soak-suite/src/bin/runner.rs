//! Server-side soak runner. One invocation per machine. Reads topology.toml,
//! filters to its --machine label, spawns the assigned nodes, registers
//! peers (machine that holds node 1 of each multi-node mode), and runs
//! kill+network chaos threads for any mode with chaos_enabled.

use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use anyhow::{Result, bail};
use clap::Parser;

use typedb_soak_suite::{
    binary,
    chaos::run_kill_loop,
    cluster::{await_path, await_port, bootstrap_machine, build_nodes_for_machine},
    config::{self, Topology},
    disk::DiskWatchdog,
    log,
    network_chaos::{cleanup_all as network_cleanup_all, run_network_loop},
};

#[derive(Parser, Debug)]
#[command(version, about = "typedb-cluster soak runner (per-machine)")]
struct Args {
    #[arg(long)]
    config: PathBuf,

    /// Machine label (must match a key under `[machines.X]` in the config).
    #[arg(long)]
    machine: String,

    /// Per-machine work dir (data + logs land here).
    #[arg(long)]
    workdir: PathBuf,

    /// Skip the bootstrap dance (peer registration etc.) — useful when
    /// re-attaching to an already-initialized cluster.
    #[arg(long)]
    skip_bootstrap: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    std::fs::create_dir_all(&args.workdir)?;
    let runner_log = args.workdir.join("runner.log");
    log::tagged(
        &runner_log,
        "BOOT",
        &format!("runner starting: machine={} workdir={}", args.machine, args.workdir.display()),
    );

    let topo: Topology = config::load(&args.config)?;
    if !topo.machines.contains_key(&args.machine) {
        bail!("unknown machine '{}' (defined: {:?})", args.machine, topo.machines.keys().collect::<Vec<_>>());
    }

    let binaries = binary::resolve(&topo.binary)?;
    log::tagged(
        &runner_log,
        "BOOT",
        &format!(
            "binaries: server={} admin={}",
            binaries.server_bin.display(),
            binaries.admin_bin.display()
        ),
    );

    let local = build_nodes_for_machine(&topo, &args.machine, &args.workdir, &binaries)?;
    if local.is_empty() {
        log::tagged(&runner_log, "BOOT", &format!("no nodes assigned to machine '{}'; nothing to do", args.machine));
        return Ok(());
    }
    log::tagged(
        &runner_log,
        "BOOT",
        &format!("local nodes: {}", local.iter().map(|n| n.label()).collect::<Vec<_>>().join(", ")),
    );

    let nodes = Arc::new(Mutex::new(local));

    if !args.skip_bootstrap {
        bootstrap_machine(&topo, &args.machine, nodes.clone(), &runner_log)?;
    } else {
        // skip-bootstrap: spawn but don't register
        let mut guard = nodes.lock().unwrap();
        for n in guard.iter_mut() {
            n.spawn()?;
        }
        for n in guard.iter() {
            await_port("127.0.0.1", n.assignment.grpc_port, Duration::from_secs(120))?;
            await_path(&n.admin_socket(), Duration::from_secs(120))?;
        }
    }

    // Public addresses summary (for the operator to feed the client).
    log::tagged(&runner_log, "READY", "all assigned nodes up; address summary follows");
    for (mode_name, mode) in &topo.modes {
        let addrs = topo.client_addresses(mode_name);
        log::tagged(
            &runner_log,
            "READY",
            &format!("[{mode_name}] client addrs: {} (chaos={})", addrs.join(","), mode.chaos_enabled),
        );
    }
    println!("[runner] ready: machine={}; modes addresses follow (also in runner.log)", args.machine);
    for (mode_name, _) in &topo.modes {
        println!("[runner]  {mode_name}: {}", topo.client_addresses(mode_name).join(","));
    }

    let shutdown = Arc::new(AtomicBool::new(false));
    {
        let s = shutdown.clone();
        ctrlc::set_handler(move || s.store(true, Ordering::Relaxed)).ok();
    }

    // Disk watchdog over the workdir filesystem.
    DiskWatchdog {
        paths: vec![args.workdir.clone()],
        warn_percent: topo.disk.warn_percent,
        interval: Duration::from_secs(topo.disk.check_interval_secs),
        runner_log: runner_log.clone(),
    }
    .spawn(shutdown.clone());

    // Chaos threads per chaos-enabled mode that has nodes on this machine.
    for (mode_name, mode) in &topo.modes {
        if !mode.chaos_enabled {
            continue;
        }
        let has_local_node = {
            let guard = nodes.lock().unwrap();
            guard.iter().any(|n| n.mode_name == *mode_name)
        };
        if !has_local_node {
            continue;
        }
        // Kill chaos
        {
            let nodes = nodes.clone();
            let cfg = topo.chaos.kill.clone();
            let runner_log = runner_log.clone();
            let mode = mode_name.clone();
            thread::spawn(move || {
                run_kill_loop(mode, nodes, cfg, runner_log);
            });
        }
        // Network chaos
        {
            let nodes = nodes.clone();
            let cfg = topo.chaos.network.clone();
            let runner_log = runner_log.clone();
            let mode = mode_name.clone();
            thread::spawn(move || {
                run_network_loop(mode, nodes, cfg, runner_log);
            });
        }
    }

    // Non-chaos watchdog: restart any non-chaos-mode node that died.
    // Snapshot indices first to keep the lock short during Command::spawn.
    {
        let nodes = nodes.clone();
        let runner_log = runner_log.clone();
        let topo = topo.clone();
        let shutdown = shutdown.clone();
        thread::spawn(move || {
            while !shutdown.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_secs(30));
                let dead: Vec<(usize, String)> = {
                    let mut guard = nodes.lock().unwrap();
                    let mut out = Vec::new();
                    for (i, n) in guard.iter_mut().enumerate() {
                        let chaos = topo.modes.get(&n.mode_name).map(|m| m.chaos_enabled).unwrap_or(false);
                        if !chaos && !n.is_alive() {
                            out.push((i, n.label()));
                        }
                    }
                    out
                };
                for (i, label) in dead {
                    log::loud_error(
                        &runner_log,
                        "WATCHDOG",
                        &format!("{label} died (non-chaos mode); restarting"),
                    );
                    if let Err(e) = nodes.lock().unwrap()[i].spawn() {
                        log::loud_error(
                            &runner_log,
                            "WATCHDOG",
                            &format!("restart {label} failed: {e}"),
                        );
                    }
                }
            }
        });
    }

    while !shutdown.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_secs(1));
    }
    log::tagged(&runner_log, "SHUTDOWN", "stopping nodes and cleaning network chaos");
    network_cleanup_all(&topo.chaos.network, &runner_log);
    let mut guard = nodes.lock().unwrap();
    for n in guard.iter_mut() {
        let _ = n.kill();
    }
    log::tagged(&runner_log, "SHUTDOWN", "done");
    Ok(())
}
