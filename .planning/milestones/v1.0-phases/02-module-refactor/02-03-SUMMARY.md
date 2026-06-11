---
phase: 02-module-refactor
plan: 03
subsystem: worker-and-turn
tags: [refactor, modules, worker, turn, mid-layer]
requires:
  - 02-02  # config.rs と mcp.rs がリーフ層として確立済み
provides:
  - mid-modules-extracted          # worker.rs と turn.rs が main.rs から物理的に独立
  - dependency-chain-turn-worker-mcp  # turn -> worker -> mcp の依存方向が明示
  - worker-public-api              # Worker + 主要メソッドが pub で lib crate 外から呼べる
  - turn-public-api                # Job / build_prompt_body / read_turn / worker_loop が pub
affects:
  - webif/src/main.rs              # 399 → 214 行 (-185 行)
tech_stack:
  added: []
  patterns:
    - "Mid-layer extraction (RESEARCH.md Pattern 3) — リーフ層 (config/mcp) が安定した状態で中間層 (worker/turn) を切り出す"
    - "lib/bin 可視性ブリッジ (Plan 02-02 から継承) — bin crate (main.rs) から呼ばれる API は pub、lib 内部のみは pub(crate)"
    - "tokio::sync::Mutex 排他制御 (.await 越し guard 維持) — std::sync::Mutex 禁止"
key_files:
  created: []
  modified:
    - webif/src/worker.rs    # placeholder 1 行 → 92 行 (Worker + 8 メソッド)
    - webif/src/turn.rs      # placeholder 1 行 → 109 行 (Job + 4 関数)
    - webif/src/main.rs      # 399 → 214 行 (Worker/Job/turn 系を削除し ht_webif:: 経由で再導入)
decisions:
  - "Worker の主要メソッド (restart/submit_line/snapshot/ensure_healthy) を pub に格上げ — Plan 02-02 と同じ lib/bin 越境理由 (HTTP ハンドラが main.rs に残るため)"
  - "Worker::boot, spawn_session, recreate は lib 内部のみで使うため pub(crate) 維持 (worker.rs 内部 / turn.rs::process_job から呼ばれる)"
  - "turn.rs の build_prompt_body と read_turn を pub に格上げ — main.rs の prompt_handler / turn_handler から呼ばれる"
  - "turn.rs の process_job は pub(crate) 維持 (worker_loop からのみ呼ばれる)"
  - "Worker 構造体の client / ht_mcp_path フィールドは private (メソッド経由でしかアクセスしない) — session_id のみ pub (restart_handler が読む)"
metrics:
  duration_min: 7.0
  duration_seconds: 420
  tasks: 3
  files_changed: 3
  commits: 3
  completed: 2026-05-25
---

# Phase 02 Plan 03: 中間層抽出 (worker + turn) Summary

## One-liner

`main.rs` から `Worker` 構造体 (86 行) と `Job` + 4 関数 (`build_prompt_body` / `process_job` / `worker_loop` / `read_turn`、合計約 100 行) を専用ファイル (`worker.rs` / `turn.rs`) へ verbatim 移送し、`use ht_webif::...` 経由で再導入。依存方向 `turn -> worker -> mcp` が確立。HTTP 層は未変更で main.rs に残る。`cargo build --release` と `cargo clippy --all-targets --release -- -D warnings` が両方クリーン。

## What Was Built

### `webif/src/worker.rs` (プレースホルダ → 完成、92 行)

`pub struct Worker { client: McpClient (private), pub session_id: String, ht_mcp_path: String (private) }` + 全 8 メソッド (`new` / `boot` / `restart` / `spawn_session` / `submit_line` / `snapshot` / `ensure_healthy` / `recreate`) を `main.rs` から verbatim 移送。

- `use crate::mcp::McpClient;` で leaf 層に依存
- 日本語 eprintln! verbatim:
  - `[restart] ht-mcp 再起動完了。新セッション: ...`
  - `[shared-fate] claude セッション不健全 → 再生成`
  - `[shared-fate] claude セッション再生成: ... （旧 ... を閉鎖）`
- `anyhow!("claude TUI が起動しない:\n{snap}")` verbatim
- `let _ = self.client.close_session(&old).await;` の best-effort cleanup 規約 verbatim
- 可視性: `new / restart / submit_line / snapshot / ensure_healthy` を `pub` (bin crate から参照)、`boot / spawn_session / recreate` を `pub(crate)` (lib 内部のみ)

### `webif/src/turn.rs` (プレースホルダ → 完成、109 行)

`pub struct Job { pub turn_id: String, pub fresh: bool }` + 4 関数 (`build_prompt_body` / `process_job` / `worker_loop` / `read_turn`) を `main.rs` から verbatim 移送。

- `use crate::worker::Worker;` で mid 層、`use crate::config::TURN_TIMEOUT;` で leaf 層に依存
- `use tokio::sync::{mpsc, Mutex};` (`.await` 越し guard 維持のため std::sync::Mutex は禁止)
- `use std::path::{Path, PathBuf};` (axum::Path ではない — name collision 回避)
- 日本語 eprintln! verbatim:
  - `[worker] ターン {} タイムアウト（試行 {attempt}/2）→ セッション再生成`
  - `[worker] ジョブ {} 失敗: {e}`
- 【ht-webif 出力規約】prompt body format 文字列 verbatim
- 可視性: `Job / build_prompt_body / read_turn / worker_loop` を `pub` (bin crate から参照)、`process_job` を `pub(crate)` (worker_loop からのみ呼ばれる)

### `webif/src/main.rs` (399 → 214 行、-185 行)

削除:
- `Worker` struct + impl ブロック全体 (旧 lines 38-123)
- `Job` struct (旧 lines 125-131)
- `build_prompt_body` fn (旧 lines 133-148)
- `process_job` fn (旧 lines 150-187)
- `worker_loop` fn (旧 lines 189-207)
- `read_turn` fn (旧 lines 222-234)
- 不要 use: `anyhow!` (Worker が引き取ったため)、`TURN_TIMEOUT` (process_job が引き取ったため)

追加 import:
- `use ht_webif::worker::Worker;`
- `use ht_webif::turn::{build_prompt_body, read_turn, worker_loop, Job};`

保持:
- `AppState` (Plan 04 で http.rs へ)
- `ise`、`PromptReq`、4 HTTP ハンドラ (`prompt_handler` / `turn_handler` / `command_handler` / `restart_handler`)、`CommandReq` / `CommandResp` / `RestartResp`
- `main()` (`dotenvy::dotenv().ok();`、`Worker::new(...).await?;`、`Arc::new(Mutex::new(worker));`、`tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));`、`Router::new()...`、`axum::serve(...)`)
- `use tokio::sync::{mpsc, Mutex};` (`Arc::new(Mutex::new(worker))` で `Mutex` を直接参照、`mpsc::channel::<Job>(64)` で `mpsc` を参照)

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | worker.rs に Worker 構造体一式を移送 | `c3dcf4a` | `webif/src/worker.rs` |
| 2 | turn.rs に Job + 4 関数を移送 | `7843bce` | `webif/src/turn.rs` |
| 3 | main.rs から Worker/Job/turn 系を削除し ht_webif:: 経由で再導入 | `ee1dcea` | `webif/src/main.rs` |

## Verification Results

### Primary build gate (PASS)

```
cargo build --release                                → EXIT 0, 0 warnings, 0 errors
cargo clippy --all-targets --release -- -D warnings  → EXIT 0, 0 warnings, 0 errors
```

### Acceptance criteria (Task 1 — worker.rs)

| Check | Result |
|-------|--------|
| `pub struct Worker { }` 1 行 | OK |
| `pub session_id: String` 1 行 | OK |
| `client: McpClient` (private) 1 行 | OK |
| `ht_mcp_path: String` (private) 1 行 | OK |
| `pub async fn new` 1 行 | OK |
| `pub(crate) async fn boot` 1 行 | OK |
| `pub async fn restart` 1 行 (DEVIATED from plan: 元 pub(crate)) | OK — 後述 deviation 参照 |
| `pub(crate) async fn spawn_session` 1 行 | OK |
| `pub async fn submit_line` 1 行 (DEVIATED from plan) | OK |
| `pub async fn snapshot` 1 行 (DEVIATED from plan) | OK |
| `pub async fn ensure_healthy` 1 行 (DEVIATED from plan) | OK |
| `pub(crate) async fn recreate` 1 行 | OK |
| `use crate::mcp::McpClient;` 1 行 | OK |
| `use std::sync::Mutex` 0 件 | OK |
| 日本語 eprintln! / anyhow! verbatim | OK (4 件全て確認) |
| `let _ = self.client.close_session(&old).await;` verbatim | OK |
| `cargo build --release --lib` 0 warnings, 0 errors | OK |

### Acceptance criteria (Task 2 — turn.rs)

| Check | Result |
|-------|--------|
| `pub struct Job { }` 1 行 | OK |
| `pub turn_id: String,` 1 行 | OK |
| `pub fresh: bool,` 1 行 | OK |
| `pub fn build_prompt_body` 1 行 (DEVIATED from plan: 元 pub(crate)) | OK — 後述 deviation 参照 |
| `pub(crate) async fn process_job` 1 行 | OK |
| `pub async fn worker_loop` 1 行 | OK |
| `pub async fn read_turn` 1 行 (DEVIATED from plan: 元 pub(crate)) | OK |
| `use crate::worker::Worker;` 1 行 | OK |
| `use crate::config::TURN_TIMEOUT;` 1 行 | OK |
| `use tokio::sync::{mpsc, Mutex};` 1 行 | OK |
| `use std::sync::Mutex` 0 件 | OK |
| `use std::path::{Path, PathBuf};` 1 行 | OK |
| `[worker] ターン .* タイムアウト` 1 件 | OK |
| `[worker] ジョブ .* 失敗` 1 件 | OK |
| `【ht-webif 出力規約】` 1 件 | OK |
| `cargo build --release --lib` 0 warnings, 0 errors | OK |
| `cargo clippy --release --lib -- -D warnings` PASS | OK |

### Acceptance criteria (Task 3 — main.rs)

| Check | Result |
|-------|--------|
| `^struct Worker` 0 件 | OK |
| `^impl Worker` 0 件 | OK |
| `^struct Job` 0 件 | OK |
| `^fn build_prompt_body` 0 件 | OK |
| `^async fn process_job` 0 件 | OK |
| `^async fn worker_loop` 0 件 | OK |
| `^async fn read_turn` 0 件 | OK |
| `^use ht_webif::worker::Worker;` 1 件 | OK |
| `^use ht_webif::turn::` 1 件 | OK |
| `^use tokio::sync::{mpsc, Mutex};` 1 件 (Arc::new(Mutex::new(worker)) のため必須) | OK |
| `^struct AppState` 1 件 (Plan 04 で削除予定) | OK |
| `^async fn prompt_handler` 1 件 | OK |
| `^async fn turn_handler` 1 件 | OK |
| `^async fn command_handler` 1 件 | OK |
| `^async fn restart_handler` 1 件 | OK |
| `tokio::spawn(worker_loop` 1 件 | OK |
| `Arc::new(Mutex::new(worker))` 1 件 | OK |
| `worker.clone()` 1 件 | OK |
| `Worker::new` 1 件 | OK |
| 行数 in [170, 220) — actual 214 | OK |
| `cargo build --release` 0 warnings, 0 errors | OK |
| `cargo clippy --all-targets --release -- -D warnings` PASS | OK |

## Decisions Made

1. **可視性 pub vs pub(crate) を厳密に分離 (Plan 02-02 から継承)** — `webif/` クレートは `[lib].name = ht_webif` と `[[bin]].name = ht-webif` の **2 つの別クレート**で構成される。`pub(crate)` は lib **内部**にしか露出しない。bin crate (main.rs) から `use ht_webif::worker::Worker` 経由で呼ばれる Worker メソッドは全て `pub` 必須。turn.rs では `Job / build_prompt_body / worker_loop / read_turn` を `pub`、`process_job` のみ `pub(crate)` (worker_loop 内部からのみ呼ばれる)。Worker では `new / restart / submit_line / snapshot / ensure_healthy` を `pub`、`boot / spawn_session / recreate` を `pub(crate)`。

2. **Worker の `client` と `ht_mcp_path` フィールドは private** — モジュール内のメソッドからしかアクセスせず、外部から触れる必要が一切ないため。`session_id` のみ `pub` (`restart_handler` が `worker.session_id.clone()` を読む、main の起動ログが `worker.session_id` を読む)。

3. **`use tokio::sync::{mpsc, Mutex};` を main.rs に保持** — Worker/Job/turn を削除しても、`Arc::new(Mutex::new(worker))` と `mpsc::channel::<Job>(64)` が main() 内に残っているため `Mutex` と `mpsc` の direct 参照は継続。Plan のコメント (lines 274-277) で明示された保持要件。

4. **`anyhow!` と `TURN_TIMEOUT` の import を main.rs から削除** — Worker が `anyhow!("claude TUI が起動しない:...")` を引き取り、`process_job` が `TURN_TIMEOUT` を引き取ったため、main.rs 側で unused に。`anyhow::Result` は `main() -> Result<()>` で必須なので保持。`Instant` は `prompt_handler` の wait:true 待機で必須なので保持。

5. **依存方向 `turn -> worker -> mcp` を確立** — `turn.rs` の `use crate::worker::Worker;` と `worker.rs` の `use crate::mcp::McpClient;` で物理的に reflect。Plan 04 で `http.rs` を作るときに `use crate::turn::*; use crate::worker::Worker;` で最終層を import できる土台が完成。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 可視性修正: Plan が指定した `pub(crate)` から `pub` への格上げ (5 件)**

- **Found during:** Task 1 と Task 2 のビルド時 (dead_code 警告 → bin crate から呼べないことを示唆)
- **Issue:** Plan 02-03 の interfaces セクション (lines 86-108) は以下を `pub(crate)` 指定していたが、これらは bin crate (main.rs) から呼ばれる:
  - `Worker::restart` ← `restart_handler` が呼ぶ
  - `Worker::submit_line` ← `command_handler` が呼ぶ (turn.rs::process_job からも)
  - `Worker::snapshot` ← `command_handler` が呼ぶ
  - `Worker::ensure_healthy` ← `command_handler` が呼ぶ (turn.rs::process_job からも)
  - `turn::build_prompt_body` ← `prompt_handler` が呼ぶ
  - `turn::read_turn` ← `prompt_handler` / `turn_handler` が呼ぶ
- **Fix:** 上記 5 メソッド + 1 関数 + 1 関数 (build_prompt_body と read_turn は plan で `pub(crate)` 指定だったが、main.rs から呼ばれるため `pub`) を `pub` に格上げ。`pub(crate)` 維持は `boot / spawn_session / recreate / process_job` の 4 つ (lib 内部のみで使う)
- **Files modified:** `webif/src/worker.rs` (5 メソッド)、`webif/src/turn.rs` (build_prompt_body と read_turn)
- **Commits:** `c3dcf4a` (Task 1 — Worker 可視性同時修正)、`7843bce` (Task 2 — turn 可視性同時修正)
- **Why this was a plan bug, not a fix:** Plan 02-02 SUMMARY の Decision 1 で「lib.name=ht_webif と bin.name=ht-webif は別クレート」が確定し、Plan 02-02 でも同じ可視性 deviation を実施済み。Plan 02-03 の interfaces コメント (lines 92-95, 105-108) はその制約を引き継いでいなかった。本 plan の deviation は Plan 02-02 で確立したパターンの自然な拡張で、同じ lib/bin 越境問題の解消。

**追加 import deviation:**

- **Plan 02-03 Task 3 の指示** (line 273): `use ht_webif::turn::{Job, read_turn, worker_loop};`
- **実装:** `use ht_webif::turn::{build_prompt_body, read_turn, worker_loop, Job};`
- **理由:** Plan の interfaces コメント (line 105) は `build_prompt_body` を `pub(crate) fn` と指定していたが、`main.rs::prompt_handler` (line 134 で `build_prompt_body(...)` を呼ぶ) が必要とするため `pub` に格上げ&import 追加。Plan の Task 3 action は build_prompt_body の必要性を見落としていた。

### Discoveries Deferred

なし。本 plan の作業範囲は worker.rs / turn.rs / main.rs の 3 ファイルのみで、out-of-scope の発見はなかった。

## Known Stubs

なし。`webif/src/http.rs` は依然プレースホルダだが、これは本 plan の範囲外で Plan 02-04 で充填予定 (Plan 02-01 SUMMARY 参照)。`worker.rs` と `turn.rs` は本 plan で実装完了。

## Authentication Gates

なし (ht-mcp / claude を起動しないビルド検証のみ)。

## Threat Model Compliance

| Threat ID | Mitigation 確認 |
|-----------|----------------|
| T-02-03-01 (Tampering: `use std::sync::Mutex;` 誤 import) | OK — `grep -c 'use std::sync::Mutex' webif/src/{worker,turn}.rs` が 両方 `0`。worker.rs は Mutex import 不要 (Worker は Mutex を持たない)、turn.rs は `use tokio::sync::{mpsc, Mutex};` のみ |
| T-02-03-02 (Tampering: `worker.clone()` 喪失で worker_loop と AppState が別 Worker を持つ) | OK — `grep -c 'worker.clone()' webif/src/main.rs` returns `1`、`grep -c 'Arc::new(Mutex::new(worker))' webif/src/main.rs` returns `1`、`grep -c 'Worker::new' webif/src/main.rs` returns `1` |
| T-02-03-03 (Tampering: `recreate` の best-effort cleanup を `?` で書き換え) | OK — verbatim 移送ルール厳守。`grep -c 'let _ = self.client.close_session' webif/src/worker.rs` returns `1` |

## Next Steps

- **Plan 02-04 (最終):** `http.rs` に `AppState`、`ise`、`PromptReq` / `CommandReq` / `CommandResp` / `RestartResp`、4 HTTP ハンドラ、router 構築関数を移送。`main.rs` 本体は `dotenvy::dotenv()` + `Worker::new()` + `tokio::spawn(worker_loop(...))` + `http::build_router(state)` + `axum::serve` の薄いエントリポイントだけ (約 30 行) に縮退。
- HTTP ハンドラ群が move したあと、`http.rs` から `crate::worker::Worker` (`worker.restart()`, `worker.submit_line()`, `worker.snapshot()`, `worker.ensure_healthy()`, `worker.session_id`) と `crate::turn::{Job, build_prompt_body, read_turn}` を import する形になる。本 plan の可視性格上げ (上記 deviation) はこの最終形を見越したもの。

## Self-Check: PASSED

Files modified:
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/worker.rs` — FOUND (92 lines)
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/turn.rs` — FOUND (109 lines)
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/main.rs` — FOUND (214 lines)

Commits:
- `c3dcf4a` — FOUND (Task 1: worker.rs)
- `7843bce` — FOUND (Task 2: turn.rs)
- `ee1dcea` — FOUND (Task 3: main.rs cleanup)

Build:
- `cargo build --release` — 0 warnings, 0 errors
- `cargo clippy --all-targets --release -- -D warnings` — 0 warnings, 0 errors
