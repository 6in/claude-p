# Phase 2: Module Refactor — Pattern Map

**Mapped:** 2026-05-24
**Files analyzed:** 8 (7 new/replaced + Cargo.toml edit)
**Analogs found:** 8 / 8 (all source-of-truth is the existing `webif/src/main.rs`)

---

## File Classification

| New / Modified File | Role | Data Flow | Source-of-Truth Analog (lines in `main.rs`) | Match Quality |
|---------------------|------|-----------|---------------------------------------------|---------------|
| `webif/src/lib.rs` | config / re-export root | — | `main.rs` lines 1–17 (doc comment) | exact — verbatim copy of `//!` block + `pub mod` declarations |
| `webif/src/config.rs` | config | — | `main.rs` lines 38–41 + 525 | exact — two `const` lines + env-var read |
| `webif/src/mcp.rs` | service | request-response (stdio JSON-RPC) | `main.rs` lines 43–198 | exact — full section moves verbatim |
| `webif/src/worker.rs` | service | request-response (session lifecycle) | `main.rs` lines 200–285 | exact — full section moves verbatim |
| `webif/src/turn.rs` | service + utility | CRUD + event-driven | `main.rs` lines 287–369 + 383–396 | exact — full section + `read_turn` move verbatim |
| `webif/src/http.rs` | controller | request-response | `main.rs` lines 371–519 (minus `read_turn`) | exact — full HTTP section moves verbatim |
| `webif/src/main.rs` (thinned) | entry point | — | `main.rs` lines 521–561 | subset — rewritten to ~30-line wiring shim |
| `webif/Cargo.toml` | config | — | `webif/Cargo.toml` lines 1–20 | additive edit — two new sections appended |

---

## Pattern Assignments

### `webif/src/lib.rs` (re-export root)

**Source-of-truth analog:** `main.rs` lines 1–17

**Doc comment to copy verbatim** (lines 1–17):
```rust
//! ht-webif — curl で叩く薄い WebIF。
//!
//! [curl] --HTTP--> WebIF --MCP(stdio)--> ht-mcp --> ht --PTY--> claude
//!
//! 非同期ジョブモデル:
//!   POST /prompt        → prompt ファイルを書き、ジョブをキュー投入、turn_id を即返す
//!   GET  /turns/{id}    → ターンの状態/結果（ファイルシステムが状態ストア）
//!   バックグラウンドの worker_loop がターンを1件ずつ直列処理する。
//!   POST /prompt {"wait":true} なら完了まで待って結果を返す（同期オプション）。
//!
//! HT-PROTOCOL v1.1 のターンファイル:
//!   prompt-<turnId>.txt   指示    （WebIF が書く）
//!   result-<turnId>.txt   回答本文（claude が書く）
//!   status-<turnId>.json  状態    （claude が最後に書く = 完了シグナル）
//!
//! 回復: claude セッション死亡 → 自動再生成 / ターンのタイムアウト → 再生成+リトライ /
//!       ht-mcp 異常 → POST /restart。MCP 呼び出しは 30s でタイムアウトする。
```

**Module declarations to add after doc comment** (new content, no analog in current file):
```rust
pub mod config;
pub mod http;
pub mod mcp;
pub mod turn;
pub mod worker;
```

**CLAUDE.md conventions that apply:**
- File-level `//!` doc comment is required (existing block moves here).
- `pub mod` declarations use snake_case module names.
- Items `main.rs` touches (`Worker`, `Job`, `worker_loop`, `AppState`, `build_router`, `load_ht_mcp_path`) must be `pub` — not `pub(crate)` — because `main.rs` is a separate `[[bin]]` crate root and cannot see `pub(crate)` items from the library.

---

### `webif/src/config.rs` (constants + env loader)

**Source-of-truth analog:** `main.rs` lines 38–41 and line 525

**Constants to move verbatim** (lines 38–41):
```rust
/// 1ターンの最大待ち時間（1試行あたり）。
const TURN_TIMEOUT: Duration = Duration::from_secs(300);
/// MCP 呼び出し1回のタイムアウト（ht-mcp の wedge 対策）。
const MCP_TIMEOUT: Duration = Duration::from_secs(30);
```
Visibility change: `const` → `pub(crate) const` (both constants are consumed inside the library tree only).

**Env-var read to extract from `main`** (line 525):
```rust
std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
```
Wraps into a `pub fn load_ht_mcp_path() -> String` (signature from RESEARCH.md Pattern 1). `dotenvy::dotenv()` stays in `main` — do NOT move it here.

**Imports needed** (`use std::time::Duration;` only — no other deps).

**CLAUDE.md conventions that apply:**
- `///` doc comment on each item (Japanese).
- `SCREAMING_SNAKE_CASE` constants with explicit `Duration` type.
- File-level `//!` doc comment: `//! 設定定数と環境変数読み込み。`

---

### `webif/src/mcp.rs` (MCP stdio client)

**Source-of-truth analog:** `main.rs` lines 43–198

**Section banner to preserve as file-level comment** (line 43):
```rust
// ── MCP クライアント（newline 区切り JSON-RPC を直接話す最小実装）─────────
```

**CRITICAL — spawn block that must be preserved verbatim** (lines 55–66):
```rust
async fn spawn(program: &str) -> Result<Self> {
    let mut child = Command::new(program)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()) // ht-mcp のログは端末にそのまま流す
        .kill_on_drop(true) // WebIF 終了・再起動時に ht-mcp も道連れにする
        .spawn()
        .with_context(|| format!("ht-mcp の起動に失敗: {program}"))?;
    let stdin = child.stdin.take().ok_or_else(|| anyhow!("stdin が取れない"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow!("stdout が取れない"))?;
    Ok(Self { child, stdin, lines: BufReader::new(stdout).lines(), next_id: 0 })
}
```
Both `.stderr(Stdio::inherit())` and `.kill_on_drop(true)` must remain unchanged. `Child` must remain as a named field inside `McpClient` — do not rename to `_child` or remove.

**Struct definition** (lines 45–51) — `#[allow(dead_code)]` on `child` must survive:
```rust
struct McpClient {
    #[allow(dead_code)]
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next_id: i64,
}
```
Visibility change: `struct McpClient` → `pub(crate) struct McpClient` (only `worker.rs` constructs it).

**MCP_TIMEOUT usage** (line 108) — import from `crate::config`:
```rust
match tokio::time::timeout(MCP_TIMEOUT, self.read_response(id)).await {
```
After move: add `use crate::config::MCP_TIMEOUT;` to the import block.

**Imports needed in `mcp.rs`:**
```rust
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::Duration;

use crate::config::MCP_TIMEOUT;
```

**Visibility changes for all methods:** All `async fn` on `impl McpClient` → `pub(crate) async fn`.

**CLAUDE.md conventions that apply:**
- All `anyhow!("...")` strings stay Japanese verbatim (e.g., `"ht-mcp が stdout を閉じた"`, `"stdin が取れない"`).
- `.with_context(|| format!(...))` pattern for OS-level errors.
- `.ok_or_else(|| anyhow!("..."))` for Option → Result.

---

### `webif/src/worker.rs` (claude session lifecycle)

**Source-of-truth analog:** `main.rs` lines 200–285

**Section banner to preserve as file-level comment** (line 200):
```rust
// ── Worker（MCP クライアント + 現在の claude セッション）──────────────────
```

**Struct definition** (lines 202–206):
```rust
struct Worker {
    client: McpClient,
    session_id: String,
    ht_mcp_path: String,
}
```
Visibility changes: `struct Worker` → `pub struct Worker`, `session_id` field → `pub session_id: String` (read from `http.rs` restart_handler and `main.rs`).

**Constructor signature** (lines 209–213):
```rust
pub async fn new(ht_mcp_path: String) -> Result<Self> {
    let (client, session_id) = Self::boot(&ht_mcp_path).await?;
    Ok(Self { client, session_id, ht_mcp_path })
}
```

**Key eprintln! log strings that must survive verbatim** (lines 228, 267, 279–282):
```rust
eprintln!("[restart] ht-mcp 再起動完了。新セッション: {}", self.session_id);
eprintln!("[shared-fate] claude セッション不健全 → 再生成");
eprintln!(
    "[shared-fate] claude セッション再生成: {} （旧 {} を閉鎖）",
    self.session_id, old
);
```

**Imports needed in `worker.rs`:**
```rust
use anyhow::{anyhow, Result};
use std::time::Duration;
use tokio::time::Instant;

use crate::mcp::McpClient;
```
Note: `worker.rs` does **not** import `Mutex`. `Worker` methods take `&mut self`, never `Arc<Mutex<Worker>>` — the `Arc<Mutex<Worker>>` wrapper is constructed in `main.rs` and the lock is acquired by callers (`turn::worker_loop`, HTTP handlers) before invoking `&mut self` methods. The `tokio::sync::Mutex` import lives in `main.rs` (constructor site) and `turn.rs` (lock-acquiring callers), not here.

**Visibility changes for all methods:**
- `pub async fn new`, `pub async fn restart`, `pub session_id` → `pub`
- `pub(crate) async fn boot`, `spawn_session`, `submit_line`, `snapshot`, `ensure_healthy`, `recreate` → `pub(crate)`

**CLAUDE.md conventions that apply:**
- `&mut self` for mutating methods, `Result<Self>` for constructors.
- Best-effort cleanup with `let _ = self.client.close_session(&old).await;` (line 277) — keep as-is.
- Japanese `anyhow!` messages: `"claude TUI が起動しない:\n{snap}"` (line 243).

---

### `webif/src/turn.rs` (job queue, turn processing, filesystem I/O)

**Source-of-truth analog:** `main.rs` lines 287–369 + 383–396

**Section banner to preserve as file-level comment** (line 287):
```rust
// ── ターン処理（バックグラウンド）────────────────────────────────────────
```

**`Job` struct** (lines 289–293):
```rust
struct Job {
    turn_id: String,
    fresh: bool,
}
```
Visibility changes: `struct Job` → `pub struct Job`, both fields → `pub turn_id` / `pub fresh`.

**`build_prompt_body` signature** (line 296):
```rust
fn build_prompt_body(task: &str, result_path: &Path, status_path: &Path) -> String {
```
Visibility change: → `pub(crate) fn build_prompt_body`.

**`process_job` signature** (line 314):
```rust
async fn process_job(worker: &mut Worker, turns_dir: &Path, job: &Job) -> Result<()> {
```
Visibility change: → `pub(crate) async fn process_job`.

**`worker_loop` signature** (lines 352–356) — `pub` required (called from `main.rs`):
```rust
pub async fn worker_loop(
    worker: Arc<Mutex<Worker>>,
    turns_dir: PathBuf,
    mut job_rx: mpsc::Receiver<Job>,
) {
```

**`read_turn` signature** (line 384):
```rust
async fn read_turn(turns_dir: &Path, turn_id: &str) -> Result<Value> {
```
Visibility change: → `pub(crate) async fn read_turn`. (`read_turn` lives here rather than `http.rs` to keep all turn-filesystem logic in one module.)

**Key TURN_TIMEOUT usage** (line 330) — import from `crate::config`:
```rust
let deadline = Instant::now() + TURN_TIMEOUT;
```
After move: add `use crate::config::TURN_TIMEOUT;` to the import block.

**Key eprintln! log strings that must survive verbatim** (lines 340–343, 360):
```rust
eprintln!(
    "[worker] ターン {} タイムアウト（試行 {attempt}/2）→ セッション再生成",
    job.turn_id
);
eprintln!("[worker] ジョブ {} 失敗: {e}", job.turn_id);
```

**Imports needed in `turn.rs`:**
```rust
use anyhow::Result;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};  // std::path::Path — NOT axum Path
use std::time::Duration;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Instant;

use crate::config::TURN_TIMEOUT;
use crate::worker::Worker;
```

**CLAUDE.md conventions that apply:**
- `///` doc comments on all functions (Japanese).
- `?` propagation throughout; `let _ = ...` for best-effort cleanup (line 366).
- Polling loop pattern with `Instant::now() + Duration` deadline + `tokio::time::sleep` (lines 330–338).

---

### `webif/src/http.rs` (HTTP handlers, DTOs, router)

**Source-of-truth analog:** `main.rs` lines 371–519 (minus `read_turn` which goes to `turn.rs`)

**Section banner to preserve as file-level comment** (line 371):
```rust
// ── HTTP 層 ──────────────────────────────────────────────────────────
```

**`AppState` struct** (lines 373–377):
```rust
struct AppState {
    worker: Arc<Mutex<Worker>>,
    turns_dir: PathBuf,
    job_tx: mpsc::Sender<Job>,
}
```
Visibility changes: `struct AppState` → `pub struct AppState`, all three fields → `pub`.

**`ise()` helper** (lines 379–381):
```rust
fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
```
Visibility change: → `pub(crate) fn ise`.

**CRITICAL — path-traversal guard that must be preserved verbatim** (lines 456–459):
```rust
// パストラバーサル防止: turn_id は数字とハイフンのみ
if turn_id.is_empty() || !turn_id.chars().all(|c| c.is_ascii_digit() || c == '-') {
    return Err((StatusCode::BAD_REQUEST, "不正な turn_id".to_string()));
}
```
This check must remain inside `turn_handler`'s body. It moves with the function automatically.

**`build_router` helper to add** (new function, no analog — from RESEARCH.md Pattern 3):
```rust
pub fn build_router(state: Arc<AppState>) -> axum::Router {
    use axum::routing::{get, post};
    axum::Router::new()
        .route("/prompt", post(prompt_handler))
        .route("/turns/{turn_id}", get(turn_handler))
        .route("/command", post(command_handler))
        .route("/restart", post(restart_handler))
        .with_state(state)
}
```
Extracts the router construction from `main.rs` lines 544–549 so `main.rs` doesn't need axum routing imports.

**DTO visibility:** All four structs (`PromptReq`, `CommandReq`, `CommandResp`, `RestartResp`) → `pub struct`. The `#[derive(Deserialize)]` / `#[derive(Serialize)]` annotations stay unchanged.

**Imports needed in `http.rs`:**
```rust
use anyhow::Result;
use axum::{
    extract::{Path as AxumPath, State},  // alias required — AxumPath ≠ std::path::Path
    http::StatusCode,
    Json,
};
use chrono;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Instant;

use crate::turn::{build_prompt_body, read_turn, Job, worker_loop};
use crate::worker::Worker;
```
Note: `use axum::extract::Path as AxumPath` alias is mandatory to avoid name collision with `std::path::Path`.

**CLAUDE.md conventions that apply:**
- Handlers return `Result<Json<T>, (StatusCode, String)>`.
- `.map_err(ise)` at all async boundaries; explicit `(StatusCode::BAD_REQUEST, ...)` / `(StatusCode::GATEWAY_TIMEOUT, ...)` / `(StatusCode::NOT_FOUND, ...)` for non-500 outcomes.
- Snapshot failure in `command_handler` uses `.unwrap_or_else(|e| format!("(snapshot 取得失敗: {e})"))` (line 499) — preserve verbatim.

---

### `webif/src/main.rs` (thinned entry point)

**Source-of-truth analog:** `main.rs` lines 521–561 (rewritten as ~30-line shim)

**Content to preserve verbatim from lines 521–561:**
- The `dotenvy::dotenv().ok();` call (line 524) — must stay in `main`, never in `config.rs`.
- All `println!` startup log strings (lines 526, 530, 535, 553–558) — preserve Japanese text exactly.
- The `tokio::fs::create_dir_all(&turns_dir).await?` call (line 534).

**CRITICAL — Arc construction sequence that must be exact** (lines 538–543):
```rust
let worker = Arc::new(Mutex::new(worker));
let (job_tx, job_rx) = mpsc::channel::<Job>(64);
tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));

let state = Arc::new(AppState { worker, turns_dir, job_tx });
```
`worker.clone()` gives `worker_loop` a second `Arc` pointer to the same `Mutex<Worker>` as `AppState`. Do NOT construct a second `Worker::new()` or a second `Arc::new(Mutex::new(...))`.

**Replacement imports for thinned `main.rs`:**
```rust
use anyhow::Result;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

use ht_webif::config::load_ht_mcp_path;
use ht_webif::http::{AppState, build_router};
use ht_webif::turn::{worker_loop, Job};
use ht_webif::worker::Worker;
```
Note: uses `ht_webif::` (library crate name with underscore) because `main.rs` is a `[[bin]]` and imports the `[lib]` by crate name.

**CLAUDE.md conventions that apply:**
- `#[tokio::main]` entry point stays.
- `dotenvy::dotenv().ok()` is the first statement.
- `?` propagation, `main` returns `Result<()>`.

---

### `webif/Cargo.toml` (additive edit)

**Source-of-truth analog:** `webif/Cargo.toml` lines 1–20 (full current content)

**Current content** (lines 1–20) — all unchanged:
```toml
[package]
name = "ht-webif"
version = "0.1.0"
edition = "2021"
description = "..."
repository = "..."
license = "MIT"
authors = [...]
readme = "../README.md"
keywords = [...]
categories = [...]

[dependencies]
tokio = { version = "1", features = ["full"] }
axum = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
chrono = "0.4"
dotenvy = "0.15"
```

**Two sections to append** (no existing sections modified):
```toml
[lib]
name = "ht_webif"
path = "src/lib.rs"

[[bin]]
name = "ht-webif"
path = "src/main.rs"
```
Note: `[lib]` name uses underscores (`ht_webif` — Rust identifier); `[[bin]]` name uses hyphens (`ht-webif` — matches the existing binary name from `[package]`).

---

## Shared Patterns

### Tokio Mutex import (applies to `worker.rs`, `turn.rs`, `http.rs`, `main.rs`)

**Source:** `main.rs` line 35
```rust
use tokio::sync::{mpsc, Mutex};
```
Every file that touches `Arc<Mutex<Worker>>` must import `tokio::sync::Mutex`, not `std::sync::Mutex`. Holding a `std::sync::MutexGuard` across `.await` causes a compile error (`MutexGuard cannot be held across an await point`). This is the single most dangerous import mistake during the split.

### Japanese `anyhow!` / `eprintln!` string preservation (applies to all modules)

**Source:** `main.rs` throughout
Japanese message strings in `anyhow!("...")`, `.with_context(|| ...)`, and `eprintln!("[tag] ...")` are part of observable operator behavior and must be copied verbatim. Do not translate, rephrase, or normalize whitespace.

### `?` + `ise()` error propagation boundary (applies to `http.rs`)

**Source:** `main.rs` lines 379–381, 422, 429, 443, 463, 468, 490–491, 498–499, 514
```rust
fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
// usage:
.await.map_err(ise)?
```
All handler-internal `.await` failures use `.map_err(ise)?`. Non-500 statuses use explicit `(StatusCode::BAD_REQUEST, ...)` etc. — never route them through `ise`.

### `///` doc comment on every non-trivial function (applies to all modules)

**Source:** `main.rs` lines 54, 76, 100, 138, 153, 185, 209, 215, 223, 232, 248, 254, 261, 273, 295, 312, 351, 383, 409, 451, 484, 509
Each public or cross-module function has a single-line `///` Japanese doc comment. Internal helpers (`write_message`, `read_response`) also carry comments. Preserve all doc comments exactly when moving code.

---

## Boundary-Fragile Excerpts (must be preserved verbatim)

### 1. `kill_on_drop(true)` + `stderr(Stdio::inherit())` spawn block

**Location after refactor:** `webif/src/mcp.rs`, inside `impl McpClient`, method `spawn`
**Source:** `main.rs` lines 55–66
```rust
let mut child = Command::new(program)
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit()) // ht-mcp のログは端末にそのまま流す
    .kill_on_drop(true) // WebIF 終了・再起動時に ht-mcp も道連れにする
    .spawn()
    .with_context(|| format!("ht-mcp の起動に失敗: {program}"))?;
```
- Do not remove `.kill_on_drop(true)` — without it, `ht-mcp` processes survive `POST /restart` and accumulate.
- Do not capture stderr — `.stderr(Stdio::inherit())` routes `ht-mcp` logs to the parent terminal.
- Do not rename or remove the `child: Child` field in `McpClient` — the drop-kill fires when `McpClient` is dropped.

### 2. Path-traversal whitelist in `turn_handler`

**Location after refactor:** `webif/src/http.rs`, inside `turn_handler`
**Source:** `main.rs` lines 456–459
```rust
// パストラバーサル防止: turn_id は数字とハイフンのみ
if turn_id.is_empty() || !turn_id.chars().all(|c| c.is_ascii_digit() || c == '-') {
    return Err((StatusCode::BAD_REQUEST, "不正な turn_id".to_string()));
}
```
- This is the only security control in the codebase (ASVS V5 path traversal).
- The guard moves automatically because it is inside the function body — no special action needed, but verify with `curl -s http://127.0.0.1:8080/turns/../../etc/passwd` → HTTP 400 after refactor.

### 3. `Arc<Mutex<Worker>>` construction and sharing in `main.rs`

**Location after refactor:** `webif/src/main.rs` (thinned), inside `main()`
**Source:** `main.rs` lines 538–543
```rust
let worker = Arc::new(Mutex::new(worker));
let (job_tx, job_rx) = mpsc::channel::<Job>(64);
tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));

let state = Arc::new(AppState { worker, turns_dir, job_tx });
```
- `worker.clone()` gives `worker_loop` an `Arc` reference to the same `Mutex<Worker>` that `AppState` holds.
- Do not call `Worker::new()` a second time, and do not wrap in a second `Arc::new(Mutex::new(...))`.
- The ownership is: one `Mutex<Worker>` allocated once, two `Arc` pointers — one owned by `worker_loop`, one inside `AppState` shared among HTTP handlers.

---

## No Analog Found

None. All target files have exact source-of-truth analogs in `webif/src/main.rs`. No file requires pattern inference from external references.

---

## Metadata

**Analog search scope:** `webif/src/main.rs` (561 lines, single source file)
**Files scanned:** 3 (`main.rs`, `Cargo.toml`, `02-RESEARCH.md`)
**Pattern extraction date:** 2026-05-24

---

## PATTERN MAPPING COMPLETE

**Phase:** 2 - Module Refactor
**Files classified:** 8
**Analogs found:** 8 / 8

### Coverage
- Files with exact analog: 8 (all source lives in `main.rs`; this is an intra-file refactor)
- Files with role-match analog: 0
- Files with no analog: 0

### Key Patterns Identified
- All modules use `tokio::sync::Mutex` (not `std::sync`) — guards are held across `.await` in `worker_loop`, `command_handler`, and `restart_handler`.
- All error propagation inside the library uses `anyhow::Result` + `?`; handlers convert at the HTTP boundary with `.map_err(ise)` or explicit `(StatusCode::..., ...)` tuples.
- Japanese string literals in `anyhow!`, `.with_context`, and `eprintln!` are observable operator output — every string must be copied verbatim, not translated.
- Three visibility tiers: `pub` for items `main.rs` (the `[[bin]]`) touches; `pub(crate)` for items shared between library modules; private for module internals.
- `build_router(state: Arc<AppState>) -> axum::Router` is a new thin helper in `http.rs` that encapsulates all axum routing imports, keeping thinned `main.rs` free of axum dependencies.

### File Created
`/home/parallels/workspaces/ht-mcp-sample/.planning/phases/02-module-refactor/02-PATTERNS.md`

### Ready for Planning
Pattern mapping complete. Planner can now reference analog patterns in PLAN.md files.
