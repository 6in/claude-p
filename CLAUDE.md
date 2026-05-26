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
- **Single host**: 現状は WebIF と ht-mcp と claude が同一ホスト＝同一ファイルシステム。HT-PROTOCOL §7 はこの前提のもとで成立している。
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Rust (edition 2021) — All application code lives in `src/main.rs`. The crate is declared in `Cargo.toml` (`name = "ht-webif"`, `version = "0.1.0"`).
- Markdown — Specification document `HT-PROTOCOL.md` and `README.md`. No build pipeline; documentation only.
- JSON — Used for MCP wire protocol and per-turn `status-<turnId>.json` files (see `src/main.rs:104`, `src/main.rs:316`).
## Runtime
- Native binary built by `cargo build` / `cargo run`. Asynchronous runtime: Tokio (`#[tokio::main]` at `src/main.rs:521`) configured with the `full` feature set in `Cargo.toml:7`.
- Listens on `127.0.0.1:8080` (hard-coded at `src/main.rs:551`).
- Cargo (bundled with the Rust toolchain). No explicit toolchain pin (`rust-toolchain.toml` / `.rust-version` not present).
- Lockfile: present at `Cargo.lock` (8 direct deps resolve to ~70 transitive crates).
## Frameworks
- `axum` 0.8 — HTTP routing layer. Routes registered at `src/main.rs:544-549` (`/prompt`, `/turns/{turn_id}`, `/command`, `/restart`).
- `tokio` 1 (feature `full`) — Async runtime for HTTP, child-process I/O, channels (`tokio::sync::mpsc` at `src/main.rs:539`), and `Mutex` (`src/main.rs:538`).
- `hyper` / `tower` — Pulled in transitively by `axum` (see `Cargo.lock:33-83`).
- None. No `tests/`, `benches/`, no `#[cfg(test)]` blocks in `src/main.rs`, no `[dev-dependencies]` in `Cargo.toml`.
- `cargo` only. No `Makefile`, no `justfile`, no CI configuration files (`.github/`, `.gitlab-ci.yml`, etc.) present.
## Key Dependencies
- `tokio` 1 (features: `full`) — Async runtime, process spawning (`tokio::process::Command` at `src/main.rs:56`), file I/O (`tokio::fs` at `src/main.rs:387`), timers, channels.
- `axum` 0.8 — HTTP server framework; `Router`, `State`, `Json`, `Path` extractors used throughout the HTTP-layer section (`src/main.rs:371-519`).
- `serde` 1 (feature: `derive`) — JSON (de)serialization for request/response structs (`PromptReq`, `CommandReq`, `CommandResp`, `RestartResp` at `src/main.rs:398-507`).
- `serde_json` 1 — Dynamic JSON value handling for MCP JSON-RPC frames and for reading `status-<turnId>.json` (`src/main.rs:32`, `src/main.rs:388`).
- `anyhow` 1 — Error type used for internal `Result<T>` returns and to format MCP failure messages (`src/main.rs:24`).
- `chrono` 0.4 — Turn-ID generation via UTC timestamp formatting `%Y%m%d-%H%M%S-%3f` (`src/main.rs:415`).
- `dotenvy` 0.15 — Loads `.env` from the working directory at startup (`src/main.rs:524`).
- `hyper` 1.9, `tower` 0.5, `http` 1.4 — HTTP plumbing under `axum`.
- `mio` 1.2, `socket2` 0.6 — Async I/O primitives under `tokio`.
- `tracing` 0.1 — Pulled in by `axum` but not used directly; logging is `println!` / `eprintln!`.
## Configuration
- Loaded by `dotenvy::dotenv()` at `src/main.rs:524`. Real process environment takes precedence over `.env` (standard `dotenvy` behaviour); the documented precedence is `env > .env > default`.
- `.env` and `.env.example` live inside `webif/` (same directory as `Cargo.toml`). The binary must be run from `webif/` so `dotenvy` finds `.env` in its cwd.
- Key variables:
- `.env` file exists at the project root and contains runtime configuration (contents not inspected).
- `Cargo.toml` — only build config.
- `Cargo.lock` — committed lockfile.
- `.gitignore` — single file at the parent repo root (`../.gitignore`); ignores `target/`, `webif/target/`, `webif/dist/`, `**/.env`, `/turns/`, IDE/OS noise.
- No `tsconfig.json`, `eslint.config.*`, `biome.json`, or other tool configs (not applicable to a Rust project).
## Platform Requirements
- Rust toolchain capable of edition 2021 (any reasonably recent stable Rust; no nightly features used).
- The `ht-mcp` binary must be installed and either on `PATH` or referenced by `HT_MCP_PATH`. Currently installed at `/home/parallels/.cargo/bin/ht-mcp` (per `.mcp.json`).
- The `claude` CLI must be on `PATH` because `ht-mcp` spawns it via `ht_create_session` with `{ "command": ["claude"] }` (`src/main.rs:155-157`).
- POSIX-like OS assumed (atomic `mv`-style rename semantics for `result-*.txt` / `status-*.json`, per HT-PROTOCOL v1.1 §6).
- Same as development. Not packaged for any specific deployment target — runs as a long-lived foreground process binding `127.0.0.1:8080` (loopback only, so requires reverse proxy or SSH tunnel for remote access).
- No Dockerfile, no systemd unit, no `Procfile`.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Language and Edition
## Naming Patterns
- Snake-case for any Rust source (`main.rs`). Only one source file exists; future modules should follow `snake_case.rs`.
- Turn artefacts on disk follow protocol-fixed prefixes: `prompt-<turnId>.txt`, `result-<turnId>.txt`, `status-<turnId>.json` (see `HT-PROTOCOL.md` §4 and `src/main.rs:315-319`).
- Spec/documentation files use UPPER-KEBAB at repo root (`HT-PROTOCOL.md`, `README.md`).
- `snake_case`, async by default. Examples in `src/main.rs`:
- Short verb names (`spawn`, `boot`, `restart`, `recreate`, `submit_line`, `snapshot`) — favour single-purpose names over noun-y wrappers.
- `snake_case` everywhere (`turn_id`, `session_id`, `ht_mcp_path`, `job_tx`, `job_rx`, `next_id`).
- Re-bind `worker` from `Worker` to `Arc<Mutex<Worker>>` once shared (`src/main.rs:538`) rather than introducing a parallel name.
- `PascalCase` for structs (`McpClient`, `Worker`, `Job`, `AppState`, `PromptReq`, `CommandReq`, `CommandResp`, `RestartResp`).
- Request DTO suffix: `Req`. Response DTO suffix: `Resp`.
- Constants: `SCREAMING_SNAKE_CASE` with explicit type (`const TURN_TIMEOUT: Duration = Duration::from_secs(300);` at `src/main.rs:39`).
- Single-segment, lowercase nouns: `/prompt`, `/turns/{turn_id}`, `/command`, `/restart` (`src/main.rs:544-548`).
- Path parameters use snake_case inside `{...}`.
- Runtime turn artefacts live in `./turns/` relative to CWD (`src/main.rs:533`).
## Language for Comments and Logs
- Module doc-comment header: `//! ht-webif — curl で叩く薄い WebIF。`
- Error: `anyhow!("ht-mcp が stdout を閉じた")`
- Log: `eprintln!("[restart] ht-mcp 再起動完了。新セッション: {}", self.session_id);`
- Use English identifiers (must compile + interop with axum/serde/tokio).
- Use Japanese for `//`, `//!`, `///` comments, `println!`/`eprintln!` text, and `anyhow!` messages that bubble back to HTTP responses.
## Documentation Comments
- File-level `//!` doc comment at top of `main.rs` (`src/main.rs:1-17`) acts as the architecture summary: data flow diagram, file responsibilities, recovery story.
- Item-level `///` doc comments are used for non-trivial functions and public-ish methods, even though everything is currently private (`src/main.rs:54, 76, 100, 138, 153, 185, ...`).
- Inline `//` comments explain *why*, not *what* (e.g. `// 旧 client は drop され、ht-mcp ごと kill される`).
## Code Style
- No `rustfmt.toml` or `.rustfmt.toml` present → defaults of `cargo fmt` (rustfmt) apply. Existing code matches default rustfmt output (4-space indent, trailing commas, `where`-clause line wrapping).
- Run `cargo fmt` before commits.
- No `clippy.toml` and no `#![deny(...)]` attributes. Run `cargo clippy` ad-hoc; the codebase currently compiles without warnings (one `#[allow(dead_code)]` on `McpClient::child` at `src/main.rs:46`).
- The single source file uses ASCII section banners as visual separators:
- When `main.rs` grows further, split along these banner boundaries into modules (`mcp.rs`, `worker.rs`, `turns.rs`, `http.rs`).
## Import Organization
## Error Handling
- `?` everywhere for propagation.
- `.with_context(|| format!("ht-mcp の起動に失敗: {program}"))` to attach Japanese context strings to OS-level errors (`src/main.rs:62`).
- `.ok_or_else(|| anyhow!("..."))` to convert `Option` into a contextual error (`src/main.rs:63-64, 83, 161, 166`).
- `anyhow!("...")` constructs ad-hoc errors with Japanese messages.
- Best-effort cleanup ignored: `let _ = self.client.close_session(&old).await;` (`src/main.rs:277`).
- Snapshot after `/quit`-like commands wraps the error into text instead of bubbling: `.unwrap_or_else(|e| format!("(snapshot 取得失敗: {e})"))` (`src/main.rs:499`).
- Status-file write on worker-loop failure is best-effort: `let _ = tokio::fs::write(&status_path, body).await;` (`src/main.rs:366`).
- Handlers return `Result<Json<...>, (StatusCode, String)>`.
- A single helper `fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String)` maps any `Display` error to `500` (`src/main.rs:379-381`).
- Use `.map_err(ise)` at the boundary. Use explicit `(StatusCode::BAD_REQUEST, ...)` / `(StatusCode::GATEWAY_TIMEOUT, ...)` / `(StatusCode::NOT_FOUND, ...)` for non-500 outcomes (`src/main.rs:436-441, 458, 468`).
## Async / Concurrency Patterns
- Single `Arc<Mutex<Worker>>` owned by `AppState` and `worker_loop` (`src/main.rs:373-377, 538-540`).
- `tokio::sync::Mutex`, not `std::sync::Mutex`, because the guard is held across `.await` points.
- Acquire pattern:
- Drop the guard as early as possible by scoping (the lock is held for the whole handler body in current code — acceptable because the worker is intentionally single-threaded / serialized).
- `tokio::sync::mpsc::channel::<Job>(64)` (`src/main.rs:539`) for fan-in from HTTP handlers to the single background `worker_loop`.
- HTTP handler converts a closed channel to a 500: `.map_err(|_| ise("ジョブキューが閉じています"))?` (`src/main.rs:429`).
- Wrap awaitables with `tokio::time::timeout(MCP_TIMEOUT, fut)` and convert the outer error into an `anyhow!` describing the operation (`src/main.rs:108-114`).
- Polling loops use `Instant::now() + Duration` deadlines + `tokio::time::sleep(...)` (`src/main.rs:235-245, 330-339, 433-442`).
- Boot wait for `claude` TUI: 700 ms (`src/main.rs:244`).
- Turn-complete polling: 1 s (`src/main.rs:338, 441`).
- Post-keystroke settle delay before `Enter`: 500 ms (`src/main.rs:189`).
- Post-command settle before snapshot: 1500 ms (`src/main.rs:493`).
- Use `tokio::process::Command` with `.kill_on_drop(true)` so dropping the client kills `ht-mcp` (`src/main.rs:60`).
- Pipe `stdin`/`stdout`, inherit `stderr` so logs surface in the parent terminal (`src/main.rs:57-59`).
## HTTP Handler Conventions (axum 0.8)
- Defensive whitelist of `turn_id` characters guards against path traversal (`src/main.rs:457-459`):
- New handlers that accept identifiers used in filesystem paths MUST apply an equivalent whitelist.
## Serde Patterns
#[derive(Deserialize)]
## Configuration
## Logging
- Tag operational `eprintln!` lines with a bracketed source: `[restart]`, `[worker]`, `[shared-fate]` (`src/main.rs:228, 267, 279, 340, 360`).
- Banners on startup describe the running route surface (`src/main.rs:553-558`).
- `ht-mcp` child stderr is **inherited**, not captured, so its logs interleave with our stderr naturally.
- Recovery events (worker restart, session recreation, ht-mcp restart): always.
- Per-turn success: not logged (rely on `status-<turnId>.json` instead).
- Per-turn timeout / failure: log with `turn_id` and attempt counter, then persist outcome to `status-<turnId>.json`.
## Function Design
- Borrow by `&str` / `&Path` / `&[String]` where ownership isn't needed (`src/main.rs:139, 296, 314, 384`).
- Take `String` when storing (`Worker::new(ht_mcp_path: String)` at `src/main.rs:210`).
- Mutating methods take `&mut self`; constructors return `Result<Self>`.
- Fallible internals return `Result<T>` (anyhow).
- Handlers return `Result<Json<T>, (StatusCode, String)>`.
- `()` is fine for fire-and-forget methods (`submit_line`, `close_session`).
## Module Design
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## System Overview
```text
```
## Component Responsibilities
| Component | Responsibility | File |
|-----------|----------------|------|
| HTTP handlers | リクエスト受信、turnId 発番、prompt 永続化、ジョブ enqueue | `src/main.rs:410` (prompt_handler), `src/main.rs:452` (turn_handler), `src/main.rs:485` (command_handler), `src/main.rs:510` (restart_handler) |
| `worker_loop` | ジョブキュー消費、直列ターン処理、失敗時の status 記録 | `src/main.rs:352` |
| `process_job` | ターン1件の駆動: trigger 送信 + status ファイル出現待ち + リトライ | `src/main.rs:314` |
| `Worker` | claude セッション ID 保持、healthy 判定、再生成/再起動 | `src/main.rs:202` |
| `McpClient` | ht-mcp 子プロセス管理、JSON-RPC 送受信、tools/call ラッパ | `src/main.rs:45` |
| `AppState` | HTTP ハンドラの共有状態 (worker, turns_dir, job_tx) | `src/main.rs:373` |
| `build_prompt_body` | prompt ファイル本文（タスク + 出力規約）の組み立て | `src/main.rs:296` |
| `read_turn` | status/result ファイルから JSON レスポンス組成 | `src/main.rs:384` |
| claude TUI (外部) | prompt 実行、result/status の書き出し | 別プロセス (ht-mcp が起動) |
| ht-mcp (外部) | MCP サーバとして ht セッションを露出 | `$HT_MCP_PATH` で指定する外部バイナリ |
## Pattern Overview
- **Async job queue**: HTTP は受信して mpsc にキュー投入するだけ。実処理は 1本のバックグラウンドタスクが直列で消費する（HT-PROTOCOL §12「1 Worker = 同時1ターン」遵守）
- **Filesystem as state store**: ターンの状態は `turns/` ディレクトリの prompt/result/status トリプルで表現する。インメモリのジョブテーブルは持たない
- **Status appearance = done**: status-<turnId>.json の存在が完了シグナル（HT-PROTOCOL §6 のセンチネル）
- **Shared-fate session recovery**: claude TUI が死ぬと検知して再生成、ht-mcp が wedge したら丸ごと restart で蘇生する
- **Single-file Rust**: 全実装が `src/main.rs` 1ファイルにフラットに収まる (~561 行)
## Layers
- Purpose: 外部からのコマンド受付。turnId 発番と prompt 永続化を行い、即応答する
- Location: `src/main.rs:371-519`
- Contains: axum Router、4つのハンドラ関数、リクエスト/レスポンス DTO
- Depends on: `AppState` (worker, turns_dir, job_tx)
- Used by: curl などの HTTP クライアント
- Purpose: ジョブキュー消費とターン1件分の駆動。完了検知（status ファイルポーリング）とリトライ
- Location: `src/main.rs:287-369`
- Contains: `Job`, `worker_loop`, `process_job`, `build_prompt_body`
- Depends on: `Worker` (MCP 越しの TUI 操作)、`turns_dir`（ファイルシステム）
- Used by: HTTP 層が mpsc::Sender 経由で起動する
- Purpose: claude セッションの寿命管理、健全性確認、再生成/全体再起動
- Location: `src/main.rs:200-285`
- Contains: `Worker` 構造体とその関連メソッド（boot/restart/spawn_session/ensure_healthy/recreate）
- Depends on: `McpClient`
- Used by: worker_loop と HTTP ハンドラの両方が `Arc<Mutex<Worker>>` を共有
- Purpose: ht-mcp バイナリと stdio で JSON-RPC を話す最小クライアント
- Location: `src/main.rs:43-198`
- Contains: `McpClient`、handshake、request/notify、call_tool ラッパ、ht-mcp 用のセッション操作（create/close/send_keys/snapshot）
- Depends on: tokio::process::Command (ht-mcp 子プロセス)
- Used by: `Worker`
## Data Flow
### Primary Request Path (POST /prompt → 非同期)
### Synchronous Path (POST /prompt with wait=true)
### Polling Path (GET /turns/{id})
### Raw Command Path (POST /command)
### Restart Path (POST /restart)
- ジョブの状態はファイルシステム (`turns/<prompt|result|status>-<turnId>.{txt|json}`) が唯一の真実
- mpsc キューはジョブ「依頼」だけを伝搬する。完了通知には使わない
- `Arc<Mutex<Worker>>` で worker_loop と HTTP ハンドラ（/command、/restart）が claude セッションを排他共有する
## Key Abstractions
- Purpose: 1往復の作業単位を識別する文字列 ID
- Format: `YYYYMMDD-HHMMSS-mmm`（UTC、ミリ秒精度）。`src/main.rs:415`
- Files: prompt-<id>.txt, result-<id>.txt, status-<id>.json を turnId で束ねる
- Pattern: 発番は Orchestrator (WebIF) のみ。Worker (claude) は発番しない（HT-PROTOCOL §3.2）
- Purpose: ジョブキューに積む最小情報
- Location: `src/main.rs:290-293`
- Fields: `turn_id: String`, `fresh: bool`
- Pattern: 値型。mpsc で move-only に送る
- Purpose: ht-mcp サブプロセス1個と JSON-RPC で話すためのトランスポート
- Location: `src/main.rs:45-198`
- Pattern: stdin/stdout を持ったまま、`next_id` を 1 ずつ進めて request/response をマッチング
- Purpose: 「現在の claude セッション」を1つ抱える状態オブジェクト
- Location: `src/main.rs:202-285`
- Pattern: `Arc<Mutex<Worker>>` で複数のタスクから共有
- Purpose: claude TUI が result/status を確実に書くようプロンプト末尾に付加する規約
- Location: `src/main.rs:296-310` (`build_prompt_body`)
- Pattern: タスク文の後ろに「出力規約」セクションを追記して、result→status の順序を強制する
## Entry Points
- Location: `src/main.rs:521` (`main`)
- Triggers: `cargo run`、外部からの HTTP リクエスト
- Responsibilities: .env 読み込み、Worker 起動、turns/ ディレクトリ作成、worker_loop の spawn、axum サーバ起動 (127.0.0.1:8080)
- `POST /prompt` → `prompt_handler` — ターン投入（既定 async、`wait:true` で sync）
- `GET  /turns/{turn_id}` → `turn_handler` — 状態/結果照会
- `POST /command` → `command_handler` — TUI に生文字列を打つ（スラッシュコマンド用）
- `POST /restart` → `restart_handler` — ht-mcp ごと再起動
- Location: `src/main.rs:540` (`tokio::spawn(worker_loop(...))`)
- Triggers: main 起動時に1本だけ立ち上がる
- Responsibilities: mpsc::Receiver からジョブを取り出し、`process_job` で1件ずつ処理する
## Architectural Constraints
- **Threading:** Tokio multi-threaded runtime (`#[tokio::main]`, `features=["full"]`)。HTTP ハンドラと worker_loop は別タスク。`Arc<Mutex<Worker>>` で TUI 操作を排他化（claude セッションは同時1操作）
- **Serial turn processing:** 同時実行ターンは1件のみ（HT-PROTOCOL §12 準拠）。`worker_loop` がチャネルから順番に取り出して `Worker` の Mutex を取る
- **Global state:** モジュールレベルのグローバルは無い。状態は `AppState` (Arc) と `Worker` (Arc<Mutex>) に集約
- **Single-file module:** `src/main.rs` 1ファイルのみ。`mod` 分割なし
- **MCP wedge guard:** `MCP_TIMEOUT = 30s` (`src/main.rs:41`) で1回の MCP 呼び出しを上限化。超えたら `request` が anyhow エラーを返し、上位で restart へ
- **Turn timeout:** 1試行 `TURN_TIMEOUT = 300s` (`src/main.rs:39`)、最大2試行。`wait:true` の sync ハンドラは別途 700 秒のデッドライン (`src/main.rs:433`)
- **Path traversal guard:** GET /turns/{id} は `^[0-9-]+$` のみ許可 (`src/main.rs:457`)
- **External binaries:** `ht-mcp` の実体は WebIF の責任外。`HT_MCP_PATH` 環境変数で位置を指定する
- **Filesystem coupling:** `turns/` ディレクトリは WebIF と claude TUI が同じパスで見える必要がある（同一ホストなら問題なし）
- **Stderr passthrough:** ht-mcp の stderr は WebIF の端末にそのまま流す (`stderr(Stdio::inherit())`、`src/main.rs:59`)
## Anti-Patterns
### TUI への長文一括送信
### 完了通知をインメモリで持つ
### turnId をクライアントや TUI 内 claude に発番させる
### TUI が wedge した時に MCP 呼び出しを無制限に待つ
### 旧セッションを残したまま新規セッションを作る
## Error Handling
- MCP 呼び出し失敗 → `anyhow!` で文脈付きエラー (`src/main.rs:62`, `src/main.rs:108-113`)
- ターンタイムアウト → セッション再生成 + 1回リトライ → それでも駄目なら `status:"timeout"` をファイルに書く (`src/main.rs:340-348`)
- ジョブ処理中の任意エラー → `worker_loop` が `status:"failed"` + `error` フィールドをファイルに書く (`src/main.rs:360-366`)
- バリデーションエラー → `(StatusCode::BAD_REQUEST, ...)` (`src/main.rs:457-459`)
- 不在ターン → `(StatusCode::NOT_FOUND, ...)` (`src/main.rs:467-468`)
- ジョブキュー閉鎖 → `(StatusCode::INTERNAL_SERVER_ERROR, "ジョブキューが閉じています")` (`src/main.rs:429`)
- snapshot 失敗時の `/command` は寛容にフォールバック文字列を返す (`src/main.rs:496-499`)
## Cross-Cutting Concerns
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
