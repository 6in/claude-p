# Architecture (ht-webif)

## System Overview

`curl` が `POST /prompt` を WebIF (axum) に送ると、ハンドラは `turns/prompt-<turnId>.txt` を書き、`Job` を `mpsc` チャネルに投入して即応答する。バックグラウンドの `worker_loop` がジョブを取り出し、`Worker`（`Arc<Mutex<Worker>>`）を通じて `McpClient` に MCP 呼び出しを送る。`McpClient` は stdio JSON-RPC で `ht-mcp` 子プロセスと会話し、`ht-mcp` が `claude` TUI を PTY 越しに操作して `turns/result-<turnId>.txt` と `turns/status-<turnId>.json` を書き出す。WebIF は `status-<turnId>.json` の出現をポーリングして完了を検知する。ワイヤープロトコルの詳細は [../HT-PROTOCOL.md](../HT-PROTOCOL.md) を参照。

## Component Responsibilities

| Component | 責務 | モジュール |
|-----------|------|-----------|
| HTTP handlers | リクエスト受信、turnId 発番、prompt 永続化、ジョブ enqueue | `src/http.rs` |
| `worker_loop` | ジョブキュー消費、直列ターン処理、失敗時の status 記録 | `src/turn.rs` |
| `process_job` | ターン1件の駆動: trigger 送信 + status ファイル出現待ち + リトライ | `src/turn.rs` |
| `Worker` | claude セッション ID 保持、healthy 判定、再生成/再起動 | `src/worker.rs` |
| `McpClient` | ht-mcp 子プロセス管理、JSON-RPC 送受信、tools/call ラッパ | `src/mcp.rs` |
| `AppState` | HTTP ハンドラの共有状態 (worker, turns_dir, job_tx) | `src/http.rs` |
| `build_prompt_body` | prompt ファイル本文（タスク + 出力規約）の組み立て | `src/turn.rs` |
| `read_turn` | status/result ファイルから JSON レスポンス組成 | `src/turn.rs` |
| claude TUI (外部) | prompt 実行、result/status の書き出し | 別プロセス (ht-mcp が起動) |
| ht-mcp (外部) | MCP サーバとして ht セッションを露出 | `$HT_MCP_PATH` で指定する外部バイナリ |

## Pattern Overview

- **Async job queue**: HTTP は受信して `mpsc` にキュー投入するだけ。実処理は1本のバックグラウンドタスクが直列で消費する（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §12「1 Worker = 同時1ターン」遵守）。
- **Filesystem as state store**: ターンの状態は `turns/` ディレクトリの prompt/result/status トリプルで表現する。インメモリのジョブテーブルは持たない。
- **Status appearance = done**: `status-<turnId>.json` の存在が完了シグナル（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §6 のセンチネル）。
- **Shared-fate session recovery**: claude TUI が死ぬと検知して再生成、ht-mcp が wedge したら丸ごと `/restart` で蘇生する。
- **Module-split Rust**: Phase 02 完了後は `mcp.rs` → `worker.rs` → `turn.rs` → `http.rs` → `lib.rs` の5モジュール構成（Phase 01 以前は `src/main.rs` 1ファイル ~561 行）。

## Layers

**HTTP 層 (`src/http.rs`)**
- Purpose: 外部からのコマンド受付。turnId 発番と prompt 永続化を行い、即応答する。
- Contains: axum Router、4 ハンドラ関数（`prompt_handler`, `turn_handler`, `command_handler`, `restart_handler`）、リクエスト/レスポンス DTO、`AppState`。
- Depends on: `AppState`（worker, turns_dir, job_tx）。
- Used by: curl などの HTTP クライアント。

**ジョブキュー/ターン処理層 (`src/turn.rs`)**
- Purpose: ジョブキュー消費とターン1件分の駆動。完了検知（status ファイルポーリング）とリトライ。
- Contains: `Job`、`worker_loop`、`process_job`、`build_prompt_body`、`read_turn`。
- Depends on: `Worker`（MCP 越しの TUI 操作）、`turns_dir`（ファイルシステム）。
- Used by: HTTP 層が `mpsc::Sender` 経由で起動する。

**セッション管理層 (`src/worker.rs`)**
- Purpose: claude セッションの寿命管理、健全性確認、再生成/全体再起動。
- Contains: `Worker` 構造体とその関連メソッド（`boot`, `restart`, `spawn_session`, `ensure_healthy`, `recreate`）。
- Depends on: `McpClient`。
- Used by: `worker_loop` と HTTP ハンドラの両方が `Arc<Mutex<Worker>>` を共有。

**MCP トランスポート層 (`src/mcp.rs`)**
- Purpose: ht-mcp バイナリと stdio で JSON-RPC を話す最小クライアント。
- Contains: `McpClient`、handshake、request/notify、call_tool ラッパ、ht-mcp 用のセッション操作（create/close/send_keys/snapshot）。
- Depends on: `tokio::process::Command`（ht-mcp 子プロセス）。
- Used by: `Worker`。

## Data Flow

**Primary async: `POST /prompt`（既定）**
HTTP ハンドラが `turns/prompt-<turnId>.txt` を書き、`Job { turn_id, fresh }` を mpsc に enqueue してステータス `"accepted"` を即返す。`worker_loop` がジョブを取り出し、`process_job` が MCP 経由でプロンプトファイルパスを claude TUI に送信する。TUI は実行後 `result-<turnId>.txt` → `status-<turnId>.json` の順にアトミック書き込みする。

**Synchronous: `POST /prompt` with `wait: true`**
上記と同じパスで enqueue するが、HTTP ハンドラは最大 ~700 秒 `status-<turnId>.json` の出現をポーリングしてブロックし、完了後にレスポンスボディに result を埋め込んで返す。

**`GET /turns/{turn_id}` — ポーリング**
ハンドラが `status-<turnId>.json` を読み、ステータスに応じて `running` / `completed` / `failed` / `timeout` を返す。ファイル不在なら `running`（まだ処理中）、ターン自体が存在しなければ `404`。

**`POST /command` — Raw TUI コマンド**
ハンドラが `Worker` の Mutex を取り、MCP `ht_send_keys` で文字列を TUI に直接送信する。1500 ms 待機後に `ht_snapshot` で TUI 画面テキストを取得してレスポンスに含める（スナップショット失敗時はフォールバック文字列）。

**`POST /restart` — ht-mcp 再起動**
ハンドラが `Worker.restart()` を呼ぶ。旧 `McpClient`（＝ht-mcp 子プロセス）を drop して kill し、新しい `McpClient` を spawn → MCP handshake → claude セッション生成 → `session_id` 更新の順に再構築して新しい session_id を返す。

## Key Abstractions

**turnId**
- フォーマット: `YYYYMMDD-HHMMSS-mmm`（UTC、ミリ秒精度）。
- ファイル: `prompt-<id>.txt`, `result-<id>.txt`, `status-<id>.json` を turnId で束ねる。
- 発番は Orchestrator（WebIF）のみ — Worker（claude TUI）もクライアントも発番しない（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §3.2）。

**Job**
- フィールド: `turn_id: String`, `fresh: bool`。
- 値型。mpsc で move-only に送る。

**McpClient**
- ht-mcp サブプロセス1個と JSON-RPC で話すトランスポート。
- stdin/stdout を保持し、`next_id` を1ずつ進めて request/response をマッチング。

**Worker**
- 「現在の claude セッション」を1つ抱える状態オブジェクト。
- `Arc<Mutex<Worker>>` で複数のタスクから共有。

**Prompt body convention**
- `build_prompt_body` がタスク文の後ろに「出力規約」セクションを追記し、result → status の書き込み順序を強制する（`src/turn.rs`）。

## Entry Points

**`main()` in `src/main.rs`**
- Triggers: `cargo run` または `just run`。
- Responsibilities: `.env` 読み込み（`dotenvy`）、設定ロード（`src/config.rs`）、`Worker` 起動、`turns/` ディレクトリ作成、`worker_loop` の spawn、axum サーバ起動（`127.0.0.1:${PORT:-8080}`）。

**HTTP ルートテーブル:**

| Method | Path | Handler | 説明 |
|--------|------|---------|------|
| POST | `/prompt` | `prompt_handler` | ターン投入（既定 async、`wait:true` で sync） |
| GET | `/turns/{turn_id}` | `turn_handler` | 状態/結果照会 |
| POST | `/command` | `command_handler` | TUI に生文字列を打つ（スラッシュコマンド用） |
| POST | `/restart` | `restart_handler` | ht-mcp ごと再起動 |

**`worker_loop` バックグラウンドタスク**
- 起動: `main()` が1本だけ `tokio::spawn`。
- Responsibilities: `mpsc::Receiver` からジョブを取り出し、`process_job` で1件ずつ処理する。

## Architectural Constraints

- **Threading:** Tokio multi-threaded runtime。HTTP ハンドラと `worker_loop` は別タスク。`Arc<Mutex<Worker>>` で TUI 操作を排他化（claude セッションは同時1操作）。
- **Serial turn processing:** 同時実行ターンは1件のみ（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §12 準拠）。`worker_loop` がチャネルから順番に取り出して `Worker` の Mutex を取る。
- **Global state:** モジュールレベルのグローバルなし。状態は `AppState`（Arc）と `Worker`（Arc<Mutex>）に集約。
- **MCP wedge guard:** `MCP_TIMEOUT = 30s` で1回の MCP 呼び出しを上限化。超えたら `request` が anyhow エラーを返し、上位で restart へ（`src/mcp.rs`）。
- **Turn timeout:** 1試行 `TURN_TIMEOUT = 300s`、最大2試行。`wait:true` の sync ハンドラは別途 ~700 秒のデッドライン（`src/http.rs`）。
- **Path traversal guard:** `GET /turns/{id}` は `^[0-9-]+$` のみ許可（`src/http.rs`）。
- **External binaries:** `ht-mcp` の実体は WebIF の責任外。`HT_MCP_PATH` 環境変数で位置を指定する。
- **Filesystem coupling:** `turns/` ディレクトリは WebIF と claude TUI が同じパスで見える必要がある（同一ホストなら問題なし）。
- **Stderr passthrough:** ht-mcp の stderr は WebIF の端末にそのまま流す（`stderr(Stdio::inherit())`、`src/mcp.rs`）。

## Anti-Patterns

**TUI への長文一括送信**
TUI の入力バッファは有限で、長文を一度に送ると文字化けや途中切断が起きる。`build_prompt_body` はタスクをファイルに書いてファイルパスを渡す方式で回避している。

**完了通知をインメモリで持つ**
プロセスが落ちると通知が失われる。ファイルシステム（`status-<turnId>.json`）が唯一の真実であり、インメモリのジョブテーブルは持たない（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §6）。

**turnId をクライアントや TUI 内 claude に発番させる**
衝突やプレフィックスの不整合が起きる。turnId は常に WebIF（Orchestrator）が発番し、TUI もクライアントも発番しない（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §3.2）。

**TUI が wedge した時に MCP 呼び出しを無制限に待つ**
ht-mcp がフリーズするとリクエストが永久ブロックする。`MCP_TIMEOUT = 30s` で上限化し、タイムアウト時は上位で `/restart` を呼ぶ（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §11 の shared-fate 原則）。

**旧セッションを残したまま新規セッションを作る**
古い claude TUI プロセスがリソースを消費し続ける。`Worker.recreate()` は旧セッションを `close_session` してから新規作成する（`// 旧 client は drop され、ht-mcp ごと kill される`、`src/worker.rs`）。

## Error Handling

- MCP 呼び出し失敗 → `anyhow!` で文脈付きエラー（`src/mcp.rs`）。
- ターンタイムアウト → セッション再生成 + 1回リトライ → それでも駄目なら `status:"timeout"` をファイルに書く（`src/turn.rs`）。
- ジョブ処理中の任意エラー → `worker_loop` が `status:"failed"` + `error` フィールドをファイルに書く（`src/turn.rs`）。
- バリデーションエラー → `(StatusCode::BAD_REQUEST, ...)` — `turn_id` ホワイトリスト違反など（`src/http.rs`）。
- 不在ターン → `(StatusCode::NOT_FOUND, ...)` — `status-<turnId>.json` と `prompt-<turnId>.txt` の両方が不在（`src/http.rs`）。
- ジョブキュー閉鎖 → `(StatusCode::INTERNAL_SERVER_ERROR, "ジョブキューが閉じています")`（`src/http.rs`）。
- snapshot 失敗時の `/command` は寛容にフォールバック文字列を返す（`src/http.rs`）。

戻る: [../CLAUDE.md](../CLAUDE.md)
