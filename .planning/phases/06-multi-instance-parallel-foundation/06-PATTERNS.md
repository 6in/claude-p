# Phase 6: Multi-Instance Parallel Foundation - Pattern Map

**Mapped:** 2026-06-15
**Files analyzed:** 8
**Analogs found:** 7 / 8

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `src/http.rs` (info_handler + AppState fields + build_router) | controller | request-response | `src/http.rs` (existing handlers) | exact — same file, additive change |
| `src/turn.rs` worker_loop (status toggle + counter increment) | service | event-driven | `src/turn.rs` worker_loop (existing) | exact — same function, additive change |
| `src/main.rs` (InstanceInfo construction + AppState wiring) | config/startup | request-response | `src/main.rs` (existing startup) | exact — same file, additive change |
| New shared lock-free state type (`InstanceInfo` / `Arc<InstanceInfo>`) | model/utility | — | `src/http.rs` AppState.output_covenant pattern | role-match (lock-free immutable + atomic fields) |
| `scripts/launch-agents.sh` (NEW) | utility/orchestrator | event-driven | `scripts/claude-p` | role-match (daemon, PID/log, readiness, stop/status) |
| `instances.conf` (NEW) | config | — | none — new format | no analog |
| `justfile` (up-all / down-all recipes) | config | — | `justfile` (existing recipes) | exact — same file, additive change |
| `README.md` (multi-instance + credential guide) | docs | — | `README.md` (existing §72-86, §169-201) | exact — same file, update |

---

## Pattern Assignments

### `src/http.rs` — `info_handler` + `AppState` new fields + `build_router` route addition

**Analog:** `src/http.rs` (read in full above)

**AppState lock-free field pattern** (lines 23-30):
```rust
pub struct AppState<M: Mcp + Send + 'static = McpClient> {
    pub worker: Arc<Mutex<Worker<M>>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
    /// プロファイルは起動後イミュータブルなので Mutex 越しに取得不要。
    /// ターン実行中（worker Mutex 保持中）でも output_covenant を即読めるようにする（CR-01）。
    pub output_covenant: String,
}
```
Add `instance_info: Arc<InstanceInfo>` to AppState using the same lock-free pattern: immutable-at-runtime data (agent_name, port, started_at) held directly on AppState; mutable metrics (is_busy AtomicBool, turns_processed AtomicU64) inside InstanceInfo but accessed lock-free via std::sync::atomic.

**Handler signature pattern** (lines 48-51, 101-104):
```rust
async fn prompt_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
    Json(req): Json<PromptReq>,
) -> Result<Json<Value>, (StatusCode, String)> {
```
`info_handler` uses the same generic + `State` extractor, no `Json` body input:
```rust
async fn info_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
) -> Json<Value> {
```
No `Result` wrapper needed — this handler cannot fail (all data is in-memory atomics).

**ise helper for 500 errors** (lines 32-34):
```rust
pub(crate) fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
```

**build_router route registration pattern** (lines 184-212):
```rust
pub fn build_router<M: Mcp + Restartable + Send + 'static>(
    state: Arc<AppState<M>>,
    cors_origins: Vec<String>,
) -> Router {
    // ... cors layer construction ...
    Router::new()
        .route("/prompt", post(prompt_handler::<M>))
        .route("/turns/{turn_id}", get(turn_handler::<M>))
        .route("/command", post(command_handler::<M>))
        .route("/restart", post(restart_handler::<M>))
        .layer(cors)
        .with_state(state)
}
```
Add `.route("/info", get(info_handler::<M>))` before `.layer(cors)`.

**Co-located test scaffolding** (lines 215-253):
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::tests::FakeMcp;
    use crate::worker::Worker;
    use axum::body::Body;
    use axum::http::Request;
    use std::path::Path;
    use tempfile::tempdir;
    use tower::ServiceExt;

    fn build_test_state(turns_dir: PathBuf) -> (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>) {
        let (job_tx, job_rx) = mpsc::channel(64);
        let profile = crate::profile::load_agent_profile("claude", Path::new("agents"))
            .expect("テスト用 agents/claude.toml のロード失敗");
        let output_covenant = profile.output_covenant.clone();
        let worker = Worker::<FakeMcp>::from_parts(
            FakeMcp::new(), "test-session".to_string(), "/dev/null".to_string(), profile,
        );
        let worker = Arc::new(Mutex::new(worker));
        let state = Arc::new(AppState {
            worker, turns_dir, job_tx, output_covenant,
        });
        (state, job_rx)
    }

    // oneshot pattern for GET /info:
    let resp = app.oneshot(
        Request::builder().method("GET").uri("/info").body(Body::empty()).unwrap(),
    ).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    // parse body, assert fields: agent, port, status, uptime, turns_processed
}
```
`build_test_state` must be extended to construct and pass `Arc<InstanceInfo>` when AppState gains that field.

---

### `src/turn.rs` — `worker_loop` status toggle + counter increment

**Analog:** `src/turn.rs` worker_loop (lines 92-110)

**Current worker_loop signature** (lines 93-96):
```rust
pub async fn worker_loop<M: Mcp + Send + 'static>(
    worker: Arc<Mutex<Worker<M>>>,
    turns_dir: PathBuf,
    mut job_rx: mpsc::Receiver<Job>,
) {
```
Add `instance_info: Arc<InstanceInfo>` parameter. Caller (main.rs) passes the same `Arc` it gave to AppState.

**Current loop body** (lines 98-109):
```rust
while let Some(job) = job_rx.recv().await {
    let mut w = worker.lock().await;
    if let Err(e) = process_job(&mut w, &turns_dir, &job).await {
        eprintln!("[worker] ジョブ {} 失敗: {e}", job.turn_id);
        let status_path = turns_dir.join(format!("status-{}.json", job.turn_id));
        let err_json =
            serde_json::to_string(&e.to_string()).unwrap_or_else(|_| "\"error\"".to_string());
        let body = format!("{{\"status\":\"failed\",\"error\":{err_json}}}\n");
        let _ = tokio::fs::write(&status_path, body).await;
    }
}
```
Augment with atomic operations wrapping `process_job`:
```rust
while let Some(job) = job_rx.recv().await {
    instance_info.is_busy.store(true, std::sync::atomic::Ordering::Relaxed);
    let mut w = worker.lock().await;
    let result = process_job(&mut w, &turns_dir, &job).await;
    instance_info.is_busy.store(false, std::sync::atomic::Ordering::Relaxed);
    instance_info.turns_processed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    if let Err(e) = result {
        // ... same error-file-write pattern as current ...
    }
}
```
`Ordering::Relaxed` is sufficient: no cross-thread ordering guarantee needed for a status read by `/info`.

**Log tag convention** (line 101): `[worker]` — `/info`-related log lines use `[info]` tag per CONTEXT §"Established Patterns".

---

### `src/main.rs` — `InstanceInfo` construction + AppState/worker_loop wiring

**Analog:** `src/main.rs` (lines 1-70, read in full)

**Config loading pattern** (lines 18-24):
```rust
dotenvy::dotenv().ok();
let ht_mcp_path = load_ht_mcp_path();
let agent_name = load_agent_name();
let agents_dir = load_agents_dir()?;
let profile = load_agent_profile(&agent_name, &agents_dir)?;
eprintln!("[profile] エージェント: {agent_name}");
```

**Lock-free pre-extraction before move** (lines 27-30):
```rust
// output_covenant は Worker::new で profile が move される前に取り出す（CR-01）。
let output_covenant = profile.output_covenant.clone();
```
Same pattern for InstanceInfo — construct before passing Arc to both AppState and worker_loop:
```rust
let port = load_port()?;
let started_at = std::time::Instant::now();
let instance_info = Arc::new(InstanceInfo {
    agent_name: agent_name.clone(),
    port,
    started_at,
    is_busy: AtomicBool::new(false),
    turns_processed: AtomicU64::new(0),
});
```

**worker_loop spawn** (line 44):
```rust
tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));
```
Becomes:
```rust
tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx, instance_info.clone()));
```

**AppState construction** (lines 47-52):
```rust
let state = Arc::new(AppState {
    worker,
    turns_dir,
    job_tx,
    output_covenant,
    instance_info,   // added
});
```

**Port load timing note:** `load_port()` is currently called at line 57 (after AppState construction). For InstanceInfo it must be called earlier (before InstanceInfo construction). Move `let port = load_port()?;` to just before InstanceInfo construction; keep `let addr = format!("127.0.0.1:{port}");` using the same binding.

---

### New shared lock-free state type (`InstanceInfo`)

**Closest analog:** `src/http.rs` AppState.output_covenant (lock-free immutable field pattern, CR-01) and the worker_loop's existing `Arc<Mutex<Worker<M>>>` (Arc sharing pattern).

**Proposed structure** (place in `src/http.rs` alongside AppState, or new `src/instance.rs` — Claude's discretion per CONTEXT §"Claude's Discretion"):
```rust
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::time::Instant;

/// 起動以降イミュータブルなインスタンス識別情報 + lock-free メトリクス。
/// worker Mutex を一切取得せず /info ハンドラが直接読む（D-02/D-05）。
pub struct InstanceInfo {
    pub agent_name: String,
    pub port: u16,
    pub started_at: Instant,          // uptime 計算用
    pub is_busy: AtomicBool,          // D-02: worker_loop がトグル
    pub turns_processed: AtomicU64,   // D-04: ターン完了ごとにインクリメント
}
```
`Instant` is not `Send + Sync` — use `std::time::SystemTime` instead if cross-thread issues arise, or store `started_at` as `std::time::Instant` and accept that it is `Send + Sync` on all target platforms (it is on Linux/macOS). Alternatively store start as `chrono::DateTime<Utc>` for JSON serialization convenience.

**`/info` response JSON** (Claude's discretion — minimum required fields per CONTEXT §"Specific Ideas"):
```json
{
  "agent": "claude",
  "port": 8080,
  "status": "idle",
  "uptime_secs": 42,
  "turns_processed": 7
}
```
`status` is `"busy"` when `is_busy.load(Ordering::Relaxed)` is true, else `"idle"`.

---

### `scripts/launch-agents.sh` (NEW) — multi-instance orchestrator

**Analog:** `scripts/claude-p` (read in full above)

**Script header + set** (lines 1-26 of claude-p):
```bash
#!/usr/bin/env bash
# launch-agents.sh — 多重インスタンス起動/停止/状態確認オーケストレータ。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_CONF="${WEBIF_DIR}/instances.conf"
```

**Log helper pattern** (lines 28-30 of claude-p):
```bash
log() { echo "[launch-agents] $*" >&2; }
```

**PID/LOG/TURNS naming convention** (lines 387-391 of claude-p) — replicate per-port:
```bash
# per-instance paths (parallel to claude-p's per-port paths)
PID_FILE="/tmp/ht-webif-${PORT}.pid"
LOG_FILE="/tmp/ht-webif-${PORT}.log"
TURNS_DIR_PATH="${WEBIF_DIR}/turns-${PORT}"
```

**Daemon spawn pattern** (lines 133-153 of claude-p):
```bash
(
    cd "$WEBIF_DIR"
    nohup env PORT="${PORT}" TURNS_DIR="${TURNS_DIR_PATH}" AGENT="${AGENT}" \
        cargo run --release >"${LOG_FILE}" 2>&1 &
    local pid=$!
    echo "$pid" > "${PID_FILE}"
    disown "$pid"
)
```
`launch-agents.sh` adds `AGENT` and per-instance credential env vars (e.g. `CODEX_HOME`) from `instances.conf` columns.

**Readiness pattern** (lines 160-193 of claude-p) — for `up` subcommand, change liveness probe from `/turns/0` to `/info` with agent-name match check (D-09):
```bash
# /info が agent 名と一致するまでポーリング（D-09）
check_info_agent() {
    local port="$1" expected_agent="$2"
    local resp
    resp=$(curl -s --max-time 2 "http://127.0.0.1:${port}/info" 2>/dev/null) || return 1
    local actual
    actual=$(echo "$resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('agent',''))" 2>/dev/null) || return 1
    [[ "$actual" == "$expected_agent" ]]
}
```
Use `jq` if available (same JSON_ENCODER detection as claude-p lines 59-69).

**Stop pattern** (lines 259-305 of claude-p) — `down-all` iterates all entries in `instances.conf`, reads each PORT's PID file, sends SIGTERM → waits 5s → SIGKILL:
```bash
cmd_down_all() {
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#|^[[:space:]]*$ ]] && continue
        local agent port extra_env
        read -r agent port extra_env <<< "$line"
        local pid_file="/tmp/ht-webif-${port}.pid"
        # ... same SIGTERM→SIGKILL logic as claude-p cmd_stop ...
    done < "$INSTANCES_CONF"
}
```

**Status pattern** (lines 307-361 of claude-p) — `status` subcommand hits `/info` per instance instead of `/turns/0`.

**Subcommand dispatch** (lines 363-385 of claude-p):
```bash
case "${1:-}" in
    up)       cmd_up ;;
    down-all) cmd_down_all ;;
    status)   cmd_status ;;
    *)        usage ;;
esac
```

---

### `instances.conf` (NEW)

**No analog in codebase.** Proposed format (Claude's discretion per CONTEXT D-07, §"Specific Ideas"):
```
# instances.conf — 多重インスタンス設定。
# 書式: <agent>  <port>  [KEY=VALUE ...]
# コメント行（#）と空行は無視される。
claude     8080
codex      8081  CODEX_HOME=/home/user/.codex-instance1
opencode   8082
```
Tab/space delimited. `KEY=VALUE` extra-env column supports `CODEX_HOME` for D-10. Default examples use claude:8080 / codex:8081 / opencode:8082 per CONTEXT §"Specific Ideas".

---

### `justfile` — `up-all` / `down-all` recipes

**Analog:** `justfile` (read in full above)

**Existing recipe pattern** (lines 27-29):
```just
build:
    cargo build --release
```

**Variable definition pattern** (lines 17-25):
```just
cargo_manifest := "Cargo.toml"
bin_name := "ht-webif"
```

**New recipes to add** (after existing recipes, before dist-* section):
```just
# 全インスタンスを起動する（instances.conf ドリブン）
up-all:
    bash scripts/launch-agents.sh up

# 全インスタンスを停止する
down-all:
    bash scripts/launch-agents.sh down-all

# 全インスタンスの状態を表示する
agents-status:
    bash scripts/launch-agents.sh status
```

---

### `README.md` — multi-instance + credential separation guide

**Analog:** `README.md` existing §"多重インスタンス" (lines 72-86) and §"claude-p" (lines 169-201).

Pattern: update existing placeholder section (lines 72-86) with:
1. `instances.conf` format explanation
2. `just up-all` / `just down-all` usage
3. Credential separation per agent:
   - claude: `~/.claude/` OAuth is read-only shared — 共有可（理由: OAuth token は read-only; セッション状態は ht-mcp が管理し ~/.claude には書き戻さない）
   - codex: `~/.codex/` includes mutable session/auth state — `CODEX_HOME` 分離必須（具体例を掲載）
   - opencode: `~/.config/opencode/` — Phase 5 実機検証結果を反映（共有可否と理由を明記）

---

## Shared Patterns

### Lock-free state access (CR-01 pattern)
**Source:** `src/http.rs` lines 27-30 (AppState.output_covenant doc comment + usage)
**Apply to:** `info_handler`, `InstanceInfo` design, `AppState` field additions
```rust
/// プロファイルは起動後イミュータブルなので Mutex 越しに取得不要。
/// ターン実行中（worker Mutex 保持中）でも output_covenant を即読めるようにする（CR-01）。
pub output_covenant: String,
```
`/info` MUST NOT call `state.worker.lock()`. All data must be readable from `Arc<InstanceInfo>` directly.

### Error handling (ise helper)
**Source:** `src/http.rs` lines 32-34
**Apply to:** Any new handler that can fail (info_handler cannot fail, so `ise` not needed there)
```rust
pub(crate) fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
```

### Log tag convention
**Source:** `src/main.rs` line 25, `src/turn.rs` line 101
**Apply to:** `info_handler` (use `[info]` tag), `launch-agents.sh` (use `[launch-agents]` tag)
```rust
eprintln!("[profile] エージェント: {agent_name}");
eprintln!("[worker] ジョブ {} 失敗: {e}", job.turn_id);
```

### co-located test structure
**Source:** `src/http.rs` lines 214-498
**Apply to:** `info_handler` test in `src/http.rs`
Pattern: `build_test_state` helper + `app.oneshot(Request::builder()...)` + status/body assertions.

### Bash daemon + PID/log file conventions
**Source:** `scripts/claude-p` throughout
**Apply to:** `scripts/launch-agents.sh`
- PID: `/tmp/ht-webif-${PORT}.pid`
- LOG: `/tmp/ht-webif-${PORT}.log`
- TURNS: `${WEBIF_DIR}/turns-${PORT}/`
- stop: SIGTERM → 5s wait → SIGKILL → rm PID file
- readiness: poll loop up to 60s with early-death detection

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `instances.conf` | config | — | No config-file-driven instance set exists; new format |

---

## Metadata

**Analog search scope:** `src/` (all .rs files), `scripts/`, `justfile`, `README.md`
**Files scanned:** 6 source files read in full (http.rs, turn.rs, main.rs, scripts/claude-p, justfile) + CONTEXT.md
**Pattern extraction date:** 2026-06-15
