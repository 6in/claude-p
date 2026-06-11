# External Integrations

**Analysis Date:** 2026-05-26

## Child Processes & External Binaries

### ht-mcp (MCP Server — stdio transport)

**What it is:**
External binary (`ht-mcp`) spawned as a child process by WebIF. Serves as an MCP (Model Context Protocol) server over stdio, exposing headless terminal (HT) session management tools.

**How it's invoked:**
- Spawned at `webif/src/mcp.rs:58` via `tokio::process::Command::new(program)`
- Program path from `HT_MCP_PATH` environment variable (default: `"ht-mcp"` on PATH)
- stdin/stdout piped for newline-delimited JSON-RPC communication
- stderr inherited (logs interleave with WebIF's stderr)
- `kill_on_drop(true)` ensures process is terminated when WebIF exits or restarts

**Protocol:**
- Newline-delimited JSON-RPC 2.0 (per MCP spec, protocol version `2024-11-05`)
- Handshake: `initialize` request with capabilities and client info (`webif/src/mcp.rs:177-189`)
- Notification after handshake: `notifications/initialized`

**MCP Tools Used:**

| Tool | Purpose | Parameters | Implementation |
|------|---------|------------|-----------------|
| `ht_create_session` | Start a headless terminal session with `claude` CLI | `{ "command": ["claude"] }` | `webif/src/mcp.rs:192-205` — calls `tools/call` RPC, parses output for session ID |
| `ht_send_keys` | Send keystrokes to terminal | `{ "sessionId": <id>, "keys": [<key1>, <key2>, ...] }` | `webif/src/mcp.rs:213-220` — wraps `tools/call`, used by `submit_line` (500ms delay between text and Enter) |
| `ht_take_snapshot` | Capture terminal output/state | `{ "sessionId": <id> }` | `webif/src/mcp.rs:231-234` — extracts text snapshot, used to verify `"auto mode"` readiness |
| `ht_close_session` | Terminate a terminal session | `{ "sessionId": <id> }` | `webif/src/mcp.rs:207-211` — cleanup during session recreation |

**Resilience:**
- **Timeout guard:** All MCP calls wrapped in `tokio::time::timeout(MCP_TIMEOUT, ...)` where `MCP_TIMEOUT = 30s` (`webif/src/config.rs:9`)
- **Restart mechanism:** If ht-mcp crashes or wedges, `POST /restart` handler triggers full respawn: kill existing process → spawn new → re-handshake → recreate claude session (`webif/src/http.rs:152+`)
- **Transparent recovery:** Worker.ensure_healthy() checks if claude TUI is still responsive; if not, session is recreated without restart

### claude CLI (Interactive TUI)

**What it is:**
The `claude` command-line TUI (Text User Interface) that runs interactively inside the HT session spawned by ht-mcp. Provides Claude AI code assistance in a REPL-like environment.

**How it's invoked:**
- Spawned by `ht_create_session` tool call: `{ "command": ["claude"] }` at `webif/src/mcp.rs:194`
- Runs inside an isolated headless terminal session (not on WebIF's local terminal)
- Must be on PATH and already logged into a Max subscription account

**Billing & Auth:**
- **Max Subscription (OAuth)** — WebIF uses claude's Max account via `~/.claude/.credentials.json` OAuth credentials, not `ANTHROPIC_API_KEY`
- This is the core design constraint: avoids `-p` (pay-per-use API) while enabling programmatic automation
- Pre-requisite: `claude -version` and `claude login` must work on the host running WebIF

**Turn Execution Model:**
- Claude reads `prompt-<turnId>.txt` file written by WebIF
- Executes the task (may use `/read`, `/write`, code generation, etc.)
- Writes results to `result-<turnId>.txt` and `status-<turnId>.json`
- "auto mode" is enabled/checked via snapshots to ensure interactive readiness

**Session Lifecycle:**
- 1 session per Worker (1 instance of WebIF = 1 long-lived claude session)
- Session survives across multiple turns (turns are sequential, not one-per-session)
- `/clear` command resets context when `fresh: true` is set on a prompt
- Session is recreated if it crashes or becomes unresponsive

## Data Storage

### File System (Shared Local Storage)

**Turns Directory:**
- Location: `./turns/` relative to WebIF working directory (`webif/src/main.rs:23`)
- Created at startup if missing: `tokio::fs::create_dir_all(&turns_dir).await`
- Contains all turn state and results

**Per-Turn Files (HT-PROTOCOL v1.1):**

| File | Writer | Format | Purpose |
|------|--------|--------|---------|
| `prompt-<turnId>.txt` | WebIF | Plain text | Task instruction sent to claude. Written immediately after turn is accepted. |
| `result-<turnId>.txt` | claude TUI | Plain text | Output/result from executed task. Created only on successful completion (status="done"). |
| `status-<turnId>.json` | claude TUI | JSON (1 line) | Completion metadata: status (`done`/`failed`/`timeout`), error message (if failed), summary. **Appearance of this file signals turn completion.** |

**File Path Construction:**
- `prompt_path = turns_dir.join(format!("prompt-{turn_id}.txt"))` (`webif/src/http.rs:50`)
- `result_path = turns_dir.join(format!("result-{turn_id}.txt"))` (`webif/src/http.rs:51`)
- `status_path = turns_dir.join(format!("status-{turn_id}.json"))` (`webif/src/http.rs:52`)

**Atomic Write Protocol:**
- `result-<id>.txt.tmp` → rename to `result-<id>.txt` (atomic)
- `status-<id>.json.tmp` → rename to `status-<id>.json` (atomic)
- Ensures WebIF reader never sees partial files
- Requires POSIX-like OS with atomic rename semantics

**Turnover Polling:**
- WebIF polls for `status-<turnId>.json` existence every 1 second (up to TURN_TIMEOUT = 300s per attempt, max 2 attempts)
- Absence of status file → turn "running"
- Presence of status file → turn complete (read JSON for result/error)

**No Database:**
- Zero external database services — all persistence is filesystem-based
- Turn state is not cached in memory; each GET /turns/{id} reads fresh from disk
- Job queue (`mpsc::channel`) is in-memory only; holds pending turn IDs, not results

## No External APIs or Web Services

**What's NOT integrated:**
- Stripe, payment processors
- AWS, GCP, Azure cloud services
- External databases (PostgreSQL, MongoDB, etc.)
- External message queues (RabbitMQ, Kafka)
- Third-party LLM APIs (OpenAI, Anthropic API directly)
- Monitoring/logging services (Datadog, Sentry)
- Authentication services (Auth0, OAuth provider — uses Max subscription's built-in OAuth)

**API Calls:**
- All MCP calls are to the local ht-mcp process (no remote APIs)
- All file operations are to local `turns/` directory (no cloud storage)
- All HTTP endpoints are HTTP (not HTTPS) on loopback (127.0.0.1:8080)

## No Environment Secrets Required

**Secrets NOT used:**
- `ANTHROPIC_API_KEY` — Explicitly NOT used (design constraint)
- Cloud credentials (AWS_ACCESS_KEY_ID, AZURE_*, GCP_*)
- OAuth tokens (stored only in claude's `~/.claude/.credentials.json`, not managed by WebIF)
- API keys for external services

**What IS configured:**
- `HT_MCP_PATH` — Optional; path to ht-mcp binary (falls back to PATH search)

## Webhooks & Callbacks

**Incoming:**
- None. WebIF is HTTP server only (receives requests). No webhooks from external systems.

**Outgoing:**
- None. WebIF does not call any external APIs or webhooks.

**Internal Channels:**
- Job queue: `tokio::sync::mpsc::channel::<Job>(64)` (`webif/src/main.rs:29`)
  - HTTP handlers send Job structs to background worker_loop via `state.job_tx.send(job)`
  - Worker loop consumes jobs in order, processes serially
  - No callback mechanism; results are polled from filesystem

## Deployment & Distribution

**No External Dependencies for Deployment:**
- Single binary (after `cargo build --release`)
- No Docker containers, no container registry
- No build artifacts beyond the binary itself
- Cross-compilation via `just dist-*` (uses `cross` + Docker, but only for **build**, not runtime)

**Output Artifacts:**
- `webif/target/debug/ht-webif` (dev builds)
- `webif/target/release/ht-webif` (release builds)
- `webif/dist/ht-webif-linux-amd64`, `ht-webif-linux-arm64`, `ht-webif-windows-amd64.exe` (cross-compiled via `just dist-all`, `cross` + Docker)

**Runtime Requirements:**
- `ht-mcp` binary on PATH or via `HT_MCP_PATH`
- `claude` CLI on PATH, logged into Max subscription
- `~/.claude/.credentials.json` OAuth credentials present and valid
- `.env` file in webif/ with `HT_MCP_PATH` (optional, defaults to PATH)
- POSIX OS (Linux, macOS) or Windows 10+ with WSL

## Session & State Management

**MCP Session Lifecycle:**
- 1 MCP handshake per WebIF startup (`webif/src/mcp.rs:177-189`)
- 1 claude TUI session spawned via `ht_create_session` at startup
- Session ID stored in `Worker.session_id` (`webif/src/worker.rs:14`)
- Session persists for the lifetime of WebIF process

**Claude Session Health Checks:**
- `ensure_healthy()` calls `snapshot()` and checks for `"auto mode"` string (`webif/src/worker.rs:84-94`)
- If unhealthy, session is recreated without restarting ht-mcp
- If ht-mcp itself crashes, `/restart` endpoint respawns the entire ht-mcp process

**Turn Processing Model:**
- Serial execution: 1 turn at a time (enforces HT-PROTOCOL §12)
- `Arc<Mutex<Worker<M>>>` ensures exclusive access to the single Worker instance
- HTTP handlers (`/prompt`, `/command`, `/restart`) and background `worker_loop` both contend for the same lock
- Lock is dropped as soon as operation completes (no long-held locks across awaits)

---

*Integration audit: 2026-05-26*
