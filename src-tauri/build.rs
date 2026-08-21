//! Build helper: place alayacore next to the Tauri bundle so the
//! runtime's "bundled binary" lookup finds it as the 1st choice.
//!
//! Tauri 2's `externalBin` config requires the source binary to be
//! named with the target triple suffix (e.g.
//! `binaries/alayacore-x86_64-unknown-linux-gnu`); the runtime
//! install strips the suffix and places the binary at the same
//! directory as the main executable. This helper guarantees that
//! source exists: it tries to find a real alayacore via the same
//! resolution logic as the runtime's `find_binary` (PATH search),
//! copies it to the suffixed path IF found, and writes a 0-byte stub
//! otherwise.
//!
//! The 0-byte stub lets the Tauri build always succeed — installs
//! without alayacore on the build machine still produce a working
//! app, and the runtime check `bundled.len() > 0` skips the stub
//! and falls back to env-var / PATH search at session-spawn time.
//! The user sees the same "AlayaCore not found" banner on the home
//! screen that they would have without this feature.
//!
//! The script is intentionally cheap to run: it only searches the
//! for a real alayacore when the destination is missing or empty,
//! so repeated builds (e.g. cargo test) do not hit the FS repeatedly.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=binaries");
    println!("cargo:rerun-if-env-changed=ALAYACORE_BIN");
    println!("cargo:rerun-if-env-changed=PATH");
    println!("cargo:rerun-if-env-changed=TARGET");

    // 1. Ensure the bundled binaries are on disk FIRST (Tauri's
    //    externalBin resolver checks for each binary at build-time
    //    and fails if any are missing). The PATH search and stub
    //    fallback live below.
    bundle_alayacore();
    bundle_ripgrep();

    // 2. Run the Tauri build (now that binaries/alayacore-<triple>
    //    and binaries/rg-<triple> exist or have their 0-byte stubs).
    tauri_build::build();
}

/// Place alayacore at the Tauri-bundle source path. Mirrors the
/// runtime's resolution order at build time:
///   1. ALAYACORE_BIN env var (explicit override)
///   2. `which` / `where` alayacore
///   3. Common locations
/// If found, copy it. If not, write a 0-byte stub so the Tauri
/// build still succeeds — the runtime skips the stub and falls back
/// to env-var / PATH at session-spawn time.
fn bundle_alayacore() {
    let dest = dest_path();
    if let Some(reason) = skip_reason(&dest) {
        println!("cargo:warning=alayacore bundling skipped: {reason}");
        return;
    }

    if let Some(src) = find_alayacore() {
        match fs::copy(&src, &dest) {
            Ok(_) => println!(
                "cargo:warning=bundled alayacore from {} -> {}",
                src.display(),
                dest.display()
            ),
            Err(e) => {
                println!(
                    "cargo:warning=could not copy alayacore from {} to {}: {} \
                     (creating 0-byte stub; runtime will fall back to PATH search)",
                    src.display(),
                    dest.display(),
                    e
                );
                write_stub(&dest);
            }
        }
    } else {
        println!(
            "cargo:warning=alayacore not found on PATH or via ALAYACORE_BIN; \
             creating 0-byte stub at {} (runtime will fall back to PATH search \
             and show the 'AlayaCore not found' banner on the home screen)",
            dest.display()
        );
        write_stub(&dest);
    }
}

/// Path where the Tauri build will look for the binary. Must match
/// the `externalBin` entry in tauri.conf.json PLUS the target triple
/// suffix that Tauri 2 appends when resolving.
fn dest_path() -> PathBuf {
    let target = env::var("TARGET").unwrap_or_default();
    let name = if cfg!(target_os = "windows") {
        format!("alayacore-{}.exe", target)
    } else {
        format!("alayacore-{}", target)
    };
    PathBuf::from("binaries").join(name)
}

/// If the destination already has a non-empty file, there is nothing
/// to do — the user (or a previous build) has placed a real binary
/// there. Re-runs of `cargo build` skip the search entirely. The
/// "binary" name in the message matches the caller (alayacore vs
/// ripgrep), set by the surrounding `bundled <name>` warning.
fn skip_reason(dest: &Path) -> Option<&'static str> {
    if !dest.exists() {
        return None;
    }
    match fs::metadata(dest) {
        Ok(meta) if meta.len() > 0 => Some("destination already has a non-empty binary"),
        Ok(_) => None, // 0-byte stub → re-try replacing it
        Err(_) => None,
    }
}

/// Same logic as `alayacore::find_binary` in the runtime, but ENDS at
/// the PATH-search step (env var + which + candidates). The runtime
/// then adds the bundled-binary lookup on top of these results.
fn find_alayacore() -> Option<PathBuf> {
    // 1. ALAYACORE_BIN env var (explicit override for the build too)
    if let Ok(bin) = std::env::var("ALAYACORE_BIN") {
        if !bin.is_empty() {
            let p = PathBuf::from(&bin);
            if p.is_file() {
                return Some(p);
            }
        }
    }

    // 2. `which` / `where`
    let which_cmd = if cfg!(target_os = "windows") { "where" } else { "which" };
    if let Ok(out) = Command::new(which_cmd).arg("alayacore").output() {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            if let Some(line) = stdout.lines().next() {
                let line = line.trim();
                if !line.is_empty() {
                    let p = PathBuf::from(line);
                    if p.is_file() {
                        return Some(p);
                    }
                }
            }
        }
    }

    // 3. Common locations
    for candidate in &[
        "alayacore",
        "../alayacore/alayacore",
        "./alayacore",
        "/usr/local/bin/alayacore",
        "/usr/bin/alayacore",
    ] {
        let p = PathBuf::from(candidate);
        if p.is_file() {
            return Some(p);
        }
    }

    None
}

fn write_stub(dest: &Path) {
    if let Some(parent) = dest.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(dest, b"");
}

/// Place ripgrep at the Tauri-bundle source path so alayacore can
/// find it on PATH next to itself (see `alayacore::prepend_rg_to_path`).
///
/// Mirrors `bundle_alayacore`: try PATH first, fall back to a 0-byte
/// stub so a local build without ripgrep installed still succeeds.
/// The runtime check `rg.len() > 0` in `prepend_rg_to_path` skips the
/// stub and lets alayacore fall back to whatever it finds on its
/// inherited PATH (or skip rg-only functionality).
fn bundle_ripgrep() {
    let dest = ripgrep_dest_path();
    if let Some(reason) = skip_reason(&dest) {
        println!("cargo:warning=ripgrep bundling skipped: {reason}");
        return;
    }

    let rg_name = if cfg!(target_os = "windows") { "rg.exe" } else { "rg" };
    if let Some(src) = find_on_path(rg_name) {
        match fs::copy(&src, &dest) {
            Ok(_) => println!(
                "cargo:warning=bundled ripgrep from {} -> {}",
                src.display(),
                dest.display()
            ),
            Err(e) => {
                println!(
                    "cargo:warning=could not copy ripgrep from {} to {}: {} \
                     (creating 0-byte stub; alayacore will fall back to PATH search)",
                    src.display(),
                    dest.display(),
                    e
                );
                write_stub(&dest);
            }
        }
    } else {
        println!(
            "cargo:warning=ripgrep ({rg_name}) not found on PATH; \
             creating 0-byte stub at {} (alayacore will fall back to PATH search)",
            dest.display()
        );
        write_stub(&dest);
    }
}

/// Path where the Tauri build will look for the ripgrep binary.
/// Same naming scheme as `dest_path` — `<name>-<target_triple>` with
/// `.exe` on Windows.
fn ripgrep_dest_path() -> PathBuf {
    let target = env::var("TARGET").unwrap_or_default();
    let name = if cfg!(target_os = "windows") {
        format!("rg-{}.exe", target)
    } else {
        format!("rg-{}", target)
    };
    PathBuf::from("binaries").join(name)
}

/// `which <name>` / `where <name>` wrapper. Used by `bundle_ripgrep`
/// to discover a system ripgrep for local builds; the release
/// workflow always downloads the matching binary so PATH search is
/// only a dev convenience.
fn find_on_path(name: &str) -> Option<PathBuf> {
    let which_cmd = if cfg!(target_os = "windows") { "where" } else { "which" };
    let out = Command::new(which_cmd).arg(name).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let line = stdout.lines().next()?.trim();
    if line.is_empty() {
        return None;
    }
    let p = PathBuf::from(line);
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}
