# Technology Stack

**Analysis Date:** 2026-05-26

## Languages

**Primary:**
- Rust (edition 2021) — All application code in `webif/src/` (`main.rs`, `lib.rs`, `http.rs`, `mcp.rs`, `worker.rs`, `turn.rs`, `config.rs`). Single binary crate `ht-webif` declared in `webif/Cargo.toml`.

**Documentation:**
- Markdown — `README.md`, `HT-PROTOCOL.md`, `CLAUDE.md` (specification and developer guides)
- JSON — Wire protocol (MCP JSON-RPC) and turn metadata files (`status-<turnId>.json`)

## Runtime

**Environment:**
- Tokio 1.x (async runtime) — Multi-threaded executor with `#[tokio::main]` at `webif/src/main.rs:11`. Configured with `features = ["full"]` in `webif/Cargo.toml:14` for comprehensive tokio support (process spawning, file I/O, channels, timers, networking).

**Package Manager:**
- Cargo (bundled with Rust toolchain) — Standard build and dependency management
- Lockfile: `webif/Cargo.lock` present and committed (version 4 format, ~70 transitive crates from 8 direct dependencies)

## Frameworks

**Core HTTP Framework:**
- `axum` 0.8.9 — HTTP routing and handlers. Router built in `webif/src/http.rs:build_router()`. Routes: `POST /prompt`, `GET /turns/{turn_id}`, `POST /command`, `POST /restart` (see `webif/src/http.rs`).

**MCP Client Framework:**
- `async-trait` 0.1.89 — Trait definitions for `Mcp` and `Restartable` traits (newline-delimited JSON-RPC client over stdio). Defined in `webif/src/mcp.rs:14-41`.

**Async Runtime Integration:**
- `tokio` 1.x — Process spawning (`tokio::process::Command` in `webif/src/mcp.rs:58`), file I/O (`tokio::fs` in `webif/src/turn.rs:110`), channel-based job queuing (`tokio::sync::mpsc` in `webif/src/main.rs:29`), `Mutex` for shared state (`tokio::sync::Mutex`).

## Key Dependencies

**Data Serialization:**
- `serde` 1.0.x (feature: `derive`) — Struct serialization for request/response DTOs (`PromptReq`, `CommandReq`, `CommandResp`, `RestartResp` in `webif/src/http.rs:32-150`)
- `serde_json` 1.0.x — JSON parsing and generation for MCP frames and turn metadata

**Error Handling:**
- `anyhow` 1.0.102 — Error type for fallible operations. Used for context-rich error propagation with `.context()` and `.with_context()` in `webif/src/mcp.rs`, `webif/src/worker.rs`, `webif/src/turn.rs`

**Time & Date:**
- `chrono` 0.4.x — Turn ID generation with UTC timestamp formatting `%Y%m%d-%H%M%S-%3f` (millisecond precision) at `webif/src/http.rs:49`

**Configuration:**
- `dotenvy` 0.15.x — Environment variable loading from `.env` file at startup (`webif/src/main.rs:14`). Supports precedence: real env vars > `.env` file > defaults

**HTTP Plumbing (Transitive):**
- `hyper` 1.9, `tower` 0.5, `http` 1.4 — HTTP transport layer pulled in by `axum`
- `tower-layer`, `tower-service` — Tower middleware framework

**I/O & Async Utilities (Transitive):**
- `mio` 1.2, `socket2` 0.6 — Async I/O primitives under tokio
- `futures-util` — Future composition utilities

**Parsing & Encoding (Transitive):**
- `memchr`, `itoa`, `percent-encoding`, `form_urlencoded` — String/data processing utilities pulled in by axum

**Test Utilities (dev-dependencies):**
- `tower` 0.5 (feature: `util`) — `ServiceExt::oneshot` for testing HTTP handlers in `webif/tests/` (D-08: version lock required)
- `tempfile` 3.x — Temporary directory management for test `turns/` directories (D-25: version pin "3" used in `webif/src/turn.rs:tests`, `webif/src/http.rs:tests`)

## Configuration

**Environment Loading:**
- Loaded by `dotenvy::dotenv()` at `webif/src/main.rs:14`
- `.env` file location: `webif/.env` (must be present; `.env.example` at `webif/.env.example` provided as template)
- Precedence: real `env` > `.env` > default value

**Key Environment Variables:**
- `HT_MCP_PATH` — Path to `ht-mcp` binary. Defaults to `"ht-mcp"` (PATH search) if not set. Loaded via `webif/src/config.rs:load_ht_mcp_path()`.

**Build Configuration:**
- `webif/Cargo.toml` — Package metadata (name: `ht-webif`, version: `0.1.0`, edition: `2021`)
- `webif/Cargo.lock` — Committed lockfile ensuring reproducible builds
- No `tsconfig.json`, `.rustfmt.toml`, or `clippy.toml` — Default rustfmt and clippy settings applied

**Development Tools:**
- `webif/justfile` — Recipes for dev workflow (`build`, `run`, `test`, `fmt`, `clippy`, `clean`) and cross-release (`dist-linux-amd64`, `dist-linux-arm64`, `dist-windows-amd64`, `dist-all`, `dist-check-tools`, `dist-clean`) using direct `cargo` / `cross` invocation

## Platform Requirements

**Development:**
- Rust toolchain (stable, edition 2021+) via `rustup`
- Cargo (bundled with Rust)
- POSIX-like OS for atomic file rename semantics (`.tmp` → final name, per HT-PROTOCOL v1.1 §6)
- Optional: `cross` + Docker for cross-compilation (`just dist-*` recipes)

**Production/Runtime:**
- `ht-mcp` binary — External child process spawned via `tokio::process::Command` at `webif/src/mcp.rs:58`. Location configured via `HT_MCP_PATH` env var or PATH search.
- `claude` CLI — Spawned by `ht-mcp` via `ht_create_session` tool (see INTEGRATIONS.md). Must be installed on PATH and logged into Max subscription account (`~/.claude/.credentials.json` OAuth credentials).
- Native binary runs on `127.0.0.1:8080` (hardcoded loopback). Designed as single-threaded HTTP server with background worker loop (no external dependencies for networking beyond tokio/hyper/axum).

**No External Services Required:**
- No cloud providers (AWS, GCP, Azure)
- No external databases (all state stored in `turns/` directory via files)
- No API keys (uses Max subscription OAuth via `claude` CLI, never `ANTHROPIC_API_KEY`)
- No containerization (Docker/Kubernetes) — native binary deployment

---

*Stack analysis: 2026-05-26*
