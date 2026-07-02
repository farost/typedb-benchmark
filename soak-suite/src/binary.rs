//! Binary discovery: local path (validated) or download (curl + extract).
//!
//! For "download": we pull a tar.gz / zip from the configured URL (with an
//! optional Authorization header), extract once into a cache dir, and
//! return paths to typedb_server_bin / typedb_admin_bin within.

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, bail};

use crate::config::Binary;

#[derive(Debug, Clone)]
pub struct Binaries {
    pub server_bin: PathBuf,
    pub admin_bin: PathBuf,
}

pub fn resolve(cfg: &Binary) -> Result<Binaries> {
    match cfg.source.as_str() {
        "local" => {
            let server_bin = PathBuf::from(cfg.server_bin.as_ref().expect("validated"));
            let admin_bin = PathBuf::from(cfg.admin_bin.as_ref().expect("validated"));
            for (p, name) in [(&server_bin, "server_bin"), (&admin_bin, "admin_bin")] {
                if !p.is_file() {
                    bail!("binary.{name} {} is not a file", p.display());
                }
            }
            Ok(Binaries { server_bin, admin_bin })
        }
        "download" => download(cfg),
        other => bail!("unknown binary.source {other:?}"),
    }
}

fn download(cfg: &Binary) -> Result<Binaries> {
    let url = cfg.download_url.as_deref().expect("validated");
    let cache = cfg
        .download_cache_dir
        .as_deref()
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("typedb-soak-binary"));
    let extracted = cache.join("extracted");
    let marker = cache.join("downloaded-from.url");

    // Already cached? Skip if marker matches.
    if extracted.is_dir()
        && marker.is_file()
        && fs::read_to_string(&marker).map(|s| s.trim() == url).unwrap_or(false)
    {
        eprintln!("[soak] using cached download at {}", extracted.display());
        return locate(&extracted);
    }

    fs::create_dir_all(&cache).with_context(|| format!("mkdir {}", cache.display()))?;
    let archive = cache.join("download.tar.gz");
    eprintln!("[soak] downloading {url} -> {}", archive.display());
    let mut args: Vec<String> = vec![
        "-fsSL".to_string(),
        "--max-time".to_string(),
        "600".to_string(),
        "-o".to_string(),
        archive.display().to_string(),
    ];
    if let Some(h) = &cfg.download_auth_header
        && !h.is_empty()
    {
        args.push("-H".to_string());
        args.push(format!("Authorization: {h}"));
    }
    args.push(url.to_string());

    let st = Command::new("curl").args(&args).status().context("spawn curl")?;
    if !st.success() {
        bail!("curl failed to download {url}: exit {st}");
    }

    // Wipe + extract fresh.
    let _ = fs::remove_dir_all(&extracted);
    fs::create_dir_all(&extracted)?;
    let st = Command::new("tar")
        .args(["--strip-components=1", "-xf", archive.to_str().unwrap(), "-C", extracted.to_str().unwrap()])
        .status()
        .context("spawn tar")?;
    if !st.success() {
        bail!("tar failed to extract {}", archive.display());
    }
    fs::write(&marker, url)?;
    locate(&extracted)
}

fn locate(extracted: &Path) -> Result<Binaries> {
    // Standard layout for the assembled archive: typedb_server_bin at the
    // root, typedb_admin_bin in admin/.
    let candidates_server = [extracted.join("typedb_server_bin"), extracted.join("server/typedb_server_bin")];
    let candidates_admin = [extracted.join("typedb_admin_bin"), extracted.join("admin/typedb_admin_bin")];
    let server_bin = candidates_server
        .iter()
        .find(|p| p.is_file())
        .ok_or_else(|| anyhow::anyhow!("typedb_server_bin not found in {} (tried {:?})", extracted.display(), candidates_server))?
        .clone();
    let admin_bin = candidates_admin
        .iter()
        .find(|p| p.is_file())
        .ok_or_else(|| anyhow::anyhow!("typedb_admin_bin not found in {} (tried {:?})", extracted.display(), candidates_admin))?
        .clone();
    Ok(Binaries { server_bin, admin_bin })
}
