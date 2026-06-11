# Phase 3: Testing & CI Automation - Context

**Gathered:** 2026-05-25
**Status:** Ready for planning

<domain>
## Phase Boundary

モジュール分割済み (`webif/src/{config,mcp,worker,turn,http,lib,main}.rs`) の Rust + axum コードに、回帰検知できる最小限のテスト基盤と CI 自動化を載せる。範囲は次の 5 件のみ:

- **TEST-01** 純粋関数の単体テスト（`build_prompt_body` / `read_turn` の status 解析 / `turn_handler` のパストラバーサル検証など）
- **TEST-02** `McpClient` の JSON-RPC リクエスト/レスポンス組み立て単体テスト
- **TEST-03** HTTP ハンドラ統合テスト — `/turns/{id}` パストラバーサル拒否（400）と GET happy path（status ファイル出現で完了レスポンス）の 2 本のみ
- **TOOL-01** `justfile`（リポジトリ直下）で `build` / `run` / `test` / `fmt` / `clippy` / `clean` の 6 レシピ
- **TOOL-02** `.github/workflows/ci.yml` で push/PR 時に `cargo fmt --check` / `cargo clippy -- -D warnings` / `cargo test` を自動実行

アプリ機能の変更は含まない。`webif/src/` のテスタビリティのために最小限の構造変更（`trait Mcp` 抽出 + `Worker<M: Mcp>` ジェネリック化）は許容するが、4 エンドポイントの挙動は Phase 2 と同一に保つ。

</domain>

<decisions>
## Implementation Decisions

### モック境界（テスタビリティのための構造変更）
- **D-01:** `mcp.rs` に `#[async_trait] pub trait Mcp` を抽出する。継ぎ目は trait 抽象化で、scripted child や request 関数の純化ではない。
- **D-02:** `trait Mcp` の API 粒度は ht-mcp ツールラッパ層（`create_claude_session` / `close_session` / `send_keys` / `submit_line` / `snapshot` / `handshake`）に合わせる。`call_tool` / `request` / `notify` は `McpClient` 内部の実装詳細として trait 外。
- **D-03:** `Worker` を `Worker<M: Mcp>` にジェネリック化し、`main.rs` は `Worker<McpClient>` を使う。`AppState` も `Arc<Mutex<Worker<M>>>` へ型パラメータ伝播。コンパイル時ディスパッチ（zero-cost、`Box<dyn Mcp>` ではない）。
- **D-04:** `async_trait` クレートを `[dependencies]` に追加（dev ではなく本体側 — trait Mcp 自体が `async_trait::async_trait` を必要とするため）。

### 単体テストの組み立て方
- **D-05:** `McpClient::spawn` に加えて `#[cfg(test)] pub fn from_streams(stdin: impl AsyncWrite + Send + 'static, stdout: impl AsyncRead + Send + 'static) -> Self` を追加。`tokio::io::duplex` でテスト側に in-memory な stdin/stdout を持つ。TEST-02 はこの duplex 経由で `request()` が書く JSON 行を読み、`jsonrpc` / `id` / `method` / `params` フィールドを `serde_json::Value` で検証する。
- **D-06:** `#[cfg(test)] mod tests` 形式で各モジュール末尾に co-locate。`webif/tests/` の統合テストファイルは作らず、全テストをユニットテスト扱いに統一。`cargo test` 1 発で全部走る。理由: lib/bin 分離済みで `pub(crate)` / `#[cfg(test)]` パターンが綺麗に使え、テスト用 helper の共有が容易。
- **D-07:** `FakeMcp` 構造体は `mcp.rs` 末尾の `#[cfg(test)] mod tests` の中で定義。Worker と turn 側のテストから使うため、`pub(crate) struct FakeMcp` で内部公開。scripted reply キュー方式（`VecDeque<Result<...>>` を持つ）。

### HTTP 統合テスト
- **D-08:** `tower::ServiceExt::oneshot` で Router を in-process 駆動。`[dev-dependencies]` に `tower` を追加（feature: `util`）。`TcpListener` バインドはしない、`reqwest` も追加しない。
- **D-09:** AppState は `Worker<FakeMcp>` で組み立て、tempdir を `turns_dir` に指定、`worker_loop` を `tokio::spawn` できる scaffolding は用意する。ただし Phase 3 の必須テスト 2 本（GET-only）では `worker_loop` を起こさず、tempdir に事前配置した `status-<id>.json` を `read_turn` 経由で確認する。
- **D-10:** TEST-03 のカバレッジは ROADMAP 規定の 2 本だけ:
  1. `GET /turns/../etc/passwd` 等の不正 `turn_id` が `400 Bad Request` を返す
  2. tempdir に `status-<id>.json` + `result-<id>.txt` を事前配置し、`GET /turns/<id>` が `{turn_id, status:"done", result:"..."}` を返す
  POST `/prompt` / `/command` / `/restart` の統合テストは Phase 3 では追加しない（Phase 2 の 8 件 curl smoke で実証済み、テストハーネスは将来拡張可能な形に整備）。

### TEST-01 純粋関数の対象
- **D-11:** 最低限カバーする純粋関数:
  - `build_prompt_body` — タスク本文と result/status パスから組み立てた文字列に「【ht-webif 出力規約】」セクションと両パスが含まれることを検証
  - `read_turn` — status JSON が garbled / `unknown` 落ち / 完全な `done` の 3 パターン
  - `turn_handler` の `turn_id` バリデーション（数字とハイフン以外を弾く）— D-10 と同じ 1 ケースで兼ねる
  - turn_id の formatter（`%Y%m%d-%H%M%S-%3f`）は `chrono::Utc::now()` 越しで非決定的なので形式の regex マッチで検証

### タスクランナー
- **D-12:** `justfile` を採用（Makefile ではなく）。配置は **リポジトリ直下** `ht-mcp-sample/justfile`。
- **D-13:** レシピは ROADMAP 規定の 6 本のみ:
  - `build` → `cargo build --release` (webif/ で実行)
  - `run` → `cargo run` (webif/ で実行)
  - `test` → `cargo test --release` (webif/ で実行)
  - `fmt` → `cargo fmt --all` (webif/ で実行)
  - `clippy` → `cargo clippy --all-targets --release -- -D warnings` (webif/ で実行)
  - `clean` → `cargo clean` (webif/ で実行)
- **D-14:** working-directory の問題は `set working-directory := 'webif'` か、各レシピで `cd webif &&` のどちらかで吸収。`just <recipe>` をリポジトリ直下で打てば動く形にする（planner の選択に委ねる）。
- **D-15:** `default` レシピと `check` レシピは含めない（最小限）。将来追加する場合は v2 でメンテナンス価値が出てから。

### CI ワークフロー
- **D-16:** `.github/workflows/ci.yml` を **リポジトリ直下** の `.github/workflows/` に置く（git root が親 `ht-mcp-sample/` のため）。
- **D-17:** トリガ: `on: { push: { branches: [main] }, pull_request: { branches: [main] } }`。フォーク PR の duplicate run を避けるため `branches:` で `main` のみに限定。
- **D-18:** OS マトリクス: `ubuntu-latest` 単一。Project Constraint「Single host / Linux 前提」に追従。Windows / macOS は v2 で必要になれば追加。
- **D-19:** Rust toolchain: `stable` 単一、`actions-rust-lang/setup-rust-toolchain@v1` で `components: rustfmt, clippy` を同時取得。beta / MSRV は v2 で評価。
- **D-20:** キャッシュ: `Swatinem/rust-cache@v2` を採用。`workspaces:` に `webif -> webif/target` を指定して webif/Cargo.lock 単位でキー化。
- **D-21:** ジョブ構成: 単一 `check` ジョブで `fmt --check` → `clippy --all-targets --release -- -D warnings` → `test --release` を **直列実行**。並列ジョブ化はしない（小規模リポでは setup 時間が直列分の節約を相殺する）。
- **D-22:** `defaults.run.working-directory: webif` を job に指定して各 step で `cd webif` を省く。
- **D-23:** justfile を CI から呼ばない（cargo を直接呼ぶ）。理由: just のインストール step が増える / レシピが `working-directory := 'webif'` を持つ場合と矛盾を起こさない / GitHub Actions のログで cargo の出力を直接確認できる。just は開発者ローカルでのショートカット用途に留める。

### E2E テスト方針
- **D-24:** Phase 3 で E2E テスト（実 ht-mcp + 実 claude TUI が必要なテスト）は **実装しない**。`#[ignore]` + `RUN_E2E=1` opt-in パターンも含めて v2 へ deferred。Phase 3 のテストはすべて hermetic（FakeMcp + tempdir）で完結する。

### 公開シンボル方針
- **D-25:** テスト用に格上げが必要な可視性変更（例: `McpClient::from_streams` を `#[cfg(test)] pub` で公開、`build_prompt_body` を `pub(crate)` のまま、`FakeMcp` を `pub(crate)`）はすべて `#[cfg(test)]` ガード or `pub(crate)` で「テスト時のみ」「同一クレート内のみ」に限定。本番 API は変えない。

### Claude's Discretion
以下は planner / executor の裁量に任せる:
- `tempfile` クレートの version pin（`tempfile = "3"` で十分）
- justfile の `set working-directory := 'webif'` vs 各レシピで `cd webif &&` の選択（実害がない範囲で）
- 各 `#[cfg(test)] mod tests` 内のテスト関数の具体的名前
- Swatinem/rust-cache の細かい `cache-on-failure` / `prefix-key` パラメータ

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase boundary / requirements
- `.planning/ROADMAP.md` §"Phase 3: Testing & CI Automation" — Goal / Success Criteria 4 件（cargo test green / HTTP 統合 / justfile / GitHub Actions） + cross-cutting constraint（`cargo build --release` と `cargo clippy --all-targets --release -- -D warnings` warning 0）
- `.planning/REQUIREMENTS.md` §"v1 Requirements" — TEST-01 / TEST-02 / TEST-03 / TOOL-01 / TOOL-02 の文面

### Project-level invariants
- `.planning/PROJECT.md` §"Constraints" — Tech stack（Rust）、MCP transport（stdio）、Concurrency（1 worker = 1 claude TUI）、Single host（Linux 単一ホスト前提）
- `.planning/PROJECT.md` §"Key Decisions" — `claude -p` 不使用 / 対話型 TUI を ht-mcp 越しに駆動 / 非同期 API 既定 / ht-mcp 自前 MCP クライアント（rmcp 不使用）

### Existing implementation surface
- `webif/src/lib.rs` — モジュール宣言（`config` / `http` / `mcp` / `turn` / `worker`）
- `webif/src/mcp.rs` — `McpClient`（trait Mcp 抽出対象）。`request` / `call_tool` / `create_claude_session` / `close_session` / `send_keys` / `submit_line` / `snapshot` / `handshake`
- `webif/src/worker.rs` — `Worker` 構造体（ジェネリック化対象）。`new` / `boot` / `restart` / `spawn_session` / `submit_line` / `snapshot` / `ensure_healthy` / `recreate`
- `webif/src/turn.rs` — `Job` / `build_prompt_body`（TEST-01 対象）/ `process_job` / `worker_loop` / `read_turn`（TEST-01 対象）
- `webif/src/http.rs` — `AppState` / `ise` / `PromptReq` / `CommandReq` / `CommandResp` / `RestartResp` / `prompt_handler` / `turn_handler`（TEST-03 対象、パストラバーサル検証は `webif/src/http.rs:89-92`）/ `command_handler` / `restart_handler` / `build_router`（テストから直接呼ぶ）
- `webif/src/config.rs` — `TURN_TIMEOUT` / `MCP_TIMEOUT` / `load_ht_mcp_path`
- `webif/Cargo.toml` — `[lib]` / `[[bin]]` 二重定義、`[dependencies]`、`license = "MIT"`、`edition = "2021"`

### Protocol / domain context
- `HT-PROTOCOL.md` §3-§7 — turn_id 規格（`YYYYMMDD-HHMMSS-mmm` UTC ミリ秒）、3 ファイル方式、`status` 出現で完了センチネル、atomic rename

### Codebase intelligence
- `.planning/codebase/TESTING.md` — Rust テスト基盤の forward-looking recommendation（`tokio::test` / `tempfile::TempDir` / `tower::ServiceExt::oneshot` / `trait Mcp` 抽出パターン / FakeMcp の VecDeque 方式）— 本 CONTEXT.md の決定はこの推奨を踏襲
- `.planning/codebase/STRUCTURE.md` §"New tests" — テスト導入時の配置慣行
- `.planning/codebase/CONVENTIONS.md` §"Language and Edition" / §"Naming Patterns" — `snake_case`、`#[cfg(test)] mod tests`、日本語コメント、`anyhow::Result` 慣行

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`build_router(state: Arc<AppState>) -> Router`** (`webif/src/http.rs:155-162`) — Phase 2 で導入された pub API。テストから直接呼んで `tower::ServiceExt::oneshot` に渡せる。`TcpListener` は不要。
- **`pub struct AppState { worker, turns_dir, job_tx }`** (`webif/src/http.rs:21-25`) — フィールドが全部 `pub`、テストから自由に組み立てられる。
- **`pub async fn read_turn(turns_dir, turn_id)`** (`webif/src/turn.rs:97`) — 純関数寄り（tempdir 入力に対する出力テストが容易）。
- **`pub fn build_prompt_body(task, result_path, status_path)`** (`webif/src/turn.rs:21`) — 完全な純関数。最初に書くべきテスト。
- **`pub async fn worker_loop(worker, turns_dir, job_rx)`** (`webif/src/turn.rs:77`) — 統合テスト用 scaffolding に使える。

### Established Patterns（Phase 2 で確立）
- **モジュール分離 `turn → worker → mcp`**: `turn.rs` が `crate::worker::Worker` を使い、`worker.rs` が `crate::mcp::McpClient` を使う。trait Mcp 抽出はこの方向と一致する（最下層 mcp.rs に trait、上層から `M: Mcp` で受け取る）。
- **`pub(crate)` と `pub` の使い分け**: Plan 02-02/03 で「lib/bin 越境のため pub 化」が記録されている。テスト用の格上げは `#[cfg(test)] pub` で本番影響を出さない方針が踏襲できる。
- **`[lib] ht_webif` / `[[bin]] ht-webif`** の二重命名（CommonJS と同類の Rust 識別子規則対応）— テストは lib 側に書き、`use ht_webif::*` から呼べる構造。
- **エラー型は `anyhow::Result<T>` で統一**、テスト側も `.unwrap()` か `.expect("context")` で良い。
- **`tokio::test` macros は `features = ["full"]` 済みで利用可**（追加依存不要、`webif/Cargo.toml:14`）。
- **`println!` / `eprintln!` で操作ログ**: `[restart]` / `[worker]` / `[shared-fate]` タグ。テスト出力でも観察できるよう `cargo test -- --nocapture` 推奨を README/justfile docs に書ける。

### Integration Points
- **新規依存追加位置**: `webif/Cargo.toml`
  - `[dependencies]` に `async-trait = "0.1"`（trait Mcp の `#[async_trait]` のため）
  - `[dev-dependencies]` を **新規追加** し、`tower = { version = "0.5", features = ["util"] }`、`tempfile = "3"` を入れる
- **`McpClient::spawn` の隣**: `webif/src/mcp.rs:22` に `#[cfg(test)] pub fn from_streams(...)` を追加する位置
- **`Worker<M>` ジェネリック化波及**: `worker.rs` → `turn.rs::Worker<M>` → `http.rs::AppState<M>` まで型パラメータが伝搬する。`main.rs` の `Worker::new(ht_mcp_path)` は最終的に `Worker<McpClient>` 型として推論される。
- **`.github/workflows/` ディレクトリ**: 現状存在しないので新規作成
- **`justfile` 配置**: リポジトリ直下に新規作成。`webif/.gitignore` / `webif/Cargo.toml` は変更しない

### Constraints / 落とし穴
- **Worker のフィールド `client: McpClient`** (`webif/src/worker.rs:10`) は `pub` ではない — ジェネリック化時に `pub(crate)` も不要、`Worker<M>` の内部詳細のまま。
- **`async_trait` の object safety**: 今回は `Box<dyn Mcp>` を使わないので `dyn` 互換性の制約は不要。`impl Trait` でも `M: Mcp` でも書ける。
- **Phase 2 cross-cutting constraint**: `cargo clippy --all-targets --release -- -D warnings` が warning 0 を要求。テスト追加で新規 lint が出ないよう `#[allow(dead_code)]` の代わりに実際に使う、`unused_imports` を避けるなど留意。
- **`AppState.job_tx: mpsc::Sender<Job>`** はテストで使わなくても drop されないよう保持が必要（チャネル closed エラー回避）。
- **`webif/Cargo.lock` はコミット済み** — `[dev-dependencies]` 追加でロックファイル更新あり。

</code_context>

<specifics>
## Specific Ideas

- ROADMAP success criteria #2 が要求する **「`../` や不正文字を 400 で弾く」** はそのまま `webif/src/http.rs:89-92` の既存ロジックを test 検証する形になる。新規セキュリティロジックの追加ではなく、**Phase 2 で実証済みの ASVS V5 制御がリグレッションで消えないこと** を保証するためのテスト。
- TEST 数の見積もり: 単体 7-9 本（build_prompt_body / read_turn 3 パターン / turn_id バリデーション / MCP request 組み立て / handshake / call_tool 結果 parsing / セッション ID parsing）+ 統合 2 本（HTTP）= **合計 10 本前後**。
- `cargo test --release` を CI のジョブで使う（dev profile ではなく）。理由: ROADMAP cross-cutting constraint と CI ジョブのプロファイルを揃え、dev profile での「警告は出ないが release で出る」事故を防ぐ。

</specifics>

<deferred>
## Deferred Ideas

これらは Phase 3 では着手しない。v2 もしくは別 phase で評価する。

- **E2E テスト（実 ht-mcp + claude TUI 必要）** — `#[ignore]` + `RUN_E2E=1` opt-in パターンで将来追加。v2 で SCALE-01 / DEPLOY-01 と合わせて検討。
- **`cargo llvm-cov` 等のカバレッジ計測 + CI 集計** — TESTING.md で提案あり。v2 で評価。
- **`cargo nextest` 採用** — テストランナー高速化。v2。
- **`cargo audit` を CI に組み込む** — セキュリティ依存スキャン。v2 で SEC-01 と合わせて検討。
- **`cargo watch` レシピを justfile に追加** — 開発者体験向上。最小限優先で外す。
- **OS マトリクス拡張（macOS / Windows）** — Single host 前提に追従。必要になれば v2 で追加。
- **Rust toolchain マトリクス（beta / MSRV）** — 同上、v2 で評価。
- **HTTP 統合テストの POST / `/command` / `/restart` カバレッジ拡張** — Phase 3 では GET 2 本だけ。POST 系の hermetic テストは Phase 2 の 8 件 curl smoke で代替済み、将来追加可能な scaffolding は今 phase で整備する。
- **justfile に `check` / `default` / `cov` / `watch` などの便利レシピ追加** — 最小 6 本に絞る判断。
- **CI で並列ジョブ化（fmt / clippy / test 分離）** — 小規模リポでは直列の方が速い。リポ規模が大きくなった時点で再評価。
- **CI から justfile を呼ぶ統合** — 二重定義を避ける判断。just はローカル用途のみ。
- **`OPS-02` tracing structured logging** — Phase 3 のテスト対象とは独立、v2 で対応。

</deferred>

---

*Phase: 3-testing-ci-automation*
*Context gathered: 2026-05-25*
