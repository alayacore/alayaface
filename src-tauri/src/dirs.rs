//! Directory and file management for AlayaFace.
//!
//! Manages `~/.alayaface/` structure:
//!   ~/.alayaface/
//!     active-preset        — name of the currently active preset
//!     presets/
//!       <name>/            — one config directory per preset
//!         model.conf       (auto-created by alayacore when missing)
//!         runtime.conf     (auto-managed by alayacore)
//!         mcp.conf         (optional; copied when present)
//!         settings.conf    — AlayaFace-owned (tool_confirm etc.); NOT copied into sessions
//!         themes/          (auto-created by alayacore when missing)
//!     sessions/
//!       <uuid>/            — PLAIN sessions only (top level is never a plan child)
//!         config/          — copy of the active preset's config (minus settings.conf)
//!         session.alaya    (created by alayacore)
//!         plans/           — plans created by this session (0..N)
//!           <planId>/      — one subtree per plan (sanitized id)
//!             <planId>.json / .meta.json / .run.json
//!             work/        — per-plan working directory
//!             <nodeId>/    — one subtree per plan node (sanitized id)
//!               <uuid>/    — the node's session dir (config/ + session.alaya)

use std::path::PathBuf;

/// Get alayaface's base directory (~/.alayaface).
pub fn alayaface_dir() -> PathBuf {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".alayaface")
}

/// Directory holding all presets (~/.alayaface/presets).
pub fn presets_root() -> PathBuf {
    alayaface_dir().join("presets")
}

/// File recording the active preset name (~/.alayaface/active-preset).
pub fn active_preset_file() -> PathBuf {
    alayaface_dir().join("active-preset")
}

/// A preset name is a short, filesystem-safe identifier.
pub fn valid_preset_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Absolute path of a preset's config directory.
pub fn preset_dir(name: &str) -> PathBuf {
    presets_root().join(name)
}

/// Read the active preset name. Errors if the marker is missing/invalid.
pub fn read_active_preset() -> Result<String, String> {
    let path = active_preset_file();
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("Failed to read active preset: {e}"))?;
    let name = text.trim().to_string();
    if !valid_preset_name(&name) {
        return Err(format!("Invalid active preset name: {name:?}"));
    }
    Ok(name)
}

/// Persist the active preset name (atomic: temp file + rename).
/// The temp name is unique per call (pid + nanosecond timestamp) so
/// concurrent writers (e.g. init seeding racing create_session's ensure)
/// never clobber each other's temp file before its rename.
pub fn write_active_preset(name: &str) -> Result<(), String> {
    if !valid_preset_name(name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let path = active_preset_file();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = alayaface_dir().join(format!("active-preset-{}-{}.tmp", std::process::id(), nanos));
    std::fs::write(&tmp, name)
        .map_err(|e| format!("Failed to write active preset: {e}"))?;
    std::fs::rename(&tmp, &path)
        .map_err(|e| format!("Failed to replace active preset: {e}"))?;
    Ok(())
}

/// Config directory of the active preset.
pub fn active_config_dir() -> Result<PathBuf, String> {
    Ok(preset_dir(&read_active_preset()?))
}

/// Resolve the config dir for a preset name. Empty/whitespace means the
/// active preset. Errors for unknown presets or invalid names.
pub fn resolve_config_dir(preset: &str) -> Result<PathBuf, String> {
    if preset.trim().is_empty() {
        let (config_dir, _) = ensure()?;
        return Ok(config_dir);
    }
    let name = preset.trim().to_string();
    if !valid_preset_name(&name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let dir = preset_dir(&name);
    if !dir.exists() {
        return Err(format!("Preset not found: {name}"));
    }
    Ok(dir)
}

/// List preset names (sorted). Missing presets root yields an empty list.
pub fn list_preset_names() -> Result<Vec<String>, String> {
    let presets = presets_root();
    if !presets.exists() {
        return Ok(Vec::new());
    }
    let mut names = Vec::new();
    for entry in std::fs::read_dir(&presets)
        .map_err(|e| format!("Cannot read presets dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("Read error: {e}"))?;
        if entry.path().is_dir() {
            if let Some(name) = entry.file_name().to_str() {
                if valid_preset_name(name) {
                    names.push(name.to_string());
                }
            }
        }
    }
    names.sort();
    Ok(names)
}

/// Ensure `~/.alayaface/` exists with the preset structure.
/// On first run, seeds the built-in presets (Default/Fast/Deep/Data/Safe)
/// and marks Default active.
/// Returns `(active_config_dir, sessions_dir)`.
pub fn ensure() -> Result<(PathBuf, PathBuf), String> {
    let base = alayaface_dir();
    let presets = presets_root();
    let sessions = base.join("sessions");

    std::fs::create_dir_all(&presets)
        .map_err(|e| format!("Cannot create {:?}: {}", presets, e))?;
    std::fs::create_dir_all(&sessions)
        .map_err(|e| format!("Cannot create {:?}: {}", sessions, e))?;

    // Seed built-in presets on first run (idempotent per preset).
    for name in SEED_PRESETS {
        let dir = presets.join(name);
        if !dir.exists() {
            create_preset_defaults(&dir, name)?;
        }
    }

    if !active_preset_file().exists() {
        write_active_preset("Default")?;
    }

    let active = read_active_preset()?;
    let config = preset_dir(&active);
    Ok((config, sessions))
}

/// Built-in presets seeded on first run. Each is a config template
/// (model/mcp placeholders); users fill keys and can copy/rename.
pub const SEED_PRESETS: [&str; 5] = ["Default", "Fast", "Deep", "Data", "Safe"];

/// Create a session directory with a copy of the active preset's config.
/// The session.alaya file itself is created by alayacore when the session starts.
/// settings.conf is AlayaFace-owned and intentionally NOT copied into sessions.
pub fn create_session_dir(sessions_dir: &PathBuf, uuid: &str) -> Result<PathBuf, String> {
    create_session_dir_from(sessions_dir, uuid, "")
}

/// Create a session directory from a specific preset's config
/// (`preset` empty = active preset). Used by Plan Mode so different DAG
/// nodes can run under different presets. settings.conf is excluded.
pub fn create_session_dir_from(
    sessions_dir: &PathBuf,
    uuid: &str,
    preset: &str,
) -> Result<PathBuf, String> {
    create_session_dir_in(sessions_dir, uuid, preset)
}

/// Map an arbitrary plan/node id to a safe single path component
/// (deterministic: create and resume apply the same mapping, so both
/// sides agree on the directory). Every character outside
/// [A-Za-z0-9_-] becomes '_' — including '.', so an id of ".." can
/// never resolve to a parent directory — and an empty result becomes
/// "p". Mirrors Go dirs.SanitizeDirComponent.
pub fn sanitize_dir_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('p');
    }
    out
}

/// Create a PLAN NODE session directory nested under
/// <originSessionDir>/plans/<planId>/<nodeId>/<uuid>/, where
/// originSessionDir is the owning session's REAL directory (the frontend
/// passes sessions/<id> for a top-level session or the nested node-session
/// dir for a plan child — P28: the sessions/ top level only ever contains
/// plain sessions). All id components are sanitized with
/// `sanitize_dir_component`. Mirrors Go CreatePlanSessionDirFrom.
pub fn create_session_dir_nested(
    _sessions_dir: &PathBuf,
    origin_session_dir: &str,
    plan_id: &str,
    node_id: &str,
    uuid: &str,
    preset: &str,
) -> Result<PathBuf, String> {
    let parent = PathBuf::from(origin_session_dir)
        .join("plans")
        .join(sanitize_dir_component(plan_id))
        .join(sanitize_dir_component(node_id));
    create_session_dir_in(&parent, uuid, preset)
}

/// Shared body: copy the preset's config into parent/<uuid>/config.
fn create_session_dir_in(parent: &std::path::Path, uuid: &str, preset: &str) -> Result<PathBuf, String> {
    ensure()?; // guarantee presets exist + active marker set
    let session_dir = parent.join(uuid);
    let dst_config = session_dir.join("config");
    let template = if preset.is_empty() {
        active_config_dir()?
    } else {
        let dir = preset_dir(preset);
        if !dir.exists() {
            return Err(format!("Preset not found: {preset}"));
        }
        dir
    };

    copy_dir_excluding(&template, &dst_config, &["settings.conf"])?;

    Ok(session_dir)
}

// ─── Internal Helpers ────────────────────────────────────────────────

/// Recursively copy a whole preset directory (including settings.conf) —
/// used when cloning the active preset to create a new one.
pub fn clone_preset_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    copy_dir(src, dst)
}

/// Seed a new preset's config with built-in defaults. `name` selects the
/// template: the Safe preset disables execute_command via settings.conf.
///
/// Presets are seeded as EMPTY shells: model.conf, runtime.conf and
/// themes/ are auto-created by alayacore on first use (verified against
/// the real binary — an empty config dir starts clean and alayacore
/// writes a working local-Ollama default model). Only AlayaFace-owned
/// settings.conf is written here, and only where it is meaningful.
pub fn create_preset_defaults(dir: &std::path::Path, name: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Cannot create {:?}: {}", dir, e))?;
    if name == "Safe" {
        // No execute_command: read/write/edit/search only.
        std::fs::write(
            dir.join("settings.conf"),
            "{\n  \"tool_confirm\": \"\",\n  \"builtin_tools\": \"read_file,write_file,edit_file,search_content\"\n}\n",
        )
        .map_err(|e| format!("Cannot write settings.conf: {e}"))?;
    }
    Ok(())
}

/// Recursively copy a directory, skipping any files whose names are in `exclude`.
fn copy_dir_excluding(
    src: &std::path::Path,
    dst: &std::path::Path,
    exclude: &[&str],
) -> Result<(), String> {
    std::fs::create_dir_all(dst)
        .map_err(|e| format!("Cannot create {:?}: {}", dst, e))?;
    for entry in std::fs::read_dir(src).map_err(|e| format!("Cannot read {:?}: {}", src, e))? {
        let entry = entry.map_err(|e| format!("Read error: {}", e))?;
        let ty = entry.file_type().map_err(|e| format!("Stat error: {}", e))?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy().to_string();
        if !ty.is_dir() && exclude.contains(&name_str.as_str()) {
            continue;
        }
        if ty.is_dir() {
            copy_dir_excluding(&entry.path(), &dst.join(&name), exclude)?;
        } else {
            std::fs::copy(&entry.path(), &dst.join(&name))
                .map_err(|e| format!("Copy error: {}", e))?;
        }
    }
    Ok(())
}

/// Recursively copy a directory (everything).
fn copy_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    copy_dir_excluding(src, dst, &[])
}

// ─── Spawn args persistence ─────────────────────────────────────────
//
// The alayacore spawn arguments used when a session was created are
// persisted as <sessionDir>/session.spawn.json so resume_session can
// re-apply them: a resumed session must keep its capability envelope
// (builtin-tools restriction, tool-confirm policy, planner prompt, work
// dir) — otherwise e.g. a Plan Session with NO tools would come back
// with ALL tools after a restart. Mirrors Go internal/dirs/spawn.go.

/// The spawn-args file inside a session directory.
pub fn spawn_args_file(session_dir: &std::path::Path) -> PathBuf {
    session_dir.join("session.spawn.json")
}

/// Persisted spawn configuration of a session.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct SpawnArgs {
    /// --tool-confirm list ("allow" = runner auto-approve).
    pub tool_confirm: String,
    /// None = don't pass --builtin-tools (all tools); Some("") = NO
    /// builtin tools (Plan Sessions); Some("a,b") = those tools only.
    pub builtin_tools: Option<String>,
    /// --system text (planner hint / delegation).
    pub system_prompt: String,
    /// Child working directory (per-plan isolation).
    pub work_dir: String,
}

impl SpawnArgs {
    /// Log-friendly summary.
    pub fn summary(&self) -> String {
        let bt = match &self.builtin_tools {
            Some(v) if v.is_empty() => "<none>".to_string(),
            Some(v) => v.clone(),
            None => "<unset>".to_string(),
        };
        format!(
            "tool_confirm={:?} builtin_tools={} system_prompt={} chars work_dir={:?}",
            self.tool_confirm,
            bt,
            self.system_prompt.chars().count(),
            self.work_dir
        )
    }
}

/// Persist the spawn args atomically (tmp + rename).
pub fn write_spawn_args(session_dir: &std::path::Path, args: &SpawnArgs) -> Result<(), String> {
    let path = spawn_args_file(session_dir);
    let tmp = session_dir.join("session.spawn.json.tmp");
    let text = serde_json::to_string_pretty(args)
        .map_err(|e| format!("Cannot serialize spawn args: {e}"))?;
    std::fs::write(&tmp, text)
        .map_err(|e| format!("Cannot write spawn args: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Cannot persist spawn args: {e}"))
}

/// Read the persisted spawn args. A missing or corrupt file yields
/// zero-value args (legacy pre-persistence behavior) — never an error,
/// so resume keeps working for old sessions.
pub fn read_spawn_args(session_dir: &std::path::Path) -> SpawnArgs {
    let text = match std::fs::read_to_string(spawn_args_file(session_dir)) {
        Ok(t) => t,
        Err(_) => return SpawnArgs::default(),
    };
    match serde_json::from_str::<SpawnArgs>(&text) {
        Ok(mut args) => {
            // Defensive: a relative work dir would resolve against the
            // backend's cwd, not the session's — treat as absent.
            if !args.work_dir.is_empty() && !std::path::Path::new(&args.work_dir).is_absolute() {
                args.work_dir = String::new();
            }
            args
        }
        Err(_) => SpawnArgs::default(),
    }
}

#[cfg(test)]
pub(crate) static TEST_HOME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
static TEST_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Run a closure with HOME pointed at a fresh isolated temp dir, under a
/// process-wide lock. All tests that mutate the HOME env var MUST go through
/// this helper — HOME is process-global, so per-module locks are not enough.
#[cfg(test)]
pub(crate) fn isolated_home<F: FnOnce() -> R, R>(f: F) -> R {
    let _guard = TEST_HOME_LOCK.lock().unwrap();
    let old_home = std::env::var_os("HOME");
    let tmp = std::env::temp_dir().join(format!(
        "alayaface-test-{}-{}",
        std::process::id(),
        TEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
    ));
    std::env::set_var("HOME", &tmp);
    let result = f();
    match old_home {
        Some(h) => std::env::set_var("HOME", h),
        None => std::env::remove_var("HOME"),
    }
    let _ = std::fs::remove_dir_all(&tmp);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_name_validation() {
        assert!(valid_preset_name("Default"));
        assert!(valid_preset_name("work-a_b2"));
        assert!(!valid_preset_name(""));
        assert!(!valid_preset_name("a/b"));
        assert!(!valid_preset_name(".."));
        assert!(!valid_preset_name("with space"));
        assert!(!valid_preset_name(&"x".repeat(65)));
    }

    #[test]
    fn ensure_seeds_defaults() {
        isolated_home(|| {
            let (config, _) = ensure().unwrap();
            // Presets are EMPTY shells: alayacore auto-creates
            // model.conf/runtime.conf/themes on first use. Seeding an
            // empty model.conf even produced "API key is required"
            // noise (fake Placeholder model), and a "{}" runtime.conf
            // made alayacore emit a parse error on every startup.
            assert!(!config.join("model.conf").exists(), "model.conf must not be pre-seeded");
            assert!(!config.join("runtime.conf").exists(), "runtime.conf must not be pre-seeded");
            assert_eq!(read_active_preset().unwrap(), "Default");

            // All seed presets exist; Safe disables execute_command.
            for name in SEED_PRESETS {
                assert!(preset_dir(name).is_dir(), "missing seed preset {name}");
            }
            let safe_settings =
                std::fs::read_to_string(preset_dir("Safe").join("settings.conf")).unwrap();
            assert!(safe_settings.contains("read_file,write_file,edit_file,search_content"));
            assert!(!safe_settings.contains("execute_command"));
            // Non-Safe presets carry no settings.conf (defaults apply).
            assert!(!preset_dir("Default").join("settings.conf").exists());
        });
    }

    #[test]
    fn session_dir_copy_excludes_settings_conf() {
        isolated_home(|| {
            let (config, sessions) = ensure().unwrap();
            // Copying an EXISTING preset is the meaningful path: files in
            // the source are copied, settings.conf (AlayaFace-owned) is not.
            std::fs::write(config.join("model.conf"), "name: \"Real\"\n").unwrap();
            std::fs::write(config.join("settings.conf"), "{\"tool_confirm\":\"x\"}").unwrap();

            let session_dir = create_session_dir(&sessions, "abc").unwrap();
            assert_eq!(
                std::fs::read_to_string(session_dir.join("config").join("model.conf")).unwrap(),
                "name: \"Real\"\n"
            );
            assert!(!session_dir.join("config").join("settings.conf").exists());
        });
    }

    #[test]
    fn create_session_dir_from_specific_preset() {
        isolated_home(|| {
            let (_, sessions) = ensure().unwrap();
            // Safe's settings.conf must not leak into the session config,
            // while its real files (e.g. a configured model.conf) are copied.
            std::fs::write(preset_dir("Safe").join("model.conf"), "name: \"SafeModel\"\n").unwrap();
            let dir = create_session_dir_from(&sessions, "xyz", "Safe").unwrap();
            assert_eq!(
                std::fs::read_to_string(dir.join("config").join("model.conf")).unwrap(),
                "name: \"SafeModel\"\n"
            );
            assert!(!dir.join("config").join("settings.conf").exists());

            // Unknown preset is rejected.
            assert!(create_session_dir_from(&sessions, "q", "nope").is_err());
        });
    }

    #[test]
    fn sanitize_dir_component_maps_to_safe_names() {
        assert_eq!(sanitize_dir_component("demo-1"), "demo-1");
        assert_eq!(sanitize_dir_component("task 1"), "task_1");
        assert_eq!(sanitize_dir_component("a/b"), "a_b");
        assert_eq!(sanitize_dir_component(".."), "__");
        assert_eq!(sanitize_dir_component("."), "_");
        assert_eq!(sanitize_dir_component(""), "p");
        // Deterministic: create and resume must agree.
        assert_eq!(sanitize_dir_component("a/b"), sanitize_dir_component("a_b"));
    }

    #[test]
    fn create_session_dir_nested_keeps_plan_children_out_of_top_level() {
        isolated_home(|| {
            let (config, sessions) = ensure().unwrap();
            std::fs::write(config.join("model.conf"), "name: \"Real\"\n").unwrap();

            let dir = create_session_dir_nested(&sessions, &sessions.join("sess-1").to_string_lossy(), "demo plan/x", "t1", "uuid-1", "").unwrap();
            let want = sessions.join("sess-1").join("plans").join("demo_plan_x").join("t1").join("uuid-1");
            assert_eq!(dir, want);
            assert!(dir.join("config").join("model.conf").exists());
            // Neither the session uuid nor the plan id may appear at the
            // sessions top level (the plan lives under its session).
            assert!(!sessions.join("uuid-1").exists());
            assert!(!sessions.join("demo_plan_x").exists());
        });
    }

    #[test]
    fn spawn_args_roundtrip() {
        isolated_home(|| {
            let dir = std::env::temp_dir().join(format!(
                "alayaface-spawn-args-{}-{}",
                std::process::id(),
                TEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            ));
            std::fs::create_dir_all(&dir).unwrap();

            // Full envelope: no-tools restriction + runner tool-confirm +
            // planner prompt + work dir.
            let full = SpawnArgs {
                tool_confirm: "allow".into(),
                builtin_tools: Some(String::new()),
                system_prompt: "planner-hint".into(),
                work_dir: "/tmp/plan-work".into(),
            };
            write_spawn_args(&dir, &full).unwrap();
            let got = read_spawn_args(&dir);
            assert_eq!(got.tool_confirm, "allow");
            assert_eq!(got.system_prompt, "planner-hint");
            assert_eq!(got.work_dir, "/tmp/plan-work");
            assert_eq!(got.builtin_tools, Some(String::new()), "explicit empty = NO tools");

            // Nil builtin_tools (don't pass the flag = all tools).
            write_spawn_args(&dir, &SpawnArgs::default()).unwrap();
            assert_eq!(read_spawn_args(&dir).builtin_tools, None);

            // A relative work dir is defensively dropped.
            write_spawn_args(&dir, &SpawnArgs { work_dir: "relative/dir".into(), ..SpawnArgs::default() }).unwrap();
            assert_eq!(read_spawn_args(&dir).work_dir, "");

            let _ = std::fs::remove_dir_all(&dir);
        });
        // Missing file → zero values (legacy sessions resume unrestricted).
        let empty = read_spawn_args(std::path::Path::new("/nonexistent-dir"));
        assert_eq!(empty.tool_confirm, "");
        assert_eq!(empty.builtin_tools, None);
    }

    #[test]
    fn spawn_args_serialization_matches_shared_fixture() {
        // M1 truth table (D3): session.spawn.json must serialize to the
        // exact bytes in testdata/serialization/spawn_cases.json — the
        // same fixture the Go side (dirs/spawn_serialization_test.go)
        // is tested against. Locks the builtin_tools null semantics
        // (None -> null, Some("") -> "", Some("a,b") -> "a,b").
        #[derive(serde::Deserialize)]
        struct Fixture {
            cases: Vec<Case>,
        }
        #[derive(serde::Deserialize)]
        struct Case {
            name: String,
            input: Input,
            expected: String,
        }
        #[derive(serde::Deserialize)]
        struct Input {
            tool_confirm: String,
            builtin_tools: Option<String>,
            system_prompt: String,
            work_dir: String,
        }

        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../testdata/serialization/spawn_cases.json");
        let text = std::fs::read_to_string(&path).expect("read spawn_cases.json fixture");
        let fx: Fixture = serde_json::from_str(&text).expect("parse spawn_cases.json fixture");

        for c in fx.cases {
            let args = SpawnArgs {
                tool_confirm: c.input.tool_confirm,
                builtin_tools: c.input.builtin_tools,
                system_prompt: c.input.system_prompt,
                work_dir: c.input.work_dir,
            };
            let got = serde_json::to_string_pretty(&args).unwrap();
            assert_eq!(got, c.expected, "SpawnArgs case {}", c.name);
        }
    }
}
