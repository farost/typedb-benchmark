//! Client-side soak loop. One invocation per mode. Connects via typedb-driver
//! gRPC to all of that mode's nodes (driver auto-discovers primary), drives
//! `insert -> commit -> read count -> verify` flat out, records consistency
//! violations to FAILURES.log.

use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use chrono::Utc;
use clap::Parser;
use serde_json::json;
use tokio::time::sleep;

use typedb_driver::{Addresses, Credentials, DriverOptions, DriverTlsConfig, TransactionType, TypeDBDriver};

use typedb_soak_suite::{
    config,
    diagnostics::{ServerEndpoint, run_diagnostics_loop},
    state::{FailureRecord, State, append_failure, workdir_paths},
};

const SCHEMA: &str = r#"
define
attribute id, value integer;
entity counter, owns id @key;
"#;

#[derive(Parser, Debug)]
#[command(version, about = "typedb-cluster soak client (per-mode, write + verify)")]
struct Args {
    #[arg(long)]
    config: PathBuf,

    /// Mode name (key under `[modes.X]` in the topology).
    #[arg(long)]
    mode: String,

    /// Workdir for STATE / FAILURES.log / client.log.
    #[arg(long)]
    workdir: PathBuf,

    #[arg(long, default_value = "admin")]
    username: String,
    #[arg(long, default_value = "password")]
    password: String,

    /// If set, run for this many seconds then exit cleanly. Use 0 for forever.
    #[arg(long, default_value = "0")]
    duration_secs: u64,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<()> {
    let args = Args::parse();
    fs::create_dir_all(&args.workdir).context("create workdir")?;
    let paths = workdir_paths(&args.workdir);

    let topo = config::load(&args.config)?;
    let mode = topo
        .modes
        .get(&args.mode)
        .ok_or_else(|| anyhow!("unknown mode '{}' (defined: {:?})", args.mode, topo.modes.keys().collect::<Vec<_>>()))?;

    let addresses = topo.client_addresses(&args.mode);
    let db_name = topo.database_name(&args.mode).to_string();
    let credentials = Credentials::new(&args.username, &args.password);

    let shutdown = Arc::new(AtomicBool::new(false));
    {
        let s = shutdown.clone();
        ctrlc::set_handler(move || s.store(true, Ordering::Relaxed)).ok();
    }

    let state = Arc::new(Mutex::new(State::load_or_new(&paths.state, &args.mode)));
    log_status(
        &paths.client_log,
        &format!(
            "startup: mode={} db={} addresses={:?} workdir={}",
            args.mode,
            db_name,
            addresses,
            args.workdir.display()
        ),
    );

    // Diagnostics polling thread.
    {
        let endpoints: Vec<ServerEndpoint> = mode
            .nodes
            .iter()
            .map(|(node_id, na)| ServerEndpoint {
                label: format!("{}/node{}", args.mode, node_id),
                host: topo.machines[&na.machine].hostname.clone(),
                grpc_port: na.grpc_port,
                monitoring_port: na.monitoring_port,
            })
            .collect();
        let state = state.clone();
        let state_path = paths.state.clone();
        let failures_path = paths.failures.clone();
        let diag_log = paths.diagnostics_log.clone();
        let poll = Duration::from_secs(topo.client.diagnostics_poll_secs);
        let shutdown = shutdown.clone();
        std::thread::spawn(move || {
            run_diagnostics_loop(endpoints, state, &state_path, &failures_path, &diag_log, poll, shutdown);
        });
    }

    // Connect with retries until success / shutdown / duration deadline.
    let connect_deadline = if args.duration_secs > 0 {
        Some(Instant::now() + Duration::from_secs(args.duration_secs))
    } else {
        None
    };
    let mut driver = connect_with_retry(
        &addresses,
        &credentials,
        topo.client.max_reconnect_backoff_ms,
        &shutdown,
        connect_deadline,
    )
    .await?;
    ensure_database_and_schema(&driver, &db_name).await?;

    // Reconcile expected with what's actually in the DB.
    let observed =
        read_count_with_retry(&mut driver, &db_name, &addresses, &credentials, topo.client.max_reconnect_backoff_ms, &shutdown, connect_deadline).await?;
    {
        let mut s = state.lock().unwrap();
        if observed != s.expected {
            log_status(
                &paths.client_log,
                &format!("reconciling on startup: STATE.expected={} db.count={}", s.expected, observed),
            );
            s.expected = observed;
            s.total_reconciliations += 1;
        }
        s.save_atomic(&paths.state).ok();
    }

    let mut last_status_at = Instant::now();
    let mut last_status_total = state.lock().unwrap().total_commits_ok;
    let started_at = Instant::now();

    loop {
        if shutdown.load(Ordering::Relaxed) {
            break;
        }
        if args.duration_secs > 0 && started_at.elapsed().as_secs() >= args.duration_secs {
            log_status(&paths.client_log, &format!("duration {}s reached, exiting", args.duration_secs));
            break;
        }

        // ----- write phase -----
        let next_id = state.lock().unwrap().expected;
        let commit_ok = match try_commit_insert(&driver, &db_name, next_id).await {
            Ok(()) => {
                let mut s = state.lock().unwrap();
                s.expected += 1;
                s.total_commits_ok += 1;
                s.last_ok_at = Some(Utc::now());
                true
            }
            Err(e) => {
                state.lock().unwrap().total_commits_err += 1;
                log_status(&paths.client_log, &format!("commit error at expected={next_id}: {e}"));
                false
            }
        };
        if !commit_ok {
            driver = connect_with_retry(&addresses, &credentials, topo.client.max_reconnect_backoff_ms, &shutdown, connect_deadline).await?;
            match read_count_with_retry(&mut driver, &db_name, &addresses, &credentials, topo.client.max_reconnect_backoff_ms, &shutdown, connect_deadline).await {
                Ok(observed) => {
                    let mut s = state.lock().unwrap();
                    if observed != s.expected {
                        log_status(
                            &paths.client_log,
                            &format!("reconcile after commit-err: expected={} observed={}", s.expected, observed),
                        );
                        s.expected = observed;
                        s.total_reconciliations += 1;
                    }
                }
                Err(e) => log_status(&paths.client_log, &format!("reconcile read failed: {e}")),
            }
            state.lock().unwrap().save_atomic(&paths.state).ok();
            continue;
        }
        state.lock().unwrap().save_atomic(&paths.state).ok();

        // ----- verify phase -----
        let expected_now = state.lock().unwrap().expected;
        match try_read_count(&driver, &db_name).await {
            Ok(observed) => {
                if observed != expected_now {
                    let mut s = state.lock().unwrap();
                    s.total_verifies_err += 1;
                    let rec = FailureRecord {
                        at: Utc::now(),
                        kind: "count_mismatch".into(),
                        expected: expected_now,
                        observed: Some(observed),
                        details: json!({
                            "mode": args.mode,
                            "addresses": addresses,
                            "last_inserted_id": next_id,
                            "total_commits_ok": s.total_commits_ok,
                            "total_commits_err": s.total_commits_err,
                            "total_reconciliations": s.total_reconciliations,
                        }),
                    };
                    append_failure(&paths.failures, rec);
                    log_status(
                        &paths.client_log,
                        &format!("!! FAILURE: count_mismatch expected={expected_now} observed={observed}"),
                    );
                    s.expected = observed;
                    s.total_reconciliations += 1;
                } else {
                    state.lock().unwrap().total_verifies_ok += 1;
                }
            }
            Err(e) => {
                state.lock().unwrap().total_verifies_err += 1;
                log_status(&paths.client_log, &format!("verify read error: {e}"));
            }
        }
        state.lock().unwrap().save_atomic(&paths.state).ok();

        // Periodic status log.
        if topo.client.status_log_every_secs == 0
            || last_status_at.elapsed() >= Duration::from_secs(topo.client.status_log_every_secs)
        {
            let s = state.lock().unwrap().clone();
            let delta = s.total_commits_ok - last_status_total;
            let elapsed = last_status_at.elapsed().as_secs_f64().max(0.001);
            log_status(
                &paths.client_log,
                &format!(
                    "status: expected={} commits_ok={} commits_err={} verifies_err={} reconciles={} ops/s_since_last={:.1}",
                    s.expected,
                    s.total_commits_ok,
                    s.total_commits_err,
                    s.total_verifies_err,
                    s.total_reconciliations,
                    (delta as f64) / elapsed,
                ),
            );
            last_status_at = Instant::now();
            last_status_total = s.total_commits_ok;
        }
    }

    log_status(&paths.client_log, "shutdown; final state saved");
    state.lock().unwrap().save_atomic(&paths.state).ok();
    Ok(())
}

async fn connect_with_retry(
    addresses: &[String],
    credentials: &Credentials,
    max_backoff_ms: u64,
    shutdown: &Arc<AtomicBool>,
    deadline: Option<Instant>,
) -> Result<TypeDBDriver> {
    let driver_options = DriverOptions::new(DriverTlsConfig::disabled());
    let addrs = Addresses::try_from_addresses_str(addresses)
        .map_err(|e| anyhow!("parse addresses {addresses:?}: {e}"))?;
    let mut backoff = Duration::from_millis(100);
    let cap = Duration::from_millis(max_backoff_ms);
    loop {
        if shutdown.load(Ordering::Relaxed) {
            return Err(anyhow!("shutdown during connect"));
        }
        if let Some(d) = deadline
            && Instant::now() >= d
        {
            return Err(anyhow!("duration deadline reached during connect"));
        }
        match TypeDBDriver::new(addrs.clone(), credentials.clone(), driver_options.clone()).await {
            Ok(d) => return Ok(d),
            Err(e) => {
                eprintln!("[soak] driver connect failed ({e}); retrying in {:?}", backoff);
                sleep(backoff).await;
                backoff = (backoff * 2).min(cap);
            }
        }
    }
}

async fn ensure_database_and_schema(driver: &TypeDBDriver, db_name: &str) -> Result<()> {
    let dbs = driver.databases();
    if !dbs.contains(db_name).await.map_err(|e| anyhow!("databases.contains: {e}"))? {
        dbs.create(db_name).await.map_err(|e| anyhow!("databases.create: {e}"))?;
        let tx = driver
            .transaction(db_name, TransactionType::Schema)
            .await
            .map_err(|e| anyhow!("open schema tx: {e}"))?;
        tx.query(SCHEMA).await.map_err(|e| anyhow!("define schema: {e}"))?;
        tx.commit().await.map_err(|e| anyhow!("commit schema: {e}"))?;
    }
    Ok(())
}

async fn try_commit_insert(driver: &TypeDBDriver, db_name: &str, id: i64) -> Result<()> {
    let tx = driver
        .transaction(db_name, TransactionType::Write)
        .await
        .map_err(|e| anyhow!("open write tx: {e}"))?;
    let q = format!("insert $c isa counter, has id {id};");
    tx.query(&q).await.map_err(|e| anyhow!("insert: {e}"))?;
    tx.commit().await.map_err(|e| anyhow!("commit: {e}"))?;
    Ok(())
}

async fn try_read_count(driver: &TypeDBDriver, db_name: &str) -> Result<i64> {
    let tx = driver
        .transaction(db_name, TransactionType::Read)
        .await
        .map_err(|e| anyhow!("open read tx: {e}"))?;
    let q = "match $c isa counter; reduce $total = count;";
    let answer = tx.query(q).await.map_err(|e| anyhow!("count query: {e}"))?;
    parse_count_from_answer(answer).await
}

async fn parse_count_from_answer(answer: typedb_driver::answer::QueryAnswer) -> Result<i64> {
    use futures::StreamExt;
    use typedb_driver::answer::QueryAnswer;
    use typedb_driver::concept::{Concept, Value};
    match answer {
        QueryAnswer::ConceptRowStream(_header, mut stream) => {
            let row_res = stream.next().await.ok_or_else(|| anyhow!("count answer had no rows"))?;
            let row = row_res.map_err(|e| anyhow!("row error: {e}"))?;
            let concept = row
                .get("total")
                .map_err(|e| anyhow!("row get total: {e}"))?
                .ok_or_else(|| anyhow!("$total column was empty"))?;
            match concept {
                Concept::Value(Value::Integer(n)) => Ok(*n),
                other => Err(anyhow!("expected integer for count, got {other:?}")),
            }
        }
        other => Err(anyhow!("unexpected QueryAnswer shape for count: {other:?}")),
    }
}

async fn read_count_with_retry(
    driver: &mut TypeDBDriver,
    db_name: &str,
    addresses: &[String],
    credentials: &Credentials,
    max_backoff_ms: u64,
    shutdown: &Arc<AtomicBool>,
    deadline: Option<Instant>,
) -> Result<i64> {
    let mut backoff = Duration::from_millis(100);
    let cap = Duration::from_millis(max_backoff_ms);
    loop {
        if shutdown.load(Ordering::Relaxed) {
            return Err(anyhow!("shutdown during read"));
        }
        if let Some(d) = deadline
            && Instant::now() >= d
        {
            return Err(anyhow!("duration deadline reached during read"));
        }
        match try_read_count(driver, db_name).await {
            Ok(n) => return Ok(n),
            Err(e) => {
                eprintln!("[soak] read count failed ({e}); recreating driver, retrying in {:?}", backoff);
                *driver = connect_with_retry(addresses, credentials, max_backoff_ms, shutdown, deadline).await?;
                sleep(backoff).await;
                backoff = (backoff * 2).min(cap);
            }
        }
    }
}

fn log_status(client_log: &PathBuf, msg: &str) {
    let line = format!("{} {msg}\n", Utc::now().to_rfc3339());
    if let Some(parent) = client_log.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(client_log) {
        let _ = f.write_all(line.as_bytes());
    }
    eprint!("{line}");
}
