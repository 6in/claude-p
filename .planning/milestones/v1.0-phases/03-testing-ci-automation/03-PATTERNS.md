# Phase 3: Testing & CI Automation - Pattern Map

**Mapped:** 2026-05-25
**Files analyzed:** 8（新規 2 + 修正 6）
**Analogs found:** 6 / 8（テスト基盤 / インフラ系 2 件は新規パターン）

---

## File Classification

| New / Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---------------------|------|-----------|----------------|---------------|
| `webif/Cargo.toml` (modify) | config (package manifest) | static config | `webif/Cargo.toml` 現状 | exact（同ファイル拡張） |
| `webif/src/mcp.rs` (modify) | service (MCP transport) + test colocate | request-response + test scaffolding | `webif/src/mcp.rs` 既存 `impl McpClient` | exact（同ファイル内 trait 抽出） |
| `webif/src/worker.rs` (modify) | service (session lifecycle) generic化 | request-response | `webif/src/worker.rs` 既存 `impl Worker` | exact（同ファイル内ジェネリック化） |
| `webif/src/turn.rs` (modify) | service (turn driver) + test colocate | event-driven (fs polling) + test | `webif/src/turn.rs` 既存純関数群 | exact |
| `webif/src/http.rs` (modify) | controller (axum handlers) generic化 + test | request-response + HTTP integration test | `webif/src/http.rs` 既存 `AppState` / `build_router` | exact |
| `webif/src/main.rs` (modify) | binary entry (wiring) | startup config | `webif/src/main.rs` 既存配線 | exact（型注釈微修正のみ） |
| `justfile` (NEW, at repo root) | tooling / task-runner | static recipe dispatch | **新規パターン** — リポジトリ内に既存タスクランナーなし | none（外部慣行に従う） |
| `.github/workflows/ci.yml` (NEW) | CI config | event-driven (push/PR trigger) | **新規パターン** — `.github/` 未存在 | none（外部慣行に従う） |

**観察:** テスト関連の修正先は全て既存モジュール内部での co-located `#[cfg(test)] mod tests`。`webif/tests/` 統合テストディレクトリは作らない（D-06）。テスト自身は新規だが、テスト「配置場所」と「テスト対象関数」は全て既存コードの中にある。

---

## Pattern Assignments

### `webif/Cargo.toml`（config 拡張）

**Analog:** 自分自身（`webif/Cargo.toml:13-20`）

**既存の `[dependencies]` ブロック** (lines 13-20)：
```toml
[dependencies]
tokio = { version = "1", features = ["full"] }
axum = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
chrono = "0.4"
dotenvy = "0.15"
```

**追記する依存:**
- `async-trait = "0.1"` を `[dependencies]` の末尾に追加（D-04: `trait Mcp` で `#[async_trait]` を使うため本体依存）
- `[dev-dependencies]` セクションを新規追加し、`tower = { version = "0.5", features = ["util"] }` と `tempfile = "3"` を入れる（D-08, D-25 で「テスト用は dev 側」と決定）

**書き方の参考パターン**（同ファイル内 `tokio` のような features 指定）：features 配列は `tower` の `["util"]` で `oneshot` を使うため必須。`tempfile` は features なしのデフォルト。

**`[lib]` / `[[bin]]` 二重定義は変更しない** (lines 22-28)。`name = "ht_webif"` の lib 側にテストを書く（識別子規則対応で `_` 区切り）。

---

### `webif/src/mcp.rs`（trait Mcp 抽出 + テスト用 from_streams + FakeMcp + 単体テスト）

**Analog:** `webif/src/mcp.rs:12-18`（既存 `McpClient` struct + impl ブロック）

**Imports pattern** (lines 1-10) — そのまま流用 + `async_trait` 追加：
```rust
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::config::MCP_TIMEOUT;
```
**追加:** `use async_trait::async_trait;`

**trait 抽出パターン**（`.planning/codebase/TESTING.md` lines 98-115 が forward-looking 推奨、本実装はこれを踏襲）：

D-02 で `trait Mcp` の API 粒度は ht-mcp ツールラッパ層（`create_claude_session` / `close_session` / `send_keys` / `submit_line` / `snapshot` / `handshake`）に合わせる。`call_tool` / `request` / `notify` は `McpClient` 内部詳細として trait 外。

参照すべき既存メソッドシグネチャ（`webif/src/mcp.rs:91-163`）：
```rust
pub async fn handshake(&mut self) -> Result<()>
pub async fn create_claude_session(&mut self) -> Result<String>
pub async fn close_session(&mut self, session_id: &str) -> Result<()>
pub async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()>
pub async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()>
pub async fn snapshot(&mut self, session_id: &str) -> Result<String>
```

**注釈:** `#[async_trait]` で書き、`Send` 境界を入れる（D-03 でコンパイル時ディスパッチ `M: Mcp` を使うので object-safety は不問だが、`Worker<M>` を `Arc<Mutex<...>>` に入れるため `Send` は必須）。

**`from_streams` テスト用コンストラクタ**（D-05、`McpClient::spawn` の隣 `webif/src/mcp.rs:20-33` に追加）：

既存 `spawn` のパターン (`webif/src/mcp.rs:22-33`)：
```rust
pub async fn spawn(program: &str) -> Result<Self> {
    let mut child = Command::new(program)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("ht-mcp の起動に失敗: {program}"))?;
    let stdin = child.stdin.take().ok_or_else(|| anyhow!("stdin が取れない"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow!("stdout が取れない"))?;
    Ok(Self { child, stdin, lines: BufReader::new(stdout).lines(), next_id: 0 })
}
```

追加すべき `from_streams`（`#[cfg(test)] pub` で本番には出さない、D-25）：
- `child: Child` フィールドが `#[allow(dead_code)]` で持っているので、テスト時はダミー `Child` を持たせるか、あるいは `child` 自体を `Option<Child>` 化して `from_streams` では `None` にする
- 入力は `tokio::io::duplex()` の片側ペア（`impl AsyncWrite + Send + 'static`, `impl AsyncRead + Send + 'static`）
- `lines: BufReader::new(stdout).lines()` の構築は spawn と同じ

**注意:** `child` フィールドを `Option<Child>` に変えると `Drop` の挙動が変わるため、`#[cfg(test)]` で別 ctor を持つアプローチが安全。具体策は planner の裁量だが、本番側の API 変更を最小化する方向で（D-25）。

**`#[cfg(test)] mod tests` の co-location パターン**（`.planning/codebase/STRUCTURE.md` line 137、`.planning/codebase/TESTING.md` lines 50-62, 69-85 の推奨）：

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use tokio::io::duplex;

    pub(crate) struct FakeMcp {
        // scripted reply キュー（D-07）
        pub create_session_replies: VecDeque<Result<String>>,
        pub snapshot_replies: VecDeque<Result<String>>,
        // 必要なら send_keys の呼び出し記録など
    }

    #[async_trait]
    impl Mcp for FakeMcp {
        async fn handshake(&mut self) -> Result<()> { Ok(()) }
        async fn create_claude_session(&mut self) -> Result<String> {
            self.create_session_replies.pop_front()
                .unwrap_or_else(|| Err(anyhow!("scripted reply 切れ")))
        }
        // ... 残りも同形
    }

    #[tokio::test]
    async fn request_builds_jsonrpc_envelope() {
        let (tx, rx) = duplex(64);
        // テスト側は rx 側で書き込みを読む / tx 側を McpClient に渡す
        // ...
    }
}
```

**TEST-02 単体テストの題材**（CONTEXT.md "specifics" lines 159 で 7-9 本想定）：
- `request` が書き出す JSON 行に `jsonrpc:"2.0"` / `id` / `method` / `params` が入る
- `next_id` が呼出ごとに +1 される
- `handshake` が `initialize` リクエスト + `notifications/initialized` 通知の順で送る
- `call_tool` がレスポンスから `result.content[0].text` を抽出する（`webif/src/mcp.rs:106-118` の組み立てロジック検証）
- `create_claude_session` のセッション ID パース（`webif/src/mcp.rs:121-134`、"Session ID:" 後の最初の whitespace まで）

**FakeMcp 可視性:** `pub(crate) struct FakeMcp` で同一クレート内に公開（D-07）。`worker.rs` / `turn.rs` / `http.rs` のテストから `use crate::mcp::tests::FakeMcp;` で参照。

---

### `webif/src/worker.rs`（Worker<M: Mcp> ジェネリック化）

**Analog:** `webif/src/worker.rs:9-13`（既存 `Worker` struct）

**既存定義** (lines 9-13)：
```rust
pub struct Worker {
    client: McpClient,
    pub session_id: String,
    ht_mcp_path: String,
}
```

**ジェネリック化後の形**（D-03）：
```rust
pub struct Worker<M: Mcp = McpClient> {
    client: M,
    pub session_id: String,
    ht_mcp_path: String,
}
```
- デフォルト型パラメータ `= McpClient` を付けると `main.rs` 側で `Worker::new(...)` のまま型推論できる（CONTEXT.md "Integration Points" line 142 を満たす）

**Imports 変更:**
- 追加: `use crate::mcp::Mcp;`（trait を `M: Mcp` バウンドで使う）
- 既存の `use crate::mcp::McpClient;` は `main.rs` から `Worker<McpClient>` 想定で残す必要があるかは planner 判断（デフォルト型なら不要）

**メソッドのジェネリック反映パターン:**

既存 `boot` (`webif/src/worker.rs:23-28`)：
```rust
pub(crate) async fn boot(ht_mcp_path: &str) -> Result<(McpClient, String)> {
    let mut client = McpClient::spawn(ht_mcp_path).await?;
    client.handshake().await?;
    let session_id = Self::spawn_session(&mut client).await?;
    Ok((client, session_id))
}
```

これは `McpClient::spawn` を呼ぶので具象型に依存。ジェネリック化対象外として **`impl Worker<McpClient>` 専用 impl ブロック** に隔離するのが綺麗。それ以外（`submit_line` / `snapshot` / `ensure_healthy` / `recreate` / `restart`）は `impl<M: Mcp + Send> Worker<M>` の汎用 impl に入る。

**self-borrow trick 既存パターン**（`webif/src/worker.rs:56-58, 62-64, 82-83`）— ジェネリック化後もそのまま：
```rust
pub async fn submit_line(&mut self, text: &str) -> Result<()> {
    let sid = self.session_id.clone();
    self.client.submit_line(&sid, text).await
}
```

**テスト追加余地:** D-06 で `#[cfg(test)] mod tests` 追加可。最小限なら省略。`ensure_healthy` が不健全時に `recreate` を呼ぶ挙動を FakeMcp 経由で確認するテストが書ければ高価値。

---

### `webif/src/turn.rs`（Worker<M> 型シグネチャ反映 + 純関数テスト）

**Analog:** `webif/src/turn.rs:21-35`（既存 `build_prompt_body` 純関数）+ `webif/src/turn.rs:97-109`（既存 `read_turn`）

**ジェネリック型反映** — `process_job` / `worker_loop` のシグネチャ:

既存 (`webif/src/turn.rs:39, 77-81`)：
```rust
pub(crate) async fn process_job(worker: &mut Worker, turns_dir: &Path, job: &Job) -> Result<()>
pub async fn worker_loop(
    worker: Arc<Mutex<Worker>>,
    turns_dir: PathBuf,
    mut job_rx: mpsc::Receiver<Job>,
)
```

ジェネリック後：
```rust
pub(crate) async fn process_job<M: Mcp + Send>(
    worker: &mut Worker<M>, turns_dir: &Path, job: &Job
) -> Result<()>

pub async fn worker_loop<M: Mcp + Send + 'static>(
    worker: Arc<Mutex<Worker<M>>>,
    turns_dir: PathBuf,
    mut job_rx: mpsc::Receiver<Job>,
)
```
- `'static` バウンドは `tokio::spawn` に渡すために必要（`main.rs:30` で spawn している）

**TEST-01 純粋関数テストの題材**（D-11、`.planning/codebase/TESTING.md` lines 174-187 の推奨パターン踏襲）：

**`build_prompt_body` テスト**（`webif/src/turn.rs:21-35` を対象）：
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn build_prompt_body_includes_task_and_paths() {
        let result_path = PathBuf::from("/tmp/result-X.txt");
        let status_path = PathBuf::from("/tmp/status-X.json");
        let body = build_prompt_body("やってほしいこと", &result_path, &status_path);
        assert!(body.contains("やってほしいこと"));
        assert!(body.contains("/tmp/result-X.txt"));
        assert!(body.contains("/tmp/status-X.json"));
        assert!(body.contains("【ht-webif 出力規約】"));
    }
}
```

**`read_turn` テスト** — 3 パターン（D-11）：
- `done`: 完全な `{"status":"done"}` + `result-*.txt` 存在 → JSON に `status:"done"`, `result:"..."` が入る
- `unknown` 落ち: `status-*.json` が garbled → `status:"unknown"` にフォールバック（`webif/src/turn.rs:101-104` の `.unwrap_or_else` パスを検証）
- `result` ファイル不在: `tokio::fs::read_to_string` の `.unwrap_or_default()` パス（`webif/src/turn.rs:105-107`）→ `result:""`

**テストヘルパパターン**（`.planning/codebase/TESTING.md` lines 133-141 推奨）— inline で十分：
```rust
async fn write_turn(dir: &Path, id: &str, status_json: &str, result: &str) {
    tokio::fs::write(dir.join(format!("status-{id}.json")), status_json).await.unwrap();
    tokio::fs::write(dir.join(format!("result-{id}.txt")), result).await.unwrap();
}
```

**turn_id formatter テスト** — `prompt_handler` 内の `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` (`webif/src/http.rs:48`) の **形式** だけを regex で検証。`turn.rs` ではなく `http.rs` 側のテストに置くか、別 helper を抽出するかは planner 裁量。

---

### `webif/src/http.rs`（AppState<M> ジェネリック化 + HTTP 統合テスト）

**Analog:** `webif/src/http.rs:21-25`（既存 `AppState`）+ `webif/src/http.rs:155-162`（既存 `build_router`）+ `webif/src/http.rs:85-103`（既存 `turn_handler`）

**ジェネリック化:**

既存 (`webif/src/http.rs:21-25`)：
```rust
pub struct AppState {
    pub worker: Arc<Mutex<Worker>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
}
```

ジェネリック後（D-03）：
```rust
pub struct AppState<M: Mcp + Send + 'static = McpClient> {
    pub worker: Arc<Mutex<Worker<M>>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
}
```

**ハンドラ4本のシグネチャ伝播:**

既存 `prompt_handler` (`webif/src/http.rs:43-46`)：
```rust
async fn prompt_handler(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PromptReq>,
) -> Result<Json<Value>, (StatusCode, String)>
```

ジェネリック後の各ハンドラ:
```rust
async fn prompt_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
    Json(req): Json<PromptReq>,
) -> Result<Json<Value>, (StatusCode, String)>
```

`turn_handler` は `worker` を触らないため、ジェネリック化しなくても動くが、`AppState<M>` から取り出すなら型パラメータ必須。

**`build_router` ジェネリック化** (`webif/src/http.rs:155-162`)：
```rust
pub fn build_router<M: Mcp + Send + 'static>(state: Arc<AppState<M>>) -> Router {
    Router::new()
        .route("/prompt", post(prompt_handler::<M>))
        .route("/turns/{turn_id}", get(turn_handler::<M>))
        .route("/command", post(command_handler::<M>))
        .route("/restart", post(restart_handler::<M>))
        .with_state(state)
}
```

**TEST-03 HTTP 統合テスト 2 本**（D-08, D-09, D-10）—`tower::ServiceExt::oneshot` パターン：

`.planning/codebase/TESTING.md` line 167 で推奨されている形。Phase 3 では `worker_loop` を起こさず、tempdir に事前配置した `status-<id>.json` を `read_turn` 経由で確認する（D-09）。

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::tests::FakeMcp;
    use axum::body::Body;
    use axum::http::Request;
    use tempfile::tempdir;
    use tower::ServiceExt;

    fn build_test_state(turns_dir: PathBuf) -> Arc<AppState<FakeMcp>> {
        // FakeMcp を持つ Worker<FakeMcp> を組み立て
        // worker_loop は spawn しない（D-09）
        // job_tx は Sender を保持するだけで drop 防止（CONTEXT "Constraints" line 150）
        let (job_tx, _job_rx) = mpsc::channel(64);
        // worker は build_router が State として要求するため必要だが、
        // turn_handler 経路では参照されない
        let worker = Arc::new(Mutex::new(/* Worker<FakeMcp> 構築 */));
        Arc::new(AppState { worker, turns_dir, job_tx })
    }

    #[tokio::test]
    async fn turn_handler_rejects_path_traversal() {
        let dir = tempdir().unwrap();
        let state = build_test_state(dir.path().to_path_buf());
        let app = build_router(state);
        let resp = app.oneshot(
            Request::builder()
                .method("GET")
                .uri("/turns/..%2Fetc%2Fpasswd")
                .body(Body::empty())
                .unwrap()
        ).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn turn_handler_returns_done_when_status_file_exists() {
        let dir = tempdir().unwrap();
        let id = "20260525-000000-000";
        tokio::fs::write(
            dir.path().join(format!("status-{id}.json")),
            "{\"status\":\"done\"}\n"
        ).await.unwrap();
        tokio::fs::write(
            dir.path().join(format!("result-{id}.txt")),
            "ok"
        ).await.unwrap();

        let state = build_test_state(dir.path().to_path_buf());
        let app = build_router(state);
        let resp = app.oneshot(
            Request::builder()
                .method("GET")
                .uri(&format!("/turns/{id}"))
                .body(Body::empty())
                .unwrap()
        ).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        // body を読んで status / result を検証（axum::body::to_bytes 経由）
    }
}
```

**パストラバーサル検証ロジックの所在**（テストが守る対象）— `webif/src/http.rs:90-92`：
```rust
if turn_id.is_empty() || !turn_id.chars().all(|c| c.is_ascii_digit() || c == '-') {
    return Err((StatusCode::BAD_REQUEST, "不正な turn_id".to_string()));
}
```

このロジックがリグレッションで消えないことを保証するのが TEST-03 の本質（CONTEXT.md "specifics" line 158）。

---

### `webif/src/main.rs`（型注釈の最小修正）

**Analog:** `webif/src/main.rs:1-46`（既存配線）

**変更点:** D-03 で `Worker<McpClient>` をデフォルト型推論で受けられるよう設計するので、main.rs は **理想的には無変更**。`Worker::new(ht_mcp_path)` (`webif/src/main.rs:19`) と `Worker::new` が `Result<Worker<McpClient>>` を返す形に推論できれば OK。

**もし明示注釈が必要なら** (line 19 を変更)：
```rust
let worker: Worker<McpClient> = Worker::new(ht_mcp_path).await?;
```
または `use ht_webif::mcp::McpClient;` を import に追加 (line 6-9 あたり)。

planner の判断ポイント: `Worker<M: Mcp = McpClient>` のデフォルト型パラメータが入っているか否かで main.rs の変更量が決まる。デフォルトを入れる方が main.rs 不変で済むので推奨。

---

## 新規パターン（Analog なし）

### `justfile`（リポジトリ直下、新規）

**新規パターン:** プロジェクト内に既存タスクランナー (`Makefile` / `justfile` / `xtask`) なし。外部の `just` 慣行に従う。

**配置:** リポジトリ直下 `/home/parallels/workspaces/ht-mcp-sample/justfile`（D-12）。理由: `webif/` は cargo プロジェクト直下、`webif/Cargo.toml` を触る `cargo` コマンドは `webif/` で実行する必要がある。リポジトリ直下から `just <recipe>` を打つ運用に統一する（D-14）。

**6 レシピ**（D-13）— 全て `webif/` で cargo を実行：

```just
# justfile（リポジトリ直下、ht-mcp-sample/justfile）
# 全レシピは webif/ で cargo コマンドを叩く。
# 開発者は ht-mcp-sample/ から `just <recipe>` で起動。

set working-directory := 'webif'

# リリースビルド
build:
    cargo build --release

# 開発実行（dev profile、.env を webif/ または親で読む）
run:
    cargo run

# 全テスト（release profile、CI と合わせる — CONTEXT specifics line 160）
test:
    cargo test --release

# rustfmt 適用
fmt:
    cargo fmt --all

# clippy（all-targets + release + -D warnings、ROADMAP cross-cutting constraint）
clippy:
    cargo clippy --all-targets --release -- -D warnings

# ビルド成果物削除
clean:
    cargo clean
```

**D-14 の選択肢:** `set working-directory := 'webif'` を使う（上記）か、各レシピ内で `cd webif && cargo ...` を書くかは planner 裁量。前者の方が DRY だが、`just --list` の見た目が変わる。

**D-15:** `default` / `check` / `cov` / `watch` レシピは含めない（最小 6 本）。

**D-23:** CI から justfile を呼ばない。justfile はローカル用ショートカット専用。

---

### `.github/workflows/ci.yml`（新規）

**新規パターン:** `.github/` ディレクトリ自体が存在しない。GitHub Actions の標準慣行に従う。

**配置:** `/home/parallels/workspaces/ht-mcp-sample/.github/workflows/ci.yml`（D-16）。リポジトリ直下の `.github/` 配下。

**スケルトン**（D-17〜D-22 に従う）：

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  check:
    name: fmt + clippy + test
    runs-on: ubuntu-latest          # D-18: 単一 OS
    defaults:
      run:
        working-directory: webif    # D-22: 各 step で cd webif 省略
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust toolchain
        uses: actions-rust-lang/setup-rust-toolchain@v1    # D-19
        with:
          toolchain: stable
          components: rustfmt, clippy

      - name: Cache cargo build
        uses: Swatinem/rust-cache@v2                        # D-20
        with:
          workspaces: webif -> webif/target

      - name: cargo fmt --check
        run: cargo fmt --all -- --check

      - name: cargo clippy
        run: cargo clippy --all-targets --release -- -D warnings

      - name: cargo test
        run: cargo test --release
```

**直列実行の根拠**（D-21）: 単一 `check` ジョブで fmt → clippy → test を直列実行。小規模リポでは並列ジョブ化の setup オーバーヘッドが直列実行時間を上回る。

**`branches: [main]` の根拠**（D-17）: フォーク PR の duplicate run を避ける。

**Swatinem/rust-cache `workspaces:` 構文**（D-20）: `webif -> webif/target` は「webif/Cargo.lock を見て webif/target をキャッシュ」の意味。

**`cargo test --release` の根拠**（CONTEXT.md specifics line 160）: ROADMAP cross-cutting constraint（`cargo build --release` と `cargo clippy --all-targets --release -- -D warnings` warning 0）と CI ジョブのプロファイルを揃えて「dev profile では出ないが release で出る」事故を防ぐ。

---

## Shared Patterns（クロスカット）

### Async test attribute

**Source:** `.planning/codebase/TESTING.md` lines 66-67 で確立済み推奨
**Apply to:** すべての非同期テスト関数（mcp / turn / http の test mod）

```rust
#[tokio::test]
async fn xxx() { ... }
```

`tokio` は `features = ["full"]` 済みなので追加依存不要（CONTEXT.md "Established Patterns" line 134）。

---

### TempDir setup pattern

**Source:** `.planning/codebase/TESTING.md` lines 75-77, 132-141 forward-looking 推奨
**Apply to:** `turn.rs` / `http.rs` の test mod（filesystem を触るテスト全部）

```rust
use tempfile::tempdir;
let dir = tempdir().unwrap();
let path = dir.path();  // &Path
// dir が drop すると自動削除（teardown 不要）
```

`#[cfg(test)] mod tests { ... }` 内で `use tempfile::tempdir;` を都度 import。共有 helper は `webif/tests/common/mod.rs` には移さない（D-06 で統合テスト dir を作らない）。

---

### FakeMcp の構造体パターン

**Source:** `.planning/codebase/TESTING.md` lines 98-115 + D-07
**Apply to:** `worker.rs` テスト / `http.rs` テスト（trait Mcp のテストダブルが要る箇所すべて）

**定義位置:** `mcp.rs` の `#[cfg(test)] mod tests` 内（D-07）：
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    pub(crate) struct FakeMcp {
        pub create_session_replies: VecDeque<Result<String>>,
        pub snapshot_replies: VecDeque<Result<String>>,
        pub send_keys_log: Vec<(String, Vec<String>)>,
    }

    impl FakeMcp {
        pub(crate) fn new() -> Self {
            Self {
                create_session_replies: VecDeque::new(),
                snapshot_replies: VecDeque::new(),
                send_keys_log: Vec::new(),
            }
        }
    }

    #[async_trait]
    impl Mcp for FakeMcp { /* ... 各メソッドは VecDeque から pop_front */ }
}
```

**Apply 先からの参照:** `use crate::mcp::tests::FakeMcp;`（pub(crate) なので同一クレート内アクセス可）。

---

### `#[cfg(test)] mod tests` co-location 規約

**Source:** `.planning/codebase/TESTING.md` lines 39, 50-62 + `.planning/codebase/STRUCTURE.md` line 137 + D-06
**Apply to:** `mcp.rs` / `worker.rs` / `turn.rs` / `http.rs`

**配置:** 各モジュールファイル末尾に `#[cfg(test)] mod tests { use super::*; ... }`。`webif/tests/` 統合テストディレクトリは **作らない**（D-06）。

**命名:** test 関数は `snake_case`、シナリオ記述形式（例: `fn rejects_turn_id_with_path_traversal()`、`fn read_turn_marks_unknown_when_garbled()`）。

**理由:** lib/bin 分離済みで `pub(crate)` / `#[cfg(test)]` パターンが綺麗に使え、テスト用 helper の共有が容易。`cargo test` 1 発で全部走る。

---

### 日本語コメント + 英語識別子

**Source:** `.planning/codebase/CONVENTIONS.md` lines 41-52
**Apply to:** すべての新規ファイル（justfile / ci.yml はコメントが任意 / Cargo.toml は description 1 箇所だけ）

- justfile レシピのコメントは日本語可（`# リリースビルド` 等）
- ci.yml の `name:` や step 名は英語推奨（GitHub UI が英語前提）、コメントは日本語可
- Rust テストコード内 `//` コメントは日本語、`assert!` のメッセージも日本語可

---

### `pub(crate)` テスト可視性

**Source:** D-25 + `.planning/codebase/CONVENTIONS.md` lines 240-244
**Apply to:** `McpClient::from_streams` (`#[cfg(test)] pub`)、`FakeMcp` (`pub(crate)`)、`build_prompt_body` (現状 `pub`、変更不要)、`read_turn` (現状 `pub`)

「テスト時のみ」「同一クレート内のみ」に限定。本番 API は変えない。

---

## Files with No Analog（外部慣行に従う）

| File | Role | Reason | Reference |
|------|------|--------|-----------|
| `justfile` | task runner | リポジトリ内に既存タスクランナーなし | `just` 公式構文、CONTEXT.md D-12〜D-15 |
| `.github/workflows/ci.yml` | CI config | `.github/` 自体が未存在 | GitHub Actions 公式、`actions-rust-lang/setup-rust-toolchain@v1`、`Swatinem/rust-cache@v2`、CONTEXT.md D-16〜D-23 |

これらは planner が CONTEXT.md の D-12〜D-23 と本ファイル「新規パターン」セクションのスケルトンを直接コピーして組み立てる。

---

## Metadata

**Analog search scope:**
- `webif/src/*.rs`（全 6 ファイル: lib.rs, main.rs, config.rs, mcp.rs, worker.rs, turn.rs, http.rs）
- `webif/Cargo.toml`
- `.planning/codebase/{TESTING,STRUCTURE,CONVENTIONS}.md`（forward-looking 推奨を analog の代替として活用）
- リポジトリ直下（justfile / .github の不在確認）

**Files scanned:** 11
**Pattern extraction date:** 2026-05-25

**観察された強い慣行（Phase 2 で確立済み、Phase 3 が踏襲）:**
1. **モジュール分離は `turn → worker → mcp` の単方向依存** — trait Mcp 抽出はこの方向と一致（最下層 mcp.rs に trait、上層から `M: Mcp` で受け取る）
2. **`pub(crate)` と `pub` の使い分け** — lib/bin 越境のため pub、テスト用格上げは `#[cfg(test)] pub` で本番影響を出さない
3. **`anyhow::Result<T>` で内部統一**、HTTP 境界で `ise` ヘルパ経由 `(StatusCode, String)` 変換、テスト側は `.unwrap()` / `.expect("context")` でよい
4. **日英バイリンガル**：識別子英語 / コメント・ログ・エラーメッセージ日本語
5. **`#[derive(...)]` 多用、手書き impl は最小限**（serde / async_trait derive で繋ぐ）
