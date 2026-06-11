<!-- refreshed: 2026-05-26 -->
# Architecture

**Analysis Date:** 2026-05-26

## System Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                    HTTP Layer (axum router)                      │
│  /prompt, /turns/{id}, /command, /restart handlers (D-11)        │
│                    `webif/src/http.rs`                           │
└────────────┬────────────────────────┬──────────────────────┬─────┘
             │                        │                      │
      enqueue Job            poll status             direct command
             │                        │                      │
             ▼                        ▼                      ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Job Queue & Worker Loop                       │
│     mpsc::Channel<Job> → process_job → MCP client driver        │
│                    `webif/src/turn.rs`                           │
│  serialize /clear, prompt, timeout/retry logic (D-02)            │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼ Arc<Mutex<Worker<M>>>
┌──────────────────────────────────────────────────────────────────┐
│            Worker & Session Management                           │
│       Holds M: Mcp client + session_id + recovery ops            │
│  `webif/src/worker.rs`: ensure_healthy, recreate, restart        │
│                    Generic over trait M: Mcp                     │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼ trait M: Mcp
┌──────────────────────────────────────────────────────────────────┐
│         MCP Transport (JSON-RPC over stdio)                      │
│   McpClient: newline-delimited JSON-RPC request/response         │
│   Trait Mcp: handshake, create_session, send_keys, snapshot      │
│              (impl by McpClient; testable via FakeMcp)           │
│                    `webif/src/mcp.rs`                            │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼ tokio::process::Command (ht-mcp child)
┌──────────────────────────────────────────────────────────────────┐
│  ht-mcp (stdio MCP server, external binary)                      │
│  Spawns claude TUI sessions, manages PTY, exposes ht tools       │
│  External dependency, referenced by HT_MCP_PATH env var          │
└────────────────────────────────────────────────────────────────────┘
             │
             ▼ PTY
┌──────────────────────────────────────────────────────────────────┐
│  Filesystem (turn artefacts)                                     │
│  ./turns/prompt-<id>.txt, result-<id>.txt, status-<id>.json     │
│  (State store; claude writes result→status in order)             │
└──────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| HTTP handlers | Accept POST /prompt, GET /turns/{id}, POST /command, POST /restart; enqueue Job or delegate to Worker | `webif/src/http.rs:44-163` (handlers), `webif/src/http.rs:170-177` (build_router) |
| worker_loop | Drain mpsc::Receiver<Job> in background; call process_job; write status on error | `webif/src/turn.rs:82-99` |
| process_job | Execute one turn: submit_line with trigger, poll status file, timeout→retry logic | `webif/src/turn.rs:40-79` |
| Worker<M> | Hold current MCP client + session_id; ensure_healthy, recreate, restart methods | `webif/src/worker.rs:12-159` |
| McpClient | Manage ht-mcp child process, JSON-RPC request/response, implement trait Mcp | `webif/src/mcp.rs:43-248` |
| trait Mcp | API for session lifecycle and TUI control (handshake, create/close session, send_keys, snapshot) | `webif/src/mcp.rs:19-27` |
| trait Restartable | Super-trait of Mcp; adds respawn for ht-mcp re-initialization | `webif/src/mcp.rs:36-41` |
| AppState<M> | Shared state: Arc<Mutex<Worker<M>>>, turns_dir, job_tx; passed to all handlers via axum State | `webif/src/http.rs:22-26` |
| build_prompt_body | Construct prompt file text with task + output covenant (result→status order guarantee) | `webif/src/turn.rs:22-36` |
| read_turn | Read status/result files from turns_dir, compose JSON response | `webif/src/turn.rs:102-114` |

## Pattern Overview

**Overall:** Async job queue feeding a single serialized worker.

**Key Characteristics:**
- **HTTP is lightweight:** Request handlers enqueue Job and return immediately (or wait synchronously). No business logic in HTTP layer.
- **One worker, one turn at a time:** `Arc<Mutex<Worker<M>>>` ensures serial TUI access. Background worker_loop holds the lock for process_job duration.
- **Filesystem is state store:** Only source of truth is `turns/` directory. Prompt, result, status files; no in-memory job table.
- **Status file is completion sentinel:** When claude writes `status-<id>.json`, the turn is done (HT-PROTOCOL §6).
- **Trait Mcp abstracts transport:** Testable via FakeMcp; production uses McpClient. Worker<M> is fully generic.

## Layers

**HTTP / Request Intake:**
- Purpose: Accept incoming turn requests, generate turn_id, persist prompt file, enqueue Job, return immediately (or sync-wait)
- Location: `webif/src/http.rs:43-86` (prompt_handler), `webif/src/http.rs:88-110` (turn_handler), `webif/src/http.rs:124-144` (command_handler), `webif/src/http.rs:152-163` (restart_handler)
- Contains: Request/response DTO (PromptReq, CommandReq, CommandResp, RestartResp), axum Router
- Depends on: AppState, turn::build_prompt_body, turn::read_turn, Worker methods
- Used by: curl, external HTTP clients

**Job Queue & Turn Processing:**
- Purpose: Dequeue jobs in background, drive each turn end-to-end (send prompt, poll status file, timeout/retry)
- Location: `webif/src/turn.rs:82-99` (worker_loop), `webif/src/turn.rs:40-79` (process_job)
- Contains: Job struct, worker_loop, process_job, build_prompt_body
- Depends on: Worker<M>, TURN_TIMEOUT constant
- Used by: Spawned as background tokio::spawn from main.rs; fed by HTTP handlers via mpsc

**Worker & Session Management:**
- Purpose: Manage claude session lifecycle, health checks, recovery (recreate on session death, restart on MCP wedge)
- Location: `webif/src/worker.rs:12-159`
- Contains: Worker<M> struct, new/boot/spawn_session (McpClient only), ensure_healthy, recreate, restart (Restartable only)
- Depends on: trait Mcp, MCP_TIMEOUT
- Used by: Arc<Mutex<Worker<M>>> shared by HTTP handlers and worker_loop; acquired exclusively via lock()

**MCP Transport & JSON-RPC:**
- Purpose: Newline-delimited JSON-RPC protocol over stdio to ht-mcp; request/response matching, timeout guarding
- Location: `webif/src/mcp.rs:43-248` (McpClient impl), `webif/src/mcp.rs:19-27` (trait Mcp), `webif/src/mcp.rs:36-41` (trait Restartable)
- Contains: McpClient (spawn, request, notify, call_tool), handshake, session tools (create/close), keys/snapshot
- Depends on: tokio::process, ht-mcp binary (external), MCP_TIMEOUT
- Used by: Worker<M>; abstracted via trait Mcp for testability

**Configuration:**
- Purpose: Constants (TURN_TIMEOUT, MCP_TIMEOUT) and env var loading (HT_MCP_PATH)
- Location: `webif/src/config.rs:1-14`
- Contains: const TURN_TIMEOUT, const MCP_TIMEOUT, fn load_ht_mcp_path()
- Depends on: std::env
- Used by: worker.rs, mcp.rs, main.rs

## Data Flow

### Primary Request Path: POST /prompt → Async Execution

1. HTTP handler receives `PromptReq { prompt, fresh, wait }` (`webif/src/http.rs:48-86`)
2. Generate turn_id via `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` (HT-PROTOCOL §3)
3. Call `build_prompt_body(task, result_path, status_path)` to append output covenant (`webif/src/turn.rs:22-36`)
4. Write prompt file to `turns/prompt-<id>.txt` (`webif/src/http.rs:56`)
5. Enqueue Job { turn_id, fresh } to mpsc channel (`webif/src/http.rs:59-66`)
6. If wait=false (default): return `{ "turn_id": id, "status": "accepted" }` immediately (`webif/src/http.rs:85`)
7. If wait=true: poll status file with 1s sleep loop, 700s deadline; when found, read and return full turn JSON (`webif/src/http.rs:68-82`)

### Background Job Processing

1. Background worker_loop task polls mpsc::Receiver (`webif/src/turn.rs:87`)
2. For each Job, lock Arc<Mutex<Worker>> and call process_job (`webif/src/turn.rs:88-89`)
3. process_job:
   - If fresh=true, submit_line("/clear"), sleep 1s (`webif/src/turn.rs:54-56`)
   - Read prompt file, construct trigger message (`webif/src/turn.rs:45-50`)
   - Call worker.submit_line(trigger) — sends text + Enter with 500ms delay between via `send_keys` (`webif/src/turn.rs:58`)
   - Poll status_path with 1s loop, TURN_TIMEOUT (300s) deadline (`webif/src/turn.rs:60-69`)
   - If timeout: attempt 2, then recreate() if needed; after 2 attempts, write `{"status":"timeout"}` to status file (`webif/src/turn.rs:73-78`)
   - On any error in process_job, worker_loop catches it and writes `{"status":"failed", "error": msg}` to status file (`webif/src/turn.rs:89-96`)
4. Claude TUI meanwhile reads prompt, executes, writes result-<id>.txt, then writes status-<id>.json (order enforced by output covenant) (`webif/src/turn.rs:27-30`)

### Polling Path: GET /turns/{id}

1. HTTP handler validates turn_id (digits + hyphens only; reject `..`, `/`, etc.) (`webif/src/http.rs:94-96`)
2. Check if status-<id>.json exists:
   - Yes: call read_turn(), parse status/result files, return `{ "turn_id": id, "status": "done"/"failed"/"timeout"/"unknown", "result": "..." }` (`webif/src/http.rs:99-101`)
   - No, but prompt-<id>.txt exists: return `{ "turn_id": id, "status": "running" }` (sentinel, not yet complete) (`webif/src/http.rs:102-103`)
   - Neither exists: return 404 (`webif/src/http.rs:105-108`)

### Raw Command Path: POST /command

1. HTTP handler locks Worker, calls ensure_healthy() (`webif/src/http.rs:129-130`)
2. Call worker.submit_line(req.text) to send arbitrary text (e.g., `/clear`) (`webif/src/http.rs:132`)
3. Sleep 1.5s for command to settle (`webif/src/http.rs:133`)
4. Call worker.snapshot() to capture TUI state; on error, return best-effort fallback text (`webif/src/http.rs:136-139`)
5. Return { sent, snapshot } (`webif/src/http.rs:140-143`)

### Restart Path: POST /restart

1. HTTP handler locks Worker, calls worker.restart() (requires Restartable trait) (`webif/src/http.rs:156-158`)
2. restart() calls `client.respawn(ht_mcp_path)` → kills old ht-mcp, spawns new, handshakes (`webif/src/worker.rs:137-158`)
3. Create new claude session, poll for "auto mode", update session_id (`webif/src/worker.rs:139-152`)
4. Return { status: "restarted", session_id } (`webif/src/http.rs:159-162`)

**State Management:**
- Turn state: `turns/prompt-<id>.txt` (human-written input), `result-<id>.txt` (claude-written output), `status-<id>.json` (sentinel)
- Worker state: `Arc<Mutex<Worker<M>>>` holding current session_id + MCP client
- Job queue: mpsc::Channel<Job> (64-slot bounded buffer) — in-flight jobs only; no persistence
- No global state (no module-level statics)

## Key Abstractions

**Turn ID (turnId):**
- Purpose: Unique identifier for one complete task execution
- Format: `YYYYMMDD-HHMMSS-mmm` (UTC, millisecond precision, 19 chars, all digits except hyphens)
- Generation: Orchestrator (WebIF) only; worker never generates (`webif/src/http.rs:49`)
- Files: prompt-<id>.txt, result-<id>.txt, status-<id>.json bound by turn_id
- Pattern: HT-PROTOCOL §3.2

**Job:**
- Purpose: Minimal work item enqueued to mpsc channel
- Definition: `pub struct Job { pub turn_id: String, pub fresh: bool }` (`webif/src/turn.rs:16-19`)
- Pattern: Value type, move-only via mpsc, processed exactly once by worker_loop

**McpClient:**
- Purpose: Lowest-level JSON-RPC transport over stdio
- Location: `webif/src/mcp.rs:43-248`
- Pattern: Async request/response matching via `next_id` counter; read_response waits for specific id
- Timeouts: MCP_TIMEOUT (30s) on any single request/notify call
- Owned by: Worker<M> (when M = McpClient)

**trait Mcp:**
- Purpose: Abstract MCP operations so Worker<M> and build_router<M> can work with any M
- Location: `webif/src/mcp.rs:19-27`
- Methods: handshake, create/close_session, send_keys, submit_line, snapshot
- Implemented by: McpClient (production), FakeMcp (testing) (`webif/src/mcp.rs:175-235` for McpClient, `webif/src/mcp.rs:294-336` for FakeMcp)
- Design: Allows Worker<FakeMcp> in tests without spawning ht-mcp child

**trait Restartable:**
- Purpose: Extend Mcp with "restart transport" capability
- Location: `webif/src/mcp.rs:36-41`
- Method: respawn(ht_mcp_path) — kill and re-spawn child process + handshake
- Implemented by: McpClient (real restart), FakeMcp (no-op) (`webif/src/mcp.rs:237-248` for McpClient, `webif/src/mcp.rs:341-348` for FakeMcp)
- Constraint in build_router: `build_router<M: Mcp + Restartable>` ensures M supports restart_handler

**Worker<M>:**
- Purpose: Stateful session manager, generic over trait M: Mcp
- Location: `webif/src/worker.rs:12-159`
- Fields: client: M, session_id: String, ht_mcp_path: String
- Generic impl (all M: Mcp): ensure_healthy, recreate, submit_line, snapshot
- Restartable impl (M: Restartable): restart
- McpClient-only static methods: new, boot, spawn_session
- Shared as: Arc<Mutex<Worker<McpClient>>> in main; can be Arc<Mutex<Worker<FakeMcp>>> in tests

**AppState<M>:**
- Purpose: Axum State container for HTTP handlers
- Location: `webif/src/http.rs:22-26`
- Fields: worker: Arc<Mutex<Worker<M>>>, turns_dir: PathBuf, job_tx: mpsc::Sender<Job>
- Generic: Allows handlers to work with any M: Mcp + Restartable
- Shared with: build_router via State extractor

**Output Covenant (prompt footer):**
- Purpose: Enforce result→status write order in claude TUI
- Pattern: Append to prompt text after task instructions (`webif/src/turn.rs:27-30`)
- Text: Instructs claude to write result-<id>.txt first, then status-<id>.json
- Guarantee: Status file appearance = turn complete (HT-PROTOCOL §6)

## Entry Points

**main():**
- Location: `webif/src/main.rs:11-52`
- Triggers: `cargo run` / `./target/release/ht-webif`
- Responsibilities:
  1. Load .env via dotenvy (line 14)
  2. Load HT_MCP_PATH from env or default to "ht-mcp" (line 15)
  3. Boot Worker::new(ht_mcp_path) — spawn ht-mcp, handshake, create claude session (line 19)
  4. Create turns/ directory (lines 23-25)
  5. Wrap Worker in Arc<Mutex> and spawn worker_loop background task (lines 28-30)
  6. Build AppState and axum router via build_router(state) (lines 33-38)
  7. Bind TCP listener on 127.0.0.1:8080 and serve (lines 40-51)

**worker_loop:**
- Location: `webif/src/turn.rs:82-99`
- Triggers: Spawned once at startup via tokio::spawn (webif/src/main.rs:30)
- Responsibilities: Infinite loop draining Job from mpsc receiver; lock Worker and call process_job for each; write status on error

**build_router:**
- Location: `webif/src/http.rs:170-177`
- Triggers: Called from main.rs:38 to construct axum Router with State
- Responsibilities: Register 4 routes (/prompt, /turns/{id}, /command, /restart) with handlers; bind AppState<M> to each

## Architectural Constraints

- **Serial turn execution:** Only 1 Job processed at a time. `Arc<Mutex<Worker<M>>>` is exclusive; worker_loop holds lock for entire process_job duration. Concurrency model: spawn multiple WebIF instances (each with own worker) for parallel turns, or scale horizontally.
- **MCP wedge guard:** Every MCP request (handshake, send_keys, snapshot, etc.) is wrapped in `tokio::time::timeout(MCP_TIMEOUT, ...)` with MCP_TIMEOUT = 30s (`webif/src/config.rs:9`). Timeout → anyhow error → propagates up, triggers recovery (recreate or restart).
- **Turn timeout:** Single attempt has TURN_TIMEOUT = 300s deadline (`webif/src/config.rs:6`). On timeout, recreate session and retry once. After 2 attempts fail, write `{"status":"timeout"}` to status file and move on.
- **Path traversal guard:** GET /turns/{id} whitelist validation: `c.is_ascii_digit() || c == '-'` only (`webif/src/http.rs:94`). Rejects `..`, `/`, `%2F`, etc. New handlers accepting filesystem paths MUST apply equivalent whitelist.
- **Single file per turn:** Artefacts are prompt-<id>.txt, result-<id>.txt, status-<id>.json. No subdirectories or secondary files. Flat turns/ directory.
- **Status file as sentinel:** Only source of turn completion is existence of status-<id>.json (HT-PROTOCOL §6). No in-memory completion map.
- **Shared ht-mcp process:** Single ht-mcp child per WebIF instance, shared by all turns via session multiplexing (multiple sessions in single ht-mcp process).
- **Filesystem coupling:** WebIF and claude TUI must see same turns/ directory (same machine, same path). No remote filesystem support; single-host only.
- **Stderr passthrough:** ht-mcp child stderr inherited, not captured. Logs interleave with WebIF stderr in terminal (`webif/src/mcp.rs:61`).
- **No global state:** All state owned by AppState or Worker. No static Mutex, no lazy_static, no Once. Testability: inject FakeMcp to build_router.

## Anti-Patterns

### Long Text in Single submit_line

**What happens:** Handler sends multi-paragraph prompt as single `send_keys([text])` + Enter. The Enter keystroke may be lost or buffered oddly by PTY.

**Why it's wrong:** HT-PROTOCOL §8 (implicit) assumes short single-line input. Long text risks silent failure.

**Do this instead:** Keep prompts <= 1 line of display text, or split into multiple submit_line calls with settle delays. See `webif/src/turn.rs:58` and `webif/src/mcp.rs:224-228` (submit_line sends text, waits 500ms, sends Enter separately).

### In-Memory Job Table

**What happens:** Store Job in a HashMap keyed by turn_id, update on completion, serve GET from map.

**Why it's wrong:** If WebIF crashes, in-memory map is lost. Claude still writes status file, but GET won't find completed turn until restart scans files. Inconsistency.

**Do this instead:** Query filesystem only. status-<id>.json is the source of truth. GET /turns/{id} calls read_turn() which reads files. GET after restart still works.

### TUI-Generated turnId

**What happens:** claude TUI generates its own turn_id, writes it to a metadata file, WebIF reads it back.

**Why it's wrong:** Adds unnecessary protocol complexity. Orchestrator (WebIF) is simpler as sole turnId generator. Decouples TUI from WebIF versioning.

**Do this instead:** WebIF generates turnId with chrono, embeds in prompt via output covenant, claude follows instructions (writes result, then status). See `webif/src/http.rs:49`, `webif/src/turn.rs:22-36`.

### Unbounded MCP Waits

**What happens:** send_keys / snapshot calls have no timeout, wait indefinitely if ht-mcp wedges.

**Why it's wrong:** Turns never complete; worker_loop blocks forever; HTTP requests hang.

**Do this instead:** Wrap all MCP operations in tokio::time::timeout(MCP_TIMEOUT, ...). See `webif/src/mcp.rs:140-146` (request wraps read_response in 30s timeout). ht-mcp timeout → anyhow error → process_job catches → tries recreate → if still fails, timeout status written.

## Error Handling

**MCP Request Failure:**
- Occurs in: McpClient::request, read_response, call_tool, handshake, send_keys, snapshot
- Signal: anyhow!(...) bubbles up to Handler → write status file or return HTTP 500
- Recovery path: If in process_job, recreate session + retry; if handshake fails in boot, fail startup; if send_keys fails mid-turn, next poll timeout → recreate + retry

**Turn Timeout (300s deadline):**
- Occurs in: process_job (webif/src/turn.rs:65-69)
- Signal: Status file not written after 300s of polling
- Recovery: Attempt 1 timeout → recreate() → Attempt 2 → still timeout → write `{"status":"timeout"}` to status file (`webif/src/turn.rs:73-78`)
- GET response: status:"timeout", result:"" (best effort)

**Session Death (shared-fate):**
- Occurs in: Worker::ensure_healthy (webif/src/worker.rs:84-94)
- Signal: worker.snapshot() fails or doesn't contain "auto mode"
- Recovery: Call recreate() → create new session, poll for ready, log recovery event

**ht-mcp Wedge:**
- Occurs in: Any MCP request hits 30s timeout
- Signal: tokio::time::timeout error
- Recovery: If in /command or /restart, fail immediately (return 500); if in process_job, timeout → recreate → retry; if in boot, fail startup

**Validation Error (GET /turns/{id}):**
- Occurs in: Path parameter validation (webif/src/http.rs:94-96)
- Signal: turn_id contains non-digit/non-hyphen chars
- Response: 400 Bad Request with "不正な turn_id"

**Turn Not Found (GET /turns/{id}):**
- Occurs in: Neither prompt-<id>.txt nor status-<id>.json exist
- Signal: File not found
- Response: 404 Not Found with "turn {id} は存在しません"

**Job Queue Closed:**
- Occurs in: POST /prompt when mpsc Sender::send fails
- Signal: worker_loop exited (mpsc Receiver dropped)
- Response: 500 Internal Server Error with "ジョブキューが閉じています"
- Prevention: worker_loop runs in background for lifetime of main process; Receiver held by main (never dropped)

**Snapshot Failure in /command:**
- Occurs in: worker.snapshot() fails after submit_line
- Signal: anyhow! error
- Recovery: Best-effort — return `{ "sent": req.text, "snapshot": "(snapshot 取得失敗: <error>)" }` (webif/src/http.rs:136-139)

## Cross-Cutting Concerns

**Logging:**
- Tool: println!() / eprintln!() (no structured logging framework)
- Startup: Banners on stdout (webif/src/main.rs:42-49)
- Recovery events: [restart], [shared-fate], [worker] tags in eprintln! (webif/src/worker.rs:90, 118, 154; webif/src/turn.rs:72, 90)
- Turn success: Not logged (rely on status-<id>.json and GET)
- Per-turn failure/timeout: Logged with turn_id and attempt number (webif/src/turn.rs:70-73, 90)
- ht-mcp stderr: Inherited, flows to parent terminal naturally (webif/src/mcp.rs:61)

**Validation:**
- HTTP request bodies: Deserialized by serde; invalid JSON → axum 400
- Path parameters (turn_id): Whitelist `[0-9-]+` to prevent traversal (webif/src/http.rs:94)
- Prompt text: No length limit enforced by WebIF (claude TUI and prompt file format are limits)
- Fresh flag: bool, default false (serde #[serde(default)])
- Wait flag: bool, default false (serde #[serde(default)])

**Authentication:**
- Strategy: None in HTTP layer. WebIF trusts localhost (127.0.0.1:8080 only). Reverse proxy (nginx, etc.) responsible for auth if exposed remotely.
- claude TUI auth: Inherited from `claude` binary (Max subscription via OAuth in ~/.claude/.credentials.json); WebIF doesn't manage credentials

**Concurrency & Locking:**
- Worker lock: tokio::sync::Mutex (not std::sync::Mutex, because held across .await) (webif/src/main.rs:28)
- Lock acquisition pattern: HTTP handler or worker_loop acquires, does one operation, drops (minimal hold time)
- Lock scope: Whole handler body or process_job (acceptable; worker is intentionally serial)
- Channel: mpsc::Sender broadcast to worker_loop; Receiver polled in loop (webif/src/turn.rs:87)

---

*Architecture analysis: 2026-05-26*
