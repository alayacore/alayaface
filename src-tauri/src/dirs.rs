//! Directory and file management for AlayaFace.
//!
//! Manages `~/.alayaface/` structure:
//!   ~/.alayaface/
//!     global.conf          — cross-preset global config overlay (recursion_limit etc.)
//!     asr.conf             — voice-input ASR config (OpenAI-compatible endpoint URL)
//!     preset_order.conf    — user-defined preset display order (JSON array of names)
//!     presets/
//!       <name>/            — one config directory per preset
//!         model.conf       (auto-created by alayacore when missing)
//!         runtime.conf     (auto-managed by alayacore)
//!         mcp.conf         (optional; copied when present)
//!         settings.conf    — AlayaFace-owned (tool_confirm, builtin_tools, system_prompt); NOT copied into sessions
//!         themes/          (auto-created by alayacore when missing)
//!     sessions/
//!       <uuid>/            — PLAIN sessions only (top level is never a plan child)
//!         config/          — copy of the creating preset's config (minus settings.conf)
//!         session.alaya    (created by alayacore)
//!         plans/           — plans created by this session (0..N)
//!           <planId>/      — one subtree per plan (sanitized id)
//!             <planId>.json / .meta.json / .run.json
//!             work/        — per-plan working directory
//!             <nodeId>/    — one subtree per plan node (sanitized id)
//!               <uuid>/    — the node's session dir (config/ + session.alaya)
//!
//! There is no "active preset": every session is created under an
//! explicitly chosen preset (the frontend always passes one), and each
//! preset carries its own settings.conf including the system_prompt
//! used as --system.

use std::path::PathBuf;
use std::sync::RwLock;

/// Process-global override for the base config directory. When set via
/// `set_override` (from the --config-path CLI flag), it replaces
/// `$HOME/.alayaface` in every helper. Mutating it after startup is
/// racy — callers should treat it as one-shot init.
///
/// `RwLock` so the read path (AlayafaceDir → many call sites) doesn't
/// block the writer and tests can re-set it freely.
static CONFIG_PATH_OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Override the base config directory used by every helper in this
/// crate. Pass an empty `PathBuf` (or the default) to fall back to
/// `$HOME/.alayaface`. A leading `~` or `~/` is expanded against
/// `$HOME`, mirroring the Go side.
pub fn set_override(path: PathBuf) {
    let mut guard = CONFIG_PATH_OVERRIDE.write().expect("CONFIG_PATH_OVERRIDE poisoned");
    *guard = if path.as_os_str().is_empty() { None } else { Some(path) };
}

/// Read the current override (empty when the default $HOME/.alayaface
/// is in effect). Tests inspect this to verify the flag plumbed through.
pub fn override_path() -> PathBuf {
    let guard = CONFIG_PATH_OVERRIDE.read().expect("CONFIG_PATH_OVERRIDE poisoned");
    guard.clone().unwrap_or_default()
}

/// Get alayaface's base directory ($HOME/.alayaface by default, or the
/// --config-path override when set).
pub fn alayaface_dir() -> PathBuf {
    let override_dir = {
        let guard = CONFIG_PATH_OVERRIDE.read().expect("CONFIG_PATH_OVERRIDE poisoned");
        guard.clone()
    };
    if let Some(path) = override_dir {
        return expand_home(&path);
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".alayaface")
}

/// Expand a leading "~" or "~/" against $HOME. A bare "~" becomes
/// $HOME; absolute and relative paths pass through unchanged (mirrors
/// the Go side).
fn expand_home(path: &std::path::Path) -> PathBuf {
    let s = path.to_string_lossy();
    if s == "~" {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".to_string());
        return PathBuf::from(home);
    }
    if let Some(rest) = s.strip_prefix("~/").or_else(|| s.strip_prefix("~\\")) {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".to_string());
        return PathBuf::from(home).join(rest);
    }
    path.to_path_buf()
}

/// Directory holding all presets (~/.alayaface/presets).
pub fn presets_root() -> PathBuf {
    alayaface_dir().join("presets")
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

/// Resolve the config dir for a preset name. The preset is REQUIRED —
/// there is no active-preset fallback. Errors for empty/invalid names
/// or unknown presets.
pub fn resolve_config_dir(preset: &str) -> Result<PathBuf, String> {
    let name = preset.trim().to_string();
    if name.is_empty() {
        return Err("Preset is required".to_string());
    }
    if !valid_preset_name(&name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let dir = preset_dir(&name);
    if !dir.exists() {
        return Err(format!("Preset not found: {name}"));
    }
    Ok(dir)
}

/// File recording the user's custom preset display order
/// (~/.alayaface/preset_order.conf). The file is a JSON array of preset
/// names; a missing file means alphabetical order.
pub fn preset_order_file() -> PathBuf {
    alayaface_dir().join("preset_order.conf")
}

/// Read the saved preset display order (names in order). A missing or
/// corrupt file yields an empty vec (fall back to alphabetical);
/// invalid/duplicate names are dropped.
pub fn read_preset_order() -> Vec<String> {
    let Ok(data) = std::fs::read_to_string(preset_order_file()) else {
        return Vec::new();
    };
    let Ok(raw): Result<Vec<String>, _> = serde_json::from_str(&data) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(raw.len());
    let mut seen = std::collections::HashSet::new();
    for n in raw {
        if valid_preset_name(&n) && seen.insert(n.clone()) {
            out.push(n);
        }
    }
    out
}

/// Persist `text` to `path` via a UNIQUE temporary file in the same
/// directory, then a rename (so a reader never sees a half-written config and
/// a crash cannot leave the real file truncated).
///
/// The temp name has to be unique per write. Every config writer used to
/// build one itself — `"{path}.tmp"`, `"settings.conf.tmp"`,
/// `"mcp.conf.tmp"`, `"session.spawn.json.tmp"` — and this API is reachable
/// from several clients at once (LAN / SSH-forwarded tabs; the Go backend is
/// multi-client, which is why sessions carry an owner and
/// close_all_sessions is per-client). Two concurrent syncs of the same file
/// wrote the SAME temp: bytes interleaved and the first rename published a
/// corrupt config while the loser failed with ENOENT.
///
/// Mirrors Go's dirs.WriteFileAtomic.
pub fn write_file_atomic(path: &std::path::Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let base = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("alayaface-conf");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let tmp = dir.join(format!(
        "{}.tmp-{}-{}-{}",
        base,
        std::process::id(),
        nanos,
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));

    let result = (|| -> Result<(), String> {
        let mut f = std::fs::File::create(&tmp).map_err(|e| format!("Cannot write {}: {e}", base))?;
        f.write_all(text.as_bytes())
            .map_err(|e| format!("Cannot write {}: {e}", base))?;
        f.sync_all().map_err(|e| format!("Cannot write {}: {e}", base))?;
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644));
        }
        std::fs::rename(&tmp, path).map_err(|e| format!("Cannot write {}: {e}", base))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Atomically persist the custom preset display order.
pub fn write_preset_order(names: &[String]) -> Result<(), String> {
    let text = serde_json::to_string_pretty(names)
        .map_err(|e| format!("Serialize preset order: {e}"))?;
    write_file_atomic(&preset_order_file(), &text)
        .map_err(|e| format!("Write preset order: {e}"))
}

/// List preset names. The user's custom order (preset_order.conf) is
/// applied when present: saved names that still exist come first (in
/// saved order), followed by any remaining presets in sorted order — so
/// a preset added later is never hidden. Missing presets root yields an
/// empty list.
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

    let ordered = read_preset_order();
    if ordered.is_empty() {
        return Ok(names);
    }
    let existing: std::collections::HashSet<&String> = names.iter().collect();
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(names.len());
    for n in ordered {
        if existing.contains(&n) && seen.insert(n.clone()) {
            out.push(n);
        }
    }
    for n in names {
        if !seen.contains(&n) {
            out.push(n);
        }
    }
    Ok(out)
}

/// Ensure `~/.alayaface/` exists with the preset structure.
/// On FIRST RUN (empty presets root), seeds the built-in presets
/// (Simple/Complex/Talk) with their settings.conf (tool_confirm/
/// builtin_tools/system_prompt). Once seeded, the seeds are regular
/// presets: deleting one must not resurrect it, so seeding never runs
/// again on a non-empty root. Returns the sessions dir.
pub fn ensure() -> Result<PathBuf, String> {
    let base = alayaface_dir();
    let presets = presets_root();
    let sessions = base.join("sessions");

    std::fs::create_dir_all(&presets)
        .map_err(|e| format!("Cannot create {:?}: {}", presets, e))?;
    std::fs::create_dir_all(&sessions)
        .map_err(|e| format!("Cannot create {:?}: {}", sessions, e))?;

    // Seed built-in presets on first run only (a non-empty root means
    // the user has already managed presets — deleting a seed must not
    // resurrect it).
    let entries: Vec<_> = std::fs::read_dir(&presets)
        .map_err(|e| format!("Cannot read {:?}: {}", presets, e))?
        .collect();
    if entries.is_empty() {
        for name in SEED_PRESETS {
            let dir = presets.join(name);
            create_preset_defaults(&dir, name)?;
        }
    }

    Ok(sessions)
}

/// Built-in presets seeded on first run:
///   - Simple  — light everyday chat and one-sentence subtasks
///   - Complex — heavy reasoning / multi-step / research subtasks
///   - Talk    — voice-first quick chat (the push-to-talk ` key opens a
///     new session under this preset and auto-starts ASR recording)
///
/// Each is a config template (model/mcp placeholders); users fill keys,
/// tune settings.conf and can copy them. The plan contract in the seeded
/// system_prompt names Simple/Complex, so they cannot be renamed (see
/// `is_seed_preset`); Talk is protected too (the push-to-talk feature
/// opens sessions by this exact name).
pub const SEED_PRESETS: [&str; 3] = ["Simple", "Complex", "Talk"];

/// Whether a preset is one of the built-in seeds. Seed presets are
/// referenced by name in the seeded system_prompt, so renaming them is
/// rejected (rename_preset).
pub fn is_seed_preset(name: &str) -> bool {
    SEED_PRESETS.contains(&name)
}

/// Create a session directory from a specific preset's config (preset
/// REQUIRED). Used by Plan Mode so different DAG nodes can run under
/// different presets. settings.conf is excluded.
pub fn create_session_dir_from(
    sessions_dir: &std::path::Path,
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

/// Report whether s is a single, non-empty path component that cannot escape
/// its parent directory. Client-supplied ids that end up inside a path
/// (session ids in particular, which `delete_session_dir` feeds to
/// `remove_dir_all`) are REJECTED rather than sanitized, so a buggy or hostile
/// client gets "Invalid session id" instead of the backend quietly touching a
/// different directory. Other characters (dots, spaces) stay allowed: session
/// directories are uuids, but a hand-named one must still resolve.
/// Mirrors Go's `SafePathComponent`.
pub fn safe_path_component(s: &str) -> bool {
    if s.is_empty() || s == "." || s == ".." {
        return false;
    }
    !s.contains('/') && !s.contains('\\') && !s.contains('\0')
}

/// Map the OWNING session's location to a directory. The frontend hands back
/// either form — the real on-disk directory (sessionDirMap) or a bare session
/// id — and a bare id resolves against the sessions root. Both backends must
/// map it identically or the same plan node session lands in (and is deleted
/// from) a different place depending on which one is running.
fn resolve_origin_session_dir(sessions_root: &std::path::Path, origin_session_dir: &str) -> PathBuf {
    let base = origin_session_dir.trim();
    if base.is_empty() {
        return sessions_root.to_path_buf();
    }
    if !base.contains('/') && !base.contains('\\') {
        return sessions_root.join(base);
    }
    PathBuf::from(base)
}

/// Return `path` when it stays inside `root`. Without this, a nested session
/// whose origin path escapes the sessions store would let delete_session_dir
/// remove arbitrary directories outside it.
fn contained_under(root: &std::path::Path, path: &std::path::Path) -> Result<PathBuf, String> {
    match path.strip_prefix(root) {
        Ok(rel) if !rel.as_os_str().is_empty() => Ok(path.to_path_buf()),
        _ => Err(format!("Session path escapes the sessions directory: {:?}", path)),
    }
}

/// Build the on-disk directory of a session and validate that it is a path we
/// are allowed to create/read/delete:
///
/// ```text
/// plain      → <sessions_root>/<session_id>
/// plan node  → <origin_dir>/plans/<plan_id>/<node_id>/<session_id>
/// ```
///
/// plan_id / node_id go through `sanitize_dir_component` (create applies the
/// SAME mapping, so resume still finds the directory it created); session_id
/// must be a single safe component; and a nested path must stay inside the
/// sessions root. This is the ONE path rule — `create_session_dir_nested` and
/// the resume/delete/fork commands all call it. Mirrors Go's `dirs.SessionPath`
/// (including its containment rule, which is why `sessions_root` is no longer
/// unused here).
pub fn session_path(
    sessions_root: &std::path::Path,
    origin_session_dir: &str,
    plan_id: &str,
    node_id: &str,
    session_id: &str,
) -> Result<PathBuf, String> {
    if !safe_path_component(session_id) {
        return Err(format!("Invalid session id: {:?}", session_id));
    }
    if plan_id.trim().is_empty() {
        return Ok(sessions_root.join(session_id));
    }
    let path = resolve_origin_session_dir(sessions_root, origin_session_dir)
        .join("plans")
        .join(sanitize_dir_component(plan_id))
        .join(sanitize_dir_component(node_id))
        .join(session_id);
    contained_under(sessions_root, &path)
}

/// Create a PLAN NODE session directory nested under
/// <originSessionDir>/plans/<planId>/<nodeId>/<uuid>/, where
/// originSessionDir is the owning session's REAL directory (the frontend
/// passes sessions/<id> for a top-level session or the nested node-session
/// dir for a plan child — P28: the sessions/ top level only ever contains
/// plain sessions). All id components are sanitized with
/// `sanitize_dir_component`. Mirrors Go CreatePlanSessionDirFrom.
pub fn create_session_dir_nested(
    sessions_dir: &std::path::Path,
    origin_session_dir: &str,
    plan_id: &str,
    node_id: &str,
    uuid: &str,
    preset: &str,
) -> Result<PathBuf, String> {
    // One rule with the resume/delete/fork side: build and validate the
    // directory via session_path, then materialize it (copy the preset
    // config). The param used to be unused (`_sessions_dir`) — Go has always
    // resolved a bare origin id against it, which is the divergence that let
    // the two backends disagree about where a plan node session lives.
    let dir = session_path(sessions_dir, origin_session_dir, plan_id, node_id, uuid)?;
    create_session_dir_in(dir.parent().unwrap_or(sessions_dir), uuid, preset)
}

/// Shared body: copy the preset's config into parent/<uuid>/config.
/// The preset is REQUIRED — there is no active-preset fallback.
fn create_session_dir_in(parent: &std::path::Path, uuid: &str, preset: &str) -> Result<PathBuf, String> {
    ensure()?; // guarantee presets exist (seeded on first run)
    let name = preset.trim().to_string();
    if name.is_empty() {
        return Err("Preset is required".to_string());
    }
    if !valid_preset_name(&name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let template = preset_dir(&name);
    if !template.exists() {
        return Err(format!("Preset not found: {name}"));
    }

    let session_dir = parent.join(uuid);
    let dst_config = session_dir.join("config");
    copy_dir_excluding(&template, &dst_config, &["settings.conf"])?;

    Ok(session_dir)
}

// ─── Internal Helpers ────────────────────────────────────────────────

/// Recursively copy a whole preset directory (including settings.conf) —
/// used when cloning a preset to create a new one.
pub fn clone_preset_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    copy_dir(src, dst)
}

/// The plan-mode contract shared by every seed preset: when to output a
/// plan, the exact JSON schema, per-task preset choice and stopping
/// rules. Keep in sync with src-go/internal/dirs/dirs.go planContract.
pub const PLAN_CONTRACT: &str = r#"
You can use AlayaFace's plan mode: for complex or multi-step tasks, first output a plan so its subtasks run in parallel / by dependency, instead of doing everything yourself in one go.

When to output a plan:
- The task needs multiple steps, research/search across several areas, or a summarized report -> output a plan;
- A simple task (doable in one sentence) -> just do it directly, do not output a plan.

Plan format (output exactly one ```json code block, then stop and wait for the plan to finish executing):
{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "plan name",
  "goal": "goal description",
  "concurrency": 8,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "subtask title", "prompt": "complete, self-contained instruction", "depends_on": [], "preset": "Simple", "max_attempts": 3 }
  ]
}
Rules:
- The top level MUST include "type": "alayaface-plan" (without it the framework will not recognize the plan)
- Field names must be spelled exactly as in the schema above (depends_on, concurrency, max_attempts, ...) — a misspelled or extra field makes the whole plan be rejected; do not invent fields
- ids are globally unique; prompts are self-contained by default; if a downstream task needs an upstream task's output, reference it in the prompt with {{t1.output}} (the framework replaces it with that upstream task's final output once it completes; you may only reference tasks already declared as dependencies — never reference tasks outside the dependency graph)
- Tasks that can run in parallel must not depend on each other
- Set "preset" on EVERY task: "Simple" for light, one-sentence subtasks; "Complex" for heavy reasoning, multi-step or research subtasks. Both presets have models configured
- For risky tasks involving commands, restrict the tool set with the tools field (e.g. read-only tools)
- Even if a task needs no decomposition (doable in one sentence), still output a plan (a single task is fine) — that is your output format
- After outputting the plan: stop, wait for the plan to finish and its result to come back, then continue your answer based on the result"#;

/// The seeded --system text for the Talk preset (used by push-to-talk:
/// hold ` to open a Talk session and record). Deliberately short and
/// plan-free: voice turns want a quick spoken-style answer, never a
/// plan JSON. Keep in sync with src-go/internal/dirs/dirs.go talkPrompt.
pub const TALK_PROMPT: &str = "You are the Talk preset of AlayaFace: a fast, voice-first assistant for quick spoken questions. Reply briefly and conversationally, in one short paragraph. Never output plans, markdown or code blocks.";

/// The seeded --system text for a preset. Simple/Complex carry the full
/// plan-mode contract (any session may be asked to create a plan); the
/// difference is the role framing. Talk is a voice-first quick-chat
/// preset: short conversational replies, NO plan contract (a speech
/// turn must never trigger planning). Keep in sync with
/// src-go/internal/dirs/dirs.go seedSystemPrompt.
pub fn seed_system_prompt(name: &str) -> String {
    if name == "Talk" {
        return TALK_PROMPT.to_string();
    }
    let role = if name == "Complex" {
        "You are the Complex preset of AlayaFace: you handle heavy reasoning, multi-step and research-heavy tasks. Prefer decomposing them into a plan.\n"
    } else {
        "You are the Simple preset of AlayaFace: handle everyday chat and light tasks directly, in one go, without planning.\n"
    };
    format!("{role}{PLAN_CONTRACT}")
}

/// Seed a new preset's config with built-in defaults. Both seed presets
/// carry a settings.conf with their system_prompt (see seed_system_prompt).
///
/// Presets are seeded as EMPTY shells: model.conf, runtime.conf and
/// themes/ are auto-created by alayacore on first use (verified against
/// the real binary — an empty config dir starts clean and alayacore
/// writes a working local-Ollama default model). Only AlayaFace-owned
/// settings.conf is written here.
pub fn create_preset_defaults(dir: &std::path::Path, name: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Cannot create {:?}: {}", dir, e))?;
    let settings = serde_json::json!({
        "tool_confirm": "",
        "builtin_tools": "",
        "reasoning_level": 1,
        "system_prompt": seed_system_prompt(name),
    });
    let text = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Cannot build settings.conf: {e}"))?;
    std::fs::write(dir.join("settings.conf"), text)
        .map_err(|e| format!("Cannot write settings.conf: {e}"))
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
            std::fs::copy(entry.path(), dst.join(name))
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
    /// --system text (the preset's system_prompt, or a recursion guard
    /// over the plan depth limit).
    pub system_prompt: String,
    /// --reasoning-level (0|1|2); None = unset → default 1 on resume.
    /// Skipped when None so legacy spawn.json keeps its exact bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<i64>,
    /// Child working directory (per-plan isolation).
    pub work_dir: String,
    /// The preset this session was created under; forks of plain
    /// sessions inherit it so they stay in the same preset.
    pub preset: String,
}

impl SpawnArgs {
    /// Log-friendly summary.
    pub fn summary(&self) -> String {
        let bt = match &self.builtin_tools {
            Some(v) if v.is_empty() => "<none>".to_string(),
            Some(v) => v.clone(),
            None => "<unset>".to_string(),
        };
        let rl = match self.reasoning_level {
            Some(v) => v.to_string(),
            None => "<unset>".to_string(),
        };
        format!(
            "tool_confirm={:?} builtin_tools={} system_prompt={} chars reasoning_level={} work_dir={:?}",
            self.tool_confirm,
            bt,
            self.system_prompt.chars().count(),
            rl,
            self.work_dir
        )
    }
}

/// Persist the spawn args atomically (tmp + rename).
pub fn write_spawn_args(session_dir: &std::path::Path, args: &SpawnArgs) -> Result<(), String> {
    let text = serde_json::to_string_pretty(args)
        .map_err(|e| format!("Cannot serialize spawn args: {e}"))?;
    write_file_atomic(&spawn_args_file(session_dir), &text)
        .map_err(|e| format!("Cannot persist spawn args: {e}"))
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
            let sessions = ensure().unwrap();
            // Presets are EMPTY shells: alayacore auto-creates
            // model.conf/runtime.conf/themes on first use. Seeding an
            // empty model.conf even produced "API key is required"
            // noise (fake Placeholder model), and a "{}" runtime.conf
            // made alayacore emit a parse error on every startup.
            assert!(!sessions.join("config").exists(), "sessions dir is not a config dir");
            for name in SEED_PRESETS {
                let dir = preset_dir(name);
                assert!(dir.is_dir(), "missing seed preset {name}");
                assert!(!dir.join("model.conf").exists(), "{name}: model.conf must not be pre-seeded");
                assert!(!dir.join("runtime.conf").exists(), "{name}: runtime.conf must not be pre-seeded");
                // All seed presets carry AlayaFace-owned settings.conf.
                let settings = std::fs::read_to_string(dir.join("settings.conf")).unwrap();
                assert!(settings.contains("system_prompt"), "{name}: settings.conf lacks system_prompt");
                // Simple/Complex carry the plan-mode contract and name
                // both presets; Talk is the voice-first push-to-talk
                // preset — deliberately short and plan-free (speech
                // turns must never trigger planning).
                if name != "Talk" {
                    assert!(settings.contains("alayaface-plan"), "{name}: system_prompt lacks the plan contract");
                    assert!(settings.contains("Simple") && settings.contains("Complex"),
                        "{name}: system_prompt must name both presets");
                } else {
                    assert!(!settings.contains("alayaface-plan"), "Talk system_prompt must NOT carry the plan contract");
                    assert!(settings.contains("Talk"), "Talk system_prompt must identify itself");
                }
            }
            // No active-preset marker anymore.
            assert!(!alayaface_dir().join("active-preset").exists());
        });
    }

    #[test]
    fn ensure_deleted_seed_not_resurrected() {
        isolated_home(|| {
            // Fresh install: everything seeded on first run.
            ensure().unwrap();
            for name in SEED_PRESETS {
                assert!(preset_dir(name).is_dir(), "fresh install missing seed {name}");
            }
            // Deleting a seed must NOT resurrect it on the next ensure —
            // seeding only ever runs on an empty presets root.
            // introduced it.
            std::fs::remove_dir_all(preset_dir("Talk")).unwrap();
            ensure().unwrap();
            assert!(!preset_dir("Talk").is_dir(), "deleted Talk must not be resurrected");
        });
    }

    #[test]
    fn resolve_config_dir_requires_preset() {
        isolated_home(|| {
            ensure().unwrap();
            assert!(resolve_config_dir("").is_err(), "empty preset must be rejected");
            assert!(resolve_config_dir("nope").is_err(), "unknown preset must be rejected");
            assert_eq!(resolve_config_dir("Simple").unwrap(), preset_dir("Simple"));
        });
    }

    #[test]
    fn session_dir_copy_excludes_settings_conf() {
        isolated_home(|| {
            let sessions = ensure().unwrap();
            let config = preset_dir("Simple");
            // Copying an EXISTING preset is the meaningful path: files in
            // the source are copied, settings.conf (AlayaFace-owned) is not.
            std::fs::write(config.join("model.conf"), "name: \"Real\"\n").unwrap();
            std::fs::write(config.join("settings.conf"), "{\"tool_confirm\":\"x\"}").unwrap();

            let session_dir = create_session_dir_from(&sessions, "abc", "Simple").unwrap();
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
            let sessions = ensure().unwrap();
            // The preset's settings.conf must not leak into the session
            // config, while its real files (e.g. a configured model.conf)
            // are copied.
            std::fs::write(preset_dir("Simple").join("model.conf"), "name: \"SimpleModel\"\n").unwrap();
            let dir = create_session_dir_from(&sessions, "xyz", "Simple").unwrap();
            assert_eq!(
                std::fs::read_to_string(dir.join("config").join("model.conf")).unwrap(),
                "name: \"SimpleModel\"\n"
            );
            assert!(!dir.join("config").join("settings.conf").exists());

            // Unknown or empty preset is rejected.
            assert!(create_session_dir_from(&sessions, "q", "nope").is_err());
            assert!(create_session_dir_from(&sessions, "q", "").is_err());
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
            let sessions = ensure().unwrap();
            std::fs::write(preset_dir("Simple").join("model.conf"), "name: \"Real\"\n").unwrap();

            let dir = create_session_dir_nested(&sessions, &sessions.join("sess-1").to_string_lossy(), "demo plan/x", "t1", "uuid-1", "Simple").unwrap();
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
            // preset system prompt + reasoning level + work dir + preset name.
            let full = SpawnArgs {
                tool_confirm: "allow".into(),
                builtin_tools: Some(String::new()),
                system_prompt: "planner-hint".into(),
                reasoning_level: Some(2),
                work_dir: "/tmp/plan-work".into(),
                preset: "Complex".into(),
            };
            write_spawn_args(&dir, &full).unwrap();
            let got = read_spawn_args(&dir);
            assert_eq!(got.tool_confirm, "allow");
            assert_eq!(got.system_prompt, "planner-hint");
            assert_eq!(got.reasoning_level, Some(2));
            assert_eq!(got.work_dir, "/tmp/plan-work");
            assert_eq!(got.preset, "Complex");
            assert_eq!(got.builtin_tools, Some(String::new()), "explicit empty = NO tools");

            // Nil builtin_tools (don't pass the flag = all tools) and
            // None reasoning level (legacy → default 1 on resume).
            write_spawn_args(&dir, &SpawnArgs::default()).unwrap();
            assert_eq!(read_spawn_args(&dir).builtin_tools, None);
            assert_eq!(read_spawn_args(&dir).reasoning_level, None);

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
            #[serde(default)]
            reasoning_level: Option<i64>,
            work_dir: String,
            preset: String,
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
                reasoning_level: c.input.reasoning_level,
                work_dir: c.input.work_dir,
                preset: c.input.preset,
            };
            let got = serde_json::to_string_pretty(&args).unwrap();
            assert_eq!(got, c.expected, "SpawnArgs case {}", c.name);
        }
    }

    // ─── --config-path override ────────────────────────────────────
    //
    // The override is a process-global RwLock<Option<PathBuf>>, so
    // tests share the static with `isolated_home`. The lock below
    // serializes them.

    /// Run a closure with both HOME and the override isolated, restoring
    /// both on exit. Tests that touch the override MUST go through this
    /// helper — `CONFIG_PATH_OVERRIDE` is process-global.
    fn isolated_override<F: FnOnce() -> R, R>(f: F) -> R {
        let _guard = TEST_HOME_LOCK.lock().unwrap();
        let old_home = std::env::var_os("HOME");
        let old_override = override_path();
        let tmp = std::env::temp_dir().join(format!(
            "alayaface-test-{}-{}",
            std::process::id(),
            TEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        std::env::set_var("HOME", &tmp);
        // Make sure no stray override leaks in.
        set_override(PathBuf::new());
        let result = f();
        match old_home {
            Some(h) => std::env::set_var("HOME", h),
            None => std::env::remove_var("HOME"),
        }
        set_override(old_override);
        let _ = std::fs::remove_dir_all(&tmp);
        result
    }

    #[test]
    fn override_replaces_home_default() {
        isolated_override(|| {
            // No override → $HOME/.alayaface as before.
            let want = std::env::temp_dir().join("default-anchor");
            std::env::set_var("HOME", &want);
            assert_eq!(alayaface_dir(), want.join(".alayaface"));

            // Absolute override replaces the default entirely.
            let custom = std::env::temp_dir().join("my-custom-alayaface");
            set_override(custom.clone());
            assert_eq!(alayaface_dir(), custom);
            // Every helper routes through the override.
            assert_eq!(presets_root(), custom.join("presets"));
            assert_eq!(preset_order_file(), custom.join("preset_order.conf"));
        });
    }

    #[test]
    fn override_tilde_expands_against_home() {
        isolated_override(|| {
            let home = std::env::temp_dir().join("tilde-home");
            std::env::set_var("HOME", &home);

            // Bare "~" expands to $HOME (NOT $HOME/.alayaface — the
            // override is used as-is, only the leading "~" is expanded).
            set_override(PathBuf::from("~"));
            assert_eq!(alayaface_dir(), home);

            // "~/nested" expands to $HOME/nested.
            set_override(PathBuf::from("~/nested/cfg"));
            assert_eq!(alayaface_dir(), home.join("nested").join("cfg"));
        });
    }

    #[test]
    fn override_clearing_restores_default() {
        isolated_override(|| {
            let home = std::env::temp_dir().join("clear-home");
            std::env::set_var("HOME", &home);

            // Set, then clear — back to $HOME/.alayaface.
            set_override(std::env::temp_dir().join("x"));
            set_override(PathBuf::new());
            assert_eq!(alayaface_dir(), home.join(".alayaface"));

            // Empty PathBuf and never-set behave identically.
            assert_eq!(alayaface_dir(), alayaface_dir());
        });
    }

    #[test]
    fn ensure_seeds_under_override_not_home() {
        isolated_override(|| {
            let home = std::env::temp_dir().join("seed-home");
            std::env::set_var("HOME", &home);

            let custom = std::env::temp_dir().join("seed-custom");
            set_override(custom.clone());

            let sessions = ensure().unwrap();
            assert_eq!(sessions, custom.join("sessions"));
            for name in SEED_PRESETS {
                let dir = custom.join("presets").join(name);
                assert!(dir.is_dir(), "{name} must be seeded under override, got {dir:?}");
            }
            // And nothing leaked into $HOME/.alayaface.
            assert!(
                !home.join(".alayaface").exists(),
                "default $HOME/.alayaface must NOT exist when override is set"
            );
        });
    }
}

#[cfg(test)]
mod atomic_write_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    // Mirrors Go's TestWriteFileAtomic. The per-site `"{path}.tmp"` names this
    // helper replaced were SHARED between concurrent writers, and this API is
    // reachable from several clients at once: the loser of the rename got
    // ENOENT (surfacing as a sync failing at random) and the
    // open-truncate-write sequence could interleave.
    #[test]
    fn concurrent_writes_never_share_a_temp() {
        let dir = std::env::temp_dir().join(format!("alayaface-atomic-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("asr.conf");

        write_file_atomic(&path, "first").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "first");

        let writers = 12;
        let failures = std::sync::Arc::new(AtomicUsize::new(0));
        let mut threads = Vec::new();
        for i in 0..writers {
            let path = path.clone();
            let failures = failures.clone();
            threads.push(std::thread::spawn(move || {
                // One repeated byte: any interleaving is detectable.
                let payload = std::iter::repeat(b'a' + (i as u8 % 26))
                    .take(4096)
                    .collect::<Vec<u8>>();
                let text = String::from_utf8(payload).unwrap();
                if write_file_atomic(&path, &text).is_err() {
                    failures.fetch_add(1, Ordering::SeqCst);
                }
            }));
        }
        for t in threads {
            t.join().unwrap();
        }
        assert_eq!(
            failures.load(Ordering::SeqCst),
            0,
            "concurrent writes failed — the temp name must be unique per write"
        );

        let final_bytes = std::fs::read(&path).unwrap();
        assert_eq!(final_bytes.len(), 4096, "config is a mix of two writes");
        assert!(
            final_bytes.iter().all(|b| *b == final_bytes[0]),
            "torn config"
        );

        // No temp left behind (the rename consumed it; failures clean up).
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains(".tmp")
            })
            .collect();
        assert!(leftovers.is_empty(), "temp files leaked: {leftovers:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod path_tests {
    use super::*;
    use std::path::Path;

    // Mirrors Go's TestSessionPathValidatesAndContains: the ONE path rule
    // shared by create and resume/delete/fork. A client supplies session_id,
    // origin_session_dir, plan_id and node_id, and delete_session_dir feeds
    // the result to remove_dir_all — so a traversal must be refused, not
    // silently folded away.
    #[test]
    fn session_path_validates_and_contains() {
        let root = Path::new("/cfg/sessions");

        let plain = session_path(root, "", "", "", "abc").unwrap();
        assert_eq!(plain, root.join("abc"));

        // A traversal in the session id is rejected outright (it used to
        // resolve to the sessions root itself, which remove_dir_all empties).
        for bad in ["..", ".", "a/b", "a\\b", ""] {
            assert!(
                session_path(root, "", "plan", "node", bad).is_err(),
                "accepted session id {bad:?}"
            );
            assert!(
                session_path(root, "", "", "", bad).is_err(),
                "accepted plain session id {bad:?}"
            );
        }

        // A nested origin that escapes the store is rejected.
        assert!(session_path(root, "/etc", "plan", "node", "abc").is_err());

        // A real origin directory keeps its shape, plan id sanitized.
        let nested =
            session_path(root, "/cfg/sessions/sess-1", "demo plan/x", "t1", "abc").unwrap();
        assert_eq!(
            nested,
            Path::new("/cfg/sessions/sess-1/plans/demo_plan_x/t1/abc")
        );

        // A BARE origin id resolves against the root — the rule Go had and
        // Rust lacked (create_session_dir_nested ignored the sessions root),
        // which put the same plan node session in different places.
        let bare = session_path(root, "sess-1", "p", "n", "abc").unwrap();
        assert_eq!(bare, Path::new("/cfg/sessions/sess-1/plans/p/n/abc"));
    }

    #[test]
    fn safe_path_component_allows_names_rejects_traversal() {
        for ok in ["abc", "a-b_c", "3f2a...", "with space.txt", "sess.1"] {
            assert!(safe_path_component(ok), "{ok:?} must be allowed");
        }
        for bad in ["", ".", "..", "a/b", "a\\b", "a\0b"] {
            assert!(!safe_path_component(bad), "{bad:?} must be rejected");
        }
    }
}
