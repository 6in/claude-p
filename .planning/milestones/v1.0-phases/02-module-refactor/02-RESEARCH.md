# Phase 2: Module Refactor — Research

**Researched:** 2026-05-24
**Domain:** Rust module system, single-binary crate layout, axum/tokio patterns
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CODE-01 | `webif/src/main.rs`（~500行）をモジュール分割する（`mcp_client`、`worker`、`turn`、`handlers`、`config` 等を `lib.rs` 配下に切り出し、`main.rs` は薄くする） | Module layout section documents exact file→symbol mapping; `lib.rs`-first approach ensures testability for Phase 3 |
| CODE-02 | モジュール分割後も既存の HTTP API（`/prompt`、`/turns/{id}`、`/command`、`/restart`）が同じ振る舞いで動くこと | Behavior-preservation risks section lists every concrete hazard and its mitigation; verification strategy section gives curl smoke tests |
</phase_requirements>

---

## Summary

The task is a **pure mechanical refactor**: move symbols out of `webif/src/main.rs` into per-responsibility files while preserving every byte of observable HTTP behavior. No new libraries are needed. No logic changes are allowed.

`webif/src/main.rs` already has four ASCII section banners that act as natural seams:
- `// ── MCP クライアント ... ─` (line 43)
- `// ── Worker ... ──` (line 200)
- `// ── ターン処理 ... ────` (line 287)
- `// ── HTTP 層 ──` (line 371)

These map cleanly to four new files: `mcp.rs`, `worker.rs`, `turn.rs`, `http.rs`. A fifth file `config.rs` extracts constants and the `HT_MCP_PATH` env-var read. A `lib.rs` at the crate root re-exports them and enables Phase 3 testing.

The single most important constraint: `McpClient` contains a `Child` (with `kill_on_drop(true)`) and `Arc<Mutex<Worker>>` is held across `.await` points using `tokio::sync::Mutex`. Both semantics must survive unchanged when types move between files — they will, because Rust ownership is file-agnostic.

**Primary recommendation:** Adopt the `lib.rs` + thin `main.rs` layout. Add a `[lib]` section to `Cargo.toml`. Keep `[[bin]]` pointing at `src/main.rs`. `main.rs` becomes ~30 lines of wiring only.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| MCP stdio JSON-RPC transport | `src/mcp.rs` | — | McpClient owns the subprocess and protocol framing |
| Claude session lifecycle | `src/worker.rs` | — | Worker owns session_id and health recovery logic |
| Turn processing & job queue | `src/turn.rs` | — | Job, process_job, worker_loop, build_prompt_body |
| HTTP handlers & DTO types | `src/http.rs` | — | AppState + 4 handlers + request/response structs |
| Configuration & constants | `src/config.rs` | — | TURN_TIMEOUT, MCP_TIMEOUT, HT_MCP_PATH resolution |
| Entry point (wiring) | `src/main.rs` | — | dotenv, Worker::new, turns_dir, mpsc, axum serve |
| Public API surface | `src/lib.rs` | — | Re-exports for lib consumers (tests in Phase 3) |

---

## Standard Stack

### Core

All packages already in `webif/Cargo.toml`. No new dependencies are required for this phase.

[VERIFIED: `cargo check` completes with no warnings on the current `webif/Cargo.toml`]

| Library | Version (locked) | Purpose | Role in Phase 2 |
|---------|-----------------|---------|-----------------|
| tokio | 1 (full) | Async runtime, process spawning, mpsc, Mutex | Unchanged; `tokio::sync::Mutex` ownership follows `Worker` to `worker.rs` |
| axum | 0.8 | HTTP routing, State/Json extractors | Unchanged; Router construction stays in `main.rs`; handlers move to `http.rs` |
| serde / serde_json | 1 | JSON (de)serialization for DTOs and MCP frames | Unchanged |
| anyhow | 1 | Error propagation with Japanese context strings | Unchanged |
| chrono | 0.4 | Turn-ID generation | Moves to `turn.rs` with `prompt_handler` |
| dotenvy | 0.15 | `.env` loading | Stays in `main.rs` |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `lib.rs` + `main.rs` | `main.rs` + sibling modules only | lib.rs required for Phase 3 `cargo test` to import internal types; skip lib.rs and Phase 3 must use integration tests only |
| `config.rs` for constants | Constants in each consuming module | config.rs avoids duplication (`TURN_TIMEOUT` used by both `turn.rs` and `http.rs`); consuming-module placement is also acceptable if cross-use is zero |

---

## Architecture Patterns

### System Architecture Diagram

Data flow is **unchanged** after the refactor. The diagram below shows which new file owns each step:

```
HTTP Client (curl)
      |
      | POST /prompt, GET /turns/{id}, POST /command, POST /restart
      v
src/http.rs  (AppState, 4 handlers, PromptReq/CommandReq/CommandResp/RestartResp)
      |
      | mpsc::Sender<Job>  ──>  src/turn.rs  (worker_loop, process_job)
      |                                 |
      |                         Arc<Mutex<Worker>>
      |                                 v
      |                         src/worker.rs  (Worker, boot, restart, ensure_healthy, recreate)
      |                                 |
      |                         &mut McpClient
      |                                 v
      |                         src/mcp.rs  (McpClient, handshake, request, call_tool, …)
      |                                 |
      |                         stdin/stdout (newline JSON-RPC)
      |                                 v
      |                         ht-mcp subprocess
      |
      | status/result file polling (turns/ directory)
      v
src/turn.rs  (build_prompt_body, read_turn)
```

### Recommended Project Structure

```
webif/src/
├── lib.rs          # pub mod declarations + re-exports for testability
├── main.rs         # wiring only: dotenv, Worker::new, turns_dir, mpsc, axum serve (~30 lines)
├── config.rs       # constants (TURN_TIMEOUT, MCP_TIMEOUT) + load_ht_mcp_path()
├── mcp.rs          # McpClient struct + spawn/handshake/request/notify/call_tool/session ops
├── worker.rs       # Worker struct + new/boot/restart/spawn_session/ensure_healthy/recreate/submit_line/snapshot
├── turn.rs         # Job struct + build_prompt_body + process_job + worker_loop + read_turn
└── http.rs         # AppState + ise() + PromptReq/CommandReq/CommandResp/RestartResp + 4 handlers
```

### Pattern 1: `lib.rs` + thin `main.rs` for single-binary crates

**What:** The crate provides both a `[lib]` and a `[[bin]]`. The binary is a thin shim that calls into the library. All testable logic lives in the library.

**When to use:** Any time Phase 3 will add `#[cfg(test)]` unit tests or `tests/` integration tests. Without a lib target, `cargo test` cannot import internal types without the `pub(crate)` trick on a binary.

**Example — Cargo.toml additions:**
```toml
# Source: Rust reference: https://doc.rust-lang.org/cargo/reference/cargo-targets.html
[lib]
name = "ht_webif"
path = "src/lib.rs"

[[bin]]
name = "ht-webif"
path = "src/main.rs"
```

[VERIFIED: `name` in `[lib]` uses underscores (Rust identifier), `name` in `[[bin]]` uses hyphens (matches the existing binary name). This distinction is correct per Cargo docs.]
[ASSUMED: The `name = "ht-webif"` value for `[[bin]]` matches the existing implicit binary name — confirmed by inspecting the package name in `Cargo.toml`.]

**Example — `src/lib.rs`:**
```rust
// Source: Rust module system — pub mod declarations
pub mod config;
pub mod mcp;
pub mod worker;
pub mod turn;
pub mod http;
```

**Example — `src/main.rs` (target state, ~30 lines):**
```rust
use anyhow::Result;
use ht_webif::{config, http::AppState, turn::Job, worker::Worker};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    let ht_mcp_path = config::load_ht_mcp_path();
    println!("ht-mcp パス: {ht_mcp_path}");

    let worker = Worker::new(ht_mcp_path).await?;
    println!("claude セッション: {}", worker.session_id);

    let turns_dir = std::env::current_dir()?.join("turns");
    tokio::fs::create_dir_all(&turns_dir).await?;
    println!("ターンディレクトリ: {}", turns_dir.display());

    let worker = Arc::new(Mutex::new(worker));
    let (job_tx, job_rx) = mpsc::channel::<Job>(64);
    tokio::spawn(ht_webif::turn::worker_loop(worker.clone(), turns_dir.clone(), job_rx));

    let state = Arc::new(AppState { worker, turns_dir, job_tx });
    let app = ht_webif::http::build_router(state);

    let addr = "127.0.0.1:8080";
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("WebIF 起動: http://{addr}");
    // ... startup prints ...
    axum::serve(listener, app).await?;
    Ok(())
}
```

### Pattern 2: Visibility — minimal `pub` surface

**What:** Each module exposes only what its consumers need. The rule is: start private, promote to `pub(crate)` when cross-module access is needed, and `pub` only if the lib's external API requires it.

**Visibility table for this phase:**

| Symbol | Current | After refactor | Reason |
|--------|---------|---------------|--------|
| `McpClient` (struct) | private | `pub(crate)` | `worker.rs` constructs it; `mcp.rs` defines it |
| `McpClient::spawn` | private | `pub(crate)` | called from `worker.rs` |
| `McpClient::handshake` | private | `pub(crate)` | called from `worker.rs` |
| `McpClient` session ops | private | `pub(crate)` | called from `worker.rs` |
| `Worker` (struct) | private | `pub` | used in `turn.rs`, `http.rs`, `main.rs` |
| `Worker::new` | private | `pub` | called from `main.rs` |
| `Worker::session_id` | private | `pub` | read in `http.rs` (restart_handler) and `main.rs` |
| `Worker::ensure_healthy` | private | `pub(crate)` | called from `turn.rs` and `http.rs` |
| `Worker::submit_line` | private | `pub(crate)` | called from `turn.rs` and `http.rs` |
| `Worker::snapshot` | private | `pub(crate)` | called from `http.rs` |
| `Worker::restart` | private | `pub(crate)` | called from `http.rs` |
| `Worker::recreate` | private | `pub(crate)` | called from `turn.rs` |
| `Job` (struct) | private | `pub` | sent across mpsc in `main.rs` and `http.rs` |
| `Job::turn_id` | private | `pub` | accessed in `turn.rs` and `http.rs` |
| `Job::fresh` | private | `pub` | accessed in `turn.rs` |
| `build_prompt_body` | private | `pub(crate)` | called from `http.rs` (prompt_handler) |
| `process_job` | private | `pub(crate)` | called from `turn.rs` (worker_loop) |
| `worker_loop` | private | `pub` | spawned from `main.rs` |
| `read_turn` | private | `pub(crate)` | called from `http.rs` |
| `AppState` (struct) | private | `pub` | used in `main.rs` and handlers |
| `AppState::worker` | private | `pub` | accessed in handlers |
| `AppState::turns_dir` | private | `pub` | accessed in handlers |
| `AppState::job_tx` | private | `pub` | accessed in `prompt_handler` |
| `ise()` | private | `pub(crate)` | used in all handlers |
| `PromptReq`, `CommandReq`, etc. | private | `pub` | used in handlers |
| `TURN_TIMEOUT`, `MCP_TIMEOUT` | private | `pub(crate)` | consumed by `turn.rs` and `mcp.rs` |

**Note:** `McpClient` internals (`stdin`, `lines`, `next_id`, `child`) remain private — only `McpClient` methods are `pub(crate)`.

### Pattern 3: `build_router` helper in `http.rs`

Extract router construction into `http.rs` so `main.rs` doesn't need to import axum routing primitives:

```rust
// src/http.rs
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

### Anti-Patterns to Avoid

- **Changing any logic while moving code:** This phase is move-only. Fixing the `turn_id` allowlist (CONCERNS.md known bug) or the boot-wait constant belongs in a later phase.
- **Moving `dotenvy::dotenv()` out of `main.rs`:** It must remain in `main` so it runs exactly once at startup before any other env reads. Do not call it inside `config::load_ht_mcp_path()`.
- **Adding `use super::*` glob imports:** Each module should import exactly what it uses. Glob imports hide what a module depends on.
- **Splitting `McpClient` fields across files:** The `Child` field that carries `kill_on_drop(true)` must stay together with `stdin`/`lines` in `mcp.rs`. Splitting the struct would break drop semantics.

---

## Concrete Symbol-to-File Mapping

Full line-range inventory of `webif/src/main.rs` (561 lines total):

[VERIFIED: direct read of `webif/src/main.rs`]

| Lines | Symbols | Target File |
|-------|---------|-------------|
| 1–17 | `//!` module doc comment (architecture summary) | `src/lib.rs` (top-level doc comment) |
| 19–36 | `use` imports | Distributed — each file imports only what it uses |
| 38–41 | `TURN_TIMEOUT`, `MCP_TIMEOUT` | `src/config.rs` |
| 43 | ASCII section banner comment | `src/mcp.rs` (as file-level comment) |
| 45–198 | `McpClient` struct + all methods | `src/mcp.rs` |
| 200 | ASCII section banner comment | `src/worker.rs` |
| 202–285 | `Worker` struct + all methods | `src/worker.rs` |
| 287 | ASCII section banner comment | `src/turn.rs` |
| 289–293 | `Job` struct | `src/turn.rs` |
| 295–310 | `build_prompt_body` fn | `src/turn.rs` |
| 312–349 | `process_job` fn | `src/turn.rs` |
| 351–369 | `worker_loop` fn | `src/turn.rs` |
| 371 | ASCII section banner comment | `src/http.rs` |
| 373–377 | `AppState` struct | `src/http.rs` |
| 379–381 | `ise()` helper fn | `src/http.rs` |
| 383–396 | `read_turn` fn | `src/turn.rs` (called from `http.rs`; logically turn-layer) |
| 398–407 | `PromptReq` struct | `src/http.rs` |
| 409–449 | `prompt_handler` fn | `src/http.rs` |
| 451–470 | `turn_handler` fn | `src/http.rs` |
| 472–476 | `CommandReq` struct | `src/http.rs` |
| 478–482 | `CommandResp` struct | `src/http.rs` |
| 484–501 | `command_handler` fn | `src/http.rs` |
| 503–507 | `RestartResp` struct | `src/http.rs` |
| 509–519 | `restart_handler` fn | `src/http.rs` |
| 521–561 | `main()` fn | `src/main.rs` (thinned to ~30 lines) |

**`read_turn` placement note:** `read_turn` is called from `http.rs` but operates on the turn filesystem layer. Placing it in `turn.rs` and marking `pub(crate)` keeps turn-related filesystem logic together. This is preferred over putting it in `http.rs` to avoid mixing transport and storage concerns.

**`config.rs` contents:**
```rust
use std::time::Duration;

// HT-PROTOCOL §12: ターンタイムアウト制約
pub(crate) const TURN_TIMEOUT: Duration = Duration::from_secs(300);
// ht-mcp の wedge 対策
pub(crate) const MCP_TIMEOUT: Duration = Duration::from_secs(30);

/// HT_MCP_PATH 環境変数を読む。env > .env > 既定 "ht-mcp" の順。
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Module visibility management | Custom re-export shims | Rust's native `pub`/`pub(crate)`/`pub(super)` | Language feature; no additional complexity |
| Cross-module error propagation | Custom error enum for refactor | Existing `anyhow::Result` | Zero change needed; anyhow is already in use |
| Router construction | Inline router in main | `build_router(state)` helper in `http.rs` | Keeps `main.rs` free of axum imports |

**Key insight:** This phase has no new library surface. The only engineering is Rust module system mechanics.

---

## Behavior-Preservation Risks

### Risk 1: `tokio::sync::Mutex` guard held across `.await` — must remain `tokio::sync::Mutex`

**What goes wrong:** If the Mutex type were accidentally changed to `std::sync::Mutex` during the move, holding the guard across `.await` in `worker_loop` or in `command_handler`/`restart_handler` would cause a compile error (or, if forced, a deadlock).

**Why it happens:** `tokio::sync::Mutex` is imported at line 35 as `use tokio::sync::{mpsc, Mutex}`. When copying the `use` block to `worker.rs`, a careless edit could import `std::sync::Mutex` instead.

**Mitigation:** In `worker.rs` import block, keep exactly `use tokio::sync::Mutex;`. Verify with `cargo check` after the move — `std::sync::Mutex` will cause a compile error if the guard crosses an `.await` point.

**Warning sign:** Compiler error `future cannot be sent between threads safely` or `MutexGuard cannot be held across an await point`.

### Risk 2: `kill_on_drop(true)` semantics — must not separate `Child` from `McpClient`

**What goes wrong:** `McpClient.child: Child` is marked `kill_on_drop(true)` (line 60). If `Child` were moved to a different struct or the field were made `Option<Child>` and accidentally `take()`'d, the drop-kill behavior would break: the ht-mcp subprocess would survive `McpClient` drops.

**Why it happens:** Refactoring temptation to "simplify" by removing the `#[allow(dead_code)]` annotation on `child` and making it `_child` or eliminating it.

**Mitigation:** Keep `child: Child` as-is in `McpClient` in `mcp.rs`. Keep the `#[allow(dead_code)]` annotation. Do not touch it.

**Warning sign:** Lingering `ht-mcp` processes visible in `ps aux` after `POST /restart`.

### Risk 3: `Arc<Mutex<Worker>>` shared between `worker_loop` and HTTP handlers — ownership must not fork

**What goes wrong:** `worker_loop` receives `Arc<Mutex<Worker>>` and the HTTP handlers access it via `AppState::worker`. Both point to the same `Arc`. If the refactor accidentally creates two separate `Worker` instances or two separate `Mutex<Worker>` wrappers, the `command_handler` and `restart_handler` would control a different Worker than `worker_loop` — silent correctness failure.

**Why it happens:** Cutting-and-pasting `main.rs` code and re-constructing `AppState` and `worker_loop` arguments independently.

**Mitigation:** Verify in `main.rs` that `worker_loop` and `AppState` are given `.clone()` of the same `Arc`:
```rust
let worker = Arc::new(Mutex::new(worker));
tokio::spawn(ht_webif::turn::worker_loop(worker.clone(), turns_dir.clone(), job_rx));
let state = Arc::new(AppState { worker, turns_dir, job_tx });
```
The `Arc::clone()` is the sharing mechanism. This code must be in `main.rs` exactly as above.

### Risk 4: `chrono` import for turn-ID generation in `prompt_handler`

**What goes wrong:** `prompt_handler` uses `chrono::Utc::now()` (line 415) to generate the turn ID. After moving to `http.rs`, the `chrono` dependency must be in `http.rs`'s `use` block.

**Mitigation:** `chrono` is a direct dependency in `Cargo.toml` — no change needed there. Just add `use chrono;` or inline the call in the handler.

### Risk 5: `AxumPath` name collision with `std::path::Path`

**What goes wrong:** `webif/src/main.rs` imports both `std::path::Path` and `axum::extract::Path as AxumPath` (line 27). When split into separate files, `http.rs` needs `AxumPath` and `turn.rs` needs `std::path::Path`. If either file imports the wrong one, compilation fails.

**Mitigation:** In `http.rs` use `use axum::extract::Path as AxumPath;`. In `turn.rs` and `mcp.rs` use `use std::path::{Path, PathBuf};`. The alias is already established in the original code.

### Risk 6: `println!`/`eprintln!` Japanese log strings — preserve verbatim

**What goes wrong:** Log strings are part of the observable "behavior" for operators. If they change, log parsing or monitoring scripts could break.

**Mitigation:** Copy all `println!`/`eprintln!` invocations verbatim. Do not translate or rephrase. Move startup prints from `main.rs` to `main.rs` wiring section only — they are not in other modules.

### Risk 7: Path-traversal guard on `turn_id` — must remain in `turn_handler`

**What goes wrong:** The regex-equivalent check `!turn_id.chars().all(|c| c.is_ascii_digit() || c == '-')` at line 457 is in `turn_handler`. If `turn_handler` is moved to `http.rs` without this guard, path traversal becomes possible.

**Mitigation:** The entire `turn_handler` function moves verbatim. The guard is inside the function body — it moves with it automatically. No special action needed, but include in acceptance criteria verification.

---

## `Cargo.toml` Changes Required

[VERIFIED: current `webif/Cargo.toml` has no `[lib]` or `[[bin]]` sections — cargo auto-detects the binary from `src/main.rs`]

```toml
# Add these two sections to webif/Cargo.toml
# (all other content unchanged)

[lib]
name = "ht_webif"
path = "src/lib.rs"

[[bin]]
name = "ht-webif"
path = "src/main.rs"
```

**Why `[[bin]]` is needed:** Without an explicit `[[bin]]` entry, Cargo infers the binary from `src/main.rs` when there is no `[lib]`. Once you add `[lib]`, Cargo still auto-detects `src/main.rs` as a binary, but making it explicit is clearer and required by the Rust Cargo reference when both targets coexist.
[ASSUMED: Cargo 1.95 auto-detection of `src/main.rs` still works when `[lib]` is present without explicit `[[bin]]` — but explicit is always safe and conventional.]

**No other `Cargo.toml` changes needed:**
- `edition = "2021"` stays
- All dependencies unchanged
- `name`, `version`, `description`, etc. unchanged

---

## Verification Strategy ("API Behavior Unchanged")

### Build verification

```bash
cd /home/parallels/workspaces/ht-mcp-sample/webif
cargo build --release 2>&1 | grep -E 'error|warning'
# Expected: no output (zero errors, zero warnings)
```

### Smoke test — manual curl set

Run these against a live instance started with `cargo run` from the project root.

**Test 1: POST /prompt (async)**
```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"echo hello"}' | jq .
# Expected: {"turn_id": "<id>", "status": "accepted"}
```

**Test 2: GET /turns/{id} — running state**
```bash
TURN_ID="<id from Test 1>"
curl -s http://127.0.0.1:8080/turns/$TURN_ID | jq .
# Expected: {"turn_id": "<id>", "status": "running"} or "done"
```

**Test 3: GET /turns/{id} — path traversal rejection**
```bash
curl -s http://127.0.0.1:8080/turns/../../etc/passwd
# Expected: HTTP 400, body contains "不正な turn_id"
```

**Test 4: POST /prompt with wait=true**
```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"echo hello","wait":true}' | jq .
# Expected: {"turn_id":"<id>","status":"done","result":"..."} (or timeout)
```

**Test 5: POST /prompt with fresh=true**
```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"echo hello","fresh":true}' | jq .
# Expected: {"turn_id":"<id>","status":"accepted"}
```

**Test 6: POST /command**
```bash
curl -s -X POST http://127.0.0.1:8080/command \
  -H 'Content-Type: application/json' \
  -d '{"text":"/help"}' | jq .
# Expected: {"sent":"/help","snapshot":"..."}
```

**Test 7: POST /restart**
```bash
curl -s -X POST http://127.0.0.1:8080/restart | jq .
# Expected: {"status":"restarted","session_id":"<new-id>"}
```

**Test 8: GET /turns/{id} — not found**
```bash
curl -s http://127.0.0.1:8080/turns/99990101-000000-000
# Expected: HTTP 404
```

### Unit-test seams created by the split (Phase 3 ready)

The refactor creates pure-function entry points that Phase 3 can unit-test without any subprocess:

| Function | File | Test type |
|----------|------|-----------|
| `build_prompt_body(task, result_path, status_path)` | `turn.rs` | Unit — no I/O, no async |
| `config::load_ht_mcp_path()` | `config.rs` | Unit — env var read |
| `turn_id` format via `chrono::Utc::now().format(...)` | `http.rs` | Unit — pure string formatting |
| `turn_id` validation logic (extracted to helper) | `http.rs` or `turn.rs` | Unit — char checks |
| `read_turn()` | `turn.rs` | Integration — needs temp files (simple with `tempfile` crate) |

---

## Common Pitfalls

### Pitfall 1: Circular imports between `http.rs` and `turn.rs`

**What goes wrong:** `http.rs` calls `read_turn` from `turn.rs`. `turn.rs` uses `Worker` from `worker.rs`. If any of these import from `http.rs`, a cycle forms and rustc refuses to compile.

**Why it happens:** Accidentally placing `AppState` in `turn.rs` so `worker_loop` can reference it, then importing `turn` from `http.rs`.

**How to avoid:** The dependency direction must be: `http.rs` → `turn.rs` → `worker.rs` → `mcp.rs`. `http.rs` also depends on `worker.rs` (for `AppState::worker` type). Neither `worker.rs` nor `mcp.rs` may import from `http.rs` or `turn.rs`.

**Warning signs:** `error[E0412]: cannot find type... in this scope` combined with import loops.

### Pitfall 2: Forgetting to re-export `Job` in `lib.rs` for `main.rs`

**What goes wrong:** `main.rs` creates the `mpsc::channel::<Job>(64)` — it needs `Job` in scope. If `lib.rs` doesn't re-export `turn::Job`, `main.rs` gets a "not in scope" compile error.

**How to avoid:** `lib.rs` must re-export at minimum: `turn::Job`, `turn::worker_loop`, `worker::Worker`, `http::AppState`, `http::build_router`, `config::load_ht_mcp_path`.

### Pitfall 3: `pub(crate)` not sufficient for `lib.rs` re-exports

**What goes wrong:** If an item is `pub(crate)` it cannot be re-exported as `pub` from `lib.rs`. The compiler will emit `error[E0603]: ... is private`.

**How to avoid:** Items re-exported from `lib.rs` to external consumers (including `main.rs`, which as a `[[bin]]` is technically a separate crate root) must be `pub`. Items only used within the library (between modules) can be `pub(crate)`.

**Clarification:** In the `lib.rs` + `main.rs` setup, `src/main.rs` uses `ht_webif::` (the lib crate name) to import. This means `pub` is required on items `main.rs` touches; `pub(crate)` suffices for items only used inside `src/lib.rs`'s module tree.

### Pitfall 4: `use` import blocks at the top of each new file — avoid over-importing

**What goes wrong:** Copying the entire `use` block from `main.rs` (lines 19–36) into every new file causes "unused import" warnings — which CLAUDE.md says the codebase must compile without.

**How to avoid:** Each file imports exactly the symbols it uses. Confirm with `cargo check` — any `unused_imports` warning means cleanup is needed.

---

## Code Examples

### File: `src/config.rs` (new file, complete)

```rust
//! 設定定数と環境変数読み込み。

use std::time::Duration;

/// 1ターンの最大待ち時間（1試行あたり）。
pub(crate) const TURN_TIMEOUT: Duration = Duration::from_secs(300);
/// MCP 呼び出し1回のタイムアウト（ht-mcp の wedge 対策）。
pub(crate) const MCP_TIMEOUT: Duration = Duration::from_secs(30);

/// `HT_MCP_PATH` 環境変数を読む。存在しない場合は "ht-mcp" を既定値とする。
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}
```

### File: `src/lib.rs` (new file, complete)

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

pub mod config;
pub mod http;
pub mod mcp;
pub mod turn;
pub mod worker;
```

### File: `src/mcp.rs` (header only — full content moves verbatim from main.rs lines 43–198)

```rust
// ── MCP クライアント（newline 区切り JSON-RPC を直接話す最小実装）─────────

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::config::MCP_TIMEOUT;

pub(crate) struct McpClient {
    #[allow(dead_code)]
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next_id: i64,
}
// ... all methods from main.rs:53–198, with `pub(crate)` on each method ...
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single-file Rust prototype | Multi-module library crate | Phase 2 | Enables `cargo test` imports; no behavior change |
| `main.rs`-only binary | `lib.rs` + thin `main.rs` | Phase 2 | Standard pattern for testable Rust binaries |

**Not changing in this phase:**
- HT-PROTOCOL v1.1 filesystem format — unchanged
- Timing constants (TURN_TIMEOUT 300s, MCP_TIMEOUT 30s, 700ms boot wait, 1s poll, 500ms submit settle, 1.5s command settle) — unchanged
- Turn-ID format `%Y%m%d-%H%M%S-%3f` — unchanged
- `turns/` directory resolution (CWD-relative) — unchanged

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Cargo 1.95 auto-detects `src/main.rs` as a binary even when `[lib]` is present, so `[[bin]]` can be made explicit without breaking anything | Cargo.toml Changes | Negligible — explicit `[[bin]]` is always safe regardless |
| A2 | `name = "ht-webif"` in `[[bin]]` matches the existing implicit binary name from `name = "ht-webif"` in `[package]` | Cargo.toml Changes | Build failure if wrong — but easily verified with `cargo build` |
| A3 | `pub(crate)` items in `src/` modules are accessible from sibling modules declared in `lib.rs` (they are — this is standard Rust) | Visibility Surface | Compile error if wrong — caught immediately by `cargo check` |

**If this table were empty:** All claims would be verified or cited — no user confirmation needed.

---

## Open Questions (RESOLVED)

1. **Should `read_turn` go in `turn.rs` or `http.rs`?**
   - What we know: `read_turn` does filesystem I/O (turn layer), is called only from `http.rs` (HTTP layer).
   - What's unclear: Whether to optimize for "callers" (put it in `http.rs`) or "responsibility" (put it in `turn.rs`).
   - Recommendation: `turn.rs` — filesystem state management is the turn layer's domain. Phase 3 can unit-test it in isolation.

2. **Should constants go in `config.rs` or in their consuming modules?**
   - What we know: `TURN_TIMEOUT` is used in `turn.rs` (process_job). `MCP_TIMEOUT` is used in `mcp.rs` (request). Neither is used in both — no duplication risk.
   - What's unclear: Whether to cluster all constants or co-locate with consumers.
   - Recommendation: `config.rs` — the success criteria explicitly mentions a `config` module, and grouping makes tunability visible in one place.

---

## Environment Availability

Step 2.6: SKIPPED (no external dependencies introduced by this phase — pure code reorganization)

The existing `cargo` toolchain (1.95.0), `rustc` (1.95.0), and `ht-mcp` binary are already present and confirmed working. [VERIFIED: `cargo check` completes cleanly on current codebase.]

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | None (Phase 2 adds no tests — that is Phase 3) |
| Config file | none — Wave 0 in Phase 3 |
| Quick run command | `cargo check` |
| Full suite command | `cargo build --release && cargo clippy -- -D warnings` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CODE-01 | `mcp_client`, `worker`, `turn`, `handlers`, `config` modules exist; `main.rs` is wiring only | structural / build | `cargo build --release` | ❌ Wave 0 (new files) |
| CODE-02 | All 4 HTTP endpoints respond identically to pre-refactor | smoke / manual curl | Manual curl set (see Verification Strategy) | ❌ Wave 0 (new files) |

### Sampling Rate

- **Per task commit:** `cargo check && cargo clippy`
- **Per wave merge:** `cargo build --release`
- **Phase gate:** `cargo build --release` with zero warnings + manual curl smoke set before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `src/lib.rs` — module declarations
- [ ] `src/config.rs` — constants + env var loader
- [ ] `src/mcp.rs` — McpClient
- [ ] `src/worker.rs` — Worker
- [ ] `src/turn.rs` — Job, build_prompt_body, process_job, worker_loop, read_turn
- [ ] `src/http.rs` — AppState, ise, handlers, build_router
- [ ] `webif/Cargo.toml` — `[lib]` + `[[bin]]` sections
- [ ] Thinned `src/main.rs` — wiring only (~30 lines)

---

## Security Domain

> `security_enforcement` not explicitly set to false — section included.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Not addressed in this phase (SEC-01 deferred to v2) |
| V3 Session Management | no | Not HTTP session — claude session managed by Worker |
| V4 Access Control | no | Not addressed in this phase |
| V5 Input Validation | yes | `turn_id` allowlist in `turn_handler` — must survive verbatim into `http.rs` |
| V6 Cryptography | no | No cryptographic operations |

**Security-relevant preservation:** The path-traversal guard (`!turn_id.chars().all(|c| c.is_ascii_digit() || c == '-')`) at main.rs:457 must appear **unchanged** in the moved `turn_handler` body. This is the only security control active in this codebase. Verify with Test 3 in the smoke set.

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal via `turn_id` | Tampering/Info Disclosure | Character allowlist in `turn_handler` — preserved verbatim |
| No auth on HTTP endpoints | Elevation of Privilege | Out of scope (SEC-01 deferred); localhost binding unchanged |

---

## Sources

### Primary (HIGH confidence)

- Direct read of `webif/src/main.rs` (561 lines) — symbol inventory
- Direct read of `webif/Cargo.toml` — dependency list, no existing `[lib]` or `[[bin]]`
- `cargo check` output — confirmed zero warnings, zero errors before refactor
- `.planning/codebase/ARCHITECTURE.md` — component responsibilities and layer documentation
- `.planning/codebase/CONCERNS.md` — known bugs, fragile areas, tech debt

### Secondary (MEDIUM confidence)

- Rust Cargo reference (from training knowledge): `[lib]` + `[[bin]]` layout for single-binary testable crates [ASSUMED: training knowledge, but this is extremely stable Rust convention]
- CLAUDE.md project conventions — naming, Japanese comments, error handling patterns

### Tertiary (LOW confidence)

- None

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all packages already present, cargo check verified
- Architecture: HIGH — direct source read, no inference
- Pitfalls: HIGH — Rust type system makes most risks compile-time detectable
- Behavior preservation: HIGH — refactor is mechanical; all risks are structurally detectable

**Research date:** 2026-05-24
**Valid until:** 60 days — Rust module system is extremely stable; axum 0.8 API unchanged for this use

---

## RESEARCH COMPLETE

**Phase:** 2 - Module Refactor
**Confidence:** HIGH

### Key Findings

1. **Exact file layout is clear:** 7 files needed — `lib.rs`, `main.rs` (thinned), `config.rs`, `mcp.rs`, `worker.rs`, `turn.rs`, `http.rs`. Every symbol from `main.rs` has a specific target file with line ranges documented.

2. **`Cargo.toml` needs exactly two new sections:** `[lib]` with `name = "ht_webif"` and `[[bin]]` with `name = "ht-webif"`. No dependency changes.

3. **Three visibility rules cover everything:** Items only `main.rs` touches → `pub`. Items multiple library modules share → `pub(crate)`. Items internal to one module → `private`. Notably `McpClient` is `pub(crate)` (only Worker uses it), `Worker` and `Job` are `pub` (main.rs needs them).

4. **Three concrete behavioral risks:** (a) wrong Mutex import — caught at compile time; (b) `Child` separation from `McpClient` — caught by `kill_on_drop` regression in restart test; (c) duplicate `Arc<Mutex<Worker>>` construction — caught by `POST /command` not affecting active turns.

5. **Zero new libraries required.** The refactor is pure Rust module mechanics — no external crates, no new tokio features, no build system changes beyond `Cargo.toml` target sections.

6. **8 curl smoke tests** cover all 4 endpoints including sync/async variants, fresh=true, path-traversal rejection, and not-found — sufficient to verify behavior preservation without any new test framework.

7. **`read_turn` belongs in `turn.rs`**, not `http.rs` — it reads turn-layer filesystem state; this placement prepares Phase 3 to unit-test it with temp files.

### File Created
`.planning/phases/02-module-refactor/02-RESEARCH.md`

### Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| Standard Stack | HIGH | All packages pre-existing; cargo check verified |
| Architecture | HIGH | Direct line-by-line read of source; no inference |
| Behavior Risks | HIGH | Rust type system surfaces most risks at compile time |
| Cargo.toml Changes | HIGH | `[lib]` + `[[bin]]` is standard, well-documented |

### Open Questions

- `read_turn` in `turn.rs` vs `http.rs` — minor; either works, recommendation given
- Constants in `config.rs` vs consuming modules — minor; `config.rs` preferred per success criteria wording

### Ready for Planning
Research complete. Planner can now create PLAN.md files.
