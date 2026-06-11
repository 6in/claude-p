# Coding Conventions

**Analysis Date:** 2026-05-26

## Naming Patterns

**Files:**
- Rust source files: `snake_case.rs` (e.g., `main.rs`, `mcp.rs`, `worker.rs`, `http.rs`, `turn.rs`, `config.rs`)
- Library entry: `lib.rs` at `src/lib.rs`
- Turn artifacts: Fixed by HT-PROTOCOL — `prompt-<turnId>.txt`, `result-<turnId>.txt`, `status-<turnId>.json` (see `src/turn.rs:22-35`)
- Documentation: UPPER-KEBAB at repo root (`HT-PROTOCOL.md`, `README.md`, `CLAUDE.md`)

**Functions:**
- `snake_case` throughout, async by default (e.g., `spawn`, `boot`, `restart`, `recreate`, `submit_line`, `snapshot`, `ensure_healthy`, `build_prompt_body`, `read_turn`, `process_job`, `worker_loop`)
- Favour short verb names over noun-y wrappers (`submit_line` rather than `submit_text_line`)
- Trait methods follow same `snake_case` pattern (`src/mcp.rs:14-27`)

**Variables:**
- `snake_case` everywhere (e.g., `turn_id`, `session_id`, `ht_mcp_path`, `job_tx`, `job_rx`, `next_id`, `turns_dir`, `status_path`, `prompt_path`)
- Binding re-use preferred over parallel names: `let worker = Arc::new(Mutex::new(worker))` in `src/main.rs:28` instead of introducing a distinct name

**Types (PascalCase):**
- Struct: `McpClient`, `Worker`, `Job`, `AppState`, `FakeMcp`
- Trait: `Mcp`, `Restartable`
- Request/Response DTO: Suffix `Req` or `Resp` (e.g., `PromptReq`, `CommandReq`, `CommandResp`, `RestartResp` in `src/http.rs:32-150`)

**Constants (SCREAMING_SNAKE_CASE):**
- Explicit type annotation required (e.g., `const TURN_TIMEOUT: Duration = Duration::from_secs(300);` in `src/config.rs:6`)
- `const MCP_TIMEOUT: Duration = Duration::from_secs(30);` in `src/config.rs:9`

**Routes (lowercase single-segment):**
- `/prompt`, `/turns/{turn_id}`, `/command`, `/restart` (`src/http.rs:172-175`)
- Path parameters use `snake_case` inside `{...}`

## Code Style

**Formatting:**
- `cargo fmt` defaults (rustfmt with no custom `rustfmt.toml`) — 4-space indent, trailing commas, `where`-clause line wrapping
- Run `cargo fmt --all` before commits (documented in `webif/justfile:19`)
- CI enforces `cargo fmt --check` on all pushes and pull requests (`.github/workflows/ci.yml:34`)

**Linting:**
- `cargo clippy --all-targets --release -- -D warnings` enforced (`.github/workflows/ci.yml:37`, `webif/justfile:23`)
- No custom `clippy.toml` — all warnings treated as errors in release mode
- Single `#[allow(dead_code)]` on `McpClient::child` (`src/mcp.rs:46`) for owned drop-trigger semantics
- Unit tests may use `#[allow(dead_code)]` where test scaffolding is incomplete (e.g., `FakeMcp` fields pre-populated for future tests in `src/mcp.rs:263`)

**Visual Section Markers:**
- ASCII banners as separators in source files (e.g., `// ── MCP クライアント ──` in `src/mcp.rs:1`)
- When `src/main.rs` grows, split along banner boundaries into modules (`mcp.rs`, `worker.rs`, `turns.rs`, `http.rs` — already completed)

## Import Organization

**Order:**
1. Standard library: `std::sync::Arc`, `std::time::Duration`, `std::path::{Path, PathBuf}`
2. External crates: `anyhow::{anyhow, Context, Result}`, `serde_json::{json, Value}`, `tokio::...`
3. Workspace crate modules: `use crate::config::...`, `use crate::http::...`, `use crate::mcp::...`
4. Re-exports from same module (rarely needed — crate is modular)

**Examples:**
- `src/http.rs:1-20` — Standard → External → Crate → Local
- `src/mcp.rs:1-12` — Standard → External (anyhow, serde_json) → External (tokio, async_trait)

**Path Aliases:**
- None currently used. Crate is small; absolute imports via `use crate::module::...` preferred

## Error Handling

**Pattern: anyhow + ? propagation:**
- Use `?` operator throughout for automatic error propagation
- Attach context via `.with_context(|| format!("..."))` at OS boundary (e.g., `src/mcp.rs:64`, `src/worker.rs:31-35`)
- Example: `let mut client = McpClient::spawn(program).with_context(|| format!("ht-mcp の起動に失敗: {program}"))?;`

**Contextual errors (anyhow!):**
- Create ad-hoc errors with Japanese messages: `anyhow!("セッション ID が取れない:\n{text}")` (`src/mcp.rs:199`)
- Contextual strings bubble through HTTP handlers and appear in JSON error responses

**HTTP boundary (Result<Json<T>, (StatusCode, String)>):**
- Helper `fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String)` maps any error to `500` (`src/http.rs:28-30`)
- Use `.map_err(ise)` for internal errors that should become 500 responses
- Explicit status codes for business logic errors:
  - `StatusCode::BAD_REQUEST` for validation (e.g., invalid `turn_id` in `src/http.rs:95`)
  - `StatusCode::NOT_FOUND` for missing turns (`src/http.rs:106-108`)
  - `StatusCode::GATEWAY_TIMEOUT` for synchronous wait timeout (`src/http.rs:74-75`)

**Best-effort cleanup (ignored errors):**
- `let _ = self.client.close_session(&old).await;` when closing old session after recreate (`src/worker.rs:115`)
- `let _ = tokio::fs::write(&status_path, body).await;` when writing status file on worker failure (`src/turn.rs:96`)
- Snapshot failures in command handler don't block response: `.unwrap_or_else(|e| format!("(snapshot 取得失敗: {e})")` (`src/http.rs:136-139`)

## Logging

**Framework:** `println!` / `eprintln!` only — no structured logging framework

**Tag format (bracketed source):**
- `[restart]` — ht-mcp restart events (`src/worker.rs:118-120`)
- `[shared-fate]` — claude session recreation (`src/worker.rs:90`, `src/worker.rs:117-120`)
- `[worker]` — job processing, timeouts, failures (`src/turn.rs:70-72`, `src/turn.rs:90`)

**Examples:**
```rust
eprintln!("[shared-fate] claude セッション不健全 → 再生成");
eprintln!("[worker] ターン {} タイムアウト（試行 {attempt}/2）→ セッション再生成", job.turn_id);
eprintln!("[worker] ジョブ {} 失敗: {e}", job.turn_id);
```

**What to log:**
- Startup banner: route surface, paths, session IDs (`src/main.rs:42-49`)
- Recovery events: worker restart, session recreation, ht-mcp restart (always logged)
- Per-turn timeouts and failures with `turn_id` and attempt counter
- Do NOT log per-turn success (rely on `status-<turnId>.json` instead)

**Stderr passthrough:**
- ht-mcp child stderr is inherited, not captured → logs interleave naturally with WebIF stderr (`src/mcp.rs:61`)

**Language:**
- Tag identifiers: English bracketed (e.g., `[restart]`, `[worker]`)
- Message text: Japanese (descriptions of what happened)

## Comments

**When to Comment:**
- File-level `//!` doc comment summarizes module: architecture, data flow, recovery story (`src/lib.rs:1-17`)
- Item-level `///` doc comments for non-trivial public methods (`src/mcp.rs:14-27`, `src/worker.rs:30-35`, `src/turn.rs:38-42`)
- Inline `//` comments explain *why*, not *what* (e.g., `// 旧 client は drop され、ht-mcp ごと kill される` in `src/mcp.rs:244`)
- Test comments explain context or non-obvious harness structure (e.g., `src/mcp.rs:357-355`)

**Language:**
- Doc comments: Japanese description, English in parameter names (e.g., `pub async fn spawn(program: &str) -> Result<Self>` with `/// ht-mcp を子プロセスとして起動する。`)
- Inline comments: Japanese
- Code identifiers: English (required for Rust compilation + axum/serde/tokio interop)

**JSDoc/TSDoc:**
- Not applicable — Rust uses `///` doc comments with similar structure
- Trait methods document the contract (e.g., `src/mcp.rs:38-40` explains the guarantee of `respawn`)

## Function Design

**Size:**
- Prefer small, single-purpose functions (~20-50 lines typical)
- Examples: `build_prompt_body` (15 lines, `src/turn.rs:22-36`), `ensure_healthy` (11 lines, `src/worker.rs:84-94`)

**Parameters:**
- Borrow by `&str`, `&Path`, `&[String]` where ownership not needed (`src/turn.rs:22`, `src/mcp.rs:57`)
- Take owned `String` when storing (e.g., `Worker::new(ht_mcp_path: String)` at `src/worker.rs:21`)
- Trait methods may require `&mut self` for interior mutability (e.g., `async fn handshake(&mut self) -> Result<()>` in `src/mcp.rs:21`)

**Return Values:**
- Fallible internals: `Result<T>` (anyhow)
- HTTP handlers: `Result<Json<T>, (StatusCode, String)>`
- Simple fire-and-forget: `async fn submit_line(...)` with no return value (`src/worker.rs:71`)

**Async:**
- `async` functions return `impl Future`, named `async fn` rather than wrapping in `Box`
- Async trait methods use `#[async_trait]` macro (`src/mcp.rs:19`, `src/worker.rs` trait context)
- `.await` used at all suspension points

## Module Design

**Exports:**
- Library root `src/lib.rs:19-23` re-exports public module structure: `pub mod config; pub mod http; pub mod mcp; pub mod turn; pub mod worker;`
- Each module exposes public API (traits, key structs, functions) needed by main.rs and cross-module calls
- Example: `src/mcp.rs` exposes `trait Mcp`, `trait Restartable`, `struct McpClient` (impl both traits), and test-only `pub(crate) struct FakeMcp`

**Barrel Files:**
- Not used; crate is small enough for direct imports
- Future growth: if modules exceed ~200 lines each, consider barrel exports at module level

**Test Modules:**
- Co-located `#[cfg(test)] mod tests` at end of each module (`src/mcp.rs:250-521`, `src/turn.rs:116-208`, `src/http.rs:179-316`)
- Test doubles (FakeMcp) live in test module with `pub(crate)` visibility for cross-module test use

## Async / Concurrency Patterns

**Tokio Runtime:**
- `#[tokio::main]` at `src/main.rs:11` with default multi-threaded executor
- `tokio::spawn` for background tasks (worker_loop at `src/main.rs:30`)
- `tokio::sync::Mutex` (not `std::sync::Mutex`) because lock guard is held across `.await` (`src/main.rs:28`, `src/http.rs:129`)

**Mutex Pattern:**
- `Arc<Mutex<Worker>>` owned by `AppState` and `worker_loop` (`src/main.rs:28-30`, `src/http.rs:22-26`)
- Acquire lock, perform operation, drop guard as early as possible via scoping (current code holds lock for entire handler body — acceptable because worker is intentionally single-threaded)
- Example: `let mut worker = state.worker.lock().await;` then `worker.submit_line(...).await?;` (`src/http.rs:129`)

**Channel Pattern:**
- `tokio::sync::mpsc::channel::<Job>(64)` for fan-in from HTTP handlers to worker_loop (`src/main.rs:29`)
- HTTP handler sends `Job { turn_id, fresh }` to `job_tx`; worker_loop receives and processes serially
- Closed channel converted to 500 error: `.map_err(|_| ise("ジョブキューが閉じています"))?` (`src/http.rs:66`)

**Timeout Patterns:**
- MCP callouts wrapped with `tokio::time::timeout(MCP_TIMEOUT, fut)` (`src/mcp.rs:140`)
- Convert timeout errors to contextual `anyhow!`: `Err(anyhow!("ht-mcp 応答タイムアウト ({}s)", MCP_TIMEOUT.as_secs()))` (`src/mcp.rs:142-145`)
- Polling loops use `Instant::now() + Duration` deadlines with `tokio::time::sleep` (`src/worker.rs:42-52`, `src/turn.rs:60-68`)

**Settle Delays:**
- Post-keystroke before `Enter`: 500 ms (`src/mcp.rs:226`)
- Post-command settle before snapshot: 1500 ms (`src/http.rs:133`)
- Boot wait for claude TUI: 700 ms polling interval (`src/worker.rs:51`)
- Turn-complete polling: 1 s interval (`src/turn.rs:68`)

**Process Lifecycle:**
- `tokio::process::Command` with `.kill_on_drop(true)` so dropping client kills ht-mcp (`src/mcp.rs:62`)
- Pipe `stdin`/`stdout`, inherit `stderr` so ht-mcp logs surface in parent terminal (`src/mcp.rs:59-61`)
- Main exits cleanly: `axum::serve(listener, app).await?` propagates result up (`src/main.rs:50`)

## HTTP Handler Conventions (axum 0.8)

**Routing:**
- Single `Router::new()` created by `build_router(state)` function (`src/http.rs:170-177`)
- Routes registered via `.route(path, handler)` with axum extractors (`Path`, `State`, `Json`)
- State passed via `State(state)` extractor (`src/http.rs:45`)

**Extractors:**
- `Path<String>` for path parameters (e.g., `turn_id` in `/turns/{turn_id}`)
- `Json<RequestType>` for JSON body deserialization (auto-derives from `#[derive(Deserialize)]`)
- `State(Arc<AppState<M>>)` for shared application state

**Response Format:**
- Success: `Json<Value>` or `Json<StructType>` with `serde_json::json!` macro
- Error: `(StatusCode, String)` tuple for explicit code + message
- JSON timestamps: generated server-side, never sent by client (turn_id from `chrono::Utc::now()`)

**Defensive Validation:**
- Path traversal guard: `turn_id` whitelist `^[0-9-]+$` only (`src/http.rs:94`)
- New handlers accepting filesystem-path identifiers MUST apply equivalent whitelist
- Validation errors return `StatusCode::BAD_REQUEST` with message

## Serde Patterns

**Derive Macros:**
```rust
#[derive(Deserialize)]
pub struct PromptReq {
    prompt: String,
    #[serde(default)]
    fresh: bool,
    #[serde(default)]
    wait: bool,
}

#[derive(Serialize)]
pub struct CommandResp {
    sent: String,
    snapshot: String,
}
```

**JSON Dynamism:**
- Use `serde_json::Value` for schema-free responses (e.g., turn status which may contain `{"status":"done"}` or `{"status":"failed","error":"..."}`)
- Parse with `.ok()` to silently handle malformed JSON (e.g., `src/turn.rs:106-108` when status.json is corrupt)

**Configuration:**
- `#[serde(default)]` on optional fields (e.g., `fresh: bool`, `wait: bool` default to `false`)
- `#[allow(dead_code)]` on unused fields if future-proofing for API extension

## Constants and Configuration

**Environment Variables:**
- Loaded by `dotenvy::dotenv()` at `src/main.rs:14` from `.env` or `.env.example`
- Precedence: real process env > `.env` > default values
- `HT_MCP_PATH` defaults to `"ht-mcp"` if not set (`src/config.rs:12-14`)

**Duration Constants:**
- `TURN_TIMEOUT: Duration = Duration::from_secs(300)` — per-attempt timeout in worker loop (`src/config.rs:6`)
- `MCP_TIMEOUT: Duration = Duration::from_secs(30)` — single MCP call timeout (`src/config.rs:9`)
- Channel capacity: 64 jobs (`src/main.rs:29`)
- Polling intervals hardcoded in functions (700 ms boot, 1 s turn polling)

## Language for Code and Docs

**Identifiers (English):**
- Function names, variable names, type names, module names
- Required for compilation and interop with external crates (axum, tokio, serde)

**Comments, Logs, Error Messages (Japanese):**
- File-level and item-level doc comments: Japanese descriptions with English identifier names
- Inline comments: Japanese
- `println!` / `eprintln!` output: Japanese
- `anyhow!("...")` error messages: Japanese
- HTTP response error strings: Japanese (e.g., `"不正な turn_id"`, `"ジョブキューが閉じています"`)

**Example Hybrid:**
```rust
/// claude セッションが生きているか確認し、死んでいれば再生成する（shared-fate 対策）。
pub async fn ensure_healthy(&mut self) -> Result<()> { ... }

anyhow!("セッション ID が取れない:\n{text}")

eprintln!("[shared-fate] claude セッション不健全 → 再生成");
```

---

*Convention analysis: 2026-05-26*
