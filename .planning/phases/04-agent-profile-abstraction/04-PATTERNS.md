# Phase 4: Agent Profile Abstraction - Pattern Map

**Mapped:** 2026-06-11
**Files analyzed:** 7 (1 new Rust module, 1 new TOML file, 5 modified Rust files)
**Analogs found:** 6 / 7

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `src/profile.rs` | config/model | request-response (startup) | `src/config.rs` | role-match |
| `agents/claude.toml` | config | — | no code analog (data file) | none |
| `src/config.rs` | config | request-response (startup) | self (modify) | exact |
| `src/mcp.rs` | service/transport | request-response | self (modify) | exact |
| `src/worker.rs` | service | event-driven | self (modify) | exact |
| `src/turn.rs` | service | CRUD/file-I/O | self (modify) | exact |
| `src/main.rs` | entry-point | request-response (startup) | self (modify) | exact |
| `src/lib.rs` | config | — | self (modify) | exact |

---

## Pattern Assignments

### `src/profile.rs` (new — config/model, startup)

**Analog:** `src/config.rs` (env-loading pattern) + `src/mcp.rs` (module structure)

**Imports pattern** — follow `src/config.rs` lines 1-5 and `src/mcp.rs` lines 1-9:
```rust
use anyhow::Context;
use std::path::{Path, PathBuf};
```

**Struct definition pattern** — serde Deserialize with deny_unknown_fields and serde defaults:
```rust
// Derived from RESEARCH.md Pattern 1 — no existing analog in codebase
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentProfile {
    pub command: Vec<String>,
    pub ready_pattern: String,
    pub fresh_mode: String,
    pub clear_command: String,
    pub output_covenant: String,
    pub trigger_template: String,
    #[serde(default = "default_startup_timeout")]
    pub startup_timeout_secs: u64,
    #[serde(default = "default_turn_timeout")]
    pub turn_timeout_secs: u64,
    pub model_flag: Option<String>,
    pub model_value: Option<String>,
}

fn default_startup_timeout() -> u64 { 25 }
fn default_turn_timeout() -> u64 { 300 }
```

**Loader pattern** — copy from `src/config.rs` lines 33-40 (`load_turns_dir`), adapt for TOML:
```rust
// src/config.rs:33-40 — the error-with-context pattern to follow
pub fn load_turns_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("TURNS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("turns")),
    }
}
```

Applied to `load_agent_profile`:
```rust
pub fn load_agent_profile(name: &str, agents_dir: &Path) -> anyhow::Result<AgentProfile> {
    let path = agents_dir.join(format!("{name}.toml"));
    let content = std::fs::read_to_string(&path).map_err(|_| {
        let available = list_available_profiles(agents_dir);
        anyhow::anyhow!(
            "agents/{name}.toml が見つかりません（探索: {}）。利用可能: {}",
            agents_dir.display(),
            if available.is_empty() { "なし".to_string() } else { available.join(", ") }
        )
    })?;
    let profile: AgentProfile = toml::from_str(&content)
        .with_context(|| format!("agents/{name}.toml のパースに失敗"))?;
    validate_profile(&profile, name)?;
    Ok(profile)
}
```

**Validation pattern** — `anyhow::bail!` for startup-time guard (consistent with `src/config.rs:25`):
```rust
fn validate_profile(p: &AgentProfile, name: &str) -> anyhow::Result<()> {
    if !p.output_covenant.contains("{result_path}") || !p.output_covenant.contains("{status_path}") {
        anyhow::bail!("agents/{name}.toml: output_covenant に {{result_path}} と {{status_path}} が必要");
    }
    if !p.trigger_template.contains("{prompt_path}") {
        anyhow::bail!("agents/{name}.toml: trigger_template に {{prompt_path}} が必要");
    }
    Ok(())
}
```

**Available-profiles scan** — use `std::fs::read_dir`, no extra deps:
```rust
fn list_available_profiles(agents_dir: &Path) -> Vec<String> {
    std::fs::read_dir(agents_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter_map(|e| {
                    let p = e.path();
                    if p.extension().and_then(|s| s.to_str()) == Some("toml") {
                        p.file_stem().and_then(|s| s.to_str()).map(String::from)
                    } else {
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}
```

**Test pattern** — co-located `#[cfg(test)] mod tests`, tempfile for hermetic profile (D-04). Follow `src/turn.rs:117-208` for co-location style. Use `tempfile::tempdir()` as in `src/turn.rs:122`:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn load_agent_profile_errors_on_missing_toml() {
        let dir = tempdir().unwrap();
        // agents/claude.toml を動的生成
        std::fs::write(dir.path().join("claude.toml"), r#"
            command = ["claude"]
            ready_pattern = "auto mode"
            fresh_mode = "command"
            clear_command = "/clear"
            output_covenant = "x {result_path} {status_path}"
            trigger_template = "{prompt_path}"
        "#).unwrap();
        let err = load_agent_profile("unknown_agent", dir.path()).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("unknown_agent"));
        assert!(msg.contains("claude"));
    }
}
```

---

### `agents/claude.toml` (new — TOML config, no code analog)

**No code analog** — this is a data file. Use the literal values from current hardcodes:

- `command` from `src/mcp.rs:194`: `["claude"]`
- `ready_pattern` from `src/worker.rs:45,87,107,143`: `"auto mode"`
- `fresh_mode`: `"command"` (current path is submit_line `/clear`)
- `clear_command` from `src/turn.rs:55`: `"/clear"`
- `output_covenant` from `src/turn.rs:23-35` — CRITICAL: capture exact v1.0 format! bytes before editing turn.rs:
  ```
  {task}\n\n────────────────────────────────\n【ht-webif 出力規約】...
  ```
- `trigger_template` from `src/turn.rs:47-50`: `"{prompt_path} を読んで、その指示に従ってください。"`

**TOML multiline note:** The `output_covenant` value must begin with `\n\n` (two newlines before the header line) to match the v1.0 `format!` output. TOML `"""` multiline: a `\` at end of first line trims the opening newline. Verify via golden test (D-12).

---

### `src/config.rs` (modify — add `load_agent_name` / `load_agents_dir`)

**Analog:** Self (lines 14-16 for simple string default, lines 33-40 for PathBuf with CWD join).

**Imports to add:** none — `std::path::PathBuf` and `anyhow::Context` already used.

**Pattern to copy from `src/config.rs:14-16`** (simple string default):
```rust
// src/config.rs:14-16
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}
```
Apply for `load_agent_name`:
```rust
pub fn load_agent_name() -> String {
    std::env::var("AGENT").unwrap_or_else(|_| "claude".to_string())
}
```

**Pattern to copy from `src/config.rs:33-40`** (PathBuf with CWD join):
```rust
pub fn load_turns_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("TURNS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("turns")),
    }
}
```
Apply for `load_agents_dir`:
```rust
pub fn load_agents_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("AGENTS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("agents")),
    }
}
```

---

### `src/mcp.rs` (modify — rename trait method + update both impls)

**Change scope:** `trait Mcp` line 22 + `McpClient impl` lines 192-205 + `FakeMcp impl` lines 303-307.

**Trait rename** (line 22):
```rust
// BEFORE (src/mcp.rs:22)
async fn create_claude_session(&mut self) -> Result<String>;
// AFTER
async fn create_session(&mut self, cmd: &[String]) -> Result<String>;
```

**McpClient impl** (lines 192-205) — pass `cmd` to `call_tool`:
```rust
// BEFORE (src/mcp.rs:192-205)
async fn create_claude_session(&mut self) -> Result<String> {
    let text = self
        .call_tool("ht_create_session", json!({ "command": ["claude"] }))
        .await?;
// AFTER
async fn create_session(&mut self, cmd: &[String]) -> Result<String> {
    let text = self
        .call_tool("ht_create_session", json!({ "command": cmd }))
        .await?;
    // rest unchanged
```

**FakeMcp impl** (lines 303-307) — ignore `_cmd`, keep scripted-reply queue:
```rust
// BEFORE (src/mcp.rs:303-307)
async fn create_claude_session(&mut self) -> Result<String> {
    self.create_session_replies
        .pop_front()
        .unwrap_or_else(|| Err(anyhow!("create_claude_session scripted reply 切れ")))
}
// AFTER
async fn create_session(&mut self, _cmd: &[String]) -> Result<String> {
    self.create_session_replies
        .pop_front()
        .unwrap_or_else(|| Err(anyhow!("create_session scripted reply 切れ")))
}
```

**Verification:** After edit, `grep -n "create_claude_session" src/mcp.rs` must return 0 results. Run `cargo test` (not just `cargo build`) because `FakeMcp` is `#[cfg(test)]`.

---

### `src/worker.rs` (modify — add `profile` field, replace 4 ready-pattern sites)

**Struct field addition** (line 12-16):
```rust
// BEFORE (src/worker.rs:12-16)
pub struct Worker<M: Mcp = McpClient> {
    client: M,
    pub session_id: String,
    ht_mcp_path: String,
}
// AFTER
pub struct Worker<M: Mcp = McpClient> {
    client: M,
    pub session_id: String,
    ht_mcp_path: String,
    pub profile: crate::profile::AgentProfile,
}
```

**Constructor change** — `Worker::new` (line 21) gains `profile: AgentProfile` param:
```rust
// BEFORE (src/worker.rs:21-28)
pub async fn new(ht_mcp_path: String) -> Result<Self> {
    let (client, session_id) = Self::boot(&ht_mcp_path).await?;
    Ok(Self { client, session_id, ht_mcp_path })
}
// AFTER
pub async fn new(ht_mcp_path: String, profile: crate::profile::AgentProfile) -> Result<Self> {
    let (client, session_id) = Self::boot(&ht_mcp_path, &profile).await?;
    Ok(Self { client, session_id, ht_mcp_path, profile })
}
```

**4 ready-pattern sites** — replace `"auto mode"` with `profile.ready_pattern` and 25s with `profile.startup_timeout_secs`. Sites:
1. `spawn_session` — `src/worker.rs:40-53` (concrete `impl Worker<McpClient>`)
2. `recreate` — `src/worker.rs:100-122` (generic `impl<M: Mcp + Send>`)
3. `restart` — `src/worker.rs:137-159` (generic `impl<M: Mcp + Restartable + Send>`)
4. `ensure_healthy` — `src/worker.rs:84-94` (generic `impl<M: Mcp + Send>`)

**Pattern to apply for each ready-check loop** (copy structure from `src/worker.rs:42-52`):
```rust
// BEFORE (src/worker.rs:42-52)
let deadline = Instant::now() + Duration::from_secs(25);
loop {
    let snap = client.snapshot(&session_id).await?;
    if snap.contains("auto mode") {
        return Ok(session_id);
    }
    if Instant::now() > deadline {
        return Err(anyhow!("claude TUI が起動しない:\n{snap}"));
    }
    tokio::time::sleep(Duration::from_millis(700)).await;
}
// AFTER (spawn_session — profile passed as parameter)
let deadline = Instant::now() + Duration::from_secs(profile.startup_timeout_secs);
loop {
    let snap = client.snapshot(&session_id).await?;
    if snap.contains(&profile.ready_pattern) {
        return Ok(session_id);
    }
    // ... rest unchanged
```

**Note for `ensure_healthy`** (lines 85-93): The `matches!` macro contains the literal — also replace:
```rust
// BEFORE (src/worker.rs:85-88)
let healthy = matches!(
    self.snapshot().await,
    Ok(snap) if snap.contains("auto mode")
);
// AFTER
let ready_pattern = self.profile.ready_pattern.clone();
let healthy = matches!(
    self.snapshot().await,
    Ok(snap) if snap.contains(&ready_pattern)
);
```

**Trait method call update** — `create_claude_session()` → `create_session(&self.profile.command)` in `recreate` (line 102) and `restart` (line 139). In `spawn_session` (line 41): `client.create_session(&profile.command)`.

**Verification:** `grep -n '"auto mode"' src/worker.rs` must return 0 results.

---

### `src/turn.rs` (modify — parametrize `build_prompt_body` + `process_job`)

**CRITICAL first step:** Before editing, capture the v1.0 golden string from `src/turn.rs:23-35` as a const in the test. The exact format! output is:
```
{task}\n\n────────────────────────────────\n【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:\n1. 回答本文を次のファイルに書く: {result_path}\n2. 完了したら最後に次のファイルを作る: {status_path}\n   中身は JSON 1行: {"status":"done"}（失敗時は {"status":"failed","error":"理由"}）\nstatus ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。
```

**`build_prompt_body` signature change** (line 22):
```rust
// BEFORE (src/turn.rs:22)
pub fn build_prompt_body(task: &str, result_path: &Path, status_path: &Path) -> String {
// AFTER
pub fn build_prompt_body(task: &str, result_path: &Path, status_path: &Path, covenant_template: &str) -> String {
```

**`build_prompt_body` body** — replace `format!` with `str::replace`:
```rust
// BEFORE (src/turn.rs:23-35) — format! with hardcoded covenant
format!(
    "{task}\n\n────────────────────────────────\n【ht-webif 出力規約】...",
    task = task,
    result = result_path.display(),
    status = status_path.display(),
)
// AFTER — template substitution
let body = covenant_template
    .replace("{result_path}", &result_path.display().to_string())
    .replace("{status_path}", &status_path.display().to_string());
format!("{task}\n\n{body}")
```

**`process_job` signature** (line 40-43) — add profile parameter:
```rust
// BEFORE (src/turn.rs:40-44)
pub(crate) async fn process_job<M: Mcp + Send>(
    worker: &mut Worker<M>,
    turns_dir: &Path,
    job: &Job,
) -> Result<()> {
// AFTER — profile comes from worker.profile; access via worker.profile reference
// (no signature change needed if profile is accessed as worker.profile)
```

**Trigger message** (lines 47-50):
```rust
// BEFORE (src/turn.rs:47-50)
let trigger = format!(
    "{} を読んで、その指示に従ってください。",
    prompt_path.display()
);
// AFTER
let trigger = worker.profile.trigger_template
    .replace("{prompt_path}", &prompt_path.display().to_string());
```

**fresh_mode dispatch** (lines 54-56):
```rust
// BEFORE (src/turn.rs:54-56)
if job.fresh {
    worker.submit_line("/clear").await?;
    tokio::time::sleep(Duration::from_millis(1000)).await;
}
// AFTER
if job.fresh {
    match worker.profile.fresh_mode.as_str() {
        "command" => {
            worker.submit_line(&worker.profile.clear_command.clone()).await?;
        }
        "respawn" => {
            worker.recreate().await?;
        }
        other => {
            anyhow::bail!("未知の fresh_mode: {other}");
        }
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
}
```

**TURN_TIMEOUT replacement** (line 60) — use profile's `turn_timeout_secs`:
```rust
// BEFORE (src/turn.rs:60)
let deadline = Instant::now() + TURN_TIMEOUT;
// AFTER
let deadline = Instant::now() + Duration::from_secs(worker.profile.turn_timeout_secs);
```

**Existing test update** (`build_prompt_body_includes_task_and_paths`, line 125-133):
The test must pass `covenant_template` as new 4th arg. Use a minimal template containing both placeholders, or load `agents/claude.toml` for the golden test.

**Golden test** — add to `src/turn.rs #[cfg(test)]` after capturing v1.0 expected string:
```rust
#[test]
fn build_prompt_body_covenant_matches_v1_output() {
    const EXPECTED: &str = "やってほしいこと\n\n────────────────────────────────\n【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:\n1. 回答本文を次のファイルに書く: /tmp/result-X.txt\n2. 完了したら最後に次のファイルを作る: /tmp/status-X.json\n   中身は JSON 1行: {\"status\":\"done\"}（失敗時は {\"status\":\"failed\",\"error\":\"理由\"}）\nstatus ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。";

    let profile = crate::profile::load_agent_profile("claude", std::path::Path::new("agents")).unwrap();
    let body = build_prompt_body(
        "やってほしいこと",
        std::path::Path::new("/tmp/result-X.txt"),
        std::path::Path::new("/tmp/status-X.json"),
        &profile.output_covenant,
    );
    assert_eq!(body, EXPECTED, "agents/claude.toml の出力規約が v1.0 と一致しない");
}
```

---

### `src/main.rs` (modify — wire profile + TURNS_DIR subdirectory)

**Imports to add** (line 6):
```rust
// BEFORE (src/main.rs:6)
use ht_webif::config::{load_cors_origins, load_ht_mcp_path, load_port, load_turns_dir};
// AFTER
use ht_webif::config::{load_agent_name, load_agents_dir, load_cors_origins, load_ht_mcp_path, load_port, load_turns_dir};
use ht_webif::profile::load_agent_profile;
```

**Startup sequence** — insert after `dotenvy::dotenv().ok()` (line 14), before Worker::new (line 19):
```rust
// BEFORE (src/main.rs:14-19)
dotenvy::dotenv().ok();
let ht_mcp_path = load_ht_mcp_path();
println!("ht-mcp パス: {ht_mcp_path}");
let worker = Worker::new(ht_mcp_path).await?;
// AFTER
dotenvy::dotenv().ok();
let ht_mcp_path = load_ht_mcp_path();
let agent_name = load_agent_name();
let agents_dir = load_agents_dir()?;
let profile = load_agent_profile(&agent_name, &agents_dir)?;
eprintln!("[profile] エージェント: {agent_name}");
let worker = Worker::new(ht_mcp_path, profile).await?;
```

**TURNS_DIR subdirectory** — D-16, replace `load_turns_dir` usage (lines 23-25):
```rust
// BEFORE (src/main.rs:23-25)
let turns_dir = load_turns_dir()?;
tokio::fs::create_dir_all(&turns_dir).await?;
println!("ターンディレクトリ: {}", turns_dir.display());
// AFTER
let turns_base = load_turns_dir()?;
let turns_dir = turns_base.join(&agent_name);   // D-16: always append agent-name
tokio::fs::create_dir_all(&turns_dir).await?;
eprintln!("[profile] ターンディレクトリ: {}", turns_dir.display());
```

---

### `src/lib.rs` (modify — add `pub mod profile`)

**Pattern** (copy line 19 from `src/lib.rs`):
```rust
// BEFORE (src/lib.rs:19-23)
pub mod config;
pub mod http;
pub mod mcp;
pub mod turn;
pub mod worker;
// AFTER — add profile between config and http
pub mod config;
pub mod http;
pub mod mcp;
pub mod profile;
pub mod turn;
pub mod worker;
```

---

## Shared Patterns

### Error Handling with Japanese Context
**Source:** `src/config.rs` lines 23-27 and `src/mcp.rs` lines 63-64
**Apply to:** `src/profile.rs` (all error paths)
```rust
// src/config.rs:23-27
s.parse::<u16>()
    .with_context(|| format!("PORT のパースに失敗 (値: {s:?})"))

// src/mcp.rs:63-64
.with_context(|| format!("ht-mcp の起動に失敗: {program}"))
```
Rule: `.with_context(|| ...)` for recoverable errors, `anyhow::bail!` for validation guards. Japanese messages, `anyhow::Result` throughout.

### Logging Pattern
**Source:** `src/worker.rs` lines 71, 117-120 and `src/turn.rs` lines 70-73
**Apply to:** `src/profile.rs` (profile load log), `src/main.rs` (startup banner)
```rust
// src/worker.rs:117-120
eprintln!(
    "[shared-fate] claude セッション再生成: {} （旧 {} を閉鎖）",
    self.session_id, old
);
// src/turn.rs:70-73
eprintln!(
    "[worker] ターン {} タイムアウト（試行 {attempt}/2）→ セッション再生成",
    job.turn_id
);
```
Rule: `eprintln!` with `[tag]` prefix. New tag for this phase: `[profile]`.

### Co-located Test Structure
**Source:** `src/turn.rs` lines 117-208 and `src/mcp.rs` lines 251-521
**Apply to:** `src/profile.rs` (new tests), `src/turn.rs` (golden test addition)
```rust
// src/turn.rs:117-122
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::tempdir;
```
Rule: `#[cfg(test)] mod tests` at bottom of each file. `tempfile::tempdir()` for hermetic FS tests (already a dev-dep from Phase 3).

### FakeMcp Scripted Reply Pattern
**Source:** `src/mcp.rs` lines 264-291 (FakeMcp struct), 294-307 (create_session impl)
**Apply to:** Update `FakeMcp::create_claude_session` → `create_session` in `src/mcp.rs`
```rust
// src/mcp.rs:264-271 — field name stays unchanged after rename
pub(crate) struct FakeMcp {
    pub handshake_calls: u32,
    pub create_session_replies: VecDeque<Result<String>>,  // field name unchanged
    // ...
}
// src/mcp.rs:303-307 — only method signature changes
async fn create_claude_session(&mut self) -> Result<String> {
    self.create_session_replies.pop_front()
        .unwrap_or_else(|| Err(anyhow!("create_claude_session scripted reply 切れ")))
}
```

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `agents/claude.toml` | config data | — | First TOML config file in project; values are extracted from Rust hardcodes, not modeled on an existing file |

---

## Implementation Order (from RESEARCH.md Primary Recommendation)

1. `src/profile.rs` (new) — struct + loader + validate + tests
2. `src/lib.rs` — add `pub mod profile`
3. `src/config.rs` — add `load_agent_name` / `load_agents_dir`
4. `agents/claude.toml` — extract all 5 hardcodes (capture golden string from turn.rs FIRST)
5. `src/mcp.rs` — rename trait method + update McpClient + update FakeMcp
6. `src/worker.rs` — add profile field, replace 4 ready-pattern sites, update create_session calls
7. `src/turn.rs` — parametrize build_prompt_body + process_job + golden test
8. `src/main.rs` — wire profile, apply D-16 turns subdirectory, update banner

## Metadata

**Analog search scope:** `src/` (all 5 existing Rust modules)
**Files scanned:** 7 (config.rs, mcp.rs, worker.rs, turn.rs, main.rs, lib.rs, + CONTEXT.md/RESEARCH.md)
**Pattern extraction date:** 2026-06-11
