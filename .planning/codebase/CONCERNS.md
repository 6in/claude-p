# Codebase Concerns

**Analysis Date:** 2026-05-26

## Tech Debt

**Hardcoded address binding (loopback only):**
- Issue: `127.0.0.1:8080` is hardcoded in `src/main.rs:40` with no configuration option
- Files: `src/main.rs:40`
- Impact: Cannot be deployed behind a reverse proxy or accessed from other hosts without code changes; loopback-only binding reduces flexibility but improves default security posture
- Fix approach: Make bind address configurable via `LISTEN_ADDR` environment variable with fallback to `127.0.0.1:8080`

**No structured logging (println!/eprintln! only):**
- Issue: All logging uses `println!`/`eprintln!` with ad-hoc formatting; `tracing` crate is pulled in by axum but never used (`src/mcp.rs:76`, `src/http.rs` imports)
- Files: `src/main.rs:16,20,42-49`, `src/turn.rs:70-73,90`, `src/worker.rs:90,117-120`, `src/http.rs:139`
- Impact: No log levels, no structured format, difficult to parse logs in production; interleaving with ht-mcp stderr is uncontrolled
- Fix approach: Integrate `tracing` subscriber at startup; tag all eprintln calls with levels (debug/info/warn/error); consider structured JSON output option

**Magic numbers scattered across timeout logic:**
- Issue: Multiple hardcoded durations lack rationale documentation:
  - `TURN_TIMEOUT = 300s` (`src/config.rs:6`) — why not 600s? 180s?
  - `MCP_TIMEOUT = 30s` (`src/config.rs:9`) — why not 60s for slower operations?
  - `700ms` boot wait (`src/worker.rs:51`) — race-condition prone; could miss faster startup
  - `500ms` post-keystroke settle (`src/mcp.rs:226`) — arbitrary; may cause flake if TUI responds faster/slower
  - `1500ms` post-command settle (`src/http.rs:133`) — undocumented
  - `700s` sync wait deadline (`src/http.rs:70`) — why so much larger than TURN_TIMEOUT × 2?
  - `25s` session boot deadline (`src/worker.rs:42`) — separate from TURN_TIMEOUT
- Files: `src/config.rs:6,9`, `src/worker.rs:42,51,104,113,141,150`, `src/mcp.rs:226`, `src/http.rs:70,133`
- Impact: Tuning fragility; changing one timeout may break others; no way to understand intent or reason about failure modes
- Fix approach: Document each timeout constant with justification (e.g., "TURN_TIMEOUT: Max time for claude to complete a turn, observed typical range 10-60s"); consolidate related timeouts; consider making configurable per phase

**Minimal error recovery context for operators:**
- Issue: When a turn times out or fails, status file contains only minimal JSON (e.g., `{"status":"timeout"}` at `src/turn.rs:77`); no diagnostic info about what claude was doing
- Files: `src/turn.rs:77`, `src/http.rs:139`
- Impact: Operators cannot diagnose why a turn failed without manually checking logs or snapshots; snapshot after timeout (`src/http.rs:133` uses 1500ms settle, not guaranteed to be post-failure)
- Fix approach: Capture snapshot before timeout, append to status JSON as `"last_snapshot"` field; include `attempt` count and final MCP_TIMEOUT exceeded flags

## Known Bugs

**Potential race between status file write and read:**
- Symptoms: Rarely, caller reads partial/corrupted status JSON if claude writes simultaneously with WebIF polling
- Files: `src/turn.rs:62-64` (polling loop), `src/turn.rs:77` (timeout status write), `src/http.rs:99-101` (GET handler reads)
- Trigger: Claude TUI finishes and writes status at same instant WebIF's 1-second polling loop wakes and attempts read
- Workaround: HT-PROTOCOL §6 calls for atomic rename (`.tmp` → `.json`), which should guarantee complete file on read; however, `src/turn.rs:77` uses `tokio::fs::write` directly (non-atomic) when writing timeout status
- Note: Claude TUI should follow protocol; WebIF's timeout-write is the bug

**Status file polling granularity (1 second) may miss rapid completions:**
- Symptoms: Turns that complete in < 1 second may see 1-second delay before WebIF notices
- Files: `src/turn.rs:68` (`tokio::time::sleep(Duration::from_secs(1))`)
- Trigger: Very fast turns (e.g., simple queries) finish and write status between polling cycles
- Workaround: Reduce sleep to 100-500ms; or implement inotify/file watch (complex, platform-dependent)
- Impact: Low (acceptable latency for most use cases, but affects /wait sync response time)

**MCP handshake lacks version negotiation:**
- Symptoms: If ht-mcp implements different protocol version, incompatibility goes undetected
- Files: `src/mcp.rs:177-188` (initialize with hardcoded `2024-11-05`)
- Trigger: Upgrade ht-mcp to new version with incompatible message format
- Workaround: None; requires pre-coordination between ht-mcp and ht-webif versions
- Impact: Medium (protocol evolution will require manual coordination)

## Security Considerations

**HTTP endpoint exposed on loopback with no authentication:**
- Risk: Any local user or process can invoke arbitrary Claude tasks (subject to Max session quota)
- Files: `src/main.rs:40-42`, `src/http.rs` (all handlers)
- Current mitigation: Loopback-only binding (`127.0.0.1:8080`) restricts to same host; assumes host is single-user or trusted
- Recommendations:
  1. Document that this is loopback-only and intended for localhost use only
  2. Add optional bearer token auth (env var `WEBIF_TOKEN`) to handlers if remote access becomes needed
  3. Consider rate-limiting per session to prevent quota exhaustion DoS (not yet implemented)

**Path traversal guard only on GET /turns/{id}:**
- Risk: POST /prompt doesn't validate prompt content; could theoretically include file paths or shell commands if claude follows literal instructions
- Files: `src/http.rs:93-96` (GET handler has whitelist)
- Current mitigation: POST /prompt doesn't directly use user input for filesystem paths (only in prompt-<id>.txt content); claude TUI is sandboxed within an HT session
- Recommendations: None (risk is inherent to passing arbitrary prompts to LLM; add comments clarifying intent)

**No validation of HT_MCP_PATH environment variable:**
- Risk: If `HT_MCP_PATH` is compromised (e.g., via .env file), arbitrary binary runs as WebIF process
- Files: `src/config.rs:12-14`, `src/mcp.rs:57-64` (spawn)
- Current mitigation: File permissions on `.env` are user responsibility; binary is spawned via exact path (no PATH search)
- Recommendations:
  1. Verify HT_MCP_PATH exists and is executable before calling `McpClient::spawn`
  2. Reject relative paths (require absolute path or well-known location like `/usr/local/bin/ht-mcp`)

**Credentials depend on ~/.claude/.credentials.json (OAuth):**
- Risk: If OAuth token expires or is revoked, all turns fail silently with MCP errors (no explicit "auth failed" message)
- Files: External dependency (claude CLI); WebIF has no direct control (`src/main.rs:20`)
- Current mitigation: None in WebIF code; depends on claude CLI refresh logic
- Recommendations:
  1. Document this dependency clearly in README
  2. Add health-check endpoint (GET /health) that tests claude session validity on startup
  3. Capture and re-surface auth errors from MCP (e.g., "auth expired" → clear 401 error in status)

## Performance Bottlenecks

**Single worker thread (no parallelism):**
- Problem: Only 1 turn executes at a time; 64-slot mpsc channel can queue jobs but processes serially
- Files: `src/main.rs:28-30`, `src/turn.rs:82-99` (worker_loop processes one job at a time)
- Cause: Deliberate design (HT-PROTOCOL §12 "1 Worker = 同時1ターン") to avoid contention on single claude session
- Improvement path: Spawn multiple `Worker` instances (each with separate claude TUI session) and route turns by `-w<workerId>` turnId suffix; requires refactoring `AppState` to hold Vec<Worker> and job dispatch logic

**1-second polling interval for status file:**
- Problem: Minimum latency to detect completion is ~1 second (see "Known Bugs" section)
- Files: `src/turn.rs:68`, `src/http.rs:78`
- Cause: Sleep between polling cycles; no inotify/fsnotify
- Improvement path: Implement optional filesystem watch via `notify` crate for sub-100ms detection on Unix; fall back to polling on unsupported platforms

**Unbounded channel buffer (64 slots):**
- Problem: If 65+ jobs queue up, 64th-65th request will block; no backpressure signal to client
- Files: `src/main.rs:29` (`mpsc::channel::<Job>(64)`)
- Cause: Fixed capacity chosen arbitrarily
- Improvement path: Return 503 (Service Unavailable) if channel is full; or increase capacity based on observed queue depth

## Fragile Areas

**Session recovery cascade (shared-fate + recreate + restart):**
- Files: `src/worker.rs:84-122` (ensure_healthy, recreate), `src/http.rs:157-162` (restart)
- Why fragile: Multiple levels of recovery are interleaved:
  1. `ensure_healthy` checks snapshot for "auto mode", recreates session if missing
  2. Timeout retry calls `recreate` again (redundant if ensure_healthy already ran)
  3. POST /restart does `respawn` (kill ht-mcp) → handshake → new session
  - If any step partially fails (e.g., handshake succeeds but create_session hangs), state becomes inconsistent
- Safe modification:
  1. Add state tracking to `Worker` (e.g., `enum SessionHealth { Healthy, NeedsRecreate, NeedsRestart }`)
  2. Make recovery idempotent: `ensure_healthy` should be a no-op if session is already healthy
  3. Add explicit test for cascade failures (e.g., mock MCP that fails on second request)
- Test coverage gaps: No test for recovery when MCP_TIMEOUT fires during `ensure_healthy` or `recreate`

**Prompt file visibility before ht-mcp sends trigger:**
- Files: `src/http.rs:55-56` (prompt written), `src/turn.rs:47-50` (trigger sent), `src/turn.rs:62` (polling for status)
- Why fragile: If claude TUI reads prompt before trigger message arrives, it may execute the wrong turn or see partial prompt
- Safe modification:
  1. Atomic transaction: write prompt → send trigger in single MCP call (requires protocol change)
  2. Or: send trigger first with filename in message, then write file (claude must wait for file to appear)
- Current protocol assumes files are written before trigger, which is what HT-PROTOCOL §8.2 prescribes, but WebIF doesn't enforce ordering

**MCP request/response matching relies on sequential id increment:**
- Files: `src/mcp.rs:133-147` (request/read_response), `src/mcp.rs:134`
- Why fragile: If MCP sends unsolicited notifications or out-of-order responses, `read_response` loop could get stuck waiting for a response that was already sent (though loop skips non-matching ids, so risk is low)
- Safe modification: Add timeout to `read_response` itself (not just wrapped in MCP_TIMEOUT) to detect stuck MCP
- Test coverage gaps: No test for MCP_TIMEOUT during read_response (timeout is at `request` level, but read_response loop has no internal deadline)

## Scaling Limits

**Single host, single filesystem:**
- Current capacity: 1 WebIF process + 1 ht-mcp process + 1 claude TUI, all on same host
- Limit: Cannot scale horizontally (e.g., 10 WebIFs, 10 claude sessions) without shared distributed filesystem
- Scaling path:
  1. Move turns/ to NFS/S3 and add distributed locking to avoid race conditions on status files
  2. Run ht-webif instances on different hosts, each with local ht-mcp; coordinate job distribution
  3. Implement worker pool with `-w<workerId>` (see "Performance Bottlenecks" section)

**OAuth credentials single-host bound:**
- Current capacity: ~/.claude/.credentials.json is tied to host where Max is logged in
- Limit: Cannot run WebIF on machine without Claude Max subscription
- Scaling path: Implement token-refresh server or centralized OAuth proxy (out of scope for WebIF)

## Dependencies at Risk

**ht-mcp binary at uncontrolled path:**
- Risk: If ht-mcp crashes, is uninstalled, or changes interface, WebIF silently fails
- Impact: Every turn hangs with MCP_TIMEOUT (30s)
- Migration plan: 
  1. Add ht-mcp version check on startup (`ht-mcp --version`, parse and log)
  2. Fail fast if ht-mcp is not found (`HT_MCP_PATH` validation in `config.rs`)
  3. Document minimum ht-mcp version in Cargo.toml or README

**dotenvy 0.15 for .env loading:**
- Risk: Low; dotenvy is widely used and stable
- Impact: None observed
- Note: .env file parsing should reject secrets (log line 1 of .env on startup to detect leaks)

**axum 0.8 HTTP framework:**
- Risk: Axum 0.8 is stable; 0.9 may introduce breaking changes
- Impact: Upgrade cost for new versions
- Migration plan: Maintain Cargo.toml with lower bound (0.8) and test upper bound quarterly

## Missing Critical Features

**No health check endpoint:**
- Problem: Cannot verify WebIF + ht-mcp + claude are all healthy without submitting a turn
- Blocks: Automated startup verification, load balancer health probes
- Suggested implementation: `GET /health` returns 200 with `{"status":"healthy","session_id":"..."}` if snapshot contains "auto mode", else 503

**No log-level control:**
- Problem: All stderr output is unfiltered; noisy during normal operation (esp. ht-mcp debug logs)
- Blocks: Clean production deployments, log aggregation
- Suggested implementation: `LOG_LEVEL` env var (RUST_LOG format); filter by module

**No graceful shutdown:**
- Problem: SIGTERM kills WebIF immediately; in-flight turns lose status updates
- Blocks: Zero-downtime deployments
- Suggested implementation: On SIGTERM, stop accepting new jobs, drain job queue with timeout, then exit

**No metrics/instrumentation:**
- Problem: Cannot observe turn latency, failure rate, queue depth without parsing logs
- Blocks: Performance monitoring, alerting
- Suggested implementation: Add Prometheus metrics endpoint (GET /metrics) with counters for turns (total, failed, timeout) and histograms for duration

## Test Coverage Gaps

**No integration test for full turn lifecycle:**
- What's not tested: POST /prompt → waiting for status → GET /turns/{id}; the complete happy path with a scripted MCP response
- Files: `src/http.rs:278-315` only tests GET, not POST; `src/turn.rs` only tests unit functions
- Risk: Critical path (prompt → dispatch → poll → result) could break without detection
- Priority: High (should be a basic smoke test)

**No test for MCP_TIMEOUT recovery:**
- What's not tested: When `request` times out after 30s, does worker correctly transition to recreate? Does status file get written?
- Files: `src/mcp.rs` has timeout at line 140-145, but tests are hermetic (duplex, no real timing)
- Risk: MCP_TIMEOUT → anyhow error → propagates to worker_loop, which writes status; but unclear if timing is correct
- Priority: Medium (affects failure path, less critical than happy path)

**No test for prompt file atomicity / race conditions:**
- What's not tested: Can two turns write simultaneously without corrupting each other? Can GET /turns/{id} race with file write?
- Files: `src/http.rs:55-56`, `src/turn.rs:62`
- Risk: Rare corruption under load
- Priority: Medium (mitigated by atomic rename protocol, but worth validating)

**No test for session recovery idempotence:**
- What's not tested: Can ensure_healthy → recreate be called twice without side effects?
- Files: `src/worker.rs:84-122`
- Risk: Double-recreation could spawn orphaned sessions
- Priority: Low (encapsulated within Worker, unlikely to be called twice, but worth documenting)

**No test for path traversal on prompt input:**
- What's not tested: Can prompt content contain `../` etc. without being sanitized? (Probably fine since it's just file content, but worth confirming)
- Files: `src/http.rs:55` (prompt written verbatim)
- Risk: Very low (claude TUI is sandboxed; can't access files outside HT session)
- Priority: Very low

---

*Concerns audit: 2026-05-26*
