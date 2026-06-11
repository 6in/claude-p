---
phase: 02-module-refactor
plan: 02
subsystem: mcp-and-config
tags: [refactor, modules, mcp, config, leaf-layer]
requires:
  - 02-01  # lib + bin スケルトンが既に存在する
provides:
  - leaf-modules-extracted        # config.rs と mcp.rs が main.rs から物理的に独立
  - mcp-client-public-api         # McpClient + 主要メソッドが pub で lib crate 外から呼び出せる
affects:
  - webif/src/main.rs            # 561 → 399 行（-162 行）
tech_stack:
  added: []
  patterns:
    - "Leaf-first extraction (RESEARCH.md Pattern 3) — 依存被参照0のリーフから順に切り出し、各 plan で増分ビルドを保証"
    - "lib/bin 可視性ブリッジ — pub(crate) は lib 内部 / pub は bin crate から見える、を明示的に分離"
key_files:
  created: []
  modified:
    - webif/src/config.rs    # placeholder 1 行 → 14 行（TURN_TIMEOUT / MCP_TIMEOUT / load_ht_mcp_path）
    - webif/src/mcp.rs       # placeholder 1 行 → 164 行（McpClient + 12 メソッド）
    - webif/src/main.rs      # 561 行 → 399 行（McpClient 定義 + config 定数を物理削除し、use ht_webif::... で再導入）
decisions:
  - "TURN_TIMEOUT は pub（main.rs bin crate から参照）／ MCP_TIMEOUT は pub(crate)（lib 内部 mcp.rs のみ）に分離 — 公開面を最小化"
  - "McpClient と main.rs が呼ぶ全メソッド（spawn/request/notify/handshake/call_tool/create_claude_session/close_session/send_keys/submit_line/snapshot）を pub に格上げ、write_message/read_response は private のまま"
  - "D-02-01 (clippy::trim_split_whitespace) を mcp.rs 移送時に同時修正 — .trim() を削除（.split_whitespace 自体が空白除去するため redundant）"
metrics:
  duration_min: 4.5
  duration_seconds: 272
  tasks: 3
  files_changed: 3
  commits: 3
  completed: 2026-05-25
---

# Phase 02 Plan 02: リーフ層抽出（config + mcp）Summary

## One-liner

`main.rs` から `TURN_TIMEOUT` / `MCP_TIMEOUT` / `HT_MCP_PATH` 読み込みと `McpClient` 全体（167 行）を専用ファイル（`config.rs`、`mcp.rs`）へ物理移送し、`use ht_webif::...` 経由で再導入。`Worker` 以降は未変更。`cargo build --release` と `cargo clippy --all-targets --release -- -D warnings` が両方ともクリーン（D-02-01 解消）。

## What Was Built

### `webif/src/config.rs`（プレースホルダ → 完成）

```rust
//! 設定定数と環境変数読み込み。
use std::time::Duration;

/// 1ターンの最大待ち時間（1試行あたり）。
pub const TURN_TIMEOUT: Duration = Duration::from_secs(300);
/// MCP 呼び出し1回のタイムアウト（ht-mcp の wedge 対策）。
pub const MCP_TIMEOUT: Duration = Duration::from_secs(30);
/// HT_MCP_PATH 環境変数を読む。存在しない場合は "ht-mcp" を既定値とする。
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}
```

注: `dotenvy::dotenv().ok()` は意図的に `main.rs` に残してある（RESEARCH.md Anti-pattern 遵守）。

### `webif/src/mcp.rs`（プレースホルダ → 完成）

`pub struct McpClient` + 全 12 メソッド（spawn / write_message / read_response / request / notify / handshake / call_tool / create_claude_session / close_session / send_keys / submit_line / snapshot）を `main.rs` から verbatim 移送。

`#[allow(dead_code)] child: Child` と `.kill_on_drop(true) + .stderr(Stdio::inherit())` の shared-fate 規約を保存。`MCP_TIMEOUT` は `use crate::config::MCP_TIMEOUT;` で参照。

### `webif/src/main.rs`（561 → 399 行）

- 削除: `TURN_TIMEOUT` / `MCP_TIMEOUT` の `const` 定義、`McpClient` struct + impl 全体、関連する use（`Stdio`、`AsyncBufReadExt`、`AsyncWriteExt`、`BufReader`、`Lines`、`Child`、`ChildStdin`、`ChildStdout`、`Command`、`Context`）
- 追加: `use ht_webif::config::{load_ht_mcp_path, TURN_TIMEOUT};` と `use ht_webif::mcp::McpClient;`
- `std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())` → `load_ht_mcp_path()`
- `Worker` / `Job` / `worker_loop` / `process_job` / `build_prompt_body` / `read_turn` / `AppState` / 全 HTTP ハンドラ / `main()` は **1 行も変更していない**

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | config.rs に TURN_TIMEOUT / MCP_TIMEOUT / load_ht_mcp_path を実装 | `2bc93ef` | `webif/src/config.rs` |
| 2 | mcp.rs に McpClient 一式を移送（+ D-02-01 同時修正） | `d27d2c3` | `webif/src/mcp.rs` |
| 3 | main.rs から元コードを物理削除し ht_webif:: 経由で再導入 | `27e9958` | `webif/src/{main,config,mcp}.rs`（可視性調整含む） |

## Verification Results

### Primary build gate (PASS)

```
cargo build --release         → EXIT 0, 0 warnings, 0 errors
cargo clippy --all-targets --release -- -D warnings  → EXIT 0, 0 warnings, 0 errors
```

### Acceptance criteria (Task 3 — plan-level)

| Check | Result |
|-------|--------|
| `grep -c '^struct McpClient' main.rs` returns 0 | OK |
| `grep -c '^impl McpClient' main.rs` returns 0 | OK |
| `grep -c '^const TURN_TIMEOUT' main.rs` returns 0 | OK |
| `grep -c '^const MCP_TIMEOUT' main.rs` returns 0 | OK |
| `grep -c '^use ht_webif::config::' main.rs` returns 1 | OK |
| `grep -c '^use ht_webif::mcp::McpClient;' main.rs` returns 1 | OK |
| `grep -c 'load_ht_mcp_path()' main.rs` returns 1 | OK |
| `grep -c 'std::env::var("HT_MCP_PATH")' main.rs` returns 0 | OK |
| `grep -c 'dotenvy::dotenv()' main.rs` returns 1 | OK |
| `grep -c '^#[tokio::main]' main.rs` returns 1 | OK |
| `grep -c '^struct Worker' main.rs` returns 1 | OK |
| `grep -c '^struct AppState' main.rs` returns 1 | OK |
| `grep -c '^async fn worker_loop' main.rs` returns 1 | OK |
| `grep -c '^async fn prompt_handler' main.rs` returns 1 | OK |
| `wc -l main.rs` in [380, 420) — actual 399 | OK |
| `cargo build --release` exits 0 with no warning/error lines | OK |
| `cargo clippy --all-targets --release -- -D warnings` exits 0 | OK |

### Acceptance criteria (Task 2 — mcp.rs)

| Check | Result |
|-------|--------|
| `pub(crate) struct McpClient` 行が `1` であること | DEVIATED: `pub struct McpClient` に変更（後述 deviation 参照） |
| `#[allow(dead_code)]` 1 件 | OK |
| `child: Child,` 1 件 | OK |
| `.stderr(Stdio::inherit())` 1 件 | OK |
| `.kill_on_drop(true)` 1 件 | OK |
| `use crate::config::MCP_TIMEOUT;` 1 件 | OK |
| 全メソッド存在（spawn/request/handshake/call_tool/create_claude_session/close_session/send_keys/submit_line/snapshot）| OK（ただし `pub(crate)` → `pub` に変更） |
| `async fn write_message` / `read_response` （private） | OK |
| 日本語エラーメッセージ verbatim（6 種） | OK |

### Acceptance criteria (Task 1 — config.rs)

| Check | Result |
|-------|--------|
| `TURN_TIMEOUT: Duration = Duration::from_secs(300)` 1 件 | OK（ただし `pub(crate)` → `pub` に変更） |
| `MCP_TIMEOUT: Duration = Duration::from_secs(30)` 1 件 | OK（`pub(crate)` のまま — lib 内部のみ使用） |
| `pub fn load_ht_mcp_path() -> String` 1 件 | OK |
| `std::env::var("HT_MCP_PATH")` 1 件 | OK |
| `dotenvy` 0 件 | OK |
| `head -1 src/config.rs` が `//!` | OK |

## Decisions Made

1. **可視性の pub vs pub(crate) を厳密に分離** — `webif/` クレートは `[lib].name = ht_webif` と `[[bin]].name = ht-webif` という 2 つの**別クレート**で構成される。`pub(crate)` は lib **内部**にしか露出しないため、bin crate から `use ht_webif::...` で参照する必要がある `TURN_TIMEOUT` / `McpClient` / `McpClient` の主要メソッドは全て `pub` に格上げ。一方で lib 内部のみで使う `MCP_TIMEOUT`（mcp.rs から参照）と `write_message` / `read_response`（McpClient 内部のみ）は `pub(crate)` または private のまま保ち、公開面を最小化。

2. **D-02-01 (clippy::trim_split_whitespace) を mcp.rs 移送時に同時修正** — Plan 02-01 で deferred-items.md に記録された pre-existing lint。`create_claude_session` の `.trim().split_whitespace()` から `.trim()` を削除（`split_whitespace` は元々 leading/trailing whitespace をスキップするため redundant）。挙動は完全に同一。コード移送中で同じファイルを編集しているため追加リスクは 0。

3. **`dotenvy::dotenv().ok()` は意図的に main.rs に残す** — RESEARCH.md Anti-pattern として「config.rs に dotenv 読み込みを移送するな（プロセス起動の副作用は main の責任）」が明記されている。`config.rs` は副作用なしの「定数 + 環境変数 getter」のみに留めた。

4. **`anyhow::Context` を main.rs の use から削除** — `Worker` は `.with_context` を使っていない（McpClient だけが使う）。Pre-existing import だったが McpClient 移送と同時に main.rs 側で `Context` が unused になるため削除。Plan 03 で `Worker` を `worker.rs` に移すときに `Context` も `worker.rs` に追加する想定。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 可視性修正: `pub(crate)` → `pub` (lib/bin crate 越境のため必須)**

- **Found during:** Task 3 build 時
- **Issue:** Plan の interfaces セクションは `TURN_TIMEOUT` を `pub(crate)`、`McpClient` を `pub(crate) struct`、全メソッドを `pub(crate)` で指定していたが、bin crate `ht-webif`（main.rs）は lib crate `ht_webif` とは別クレートなので `pub(crate)` シンボルを `use ht_webif::config::TURN_TIMEOUT;` で参照できず、`error[E0603]: constant TURN_TIMEOUT is private` と `error[E0603]: struct McpClient is private` が発生
- **Fix:** main.rs から呼ばれる lib シンボルを以下の通り `pub` に格上げ:
  - `config.rs`: `TURN_TIMEOUT` を `pub`（`MCP_TIMEOUT` は lib 内部のみ使用なので `pub(crate)` を維持）
  - `mcp.rs`: `pub struct McpClient`、`pub async fn spawn / request / notify / handshake / call_tool / create_claude_session / close_session / send_keys / submit_line / snapshot`（`write_message` / `read_response` は McpClient 内部のみなので private のまま）
- **Files modified:** `webif/src/config.rs`、`webif/src/mcp.rs`
- **Commit:** `27e9958`（Task 3 と同じコミットで実施 — 同じ可視性問題の解消が Task 3 の前提条件のため）
- **Why this was a plan bug, not a fix:** Plan の interfaces コメント（02-02-PLAN.md line 81）は「pub(crate) for crate-internal use only」と書いてあるが、lib + bin 二重ターゲット構造では bin が「crate-external」になる。Plan 02-01 SUMMARY の Decision 1 で「lib.name=ht_webif と bin.name=ht-webif は別クレート」が確定済みなので、Plan 02-02 の可視性指定は内部矛盾していた。今回の修正はその矛盾の解消。

**2. [Rule 1 - Bug] D-02-01: `clippy::trim_split_whitespace` (Plan 02-01 で deferred、本 plan で解消)**

- **Found during:** Plan 02-01 実行時に発見、本 plan の Task 2 で計画通り修正
- **Issue:** `create_claude_session` の `.trim().split_whitespace()` chain は redundant（`split_whitespace` 自体が leading/trailing whitespace を skip するため）
- **Fix:** `mcp.rs` 移送時に `.trim()` 呼び出しを削除
- **Files modified:** `webif/src/mcp.rs`（main.rs の元コードは Task 3 で削除）
- **Commit:** `d27d2c3`
- **Origin:** Pre-existing — baseline commit `5439df5` から存在。Plan 02-01 が `main.rs` を 1 バイトも変更しない方針だったため deferred-items.md (D-02-01) に記録され、Plan 02-02 owner にされていた。本 plan で計画通り解消。

### Discoveries Deferred

なし。本 plan の作業範囲は config.rs / mcp.rs / main.rs の 3 ファイルのみで、out-of-scope の発見はなかった。

## Known Stubs

なし。`webif/src/{worker,turn,http}.rs` は依然プレースホルダだが、これは本 plan の範囲外で、Plan 02-03 / 02-04 で充填予定（Plan 02-01 SUMMARY 参照）。`config.rs` と `mcp.rs` は本 plan で実装完了。

## Authentication Gates

なし（ht-mcp / claude を起動しないビルド検証のみ）。

## Threat Model Compliance

| Threat ID | Mitigation 確認 |
|-----------|----------------|
| T-02-02-01 (Tampering: `.kill_on_drop(true)` 喪失で orphan ht-mcp) | OK — `grep -c '\.kill_on_drop(true)' src/mcp.rs` returns `1`、`#[allow(dead_code)] child: Child` フィールドも保持 |
| T-02-02-02 (Info disclosure: `.stderr(Stdio::inherit())` 喪失で wedge 検知遅延) | OK — `grep -c '\.stderr(Stdio::inherit())' src/mcp.rs` returns `1` |
| T-02-02-03 (Tampering: 誤った Mutex import) | OK — mcp.rs に `Mutex` の import なし（McpClient は Mutex を持たない）。コンパイラ catch（cargo build clean） |

## Next Steps

- **Plan 02-03:** `worker.rs` と `turn.rs` に `Worker` / `Job` / `worker_loop` / `process_job` / `build_prompt_body` / `read_turn` を移送。`Worker` 内の `client: McpClient` は `use ht_webif::mcp::McpClient;` で参照可能（pub 化済み）、`TURN_TIMEOUT` は `use ht_webif::config::TURN_TIMEOUT;`（同 pub 化済み）で参照可能 — リーフ層の独立化が Plan 03 の依存解決を素直にする。
- **Plan 02-04:** `http.rs` に handlers / DTOs / router を移送、`main.rs` 本体を薄いエントリポイントだけに縮退。

## Self-Check: PASSED

Files modified:
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/config.rs` — FOUND (14 lines)
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/mcp.rs` — FOUND (164 lines)
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/main.rs` — FOUND (399 lines)

Commits:
- `2bc93ef` — FOUND (Task 1: config.rs)
- `d27d2c3` — FOUND (Task 2: mcp.rs + D-02-01 fix)
- `27e9958` — FOUND (Task 3: main.rs cleanup + visibility fix)

Build:
- `cargo build --release` — 0 warnings, 0 errors
- `cargo clippy --all-targets --release -- -D warnings` — 0 warnings, 0 errors
