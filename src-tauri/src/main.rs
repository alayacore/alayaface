// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;

fn main() {
    // Parse --config-path BEFORE alayaface_lib::run() so the override is
    // installed before any Tauri command handler (which reads
    // dirs::alayaface_dir) is reached. Tauri consumes its own args, but
    // std::env::args() still sees them at the front of the argv vector.
    let mut config_path: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--config-path" {
            match args.next() {
                Some(v) => config_path = Some(PathBuf::from(v)),
                None => {
                    eprintln!("--config-path requires a value");
                    std::process::exit(2);
                }
            }
        } else if let Some(rest) = arg.strip_prefix("--config-path=") {
            config_path = Some(PathBuf::from(rest));
        }
        // Other args are passed through to Tauri's CLI parser.
    }
    if let Some(p) = config_path {
        alayaface_lib::dirs::set_override(p);
    }

    alayaface_lib::run()
}
