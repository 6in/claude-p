# Codebase Structure

**Analysis Date:** 2026-05-26

## Directory Layout

```
/home/parallels/workspaces/ht-mcp-sample/
├── webif/                          # Rust crate root (ht-webif package)
│   ├── src/
│   │   ├── lib.rs                  # Module index; documents overall architecture
│   │   ├── main.rs                 # ~52 lines: wiring shim (startup, listener, router)
│   │   ├── http.rs                 # HTTP handlers, AppState, build_router
│   │   ├── turn.rs                 # Job, worker_loop, process_job, build_prompt_body
│   │   ├── worker.rs               # Worker<M> session lifecycle (new, boot, ensure_healthy, recreate, restart)
│   │   ├── mcp.rs                  # McpClient (JSON-RPC), traits Mcp & Restartable, FakeMcp
│   │   └── config.rs               # Constants (TURN_TIMEOUT, MCP_TIMEOUT), env var loading
│   ├── Cargo.toml                  # Package manifest, dependencies, lib/bin targets
│   ├── Cargo.lock                  # Committed lockfile (~70 transitive crates)
│   ├── CLAUDE.md                   # Pre-refactor design doc (reference only)
│   ├── HT-PROTOCOL.md              # ht-webif ↔ claude TUI protocol spec (v1.1)
│   ├── README.md                   # User-facing quickstart
│   ├── justfile                    # Build + dev + cross-release recipes (cargo, cross, dist-*)
│   ├── .env                        # Runtime configuration (not in git)
│   ├── .env.example                # Template for .env
│   └── .gitignore                  # Ignores target/, .env, turns/
│
├── turns/                          # Runtime turn artefacts directory (created at startup)
│   ├── prompt-<id>.txt             # Task input (WebIF writes; one per turn)
│   ├── result-<id>.txt             # Task output (claude writes)
│   └── status-<id>.json            # Completion sentinel (claude writes last)
│
└── .planning/
    └── codebase/                   # Architecture documentation (this directory)
        ├── ARCHITECTURE.md         # System design, layers, data flow, constraints
        └── STRUCTURE.md            # This file — directory layout and file roles
```

## Directory Purposes

**webif/:**
- Purpose: Rust crate root containing HTTP WebIF implementation
- Contains: Source code (src/), Cargo manifest, build artifacts (target/)
- Key files: src/main.rs (startup shim), src/lib.rs (module index), src/http.rs (handlers)

**webif/src/:**
- Purpose: Rust source code, split into functional modules
- Contains: lib.rs (public module index), main.rs (binary entry), 5 functional modules
- Pattern: Each module is a `.rs` file exporting public types and functions; no nested mod directories

**turns/:**
- Purpose: Runtime artefact store for turn lifecycle (created by WebIF at startup if missing)
- Contains: Three-file tuples per turn: prompt-<id>.txt, result-<id>.txt, status-<id>.json
- Generated: Yes (WebIF creates turns/ on first run)
- Committed: No (ignored by .gitignore, not tracked)
- Lifecycle: Files persist after turn completion; manual cleanup or external housekeeping script required

**.planning/codebase/:**
- Purpose: Generated architecture reference for downstream GSD commands (gsd-plan-phase, gsd-execute-phase)
- Contains: ARCHITECTURE.md and STRUCTURE.md (this file)
- Generated: Yes (written by gsd-map-codebase agent)
- Committed: Yes (part of project docs)

## Key File Locations

**Entry Points:**
- `webif/src/main.rs`: Program startup (tokio runtime, .env loading, Worker::new, listener bind, axum::serve)
- Triggers: `cargo run` or `./target/release/ht-webif`

**Configuration:**
- `webif/.env`: Runtime env vars (not in git; user creates from .env.example) — contains HT_MCP_PATH
- `webif/.env.example`: Template, checked in; shows expected variables
- `webif/Cargo.toml`: Dependency manifest, build config, lib/bin target routing

**Core Logic:**
- `webif/src/http.rs` (370 lines): 4 handlers (prompt, turn, command, restart), AppState, build_router, request/response DTOs
- `webif/src/turn.rs` (209 lines): worker_loop, process_job, build_prompt_body, read_turn, Job struct; includes unit tests
- `webif/src/worker.rs` (160 lines): Worker<M> generic struct, boot/spawn_session/ensure_healthy/recreate/restart methods
- `webif/src/mcp.rs` (500+ lines): McpClient JSON-RPC transport, trait Mcp, trait Restartable, FakeMcp test double; includes unit tests

**Traits & Abstractions:**
- `webif/src/mcp.rs:19-27`: trait Mcp (6 async methods: handshake, create/close session, send_keys, submit_line, snapshot)
- `webif/src/mcp.rs:36-41`: trait Restartable (1 method: respawn) — super-trait of Mcp
- `webif/src/http.rs:22-26`: AppState<M> struct — holds Worker, turns_dir, job_tx; generic over M: Mcp

**Testing:**
- `webif/src/http.rs:179-316`: Integration tests (co-located, #[cfg(test)] mod tests) — tests path traversal defense, status file reading
- `webif/src/turn.rs:117-208`: Unit tests (co-located) — tests turn_id formatting, read_turn resilience, prompt_body composition
- `webif/src/mcp.rs:251-500+`: Unit tests (co-located) — tests JSON-RPC request envelope, FakeMcp, duplex-based McpClient
- Test helpers: tempdir (tempfile crate), FakeMcp scripted response queues, duplex streams for in-memory MCP simulation

**Protocol & Specification:**
- `webif/HT-PROTOCOL.md`: Formal spec of turn file format, turn_id generation, output covenant, session lifecycle
- `webif/CLAUDE.md`: Pre-refactor design doc (reference for constraints, antipatterns, conventions)
- `webif/README.md`: User-facing quickstart, curl examples, deployment notes

## Naming Conventions

**Files:**
- Rust modules: `snake_case.rs` (lib.rs, main.rs, http.rs, turn.rs, worker.rs, mcp.rs, config.rs)
- Cargo manifest: `Cargo.toml`, `Cargo.lock`
- Turn artefacts: `{prompt|result|status}-<turnId>.{txt|json}`
- Spec docs: `UPPER-KEBAB-CASE.md` (ARCHITECTURE.md, STRUCTURE.md, HT-PROTOCOL.md, CLAUDE.md, README.md)
- Config files: `.env`, `.env.example`, `.gitignore`, `justfile`

**Directories:**
- Crate root: `webif/` (lowercase, matches Cargo.toml package name `ht-webif`)
- Source: `src/` (Rust convention)
- Build: `target/` (cargo default, ignored)
- Turn artefacts: `turns/` (lowercase, runtime, ignored in git)
- Planning: `.planning/` (dot-prefixed, ignored by default, but explicitly tracked in .gitignore negation)

**Rust Identifiers:**
- Modules: `snake_case` (mcp, worker, http, turn, config)
- Structs: `PascalCase` (McpClient, Worker, Job, AppState, PromptReq, CommandReq, etc.)
- Functions: `snake_case` (build_prompt_body, process_job, worker_loop, read_turn, ensure_healthy, recreate, restart)
- Constants: `SCREAMING_SNAKE_CASE` (TURN_TIMEOUT, MCP_TIMEOUT)
- Traits: `PascalCase` (Mcp, Restartable)
- Generics: Single letter or descriptive (M for MCP client trait, E for error type)

**HTTP Routes:**
- Single-segment, lowercase nouns + optional path params: `/prompt`, `/turns/{turn_id}`, `/command`, `/restart`
- Path parameters: `snake_case` inside braces: `{turn_id}`

## Where to Add New Code

**New HTTP Endpoint (e.g., GET /stats):**
- Implementation: `webif/src/http.rs` — add handler function `async fn stats_handler<M: Mcp + ...>()` and route in `build_router()` (line 171-176)
- Request DTO: If needed, define struct in http.rs with `#[derive(Deserialize)]`
- Response DTO: Define response type, derive Serialize, return `Result<Json<T>, (StatusCode, String)>`
- Tests: Add `#[tokio::test]` in http.rs test module (lines 179-316) using `build_test_state()` helper

**New Turn Processing Logic (e.g., post-process result):**
- Implementation: `webif/src/turn.rs` — modify `process_job()` (lines 40-79) or add new helper function
- Call site: Either in process_job loop, or as separate step in worker_loop
- Tests: Add unit test in turn.rs test module (lines 117-208) using tempdir for filesystem isolation

**New Worker Method (e.g., get session info):**
- Implementation: `webif/src/worker.rs` — add method to `impl<M: Mcp + Send> Worker<M>` block (lines 57-123) or specific impl like `impl<M: Mcp + Restartable>` (lines 134-159)
- If only McpClient should have it: Add to `impl Worker<McpClient>` (lines 19-54)
- Tests: Either inline via `#[cfg(test)]` test methods or in http.rs integration tests if testing via HTTP handler

**New MCP Tool (e.g., call a new ht tool):**
- Implementation: `webif/src/mcp.rs` — add method to `impl McpClient` (lines 55-173) or trait Mcp (lines 19-27 if public API)
- Pattern: Use `self.call_tool(name, json!{...})` or `self.request(method, params)` for direct JSON-RPC
- Tests: Add unit test in mcp.rs test module (lines 251-500+) using duplex streams and FakeMcp scripted replies

**New Configuration Constant:**
- Location: `webif/src/config.rs` — add `pub const NAME: Type = value;`
- Usage: Import in other modules via `use crate::config::NAME;`
- Tests: Add unit test in config.rs test module if validation needed

**Shared Utilities (if needed):**
- New module: Create `webif/src/util.rs` (or similar) with `pub fn helper() {}`
- Register: Add `pub mod util;` to `webif/src/lib.rs` (line 19-23)
- Use: `use crate::util::helper;` in other modules

## Special Directories

**webif/target/:**
- Purpose: Cargo build output (debug/ and release/ subdirs)
- Generated: Yes (cargo build)
- Committed: No (.gitignore)
- Cleanup: `cargo clean` removes entire target/

**turns/:**
- Purpose: Turn artefacts at runtime (prompt, result, status files)
- Generated: Yes (WebIF creates at startup if missing)
- Committed: No (.gitignore adds `/turns/`)
- Cleanup: Manual deletion or external script; no automatic housekeeping in WebIF

**.git/:**
- Purpose: Git repository metadata
- Generated: Yes (git init)
- Committed: N/A (special)

**webif/.git/:**
- Purpose: Submodule / standalone repo (confirm with `git remote -v`)
- Status: Check actual repo structure at runtime

---

*Structure analysis: 2026-05-26*
