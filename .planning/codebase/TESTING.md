# Testing Patterns

**Analysis Date:** 2026-05-26

## Test Framework

**Runner:**
- Rust built-in `#[tokio::test]` for async tests (no separate test framework)
- Config: `Cargo.toml` specifies `[dev-dependencies]` with `tower` (feature `util`) and `tempfile` (version `3`)
- No `tests/` directory — all tests co-located with source (`#[cfg(test)] mod tests`)

**Assertion Library:**
- Standard Rust `assert!`, `assert_eq!`, `assert_ne!` macros
- No external assertion library

**Run Commands:**
```bash
cargo test --release            # Run all tests (CI mode, matches local justfile)
cargo test --release -- --nocapture  # With println! output
cargo test --release [test_name]     # Single test by name
just test                       # From webif/ directory (justfile:14)
```

**Watch Mode:**
- Not configured; use `cargo watch -x 'test --release'` manually (requires cargo-watch external)

**Coverage:**
- Not enforced (no coverage target in CI)
- No lcov/tarpaulin integration

## Test File Organization

**Location:**
- Co-located inline: `#[cfg(test)] mod tests { ... }` at end of each module
  - `src/mcp.rs:250-521` — McpClient request/response roundtrip tests
  - `src/turn.rs:116-208` — build_prompt_body, read_turn, turn_id formatting tests
  - `src/http.rs:179-316` — HTTP handler path traversal and status file tests

**Naming:**
- Test modules: `mod tests` (conventional, single per file)
- Test functions: `test_*` or descriptive assertion phrase (e.g., `turn_handler_rejects_path_traversal_via_percent_encoded_slash`, `read_turn_returns_done_when_status_complete`)

**Structure:**
```
src/
├── mcp.rs
│   ├── [production code]
│   └── #[cfg(test)]
│       mod tests {
│           [test doubles like FakeMcp]
│           [helper functions]
│           #[tokio::test]
│           async fn test_name() { ... }
│       }
├── turn.rs
│   └── #[cfg(test)]
│       mod tests {
│           #[test]
│           fn test_name() { ... }
│           #[tokio::test]
│           async fn async_test_name() { ... }
│       }
└── http.rs
    └── #[cfg(test)]
        mod tests {
            #[tokio::test]
            async fn test_name() { ... }
        }
```

## Test Structure

**Suite Organization:**
- Each module exposes tests independently
- No shared test setup in a common harness — each test module imports what it needs
- Example: `src/http.rs:181-189` imports `FakeMcp` from sibling `mcp::tests`, `Worker`, `tempdir`, `tower::ServiceExt`

**Patterns:**

### Synchronous Unit Test
```rust
#[test]
fn build_prompt_body_includes_task_and_paths() {
    let result_path = PathBuf::from("/tmp/result-X.txt");
    let status_path = PathBuf::from("/tmp/status-X.json");
    let body = build_prompt_body("やってほしいこと", &result_path, &status_path);
    assert!(body.contains("やってほしいこと"));
    assert!(body.contains("/tmp/result-X.txt"));
    assert!(body.contains("【ht-webif 出力規約】"));
}
```
(from `src/turn.rs:124-133`)

### Async Unit Test with Tokio
```rust
#[tokio::test]
async fn read_turn_returns_done_when_status_complete() {
    let dir = tempdir().unwrap();
    let id = "20260525-000000-000";
    tokio::fs::write(dir.path().join(format!("status-{id}.json")), "{\"status\":\"done\"}\n")
        .await
        .unwrap();
    tokio::fs::write(dir.path().join(format!("result-{id}.txt")), "回答本文")
        .await
        .unwrap();
    let v = read_turn(dir.path(), id).await.unwrap();
    assert_eq!(v.get("status").and_then(Value::as_str), Some("done"));
}
```
(from `src/turn.rs:155-172`)

### Async Round-trip Test with Duplex
```rust
#[tokio::test]
async fn request_builds_jsonrpc_envelope_with_method_and_params() {
    let (mut client, mut harness_reader, mut harness_writer) = make_client_and_harness();
    
    let client_task = tokio::spawn(async move {
        client.request("tools/call", json!({ "name": "ht_take_snapshot" })).await
    });
    
    let mut line = String::new();
    harness_reader.read_line(&mut line).await.unwrap();
    let parsed: Value = serde_json::from_str(line.trim()).expect("JSON パース失敗");
    assert_eq!(parsed.get("jsonrpc").and_then(Value::as_str), Some("2.0"));
    
    // Write fake response
    let id = parsed["id"].as_i64().unwrap();
    let response = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"content\":[{{\"text\":\"snap-data\"}}]}}}}\n");
    harness_writer.write_all(response.as_bytes()).await.unwrap();
    
    let result = client_task.await.unwrap().unwrap();
    assert!(result.get("content").is_some());
}
```
(from `src/mcp.rs:373-432`)

### Integration Test with Tower ServiceExt
```rust
#[tokio::test]
async fn turn_handler_rejects_path_traversal_via_percent_encoded_slash() {
    let dir = tempdir().unwrap();
    let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
    let app = build_router(state);
    
    let resp = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/turns/..%2Fetc%2Fpasswd")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
```
(from `src/http.rs:220-242`)

**Setup Pattern:**
- `tempdir()` from crate `tempfile` creates isolated temp directories (`src/turn.rs:157`)
- Write files directly: `tokio::fs::write(path, content).await.unwrap()`
- No shared fixtures — each test creates its own files/state

**Teardown Pattern:**
- `tempdir()` auto-cleans on drop (no manual cleanup needed)
- Test isolation guaranteed by separate directory per test

**Assertion Pattern:**
- `assert_eq!(a, b, "optional message")` for equality with context message
- `.and_then()` chains for Option navigation: `v.get("status").and_then(Value::as_str)`
- `.is_some()` / `.is_none()` for Option checks

## Mocking

**Framework:** Ad-hoc trait-based doubles (no mockall, no Mock! macro)

**Test Doubles:**

### FakeMcp Struct
```rust
pub(crate) struct FakeMcp {
    pub handshake_calls: u32,
    pub create_session_replies: VecDeque<Result<String>>,
    pub close_session_log: Vec<String>,
    pub send_keys_log: Vec<(String, Vec<String>)>,
    pub submit_line_log: Vec<(String, String)>,
    pub snapshot_replies: VecDeque<Result<String>>,
}

impl FakeMcp {
    pub(crate) fn new() -> Self { ... }
}
```
(from `src/mcp.rs:264-291`)

**Trait Implementations:**
- `FakeMcp` implements `Mcp` trait with scripted replies (queue-based) (`src/mcp.rs:294-336`)
- `FakeMcp` implements `Restartable` trait with no-op respawn (increments `handshake_calls` only) (`src/mcp.rs:342-348`)
- Pattern: trait methods pop from scripted reply queue; if empty, return error; logging methods record calls to Vec

**Patterns:**

### Scripted Reply Queue
```rust
// In test setup:
let mut fake = FakeMcp::new();
fake.create_session_replies.push_back(Ok("session-123".to_string()));

// In trait impl:
async fn create_claude_session(&mut self) -> Result<String> {
    self.create_session_replies
        .pop_front()
        .unwrap_or_else(|| Err(anyhow!("create_claude_session scripted reply 切れ")))
}
```

### Call Log Inspection
```rust
#[test]
fn test_something() {
    let mut fake = FakeMcp::new();
    // ... make calls that invoke submit_line ...
    assert_eq!(fake.submit_line_log.len(), 1);
    assert_eq!(fake.submit_line_log[0], ("session-id".to_string(), "/clear".to_string()));
}
```

**What to Mock:**
- External dependencies: `McpClient` → `FakeMcp` (trait boundary)
- No mocking of filesystem — use `tempdir()` for hermetic tests
- No mocking of network — tests are entirely local (no real HTTP in tests)

**What NOT to Mock:**
- Filesystem operations: write/read with real temp directories
- JSON parsing/serialization: test actual serde behavior
- Async runtime: use `#[tokio::test]` to run on real Tokio

## Fixtures and Factories

**Test Data / Fixture Creation:**

### build_test_state Helper
```rust
fn build_test_state(turns_dir: PathBuf) -> (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>) {
    let (job_tx, job_rx) = mpsc::channel(64);
    let worker = Worker::<FakeMcp>::from_parts(
        FakeMcp::new(),
        "test-session".to_string(),
        "/dev/null".to_string(),
    );
    let worker = Arc::new(Mutex::new(worker));
    let state = Arc::new(AppState {
        worker,
        turns_dir,
        job_tx,
    });
    (state, job_rx)
}
```
(from `src/http.rs:194-209`)

### Worker::from_parts Constructor (Test-Only)
```rust
#[cfg(test)]
pub(crate) fn from_parts(client: M, session_id: String, ht_mcp_path: String) -> Self {
    Self {
        client,
        session_id,
        ht_mcp_path,
    }
}
```
(from `src/worker.rs:62-69`)

- `#[cfg(test)]` guards against production inclusion
- `pub(crate)` restricts to same-crate test modules only
- Allows direct assembly of `Worker<FakeMcp>` without spawning ht-mcp

### Duplex Harness Helper
```rust
fn make_client_and_harness() -> (
    McpClient,
    BufReader<tokio::io::DuplexStream>,
    tokio::io::DuplexStream,
) {
    let (client_stdin, test_reads) = duplex(1024);
    let (test_writes, client_stdout) = duplex(1024);
    let client = McpClient::from_streams(client_stdin, client_stdout);
    (client, BufReader::new(test_reads), test_writes)
}
```
(from `src/mcp.rs:359-370`)

- `McpClient::from_streams` is test-only constructor (`#[cfg(test)]` at `src/mcp.rs:85`)
- Returns tuple of (client ready to test, harness reader, harness writer)
- `duplex(1024)` is in-memory bidirectional pipe (tokio I/O)

**Location:**
- Fixtures and factories co-located in test module where used (e.g., `build_test_state` in `src/http.rs:180+`)
- Test-only constructors (`from_parts`, `from_streams`) in production module but guarded `#[cfg(test)]`

## Coverage

**Requirements:** None enforced

**Current Coverage Areas:**
- `build_prompt_body`: 4 assertions (`src/turn.rs:124-152`)
- `read_turn`: Happy path (done), error path (garbled JSON → unknown), missing file → empty (`src/turn.rs:155-207`)
- `McpClient::request`: JSON-RPC envelope structure, next_id increment, result extraction (`src/mcp.rs:373-520`)
- HTTP handlers: Path traversal rejection (2 forms), status file detection, HTTP status codes (`src/http.rs:220-315`)
- `turn_id` formatter: YYYYMMDD-HHMMSS-mmm shape (`src/turn.rs:137-152`)

**Gaps:**
- Worker lifecycle (boot, recreate, restart) — tested indirectly via HTTP integration, not isolated
- Error paths in MCP protocol (bad JSON, timeout behavior) — timeout covered by wrapping, JSON error handling implicit
- Full synchronous `/prompt` wait=true flow — no explicit test, but covered by hermetic file + polling
- Concurrent turns in worker_loop — single-threaded by design, not tested

## Test Types

**Unit Tests:**
- Scope: Single function or method in isolation
- Example: `build_prompt_body_includes_task_and_paths` (`src/turn.rs:124-133`) — tests string formatting
- Approach: Synchronous (`#[test]`) with minimal setup

**Integration Tests (co-located):**
- Scope: Multiple modules or layers interacting (via trait boundaries)
- Example: `turn_handler_returns_done_when_status_file_exists` (`src/http.rs:278-315`) — HTTP handler + file I/O + JSON parsing
- Approach: Async (`#[tokio::test]`), uses `tempdir()`, `tower::ServiceExt::oneshot` for HTTP simulation

**Hermetic Tests:**
- All tests are hermetic: no external network, no real ht-mcp spawning, no /tmp pollution (tempfile auto-cleanup)
- Example: `McpClient::request` tests use in-memory duplex instead of spawning real process (`src/mcp.rs:373+`)

**No E2E Tests:**
- No tests that spawn actual ht-mcp and claude
- Not in scope for this codebase (documented in CLAUDE.md project intent)

## Common Patterns

**Async Testing with Tokio:**
```rust
#[tokio::test]
async fn test_name() {
    let value = some_async_function().await;
    assert_eq!(value, expected);
}
```

**Concurrent Task Testing:**
```rust
#[tokio::test]
async fn test_concurrent() {
    let task = tokio::spawn(async { /* long-running */ });
    // Do something else while task runs
    let result = task.await;
    assert_eq!(result, expected);
}
```
(from `src/mcp.rs:379` pattern)

**Error Testing:**
```rust
#[tokio::test]
async fn test_error_case() {
    let err = operation_that_fails().await;
    match err {
        Err(e) if e.to_string().contains("expected error text") => { /* ok */ },
        _ => panic!("unexpected error"),
    }
}
```

Implicit in tests where `.expect("message")` validates error path exists.

**Timeout Testing:**
- Timeouts tested indirectly via `tokio::time::timeout` in implementation (`src/mcp.rs:140`)
- No explicit timeout test (would slow CI); rely on CI kill if hang

**File I/O Testing:**
```rust
#[tokio::test]
async fn test_file_ops() {
    let dir = tempdir().unwrap();
    tokio::fs::write(dir.path().join("file.txt"), "content").await.unwrap();
    let content = tokio::fs::read_to_string(dir.path().join("file.txt")).await.unwrap();
    assert_eq!(content, "content");
}
```
(from `src/turn.rs:159+` pattern)

**HTTP Handler Testing (Tower):**
```rust
#[tokio::test]
async fn test_http_handler() {
    let (state, _job_rx) = build_test_state(tempdir().unwrap().path().to_path_buf());
    let app = build_router(state);
    
    let response = app
        .oneshot(Request::builder()...)
        .await
        .unwrap();
    
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["turn_id"], "...");
}
```
(from `src/http.rs:278-315` pattern)

## CI/CD Testing Flow

**GitHub Actions (`.github/workflows/ci.yml:1-41`):**

Runs on every `push` to `main` and `pull_request` targeting `main`:

1. **Checkout** → Clone repo
2. **Install Rust** → `actions-rust-lang/setup-rust-toolchain@v1`, stable toolchain + rustfmt + clippy components
3. **Cache cargo** → `Swatinem/rust-cache@v2`, workspace `webif -> webif/target`
4. **Format check** → `cargo fmt --all -- --check` (fails if formatting issues)
5. **Clippy** → `cargo clippy --all-targets --release -- -D warnings` (fails on any warning)
6. **Test** → `cargo test --release` (runs all #[test] and #[tokio::test] in codebase)

**Local Equivalents (webif/justfile):**
```bash
just fmt     # cargo fmt --all
just clippy  # cargo clippy --all-targets --release -- -D warnings
just test    # cargo test --release
```

**Order of Checks:**
1. Format (catches style issues early)
2. Clippy (catches logic/safety issues)
3. Tests (validates functionality)

Failing at any stage stops the pipeline.

**Continuous Integration Note:**
- Single Ubuntu runner, no matrix (no cross-platform testing in CI — handled by `.github/workflows/release.yml` for binary releases)
- No conditional tests (same test suite runs on all PRs)
- Test output (`--release` profile, no `--nocapture`) is silent on success, verbose on failure

## Dev Dependencies

**In Cargo.toml (`webif/Cargo.toml:23-27`):**
```toml
[dev-dependencies]
tower = { version = "0.5", features = ["util"] }
tempfile = "3"
```

**Why:**
- `tower::ServiceExt::oneshot` — Simulate HTTP requests without running server (`src/http.rs:227-234`)
- `tempfile::tempdir()` — Create isolated temp directories for file-based tests (`src/turn.rs:157`, `src/http.rs:223`)

---

*Testing analysis: 2026-05-26*
