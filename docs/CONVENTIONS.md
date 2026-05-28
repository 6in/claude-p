# Coding Conventions (ht-webif)

## Naming

**ファイル名:**
- Rust ソース: `snake_case.rs`（`mcp.rs`, `worker.rs`, `turn.rs`, `http.rs`, `config.rs`, `lib.rs`, `main.rs`）
- 仕様/ドキュメント: `UPPER-KEBAB.md`（`HT-PROTOCOL.md`, `README.md`）
- ターン成果物: プロトコル固定プレフィックス `prompt-<turnId>.txt`, `result-<turnId>.txt`, `status-<turnId>.json`（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §4）

**関数・変数:**
- `snake_case`、async by default（`spawn`, `boot`, `restart`, `recreate`, `submit_line`, `snapshot` など単一目的の短い動詞名を優先）。
- `snake_case` everywhere: `turn_id`, `session_id`, `ht_mcp_path`, `job_tx`, `job_rx`, `next_id`。
- `worker` を `Worker` → `Arc<Mutex<Worker>>` に rebind するとき並列名を導入しない（`src/worker.rs`）。

**型名:**
- 構造体: `PascalCase`（`McpClient`, `Worker`, `Job`, `AppState`, `PromptReq`, `CommandReq`, `CommandResp`, `RestartResp`）。
- リクエスト DTO サフィックス: `Req`、レスポンス DTO サフィックス: `Resp`。
- 定数: `SCREAMING_SNAKE_CASE` + 明示的型（例: `const TURN_TIMEOUT: Duration = Duration::from_secs(300);`）。

**ルート:**
- 単一セグメント小文字名詞: `/prompt`, `/turns/{turn_id}`, `/command`, `/restart`。
- パスパラメータは `snake_case`（`{turn_id}`）。
- ランタイムターン成果物は `./turns/` 相対 CWD（`TURNS_DIR` でオーバーライド可、`src/config.rs`）。

## Language for Comments and Logs

- **識別子（変数、関数、構造体名など）:** 英語（コンパイラ + axum/serde/tokio との相互運用性のため必須）。
- **`//`, `//!`, `///` コメント、`println!`/`eprintln!` のテキスト、`anyhow!` メッセージ:** 日本語。
- 例:
  - `//! ht-webif — curl で叩く薄い WebIF。`
  - `anyhow!("ht-mcp が stdout を閉じた")`
  - `eprintln!("[restart] ht-mcp 再起動完了。新セッション: {}", self.session_id);`

## Documentation Comments

- **ファイルレベル `//!`:** `src/lib.rs` の先頭にクレートアーキテクチャサマリ（データフロー図、ファイル責務、リカバリストーリー）を記述（Phase 02 モジュール分割以降は `lib.rs` が起点）。
- **アイテムレベル `///`:** 非自明な関数・メソッドには `///` を付ける（現在は `pub(crate)` 以上に準じて）。
- **インライン `//`:** 「why」を説明する（`// 旧 client は drop され、ht-mcp ごと kill される` など）。

## Code Style

- `rustfmt.toml` なし → `cargo fmt` デフォルト（4 スペースインデント、trailing comma、`where` 句の折り返し）。コミット前に `cargo fmt` を実行すること。
- `clippy.toml` / `#![deny(...)]` なし。`cargo clippy` をアドホックに実行。
- ASCII セクションバナーを視覚的セパレータとして使用（各モジュールファイル内）。
- **モジュール分割（Phase 02 完了済み）:** `mcp.rs`（transport） → `worker.rs`（セッションライフサイクル） → `turn.rs`（ジョブ + ターンファイル）→ `http.rs`（axum ルータ）→ `lib.rs`（re-exports + クレートドキュメント）。`main.rs` は薄い bin シム。

## Error Handling

- **`?`** で全面的に伝播。
- **`.with_context(|| format!("...")))`** で OS エラーに日本語文脈文字列を付与。
- **`.ok_or_else(|| anyhow!("..."))`** で `Option` をコンテキスト付きエラーに変換。
- **`anyhow!("...")`** で日本語メッセージ付きアドホックエラーを構築。
- **ベストエフォートクリーンアップ:** `let _ = self.client.close_session(&old).await;`（エラーを無視）。
- **スナップショット失敗フォールバック:** `.unwrap_or_else(|e| format!("(snapshot 取得失敗: {e})"))`。
- **ステータスファイル書き込み失敗:** `let _ = tokio::fs::write(&status_path, body).await;`（ベストエフォート）。
- **ハンドラの戻り値:** `Result<Json<T>, (StatusCode, String)>`。
- **`fn ise<E: Display>(e: E) -> (StatusCode, String)`** — 任意の `Display` エラーを 500 にマップするヘルパー（`src/http.rs`）。
- `.map_err(ise)` でバウンダリ変換。非 500 は明示的に `StatusCode::BAD_REQUEST` / `GATEWAY_TIMEOUT` / `NOT_FOUND` を使う。

## Async / Concurrency

- **`Arc<Mutex<Worker>>`** を `AppState` と `worker_loop` が共有（`src/worker.rs`, `src/http.rs`）。
- **`tokio::sync::Mutex`**（`std::sync::Mutex` ではない）— `.await` をまたいでガードを保持するため必須。
- ロック取得パターン: ハンドラ本文全体でロックを保持（worker は意図的に直列化されているため許容、[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §12）。
- **`tokio::sync::mpsc::channel::<Job>(64)`** — HTTP ハンドラから `worker_loop` 1本へのファンイン。
- チャネルクローズ時は 500 へ: `.map_err(|_| ise("ジョブキューが閉じています"))?`。
- MCP 呼び出しは `tokio::time::timeout(MCP_TIMEOUT, fut)` でラップ（`MCP_TIMEOUT = 30s`）。
- ポーリングループは `Instant::now() + Duration` デッドライン + `tokio::time::sleep(...)` を使用。
- **タイミング定数（マジックナンバーの拠り所）:**
  - `claude` TUI ブート待機: 700 ms
  - ターン完了ポーリング間隔: 1 s
  - キーストローク後セトル遅延（Enter 前）: 500 ms
  - コマンド後スナップショット前セトル: 1500 ms
- `tokio::process::Command` + `.kill_on_drop(true)` でクライアントをドロップすると `ht-mcp` が kill される。
- `stdin`/`stdout` はパイプ、`stderr` はホスト端末に継承（`src/mcp.rs`）。

## HTTP Handler Conventions (axum 0.8)

- **`turn_id` 文字ホワイトリスト:** `^[0-9-]+$` のみ許可（パストラバーサル対策、`src/http.rs`）。Phase 03 でユニットテスト `path_traversal_*` も追加済み。
- ファイルシステムパスに使う識別子を受け取る新ハンドラは、同等のホワイトリストを必ず適用すること。

## Serde Patterns

- リクエスト DTO: `#[derive(Deserialize)]`。
- レスポンス DTO: `#[derive(Serialize)]`。
- カスタム実装なし（derive のみ）。
- `serde_json::Value` を使う場面は MCP JSON-RPC フレームと動的 JSON 読み込みに限定。

## Logging

- 操作系 `eprintln!` にはブラケット付きソースタグを付ける: `[restart]`, `[worker]`, `[shared-fate]`。
- 起動時バナーで提供中のルートサーフェスを記述。
- `ht-mcp` 子プロセスの stderr はホスト端末に **継承**（キャプチャしない）し、ログが自然に混在する。
- **常にログを出す:** リカバリイベント（worker 再起動、セッション再生成、ht-mcp 再起動）。
- **ログを出さない:** ターン成功時（`status-<turnId>.json` を読んで確認）。
- **ログを出す:** ターンタイムアウト/失敗時 → `turn_id` と試行回数を記録し、`status-<turnId>.json` にも永続化。

## Function Design

- `&str` / `&Path` / `&[String]` で所有権が不要な場合はボロー。
- `String` は保存するとき（`Worker::new(ht_mcp_path: String)` など）。
- ミュータブルメソッドは `&mut self`。コンストラクタは `Result<Self>` を返す。
- 内部フォールブルは `Result<T>`（anyhow）。
- ハンドラは `Result<Json<T>, (StatusCode, String)>` を返す。
- `()` はファイア・アンド・フォーゲットメソッドに使う（`submit_line`, `close_session`）。

## Module Design

Phase 02 でシングルファイル (`src/main.rs` ~561 行) からモジュール分割した構成:

| モジュール | 責務 |
|-----------|------|
| `src/mcp.rs` | `McpClient` — ht-mcp 子プロセス管理、stdio JSON-RPC トランスポート |
| `src/worker.rs` | `Worker` — claude セッション ID 保持、健全性判定、再生成/再起動 |
| `src/turn.rs` | `Job`, `worker_loop`, `process_job`, `build_prompt_body`, `read_turn` — ジョブキュー消費とターンファイルプランビング |
| `src/http.rs` | axum ルータ、4 ハンドラ、`AppState`、リクエスト/レスポンス DTO |
| `src/config.rs` | 環境変数読み込みと設定構造体 |
| `src/lib.rs` | re-exports、クレートレベル `//!` ドキュメント |
| `src/main.rs` | 薄い bin シム（ランタイム起動のみ） |

依存方向は下流のみ: `http` → `turn` → `worker` → `mcp`。テスト専用コンストラクタは `#[cfg(test)] pub(crate)` でガード（Phase 03、STATE.md decisions 03-01/03-04）。

戻る: [../CLAUDE.md](../CLAUDE.md)
