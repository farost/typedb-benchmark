//! Per-machine network-chaos thread for chaos-enabled modes.
//!
//! Each cycle: picks a random impairment type — packet drop, latency,
//! full partition, asymmetric partition — applies it to one of this
//! machine's chaos-mode nodes' clustering ports for a random duration,
//! then removes it. Loud start/stop logs so failures can be correlated.
//!
//! Scope is per-port (the clustering port of the target node), so impairments
//! don't bleed into other modes' traffic on the same machine.
//!
//! Requires `iptables` and `tc` on PATH, and (typically) sudo. The
//! `use_sudo` flag in config controls whether commands are prefixed.

use std::{
    path::PathBuf,
    process::Command,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use rand::{Rng, thread_rng};

use crate::{
    cluster::Node,
    config::NetworkChaosConfig,
    log,
};

#[derive(Debug, Clone, Copy)]
enum Impairment {
    Drop,
    Delay,
    Partition,
    Asymmetric,
}

impl Impairment {
    fn label(self) -> &'static str {
        match self {
            Impairment::Drop => "drop",
            Impairment::Delay => "delay",
            Impairment::Partition => "partition",
            Impairment::Asymmetric => "asymmetric",
        }
    }
}

pub fn run_network_loop(
    mode_name: String,
    nodes: Arc<Mutex<Vec<Node>>>,
    cfg: NetworkChaosConfig,
    runner_log: PathBuf,
) -> ! {
    // Pre-flight: make sure iptables and tc are usable. If not, log loudly
    // and disable the thread (don't crash the whole runner).
    if !preflight(&cfg, &runner_log) {
        log::loud_error(
            &runner_log,
            "NET-CHAOS",
            "preflight failed; network chaos disabled for this run (kill chaos still active)",
        );
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    }

    log::tagged(
        &runner_log,
        "NET-CHAOS",
        &format!(
            "thread started for mode='{mode_name}' clean={}-{}s dirty={}-{}s iface={}",
            cfg.min_clean_secs, cfg.max_clean_secs, cfg.min_dirty_secs, cfg.max_dirty_secs, cfg.interface
        ),
    );
    loop {
        let mut rng = thread_rng();
        let clean = rng.r#gen_range(cfg.min_clean_secs..=cfg.max_clean_secs);
        thread::sleep(Duration::from_secs(clean));

        // Pick an ALIVE target node + an impairment type. Applying iptables
        // rules against a dead node's port is wasted chaos time.
        let target = {
            let mut guard = nodes.lock().unwrap();
            let mut candidates: Vec<(usize, u16, String)> = Vec::new();
            for (i, n) in guard.iter_mut().enumerate() {
                if n.mode_name == mode_name && n.is_alive() {
                    candidates.push((i, n.assignment.clustering_port, n.label()));
                }
            }
            if candidates.is_empty() {
                log::tagged(
                    &runner_log,
                    "NET-CHAOS",
                    &format!("no alive local nodes for mode '{mode_name}'; skipping cycle"),
                );
                continue;
            }
            candidates[rng.r#gen_range(0..candidates.len())].clone()
        };
        let (target_idx, target_port, target_label) = target;
        let _ = target_idx;

        let impair: Impairment = match rng.r#gen_range(0u8..4) {
            0 => Impairment::Drop,
            1 => Impairment::Delay,
            2 => Impairment::Partition,
            _ => Impairment::Asymmetric,
        };
        let dirty = rng.r#gen_range(cfg.min_dirty_secs..=cfg.max_dirty_secs);

        log::tagged(
            &runner_log,
            "NET-CHAOS",
            &format!(
                "STARTING {} on {target_label} (clustering port {target_port}) for {dirty}s — SNEAKY THINGS HAPPENING",
                impair.label()
            ),
        );

        let rules = match impair {
            Impairment::Drop => apply_drop(&cfg, target_port, &mut rng),
            Impairment::Delay => apply_delay(&cfg, target_port, &mut rng),
            Impairment::Partition => apply_partition(&cfg, target_port),
            Impairment::Asymmetric => apply_asymmetric(&cfg, target_port),
        };

        let rules = match rules {
            Ok(r) => r,
            Err(e) => {
                log::loud_error(
                    &runner_log,
                    "NET-CHAOS",
                    &format!("apply {} on {target_label} failed: {e}", impair.label()),
                );
                continue;
            }
        };

        thread::sleep(Duration::from_secs(dirty));

        log::tagged(
            &runner_log,
            "NET-CHAOS",
            &format!("STOPPING {} on {target_label} (port {target_port}) — restoring clean state", impair.label()),
        );
        for cmd in rules.cleanup {
            if let Err(e) = run(&cfg, &cmd) {
                log::loud_error(
                    &runner_log,
                    "NET-CHAOS",
                    &format!("CLEANUP failed for {}: {e}. Manual cleanup may be needed!", cmd.join(" ")),
                );
            }
        }
        log::tagged(&runner_log, "NET-CHAOS", &format!("CLEAN on {target_label}"));
    }
}

struct AppliedRules {
    cleanup: Vec<Vec<String>>,
}

fn preflight(cfg: &NetworkChaosConfig, runner_log: &std::path::Path) -> bool {
    let iptables_ok = run(cfg, &cmd_vec(&["iptables", "-L", "OUTPUT", "-n"])).is_ok();
    let tc_ok = run(cfg, &cmd_vec(&["tc", "qdisc", "show", "dev", &cfg.interface])).is_ok();
    if !iptables_ok {
        log::loud_error(runner_log, "NET-CHAOS", "iptables not usable (sudo? missing?)");
    }
    if !tc_ok {
        log::loud_error(runner_log, "NET-CHAOS", &format!("tc not usable for iface {}", cfg.interface));
    }
    iptables_ok && tc_ok
}

fn apply_drop(cfg: &NetworkChaosConfig, port: u16, rng: &mut impl Rng) -> anyhow::Result<AppliedRules> {
    let p = rng.r#gen_range(cfg.drop_probability.0..=cfg.drop_probability.1);
    // Drop a random fraction of packets on OUR clustering port. We filter
    // both directions of the local listener:
    //   INPUT  --dport OUR_PORT : peers connecting in
    //   OUTPUT --sport OUR_PORT : our listener's replies going out
    // This also catches peers that share the same clustering port number
    // (the typical topology) for outbound new connections in both fields.
    let cmds: [Vec<String>; 2] = [
        cmd_vec(&[
            "iptables", "-I", "INPUT", "-p", "tcp", "--dport", &port.to_string(), "-m", "statistic",
            "--mode", "random", "--probability", &format!("{p:.4}"),
            "-m", "comment", "--comment", "soak-net-chaos",
            "-j", "DROP",
        ]),
        cmd_vec(&[
            "iptables", "-I", "OUTPUT", "-p", "tcp", "--sport", &port.to_string(), "-m", "statistic",
            "--mode", "random", "--probability", &format!("{p:.4}"),
            "-m", "comment", "--comment", "soak-net-chaos",
            "-j", "DROP",
        ]),
    ];
    for c in &cmds {
        run(cfg, c)?;
    }
    let cleanup: Vec<Vec<String>> = cmds
        .iter()
        .map(|c| {
            let mut d = c.clone();
            // change -I to -D (delete)
            if let Some(pos) = d.iter().position(|x| x == "-I") {
                d[pos] = "-D".to_string();
            }
            d
        })
        .collect();
    Ok(AppliedRules { cleanup })
}

fn apply_delay(cfg: &NetworkChaosConfig, port: u16, rng: &mut impl Rng) -> anyhow::Result<AppliedRules> {
    let delay = rng.r#gen_range(cfg.delay_ms.0..=cfg.delay_ms.1);
    let jitter = rng.r#gen_range(cfg.jitter_ms.0..=cfg.jitter_ms.1);
    let iface = &cfg.interface;
    // Clean any prior root qdisc first (default `pfifo_fast` blocks our
    // `add root`). Then build a prio qdisc, add netem on band 1:3, and
    // filter BOTH source-port and dest-port of our clustering listener
    // into that band so both inbound and outbound clustering traffic is
    // delayed (egress only, since tc is egress-shaping by default — which
    // is enough to slow Raft handshakes).
    let _ = run(cfg, &cmd_vec(&["tc", "qdisc", "del", "dev", iface, "root"])); // best-effort
    let setup: Vec<Vec<String>> = vec![
        cmd_vec(&["tc", "qdisc", "add", "dev", iface, "root", "handle", "1:", "prio"]),
        cmd_vec(&[
            "tc", "qdisc", "add", "dev", iface, "parent", "1:3", "handle", "30:", "netem",
            "delay", &format!("{delay}ms"), &format!("{jitter}ms"),
        ]),
        cmd_vec(&[
            "tc", "filter", "add", "dev", iface, "protocol", "ip", "parent", "1:0", "prio", "3",
            "u32", "match", "ip", "dport", &port.to_string(), "0xffff", "flowid", "1:3",
        ]),
        cmd_vec(&[
            "tc", "filter", "add", "dev", iface, "protocol", "ip", "parent", "1:0", "prio", "3",
            "u32", "match", "ip", "sport", &port.to_string(), "0xffff", "flowid", "1:3",
        ]),
    ];
    for c in &setup {
        run(cfg, c)?;
    }
    let cleanup = vec![cmd_vec(&["tc", "qdisc", "del", "dev", iface, "root"])];
    Ok(AppliedRules { cleanup })
}

fn apply_partition(cfg: &NetworkChaosConfig, port: u16) -> anyhow::Result<AppliedRules> {
    // Full partition of our local node from Raft. We block FOUR rules so
    // both ingress and egress on our clustering port are dropped, and any
    // outbound new connection we make to a peer using the same clustering
    // port (the standard topology) is also blocked.
    //   INPUT  --dport OUR_PORT : peers connecting in
    //   OUTPUT --sport OUR_PORT : our replies going out
    //   OUTPUT --dport OUR_PORT : us connecting out to peers (same port topology)
    //   INPUT  --sport OUR_PORT : responses to our outbound (same port topology)
    let cmds: [Vec<String>; 4] = [
        cmd_vec(&["iptables", "-I", "INPUT",  "-p", "tcp", "--dport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
        cmd_vec(&["iptables", "-I", "OUTPUT", "-p", "tcp", "--sport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
        cmd_vec(&["iptables", "-I", "OUTPUT", "-p", "tcp", "--dport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
        cmd_vec(&["iptables", "-I", "INPUT",  "-p", "tcp", "--sport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
    ];
    for c in &cmds {
        run(cfg, c)?;
    }
    let cleanup: Vec<Vec<String>> = cmds
        .iter()
        .map(|c| {
            let mut d = c.clone();
            if let Some(pos) = d.iter().position(|x| x == "-I") {
                d[pos] = "-D".to_string();
            }
            d
        })
        .collect();
    Ok(AppliedRules { cleanup })
}

fn apply_asymmetric(cfg: &NetworkChaosConfig, port: u16) -> anyhow::Result<AppliedRules> {
    // Asymmetric: this node can RECEIVE but not REPLY on its listener.
    // Causes peers to time out waiting for AppendEntries acks even though
    // their requests reach us.
    let cmds: [Vec<String>; 2] = [
        cmd_vec(&["iptables", "-I", "OUTPUT", "-p", "tcp", "--sport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
        cmd_vec(&["iptables", "-I", "OUTPUT", "-p", "tcp", "--dport", &port.to_string(),
            "-m", "comment", "--comment", "soak-net-chaos", "-j", "DROP"]),
    ];
    for c in &cmds {
        run(cfg, c)?;
    }
    let cleanup: Vec<Vec<String>> = cmds
        .iter()
        .map(|c| {
            let mut d = c.clone();
            if let Some(pos) = d.iter().position(|x| x == "-I") {
                d[pos] = "-D".to_string();
            }
            d
        })
        .collect();
    Ok(AppliedRules { cleanup })
}

fn cmd_vec(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

fn run(cfg: &NetworkChaosConfig, parts: &[String]) -> anyhow::Result<()> {
    let mut full: Vec<String> = if cfg.use_sudo {
        let mut v = vec!["sudo".to_string(), "-n".to_string()];
        v.extend(parts.iter().cloned());
        v
    } else {
        parts.to_vec()
    };
    let cmd = full.remove(0);
    let out = Command::new(&cmd).args(&full).output()?;
    if !out.status.success() {
        anyhow::bail!(
            "{cmd} {} exit={}: {}{}",
            full.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

/// Best-effort cleanup of all soak-net-chaos iptables rules + tc qdiscs.
/// Called on runner shutdown so a crashed runner doesn't leave the machine
/// in a partitioned state.
pub fn cleanup_all(cfg: &NetworkChaosConfig, runner_log: &std::path::Path) {
    log::tagged(runner_log, "NET-CHAOS", "running shutdown cleanup");
    // List + delete iptables rules with our comment. iptables -S can emit
    // policy lines like "-P OUTPUT ACCEPT" — only -A lines are deletable
    // (and only those tagged with our marker comment).
    for chain in ["OUTPUT", "INPUT"] {
        let listing = if cfg.use_sudo {
            Command::new("sudo").args(["-n", "iptables", "-S", chain]).output()
        } else {
            Command::new("iptables").args(["-S", chain]).output()
        };
        if let Ok(out) = listing {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if !line.starts_with("-A ") {
                    continue;
                }
                if !line.contains("soak-net-chaos") {
                    continue;
                }
                let mut rule: Vec<String> = line.split_whitespace().map(|s| s.to_string()).collect();
                rule[0] = "-D".to_string();
                let mut argv = vec!["iptables".to_string()];
                argv.extend(rule);
                let _ = run(cfg, &argv);
            }
        }
    }
    // Best-effort: remove the root qdisc only if it's the prio handle we
    // installed. `tc qdisc show` lists qdiscs; if we see `qdisc prio 1:`
    // it's ours (or someone else's prio — accept that small risk).
    let show = if cfg.use_sudo {
        Command::new("sudo").args(["-n", "tc", "qdisc", "show", "dev", &cfg.interface]).output()
    } else {
        Command::new("tc").args(["qdisc", "show", "dev", &cfg.interface]).output()
    };
    if let Ok(out) = show {
        let s = String::from_utf8_lossy(&out.stdout);
        if s.contains("qdisc prio 1:") {
            let _ = run(cfg, &cmd_vec(&["tc", "qdisc", "del", "dev", &cfg.interface, "root"]));
        }
    }
}
