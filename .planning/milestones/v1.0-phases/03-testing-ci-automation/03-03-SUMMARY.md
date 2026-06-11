---
phase: 03-testing-ci-automation
plan: 03
subsystem: testing
tags: [rust, tokio-test, tokio-io-duplex, async-trait, test-double, mcp, json-rpc, hermetic-test]

# Dependency graph
requires:
  - phase: 03-testing-ci-automation
    plan: 01
    provides: "trait Mcp + trait Restartable + McpClient::from_streams<W,R>(stdin, stdout) (#[cfg(test)] pub, next_id:0 init)、async-trait 本体依存、tokio (full features) で tokio::io::duplex 利用可"
provides:
  - "webif/src/mcp.rs 末尾の #[cfg(test)] pub(crate) mod tests ─ FakeMcp + Mcp/Restartable impl + 3 本の MCP request 単体テスト"
  - "pub(crate) struct FakeMcp (scripted reply VecDeque + 呼び出しログ Vec) ─ Wave 3 の http テストから use crate::mcp::tests::FakeMcp; で参照可能"
  - "tokio::io::duplex(1024) を 2 組使った in-memory MCP テストハーネスパターン (make_client_and_harness ヘルパ)"
affects: [03-04, 03-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "hermetic MCP test: tokio::io::duplex を 2 組 + McpClient::from_streams + tokio::spawn(client_task) + harness 側で read_line → write_response → join のシリアル化"
    - "scripted reply test double: VecDeque<Result<T>> を pop_front、空ならエラー"
    - "pub(crate) mod tests による cross-module test 共有 (FakeMcp を mcp::tests から worker/turn/http の test mod に提供)"
    - "#[allow(dead_code)] を FakeMcp 本体に付与 ─ 本プラン (03-03) では自モジュール内で未使用、Wave 3 で消費される future-consumer 構造体"

key-files:
  created: []
  modified:
    - "webif/src/mcp.rs (末尾に #[cfg(test)] pub(crate) mod tests を新規追加: FakeMcp struct + new() + impl Mcp for FakeMcp (6 メソッド) + impl Restartable for FakeMcp (no-op) + make_client_and_harness ヘルパ + 3 #[tokio::test] 関数、計 284 行追加)"

key-decisions:
  - "pub(crate) mod tests に格上げ ─ mod tests 自体を pub(crate) にしないと Wave 3 (Plan 03-04) の http.rs の test mod から use crate::mcp::tests::FakeMcp; がプライバシエラー (E0603) で参照不可。当初プランは mod tests のままだったが、これでは pub(crate) struct FakeMcp の effective visibility が private になる"
  - "make_client_and_harness ヘルパで duplex 2 組のセットアップを集約 ─ 3 テスト全てで同形のセットアップが必要なため (DRY)、戻り値は (client, BufReader<DuplexStream> 読み側, DuplexStream 書き側) のタプル"
  - "next_id_increments_per_request は 2 回の request を 1 タスク内で連続発火 ─ Mutex 不要、harness 側で read_line→write_response を 2 round 順次回す"
  - "FakeMcp + 全 impl に #[allow(dead_code)] 付与 ─ 本プランの 3 テストは McpClient のみ使用、FakeMcp は Wave 3 で初めて消費される。clippy --release -D warnings をパスするため必要"
  - "テスト用擬似応答の JSON は format! で直書き ─ serde_json::to_string ラウンドトリップは応答書き出しのテスト対象ではないため不要、format! の方が JSON 構造が一目でわかる"

patterns-established:
  - "Hermetic transport test: spawn 不要、duplex 2 組で writer/reader を交差させて McpClient を作る"
  - "client_task tokio::spawn + tokio::time::timeout(5s) で読み書きのデッドロック検知"
  - "future-consumer struct: 同一プランの自テストでは使わないが、後続プランで消費される pub(crate) struct には #[allow(dead_code)] を付ける"

requirements-completed: [TEST-02]

# Metrics
duration: 2.4min
completed: 2026-05-25
---

# Phase 03 Plan 03: MCP Client Unit Tests Summary

**`webif/src/mcp.rs` 末尾に `#[cfg(test)] pub(crate) mod tests` を新設。`FakeMcp` (scripted reply test double + Mcp/Restartable 実装) と、`tokio::io::duplex` 経由で `McpClient::request` の JSON-RPC envelope / `next_id` インクリメント / `result` 抽出を検証する 3 本の hermetic 単体テストを追加。`cargo test --release` で 8 passed (5 turn + 3 mcp)、clippy warning 0。**

## Performance

- **Duration:** 2.4 min
- **Started:** 2026-05-25T13:33:45Z
- **Completed:** 2026-05-25T13:36:10Z
- **Tasks:** 2 / 2
- **Files modified:** 1 (`webif/src/mcp.rs`)

## Accomplishments

- `webif/src/mcp.rs` 末尾に `#[cfg(test)] pub(crate) mod tests { ... }` ブロックを新規追加 (合計 284 行)。
- `pub(crate) struct FakeMcp` を定義 (6 フィールド: `handshake_calls: u32`, `create_session_replies: VecDeque<Result<String>>`, `close_session_log: Vec<String>`, `send_keys_log: Vec<(String, Vec<String>)>`, `submit_line_log: Vec<(String, String)>`, `snapshot_replies: VecDeque<Result<String>>`)。
- `impl FakeMcp { pub(crate) fn new() -> Self }` (全フィールド空初期化)。
- `#[async_trait] impl Mcp for FakeMcp` (6 メソッド: scripted reply キューから `pop_front` または呼び出しログに `push`)。
- `#[async_trait] impl Restartable for FakeMcp` (no-op、`handshake_calls += 1` のみ — Wave 3 の `build_router::<FakeMcp>` 成立用)。
- `make_client_and_harness()` ヘルパ — `tokio::io::duplex(1024)` を 2 組作り `McpClient::from_streams` 経由で `(client, BufReader<DuplexStream>, DuplexStream)` のタプルを返す。
- 3 本の `#[tokio::test]`:
  1. `request_builds_jsonrpc_envelope_with_method_and_params`
  2. `next_id_increments_per_request`
  3. `request_extracts_result_from_response`
- `cd webif && cargo test --release` で **8 passed; 0 failed; 0 ignored** (5 turn + 3 mcp)。
- `cd webif && cargo clippy --all-targets --release -- -D warnings` exit 0、warning 0。
- 依存追加なし、`webif/tests/` 統合テスト dir 未作成 (D-06 遵守)。

## Task Commits

各タスクを atomically コミット:

1. **Task 1: FakeMcp 定義 (pub(crate)、scripted reply queue、Mcp + Restartable 実装)** - `49d9d95` (test)
2. **Task 2: McpClient::request の JSON-RPC envelope と next_id 単体テスト 3 本** - `2c655cd` (test)

## Files Created/Modified

- `webif/src/mcp.rs` - 末尾に `// ── テスト ─...` セパレータコメント + `#[cfg(test)] pub(crate) mod tests { use super::*; use std::collections::VecDeque; use tokio::io::{duplex, AsyncBufReadExt, AsyncWriteExt, BufReader}; ... }` ブロックを追加。本体 (lines 1-239) は完全に無変更。

## 追加した FakeMcp の最終フィールド集合

```rust
#[allow(dead_code)]
pub(crate) struct FakeMcp {
    pub handshake_calls: u32,
    pub create_session_replies: VecDeque<Result<String>>,
    pub close_session_log: Vec<String>,
    pub send_keys_log: Vec<(String, Vec<String>)>,
    pub submit_line_log: Vec<(String, String)>,
    pub snapshot_replies: VecDeque<Result<String>>,
}
```

| フィールド | 型 | 用途 | trait メソッドからの操作 |
|---|---|---|---|
| `handshake_calls` | `u32` | 呼び出し回数カウンタ | `handshake()` で `+= 1`、`respawn()` で `+= 1` (no-op respawn) |
| `create_session_replies` | `VecDeque<Result<String>>` | scripted reply キュー | `create_claude_session()` で `pop_front` |
| `close_session_log` | `Vec<String>` | session_id 呼び出しログ | `close_session(session_id)` で `push(session_id.to_string())` |
| `send_keys_log` | `Vec<(String, Vec<String>)>` | (session_id, keys) ペアログ | `send_keys(session_id, keys)` で `push((sid, keys.to_vec()))` |
| `submit_line_log` | `Vec<(String, String)>` | (session_id, text) ペアログ | `submit_line(session_id, text)` で `push((sid, text.to_string()))` |
| `snapshot_replies` | `VecDeque<Result<String>>` | scripted reply キュー | `snapshot()` で `pop_front` |

`impl FakeMcp::new()` で全フィールドを `VecDeque::new() / Vec::new() / 0` で初期化。テスト側は `let mut fake = FakeMcp::new();` の後に `fake.create_session_replies.push_back(Ok("sid-1".into()));` 等で scripted reply を仕込む想定。

## 追加した MCP request テスト 3 本の名前

| # | テスト関数名 | 種別 | 検証対象 |
|---|---|---|---|
| 1 | `request_builds_jsonrpc_envelope_with_method_and_params` | `#[tokio::test]` | `request("tools/call", json!({"name":"ht_take_snapshot"}))` が書き出す JSON 行に `jsonrpc:"2.0"` / `id` (i64) / `method:"tools/call"` / `params.name:"ht_take_snapshot"` が全て揃うこと |
| 2 | `next_id_increments_per_request` | `#[tokio::test]` | `from_streams` 経由の `McpClient` で 1 回目 `id=1`、2 回目 `id=2`、`id2 == id1 + 1` (next_id 初期値 0 の前提を実証) |
| 3 | `request_extracts_result_from_response` | `#[tokio::test]` | 擬似応答 `{"jsonrpc":"2.0","id":N,"result":{"foo":"bar"}}` を書き戻したとき、`request().await?` の戻り値が `{"foo":"bar"}` の clone (`v["foo"] == "bar"`) であること |

3 本全て `tokio::time::timeout(Duration::from_secs(5), ...)` で各 await をラップ、harness 側のデッドロックを 5 秒で検知できる安全策付き。

## `McpClient::from_streams` のシグネチャと Plan 03-01 整合性

Plan 03-01 で確定したシグネチャ:

```rust
#[cfg(test)]
pub fn from_streams<W, R>(stdin: W, stdout: R) -> Self
where
    W: AsyncWrite + Send + Unpin + 'static,
    R: AsyncRead + Send + Unpin + 'static,
```

**確認結果: `<W, R>` 直渡しで本プランのテストが書けた。Box 化は不要。**

`tokio::io::duplex(1024)` は `(DuplexStream, DuplexStream)` を返し、`DuplexStream` は `AsyncRead + AsyncWrite + Send + Unpin` を満たす。`'static` バウンドも `DuplexStream` 自体が non-borrowing なので満たす。よって `make_client_and_harness` は以下のように書けた:

```rust
fn make_client_and_harness() -> (McpClient, BufReader<tokio::io::DuplexStream>, tokio::io::DuplexStream) {
    let (client_stdin, test_reads) = duplex(1024);    // client が書く → test が読む
    let (test_writes, client_stdout) = duplex(1024);  // test が書く → client が読む
    let client = McpClient::from_streams(client_stdin, client_stdout);
    (client, BufReader::new(test_reads), test_writes)
}
```

Plan 03-01 でシグネチャを `<W, R>` ジェネリック + `'static` バウンド付きにしておいた判断が、本プランで Box 化のボイラープレートを不要にした。さらに `next_id: 0` 初期化の契約 (Plan 03-01 acceptance) も `next_id_increments_per_request` テストで `id1 == 1` の assertion により実証された。

## `cargo test --release` の最終結果

```
$ cd webif && cargo test --release
   Compiling ht-webif v0.1.0 (/home/parallels/workspaces/ht-mcp-sample/webif)
    Finished `release` profile [optimized] target(s) in 0.70s
     Running unittests src/lib.rs (target/release/deps/ht_webif-948c5992343616ee)

running 8 tests
test turn::tests::build_prompt_body_includes_task_and_paths ... ok
test mcp::tests::request_builds_jsonrpc_envelope_with_method_and_params ... ok
test mcp::tests::request_extracts_result_from_response ... ok
test mcp::tests::next_id_increments_per_request ... ok
test turn::tests::turn_id_formatter_matches_expected_shape ... ok
test turn::tests::read_turn_marks_unknown_when_status_garbled ... ok
test turn::tests::read_turn_returns_empty_result_when_result_file_missing ... ok
test turn::tests::read_turn_returns_done_when_status_complete ... ok

test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/main.rs (target/release/deps/ht_webif-af71d3a66d9cbdc1)

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests ht_webif

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

**`cargo clippy --all-targets --release -- -D warnings`** も exit 0、warning 0 を確認済み。テストカウントが Plan 03-02 完了時点の 5 から 8 に増えた (mcp::tests:: の 3 本追加分)。

## Decisions Made

1. **`pub(crate) mod tests` への格上げ**
   元のプラン action 注 ((d)) は `#[cfg(test)] mod tests` を `mcp.rs` の末尾に置くと指定していたが、`mod tests` 自体をデフォルトの private のままにすると、Wave 3 で `http.rs` の test mod が `use crate::mcp::tests::FakeMcp;` を書いた瞬間 Rust の privacy rule で `tests` モジュール自体が見えず E0603 になる。`#[cfg(test)] pub(crate) mod tests` に格上げすれば、`#[cfg(test)]` の cfg ガードは保ちつつ同一クレートの他モジュールの test mod (これも `#[cfg(test)]` 配下) から参照できる。本プランは 03-04 で消費される FakeMcp の供給源も兼ねるため、本決定はその準備として必要。

2. **`make_client_and_harness()` ヘルパで duplex セットアップを集約**
   3 テスト全てが「duplex 2 組作って `McpClient::from_streams` に渡す」同形のセットアップを必要としたため、DRY 原則でヘルパ化。戻り値はタプル `(McpClient, BufReader<DuplexStream>, DuplexStream)` で、それぞれ「テスト対象クライアント」「client の stdout 書き込みを読む harness 側 reader (BufReader 済みで `read_line` 即利用可)」「client の stdin に書き戻す harness 側 writer」の役割。

3. **`next_id_increments_per_request` を 1 タスク内 2 連続 request 構成にした**
   Mutex で client を共有する案 / 都度新 client を作る案も検討したが、最も簡潔なのは「`tokio::spawn` した client_task 内で `request` を 2 回連続呼び、harness 側は 2 round の read_line → write_response を順次実行」だった。client_task の戻り値は `(Result, Result)` のタプルで両 result を unwrap。

4. **`FakeMcp` 本体に `#[allow(dead_code)]` 付与**
   本プランの 3 テストはすべて `McpClient` (本体) のみ使用し、`FakeMcp` は使わない (使うのは Wave 3 の 03-04)。`cargo clippy --release -- -D warnings` をパスするために `#[allow(dead_code)]` を `pub(crate) struct FakeMcp` 本体と `pub(crate) fn new()` の 2 箇所に付与。Plan 03-01 で `McpClient.child: Option<Child>` に同じ理由で `#[allow(dead_code)]` を付けたパターンと整合。

5. **擬似応答 JSON を `format!` で直書きに**
   `serde_json::to_string(&json!({...}))` でラウンドトリップする案も検討したが、本テストの focus は「client が書く JSON envelope の検証」と「応答 result の抽出」であり、harness 側の応答書き出し自体は焦点外。`format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"foo\":\"bar\"}}}}\n")` の方が JSON 構造が一目でわかり、エスケープも 1 箇所で済む。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `mod tests` を `pub(crate) mod tests` に格上げ**
- **Found during:** Task 1 (FakeMcp 定義)
- **Issue:** プラン action 注 (line 140) は「`use crate::mcp::tests::FakeMcp;` は同一クレート内の他モジュールの test mod から参照する場合に有効」と述べているが、Rust の privacy rule で `mod tests` 自体がデフォルト private なため、`pub(crate) struct FakeMcp` を中に置いても **`crate::mcp::tests` モジュール自体が見えない** ためアクセス不可 (E0603)。Plan 03-04 で `http::tests` から `use crate::mcp::tests::FakeMcp;` を書く瞬間に compile error になる。本プランの 2 タスクは現時点では自モジュール内テストしか書かないため、放置するとデグレを Wave 3 まで持ち越す。
- **Fix:** `mod tests` を `pub(crate) mod tests` に変更。これにより `#[cfg(test)]` cfg ガードを保ったまま、同一クレート内の他モジュール test mod (これも `#[cfg(test)]` 配下) から `tests::FakeMcp` を参照可能になる。本プラン自体には影響なし (本プラン内テストは `mcp::tests` の内側からアクセスするため privacy 関係ない)。
- **Files modified:** `webif/src/mcp.rs` (l. 242 を `#[cfg(test)] mod tests` → `#[cfg(test)] pub(crate) mod tests` に変更)
- **Verification:** `cargo build --tests --release` で warning 0 / error 0、Wave 3 で `use crate::mcp::tests::FakeMcp;` が書ける構造に。
- **Committed in:** `49d9d95` (Task 1 commit)

**2. [Rule 1 - Bug / Rule 2 - Critical] `FakeMcp` 本体に `#[allow(dead_code)]`**
- **Found during:** Task 1 verification (`cargo build --tests --release`)
- **Issue:** 本プランの 3 テストは `McpClient` のみ使用し、`FakeMcp` は Wave 3 (Plan 03-04) で初めて消費される。そのため本プラン完了時点では `FakeMcp` struct と `new` メソッドが unused とみなされ、`warning: struct 'FakeMcp' is never constructed` と `warning: associated function 'new' is never used` が 2 件発生。`cargo clippy --release -D warnings` をパスできない (acceptance violation)。
- **Fix:** `pub(crate) struct FakeMcp` 本体と `pub(crate) fn new()` の双方に `#[allow(dead_code)]` を付与。コメントで「本プラン (03-03) では自モジュール内で未使用、Wave 3 で消費される」旨を明示。Plan 03-01 で `McpClient.child: Option<Child>` に同じ理由で allow を付けた前例と整合。
- **Files modified:** `webif/src/mcp.rs` (FakeMcp struct definition と `impl FakeMcp::new()` に attribute 追加)
- **Verification:** `cargo clippy --all-targets --release -- -D warnings` exit 0、warning 0。
- **Committed in:** `49d9d95` (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (1 Rule 3 - blocking, 1 Rule 2 - clippy warning gate)
**Impact on plan:** どちらも acceptance を満たすために必須の修正。Rule 3 の `pub(crate) mod tests` は Wave 3 (03-04) を成立させる前提となる privacy 調整で、CONTEXT D-07 の意図 (FakeMcp を `pub(crate)` で同一クレートに公開) を Rust の privacy rule 上で実際に成立させるための tweak。本番経路の挙動は完全に保たれている (本体 lines 1-239 は無変更)。

## Issues Encountered

- 初回 `cargo build --tests --release` で `FakeMcp` 関連の dead_code warning が 2 件発生 (上記 deviation 2)。`#[allow(dead_code)]` 付与で解消。
- `next_id_increments_per_request` の構造を検討する際、当初 client を `Arc<Mutex<...>>` で共有する案を考えたが、async fn の `&mut self` 借用と Mutex guard を across `.await` で持つ煩雑さを避けるため、1 タスク内 2 連続 request 構成に変更。harness 側が 2 round の read_line → write_response を順次回す形が最も読みやすかった。

## Threat Flags

None - 本プランで追加したのは `#[cfg(test)]` 配下の test mod と FakeMcp テストダブルのみで、本番経路 (`McpClient::spawn` / `request` / `handshake` 等) には一切手を入れていない。新たなネットワークエンドポイント、auth path、ファイルアクセスパターン、trust boundary でのスキーマ変更は導入していない。`tokio::io::duplex` は in-memory 専用で外部 I/O を発生させない。

## Known Stubs

None - FakeMcp は `pub(crate)` テストダブルとして意図的に scripted reply 方式で実装されており、Wave 3 (Plan 03-04) で http テストから消費される設計。本プランの 3 テストは FakeMcp 不使用 (McpClient + duplex のみ) で完結しており、stub ではなく future-consumer interface。

## Verification Coverage (TEST-02)

PLAN.md `<verification>` の 5 観点をすべて満たす:

1. **JSON-RPC envelope の jsonrpc / id / method / params フィールド組み立て** → `request_builds_jsonrpc_envelope_with_method_and_params` で `parsed["jsonrpc"]`, `parsed["id"]`, `parsed["method"]`, `parsed["params"]["name"]` の 5 assertion ✓
2. **`next_id` が呼出ごとに +1 される (初期 0 → 1 → 2)** → `next_id_increments_per_request` で `id1==1`, `id2==2`, `id2==id1+1` の 3 assertion ✓
3. **応答 JSON の `result` フィールドが request の戻り値として返される** → `request_extracts_result_from_response` で `v["foo"] == "bar"` assertion ✓
4. **FakeMcp の用意 (Wave 3 で消費)** → `pub(crate) struct FakeMcp` + `impl Mcp` + `impl Restartable` を `#[cfg(test)] pub(crate) mod tests` 内に定義、`use crate::mcp::tests::FakeMcp;` で参照可能 ✓
5. **`cargo test --release` / `cargo clippy --release -D warnings` がパス** → 8 passed / 0 failed / 0 warnings ✓

検証コマンド実行結果:

| コマンド | 結果 |
|---|---|
| `cd webif && cargo test --release` | `test result: ok. 8 passed; 0 failed; 0 ignored` |
| `cd webif && cargo clippy --all-targets --release -- -D warnings` | exit 0、warning 0 |
| `grep -c 'pub(crate) struct FakeMcp' webif/src/mcp.rs` | `1` |
| `grep -c 'impl Mcp for FakeMcp' webif/src/mcp.rs` | `1` |
| `grep -c 'impl Restartable for FakeMcp' webif/src/mcp.rs` | `1` |
| `grep -c 'use tokio::io::{duplex' webif/src/mcp.rs` | `1` |
| `grep -c '#\[tokio::test\]' webif/src/mcp.rs` | `3` |

## User Setup Required

None - external configuration / credentials は不要。`cargo test --release` を実行できる環境さえあれば誰でも全テストを再現できる。`tokio::io::duplex` は in-memory なので ht-mcp / claude バイナリも不要。

## Next Phase Readiness

- **Wave 2 完了 (03-02 sibling と本プラン 03-03)** Wave 2 の 2 プランがどちらも green。`webif/src/turn.rs` (5 tests) と `webif/src/mcp.rs` (3 tests) の test mod が確立、`cargo test --release` 全 8 passed。
- **Wave 3 (03-04 http.rs テスト) 着手可能:** 本プランで導入した `pub(crate) mod tests` + `pub(crate) struct FakeMcp` (with `Mcp` + `Restartable` 両 impl) により、`http.rs` の test mod から `use crate::mcp::tests::FakeMcp;` でテストダブルを呼び出せる。`build_router::<FakeMcp>(state)` も `Restartable` 制約を満たすためコンパイル可能 (Plan 03-01 で trait Restartable 新設、本プランで FakeMcp impl 完了)。
- **Wave 4 (03-05 / 03-06 justfile / CI):** `cargo test --release` が 8 passed で安定、CI 化の前提を満たす。

### 03-04 への確認事項

03-04 で `http.rs` の test mod を書く際:

1. `use crate::mcp::tests::FakeMcp;` で FakeMcp を取り込み可能 (`pub(crate) mod tests` 格上げ済み)。
2. `FakeMcp::new()` で空インスタンス生成 → `fake.create_session_replies.push_back(Ok("sid-1".into()));` で scripted reply 仕込み。
3. `Worker::new` を `Worker<FakeMcp>` に渡すルートは本プランでは未テスト (Plan 03-01 で型システム上は成立確認済み)。03-04 で `Worker::new_with_client` 相当のテスト用 ctor が必要なら 03-04 側で追加すること。
4. `AppState<FakeMcp>` を組み立てて `build_router(state)` に渡すフローで `restart_handler::<FakeMcp>` が `Restartable` 制約を満たすことは本プランの no-op `impl Restartable for FakeMcp { async fn respawn(...) { handshake_calls += 1; Ok(()) } }` で保証されている。

## Self-Check: PASSED

- File exists: `webif/src/mcp.rs` (modified, mod tests appended) ✓
- File exists: `.planning/phases/03-testing-ci-automation/03-03-SUMMARY.md` (about to be written) ✓
- Commit `49d9d95`: exists (Task 1 — `git log` 確認済み) ✓
- Commit `2c655cd`: exists (Task 2 — `git log` 確認済み) ✓
- Test count: 8 passed; 0 failed (5 turn + 3 mcp) ✓
- Clippy: 0 warnings (exit 0) ✓
- D-06 compliance: `webif/tests/` 不在 ✓
- No new dependencies: `git diff webif/Cargo.toml` 空 ✓
- FakeMcp implements both `Mcp` and `Restartable` (verified by grep + build) ✓

---
*Phase: 03-testing-ci-automation*
*Completed: 2026-05-25*
