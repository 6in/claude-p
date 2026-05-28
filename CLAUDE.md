<!-- GSD:project-start source:PROJECT.md -->
## Project

**ht-webif**

`curl` 1発で Claude にタスクを送って結果を受け取れる、軽量な HTTP WebIF。`claude -p`（API クレジット課金）を回避し、対話型 Claude Code TUI を `ht-mcp`（headless terminal MCP サーバ）越しに駆動することで **Max サブスクリプション課金のまま** Claude をプログラマブルに呼び出せる。Rust + axum で実装し、リクエストはターン方式で直列処理する。利用者は自分のシェルスクリプト・自動化ループ・Web UI から `POST /prompt` するだけで Claude を扱える。

**Core Value:** **`-p` を避けつつ curl で Claude を実行できる。** これがすべての設計判断の原点。サブスクリプション課金の維持、対話型 TUI の駆動、ファイル経由の入出力、自己回復機構 — どれもこの一点を成立させるために存在する。

### Constraints

- **Tech stack**: Rust（言語の堅牢性・単一バイナリ・パフォーマンス）— このプロジェクトの方針。
- **MCP transport**: stdio MCP（ht-mcp が stdio 専用）— `ht-mcp` を子プロセスで `spawn` し、newline 区切り JSON-RPC で会話。
- **Billing**: 必ず Max サブスクリプション経由 — `claude -p` 不使用、`ANTHROPIC_API_KEY` 不使用、`~/.claude/.credentials.json` の OAuth に依存。
- **Concurrency**: 同一プロセス内 1 worker = 1 claude TUI = 同時 1 ターン（直列）。並列化は worker 増設で対応する設計。
- **Auth context**: ホストの `claude` バイナリが既に Max でログイン済みである必要がある。
- **Single host**: WebIF と ht-mcp と claude は同一ホスト＝同一ファイルシステムを共有する前提。同一ホスト上の多重インスタンス運用は `PORT` と `TURNS_DIR` を変えれば可能（v0.1 段階1で env 化済み）。HT-PROTOCOL §7 はこの前提のもとで成立している。
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

- **Language:** Rust edition 2021, single binary (`ht-webif`).
- **Runtime:** Tokio (`full`), axum 0.8 HTTP server bound to `127.0.0.1:${PORT:-8080}`.
- **Process model:** spawns `ht-mcp` as a child via stdio JSON-RPC; `ht-mcp` in turn spawns `claude` TUI.
- **Key crates:** axum, tokio, serde/serde_json, anyhow, chrono (turnId), dotenvy, tower-http (CORS).
- **Config:** `.env` in `webif/` (cwd-relative). Env vars: `PORT`, `TURNS_DIR`, `HT_MCP_PATH`, `CORS_ORIGINS`. Precedence: env > .env > default.
- **Build/test:** `cargo` + `webif/justfile`. CI: `.github/workflows/ci.yml` (fmt-check → clippy → test, single ubuntu-latest stable job).
- **Platform:** POSIX-like OS (atomic rename for turn files); requires `ht-mcp` and `claude` on `PATH`; loopback bind (use SSH tunnel / reverse proxy for remote).

詳細: [docs/STACK.md](docs/STACK.md)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

- **Comments / log strings / `anyhow!` messages:** Japanese. **Identifiers:** English.
- **Modules:** `src/main.rs` is a thin shim; logic split into `mcp.rs` (transport) → `worker.rs` (session lifecycle) → `turn.rs` (job/turn-files) → `http.rs` (axum router) → `lib.rs` (re-exports + crate doc).
- **Naming:** snake_case fns/vars, PascalCase structs, `Req`/`Resp` DTO suffixes, SCREAMING_SNAKE_CASE consts with explicit type.
- **Error handling:** `?` + `anyhow::Result` internally; handlers return `Result<Json<T>, (StatusCode, String)>` via `ise()` helper for 500s; explicit non-500 status codes at the boundary.
- **Async/locks:** `tokio::sync::Mutex` (held across `.await`), one `Arc<Mutex<Worker>>` shared by `AppState` and `worker_loop`. Wrap MCP calls in `tokio::time::timeout(MCP_TIMEOUT, ...)`.
- **HTTP safety:** any `turn_id`-style identifier that hits the filesystem MUST be whitelisted (current rule: `^[0-9-]+$`).
- **Logging:** `eprintln!` with bracketed source tags (`[restart]`, `[worker]`, `[shared-fate]`). Per-turn success: file-only (read `status-<turnId>.json`). Per-turn failure: log + file.
- **Tooling:** `cargo fmt` + `cargo clippy` before commits. CI enforces `cargo fmt --check`.

詳細: [docs/CONVENTIONS.md](docs/CONVENTIONS.md)
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Data flow: `curl → axum handler → mpsc<Job> → worker_loop → Worker (Arc<Mutex>) → McpClient (stdio JSON-RPC) → ht-mcp → claude TUI → turns/{prompt,result,status}-<turnId>.{txt,json}`.

- **Single worker, serial turns** (HT-PROTOCOL §12): one in-flight turn at a time; concurrency story is "add more workers", not "parallelise inside one worker".
- **Filesystem is the state store:** `turns/<prompt|result|status>-<turnId>.{txt|json}` is the source of truth. mpsc carries job *requests* only — never completion signals.
- **Status file appearance = done** (HT-PROTOCOL §6 sentinel).
- **Shared-fate recovery:** dead claude TUI → recreate session; wedged ht-mcp → full `/restart` rebuilds the child process.
- **TurnId allocation:** orchestrator (WebIF) only — never the TUI or the client (HT-PROTOCOL §3.2). Format: `YYYYMMDD-HHMMSS-mmm` UTC.
- **Timeouts:** `MCP_TIMEOUT = 30s` per MCP call; `TURN_TIMEOUT = 300s` per turn attempt (max 2 attempts); sync `wait:true` handler has its own ~700s deadline.
- **Endpoints:** `POST /prompt` (async default, `wait:true` for sync), `GET /turns/{turn_id}`, `POST /command` (raw TUI keystrokes), `POST /restart` (kill+respawn ht-mcp+claude).
- **Anti-patterns:** sending huge prompts inline to the TUI; tracking turn state in memory; letting clients pick turnIds; unbounded MCP waits; leaking the old session when creating a new one. See linked doc for the "why".

詳細: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ／ ワイヤープロトコル: [HT-PROTOCOL.md](HT-PROTOCOL.md)
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
