# Technology Stack (ht-webif)

## Languages

- **Rust** (edition 2021) — アプリケーションコード全体。`src/lib.rs` がクレートルート（Phase 02 でモジュール分割済み）、`src/main.rs` は薄い bin シム。クレート名 `ht-webif`、バージョン `0.1.0`（`Cargo.toml`）。
- **Markdown** — 仕様書 `HT-PROTOCOL.md`、`README.md`、本 `docs/` 配下。ビルドパイプラインなし、ドキュメント専用。
- **JSON** — MCP wire protocol（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) §2）と各ターンの `status-<turnId>.json` に使用。

## Runtime

- 非同期ランタイム: **Tokio** (`#[tokio::main]`, feature `full`)。`src/main.rs` にてランタイム起動。
- HTTP サーバは `127.0.0.1:${PORT:-8080}` にバインド（`PORT` 環境変数でオーバーライド可、`src/config.rs`）。
- `cargo build` / `cargo run` でネイティブバイナリをビルド。ツールチェーンピン（`rust-toolchain.toml`）なし — edition 2021 対応の stable Rust が必要。
- ロックファイル `Cargo.lock` はコミット済み（8 直接依存 → ~70 推移的クレート）。

## Frameworks

- **`axum` 0.8** — HTTP ルーティング層。ルートは `src/http.rs` に登録: `POST /prompt`, `GET /turns/{turn_id}`, `POST /command`, `POST /restart`。
- **`tokio` 1 (full)** — 非同期 HTTP、子プロセス I/O、`mpsc` チャネル、`Mutex`。
- **`hyper` / `tower`** — `axum` に引き込まれる推移的依存（`Cargo.lock` 参照）。

## Build & Test Tooling

- **`cargo`** + **`just`** (`webif/justfile`) — ビルド・起動・フォーマット確認などのタスクランナー。
- **CI:** `.github/workflows/ci.yml` — `cargo fmt --check` → `cargo clippy` → `cargo test --release` の 3 ステップ。ubuntu-latest stable 1 ジョブ。
- **テスト:** `cargo test --release` で実行。`src/` 内 `#[cfg(test)]` ブロックと `[dev-dependencies]` (`tower` util, `tempfile`) を使用（Phase 03 で追加）。

## Key Dependencies

- `tokio` 1 (features: `full`) — 非同期ランタイム、子プロセス起動 (`tokio::process::Command`)、ファイル I/O (`tokio::fs`)、タイマー、チャネル。
- `axum` 0.8 — HTTP サーバフレームワーク。`Router`, `State`, `Json`, `Path` エクストラクタを `src/http.rs` で使用。
- `serde` 1 (feature: `derive`) — リクエスト/レスポンス DTO の JSON (de)シリアライズ（`PromptReq`, `CommandReq`, `CommandResp`, `RestartResp`）。
- `serde_json` 1 — MCP JSON-RPC フレームと `status-<turnId>.json` の動的 JSON 処理（`src/mcp.rs`, `src/turn.rs`）。
- `anyhow` 1 — 内部 `Result<T>` の汎用エラー型。MCP 失敗メッセージの文脈付きエラーに使用。
- `chrono` 0.4 — turnId 生成（UTC タイムスタンプ `%Y%m%d-%H%M%S-%3f`、`src/http.rs`）。
- `dotenvy` 0.15 — 起動時に cwd の `.env` を読み込む（`src/main.rs`）。
- `tower-http` 0.6 (feature: `cors`) — CORS ミドルウェア（quick task 260527-lb8、commit c59b41b で追加）。
- `hyper` 1.x, `tower` 0.5, `http` 1.x — `axum` の下層 HTTP プランビング。
- `mio` 1.x, `socket2` 0.6 — `tokio` の下層 async I/O プリミティブ。
- `tracing` 0.1 — `axum` に引き込まれるが直接使用なし。ロギングは `println!` / `eprintln!`。

## Configuration

`.env` は `dotenvy::dotenv()` で起動時に読み込む（`src/main.rs`）。プロセス環境変数が `.env` より優先される（`dotenvy` 標準動作）。

優先順位: **実環境変数 > `.env` > 既定値**

`.env` / `.env.example` は `webif/` 配下（`Cargo.toml` と同じディレクトリ）。バイナリは `webif/` から実行すること（`dotenvy` が cwd の `.env` を探すため）。

| 変数 | 既定値 | 説明 |
|------|--------|------|
| `PORT` | `8080` | HTTP listener ポート番号。多重起動時はインスタンス毎に変える |
| `TURNS_DIR` | `./turns` | ターン成果物の出力先ディレクトリ |
| `HT_MCP_PATH` | `ht-mcp` | `ht-mcp` バイナリのパス。未設定なら PATH を探索 |
| `CORS_ORIGINS` | `*` | CORS 許可オリジン（カンマ区切り）。`*` で全許可 |

Cargo ビルド設定は `Cargo.toml` のみ。`tsconfig.json` / `eslint.config.*` / `biome.json` 等は存在しない（Rust プロジェクトのため不要）。

## Platform Requirements

- **Rust toolchain**: edition 2021 対応 stable Rust（nightly 機能不使用）。
- **`ht-mcp` バイナリ**: PATH 上にあるか `HT_MCP_PATH` で指定。参考インストール先: `/home/parallels/.cargo/bin/ht-mcp`。
- **`claude` CLI**: PATH 上にあり、Max サブスクリプションでログイン済みであること（`ht-mcp` が `ht_create_session` 経由で `["claude"]` を起動）。
- **POSIX-like OS**: `result-*.txt` / `status-*.json` の atomic rename（`.tmp` → 本名）を前提（[../HT-PROTOCOL.md](../HT-PROTOCOL.md) v1.1 §6）。
- ループバック専用バインド（`127.0.0.1`）。外部アクセスにはリバースプロキシまたは SSH トンネルが必要。
- Dockerfile / systemd unit / Procfile なし。長期起動フォアグラウンドプロセスとして運用。

戻る: [../CLAUDE.md](../CLAUDE.md)
