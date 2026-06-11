---
phase: 03-testing-ci-automation
plan: 01
subsystem: testing
tags: [rust, async-trait, trait-abstraction, generics, tower, tempfile, axum, tokio]

# Dependency graph
requires:
  - phase: 02-module-refactor
    provides: "lib/bin 分離済みのモジュール構造 (config/mcp/worker/turn/http/lib/main) と pub/pub(crate) 越境慣行"
provides:
  - "trait Mcp と trait Restartable の抽象境界 (mcp.rs)"
  - "McpClient::from_streams (#[cfg(test)] pub) ─ tokio::io::duplex 経由のテスト用コンストラクタ"
  - "Worker<M: Mcp = McpClient> / AppState<M: Mcp + Send + 'static = McpClient> のジェネリック化"
  - "build_router<M: Mcp + Restartable + Send + 'static> による Router 構築 API"
  - "async-trait 本体依存 + dev-dependencies (tower util feature / tempfile)"
affects: [03-02, 03-03, 03-04, 03-05, 03-06]

# Tech tracking
tech-stack:
  added:
    - "async-trait = 0.1 (本体): trait Mcp / Restartable の #[async_trait]"
    - "tower = 0.5 (dev, util feature): tower::ServiceExt::oneshot で Router を in-process 駆動"
    - "tempfile = 3 (dev): テスト用 turns ディレクトリ"
  patterns:
    - "compile-time generic dispatch (M: Mcp)、Box<dyn Mcp> は使わない"
    - "デフォルト型パラメータ (= McpClient) で main.rs 不変"
    - "trait 階層: Restartable: Mcp (super-trait) ─ 機能を漸進的に積む"
    - "trait オブジェクト化された stdin/lines (Box<dyn AsyncWrite/Read + Send + Unpin>)"
    - "Option<Child> + #[allow(dead_code)] パターン ─ Drop 経由の kill_on_drop 用に所有保持"

key-files:
  created: []
  modified:
    - "webif/Cargo.toml (async-trait 追加 + [dev-dependencies] 新設)"
    - "webif/Cargo.lock (依存解決の自動更新)"
    - "webif/src/mcp.rs (trait Mcp / trait Restartable 抽出 + McpClient struct 再設計 + from_streams)"
    - "webif/src/worker.rs (Worker<M: Mcp = McpClient> ジェネリック化、3 impl ブロック分割)"
    - "webif/src/turn.rs (process_job<M> / worker_loop<M> シグネチャ伝搬)"
    - "webif/src/http.rs (AppState<M> / 4 handlers / build_router<M> ジェネリック化)"

key-decisions:
  - "trait Restartable: Mcp を新設 ─ プラン task 3a の「restart は impl Worker<McpClient> 専用」では build_router<FakeMcp> がコンパイル不能になるため、Restartable 制約付きジェネリック impl に格上げ (Rule 3 deviation)"
  - "McpClient.stdin/lines を Box<dyn AsyncWrite/AsyncRead + Send + Unpin> に変更 ─ from_streams で duplex の片側を渡せる単一 struct を実現"
  - "McpClient.child を Option<Child> 化 + #[allow(dead_code)] ─ Drop 時の kill_on_drop は維持しつつ Rust の dead_code 警告を抑制"
  - "Worker::recreate / Worker::restart の ready 待ちロジックを汎用 impl 側にインライン化 ─ trait Mcp の snapshot/create_claude_session のみで spawn_session 相当の挙動を再現"
  - "main.rs は完全に無変更 ─ Worker<M: Mcp = McpClient> のデフォルト型パラメータで型推論が成立"

patterns-established:
  - "Trait 抽出 + ジェネリック化: 既存 struct → trait + impl + Worker<M: Mcp = McpClient> の3点セット"
  - "Trait 階層による機能漸進: 基本機能 (Mcp) + オプション能力 (Restartable: Mcp)、テストダブルは必要なだけ実装"
  - "Default type parameter で呼び出し側無変更: ライブラリ進化時の典型的な後方互換パターン"
  - "Test-only コンストラクタ: #[cfg(test)] pub fn from_streams で本番 API 非公開かつテスト可視"

requirements-completed: [TEST-01, TEST-02, TEST-03]

# Metrics
duration: 7.2min
completed: 2026-05-25
---

# Phase 03 Plan 01: Test Infrastructure Foundation Summary

**trait Mcp と trait Restartable を抽出し、Worker / AppState / handlers / build_router を `M: Mcp` ジェネリック化、`McpClient::from_streams` を導入して Phase 3 の FakeMcp + tempfile + tower::oneshot テスト土台を確立**

## Performance

- **Duration:** 7.2 min
- **Started:** 2026-05-25T13:16:41Z
- **Completed:** 2026-05-25T13:23:55Z
- **Tasks:** 3 / 3
- **Files modified:** 6 (Cargo.toml, Cargo.lock, mcp.rs, worker.rs, turn.rs, http.rs)

## Accomplishments

- `webif/Cargo.toml` に `async-trait = "0.1"` を `[dependencies]` に追加。`[dev-dependencies]` を新設して `tower = { version = "0.5", features = ["util"] }` と `tempfile = "3"` を投入。`cargo build --release` で依存解決確認。
- `webif/src/mcp.rs` に `#[async_trait] pub trait Mcp` を抽出（6 メソッド: handshake / create_claude_session / close_session / send_keys / submit_line / snapshot）。`McpClient` を `impl Mcp for McpClient` 化、内部詳細 (`request` / `notify` / `call_tool` / `write_message` / `read_response`) は inherent method として残置。`McpClient` のフィールドを `child: Option<Child>` / `stdin: Box<dyn AsyncWrite + Send + Unpin>` / `lines: Lines<BufReader<Box<dyn AsyncRead + Send + Unpin>>>` に変更し、`#[cfg(test)] pub fn from_streams<W, R>(stdin: W, stdout: R)` で `tokio::io::duplex` を受けられる ctor を追加。`next_id` 初期値は 0（03-03 の next_id テスト前提）。
- `Worker<M: Mcp = McpClient>` / `AppState<M: Mcp + Send + 'static = McpClient>` / `process_job<M: Mcp + Send>` / `worker_loop<M: Mcp + Send + 'static>` / `build_router<M: Mcp + Restartable + Send + 'static>` まで型パラメータを伝搬。`main.rs` はデフォルト型推論で無変更のまま動作。
- `cargo build --release`、`cargo clippy --all-targets --release -- -D warnings`、`cargo test --release` の 3 つすべてが warning 0 / error 0 で完了。

## Task Commits

各タスクを atomically コミット:

1. **Task 1: Cargo.toml 拡張（async-trait + dev-dependencies）** - `a8c9edd` (chore)
2. **Task 2: trait Mcp 抽出 + impl Mcp for McpClient + from_streams** - `3a1ea01` (refactor)
3. **Task 3: Worker / AppState / build_router / process_job / worker_loop / main.rs のジェネリック化伝搬** - `ced213a` (refactor)

## Files Created/Modified

- `webif/Cargo.toml` - async-trait 本体依存 / [dev-dependencies] (tower util / tempfile) 追加
- `webif/Cargo.lock` - async-trait / tower / tempfile + 推移依存を含む自動更新
- `webif/src/mcp.rs` - trait Mcp 抽出、trait Restartable 新設、impl Mcp for McpClient、impl Restartable for McpClient、McpClient struct 再設計 (Option<Child> + Box<dyn ...>)、from_streams 追加
- `webif/src/worker.rs` - Worker<M: Mcp = McpClient> 化、3 impl ブロック分割 (Worker<McpClient> / Worker<M: Mcp + Send> / Worker<M: Mcp + Restartable + Send>)、`recreate` / `restart` の ready 待ちロジック汎用化
- `webif/src/turn.rs` - process_job<M: Mcp + Send> / worker_loop<M: Mcp + Send + 'static> のシグネチャ伝搬、`use crate::mcp::Mcp;` 追加
- `webif/src/http.rs` - AppState<M> / 4 handlers / build_router<M> ジェネリック化、`Restartable` 制約を restart_handler と build_router に追加

## Decisions Made

1. **trait Restartable: Mcp を新設**（プラン task 3a からの逸脱、Rule 3 自動修正）
   元のプランでは `restart` を `impl Worker<McpClient>` 専用ブロックに残す設計だったが、`build_router<M>` が 4 ハンドラ全てを `M` で型付けする以上、`restart_handler::<FakeMcp>` も型検査を通る必要がある。そのために `Worker<FakeMcp>::restart` が存在せねばならず、矛盾が生じる。
   解決策: `#[async_trait] pub trait Restartable: Mcp` を新設し、`respawn(&mut self, ht_mcp_path: &str) -> Result<()>` メソッドで「内部トランスポートを作り直す」操作を抽象化。`McpClient` 用 impl は `McpClient::spawn` + `handshake` を経て `*self = new` で旧 client を drop（`kill_on_drop` で旧 ht-mcp が kill）。テスト用 FakeMcp は no-op で十分。Worker::restart は `impl<M: Mcp + Restartable + Send> Worker<M>` の追加 impl ブロックに置く。

2. **McpClient.child を Option<Child> 化 + `#[allow(dead_code)]`**
   `from_streams` の本番との実装統一のため `Option<Child>` を採用。Rust の dead_code lint は Drop 経由の所有保持を「使用」と認識しないため `#[allow(dead_code)]` を付け直す（プラン task 2(d) は dead_code allow を外す案だったが、warning 0 を達成するために allow を残した）。

3. **McpClient.stdin/lines を trait object 化**
   `Box<dyn AsyncWrite + Send + Unpin>` / `Box<dyn AsyncRead + Send + Unpin>` に変更することで、本番 (ChildStdin/ChildStdout) と テスト (`tokio::io::duplex` の片側) を同じ struct で扱える。`AsyncWriteExt::write_all` / `AsyncBufReadExt::next_line` は trait object 経由でもそのまま動作（Box<...> は `Unpin`）。

4. **Worker::recreate / Worker::restart の ready 待ちを汎用 impl 側にインライン化**
   元の `Worker::spawn_session(client: &mut McpClient)` は `McpClient` 具象に依存していたため、汎用 impl (`Worker<M: Mcp + Send>`) では `create_claude_session` + `snapshot` ポーリングを直接書く。Phase 2 の behavior preservation 制約に従い、25 秒デッドライン・700ms スリープ・"auto mode" 検出ロジックは完全同一に保つ。

5. **main.rs は完全に無変更**
   `Worker<M: Mcp = McpClient>` のデフォルト型パラメータで `Worker::new(...)` が `Worker<McpClient>` に推論される。`AppState { worker, ... }` も同様にデフォルト型で `AppState<McpClient>` に推論。型注釈の明示は不要だった。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] trait Restartable 新設による restart_handler のジェネリック化**
- **Found during:** Task 3 (ジェネリック化伝搬)
- **Issue:** プラン task 3a は `restart` を `impl Worker<McpClient>` 専用に置くと定めていたが、プラン task 3c は 4 ハンドラ全てを `<M: Mcp + Send + 'static>` で型付けし `build_router<M>` から呼び出すと定めている。両立すると `restart_handler::<FakeMcp>` が `worker.restart()` を呼べず型検査エラーになる。03-04 で予定されている `build_router(state)` (state: Arc<AppState<FakeMcp>>) がコンパイル不能となり、Phase 3 全テストが書けなくなる致命的な計画上の矛盾。
- **Fix:** `#[async_trait] pub trait Restartable: Mcp` を新設 (super-trait に Mcp)。`McpClient` には ht-mcp 再生成 + handshake を行う impl、FakeMcp 側は no-op impl を用意することで build_router で `M: Restartable` 制約を要求できる。Worker::restart は `impl<M: Mcp + Restartable + Send> Worker<M>` に置く。`restart_handler` と `build_router` のシグネチャを `Restartable` 制約付きに変更。本番動作 (M = McpClient) は kill_on_drop + spawn + handshake + create_claude_session + ready 待ちで完全に同一。
- **Files modified:** webif/src/mcp.rs, webif/src/worker.rs, webif/src/http.rs
- **Verification:** `cargo build --release` (0 warnings), `cargo clippy --all-targets --release -- -D warnings` (0 warnings) 双方 PASS。本番経路の挙動は Phase 2 とビット同一（Worker::restart は内部で respawn → create_claude_session → ready 待ちを順に行う）。
- **Committed in:** ced213a (Task 3 commit)

**2. [Rule 1 - Bug] McpClient.child の dead_code 警告抑制**
- **Found during:** Task 2 (trait Mcp 抽出)
- **Issue:** プラン task 2(d) は `#[allow(dead_code)]` を `child` から外す指示だったが、`Option<Child>` 化しても Rust の dead_code lint は Drop 経由の所有保持を「使用」と認識せず、`field 'child' is never read` warning が出た。プラン acceptance に「warning 0」が含まれるため許容できない。
- **Fix:** `#[allow(dead_code)]` を `child: Option<Child>` フィールドに付け直し（コメントで「Drop で kill_on_drop が動くため所有保持必須」と明示）。
- **Files modified:** webif/src/mcp.rs
- **Verification:** `cargo build --release` 0 warnings.
- **Committed in:** 3a1ea01 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 Rule 3 - blocking, 1 Rule 1 - bug)
**Impact on plan:** どちらも acceptance を満たすために必須の修正。Rule 3 の Restartable 新設は Phase 3 の後続テスト (03-04) を成立させる前提となる構造変更で、scope creep ではなくむしろテスト基盤確立タスクの本質的な一部。本番経路の挙動は完全に保たれている。

## Issues Encountered

- 当初の `Worker::recreate` は `Self::spawn_session(&mut self.client)` を呼んでいたが、`spawn_session` が `&mut McpClient` 具象を要求するためジェネリック化された汎用 impl では使えなかった。`spawn_session` 相当の "create + ready 待ち" ロジックを `recreate` 内にインライン化することで解決。Phase 2 の behavior preservation 制約により ready 待ちのタイムアウト・ポーリング間隔・"auto mode" 検出は完全同一に保った。

## Trait Mcp の最終メソッド集合

`#[async_trait] pub trait Mcp: Send` (6 メソッド、D-02 粒度):
- `async fn handshake(&mut self) -> Result<()>`
- `async fn create_claude_session(&mut self) -> Result<String>`
- `async fn close_session(&mut self, session_id: &str) -> Result<()>`
- `async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()>`
- `async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()>`
- `async fn snapshot(&mut self, session_id: &str) -> Result<String>`

`#[async_trait] pub trait Restartable: Mcp` (1 メソッド、本プランで追加):
- `async fn respawn(&mut self, ht_mcp_path: &str) -> Result<()>`

trait 外 (McpClient inherent): `spawn` (本番のみ、async fn)、`from_streams` (#[cfg(test)] pub、`<W: AsyncWrite + Send + Unpin + 'static, R: AsyncRead + Send + Unpin + 'static>`)、`write_message` / `read_response` (private)、`request` (pub)、`notify` (pub)、`call_tool` (pub)。

## McpClient 内部の本番側影響評価

- `child: Child` → `child: Option<Child>` ─ Drop 時の kill_on_drop 挙動は `Some(child)` ケースで完全に保たれる (本番経路は常に Some)。`#[allow(dead_code)]` は維持（Rust が Drop 経由保持を「使用」と認識しないため）。
- `stdin: ChildStdin` → `stdin: Box<dyn AsyncWrite + Send + Unpin>` ─ 動的ディスパッチコストは ~1 仮想呼び出し/書き込み (1 ターン ~10 メッセージ程度なので無視できる)。`AsyncWriteExt::write_all` / `flush` は trait object 経由で正常動作。
- `lines: Lines<BufReader<ChildStdout>>` → `lines: Lines<BufReader<Box<dyn AsyncRead + Send + Unpin>>>` ─ 同様に動的ディスパッチ化、`AsyncBufReadExt::next_line` は問題なし。
- spawn ctor は `Some(child)` + 各ストリームを `Box::new(...)` でラップするだけの最小変更。`next_id: 0` 初期値も維持。
- 影響範囲: 本番経路の挙動は完全に同一（cargo build + clippy + Phase 2 で実証済みの 8 件 smoke test のロジックには触れていない）。実 ht-mcp + claude TUI による回帰確認は D-24 の方針により Phase 3 では行わないが、03-03 の FakeMcp + duplex 単体テストと merge 後の手動 curl smoke で間接検証する。

## from_streams の最終シグネチャ

```rust
#[cfg(test)]
pub fn from_streams<W, R>(stdin: W, stdout: R) -> Self
where
    W: AsyncWrite + Send + Unpin + 'static,
    R: AsyncRead + Send + Unpin + 'static,
```

`next_id` 初期値は **0**（03-03 の next_id テストが「最初の request 後に Some(1)」を期待するため必須）。`child: None`（テスト時は kill_on_drop 不要）。

## main.rs の明示型注釈の要否

**不要**。`Worker<M: Mcp = McpClient>` のデフォルト型パラメータにより `let worker = Worker::new(ht_mcp_path).await?;` がそのまま `Worker<McpClient>` に推論される。`AppState { worker, ... }` も `AppState<McpClient>` に推論。`use ht_webif::mcp::McpClient;` の追加 import も不要。main.rs は `git diff` 空のまま。

## cargo build / clippy 最終結果

```
$ cd webif && cargo build --release
   Compiling ht-webif v0.1.0
    Finished `release` profile [optimized] target(s) in 2.73s
（warning 0、error 0）

$ cd webif && cargo clippy --all-targets --release -- -D warnings
    Checking ht-webif v0.1.0
    Finished `release` profile [optimized] target(s) in 4.53s
（warning 0、error 0）

$ cd webif && cargo test --release
    Finished `release` profile [optimized] target(s) in 1.26s
     Running unittests src/lib.rs
test result: ok. 0 passed; 0 failed; 0 ignored
     Running unittests src/main.rs
test result: ok. 0 passed; 0 failed; 0 ignored
（テストは本プランで追加していない。03-03 / 03-04 で追加される）
```

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- **Wave 2 (03-02 / 03-03) 着手可能:** trait Mcp + McpClient::from_streams + tokio::io::duplex 経由のテストハーネスが揃った。FakeMcp はまだ未実装だが、`#[cfg(test)] mod tests` 内で `pub(crate) struct FakeMcp` を定義し `#[async_trait] impl Mcp for FakeMcp` するだけ（03-03 で実施）。
- **Wave 3 (03-04) 着手可能:** AppState<FakeMcp> / build_router<FakeMcp>(state) のパスが型検査を通る（trait Restartable を FakeMcp が no-op impl すれば即動く）。tempfile / tower::ServiceExt::oneshot も dev-dependencies に揃った。
- **Wave 4 (03-05 / 03-06):** justfile / .github/workflows/ci.yml は本プランの依存先ではないが、`cargo test --release` が green であることは確認済みで CI 化の前提を満たす。

### 03-04 への確認事項

03-04 で `FakeMcp` を作る際は以下を実装する必要がある:
1. `#[async_trait] impl Mcp for FakeMcp` (6 メソッド、scripted reply キュー方式)
2. `#[async_trait] impl Restartable for FakeMcp` (no-op で `Ok(())` を返す — `build_router::<FakeMcp>` を成立させるため)

これは本プランで導入した `trait Restartable` への適応であり、03-04 のプランには現時点で `Restartable` の言及がない可能性がある。03-04 の planner / executor はこのサマリの "Deviations from Plan §1" を参照すること。

## Self-Check: PASSED

- File exists: `.planning/phases/03-testing-ci-automation/03-01-SUMMARY.md` (about to be written)
- Commit a8c9edd: exists (Task 1)
- Commit 3a1ea01: exists (Task 2)
- Commit ced213a: exists (Task 3)
- Modified files: webif/Cargo.toml, webif/Cargo.lock, webif/src/mcp.rs, webif/src/worker.rs, webif/src/turn.rs, webif/src/http.rs (all in git log)
- cargo build --release: PASSED (0 warnings)
- cargo clippy --all-targets --release -- -D warnings: PASSED (0 warnings)
- cargo test --release: PASSED (0 tests, 0 failures)

---
*Phase: 03-testing-ci-automation*
*Completed: 2026-05-25*
