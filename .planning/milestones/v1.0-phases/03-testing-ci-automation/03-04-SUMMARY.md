---
phase: 03-testing-ci-automation
plan: 04
subsystem: testing
tags: [rust, axum, tower-oneshot, integration-test, asvs-v5, path-traversal, hermetic-test, fake-mcp]

# Dependency graph
requires:
  - phase: 03-testing-ci-automation
    plan: 01
    provides: "Worker<M: Mcp = McpClient> / AppState<M: Mcp + Send + 'static = McpClient> / build_router<M: Mcp + Restartable + Send + 'static>(state) ジェネリック化、tower (dev, util) + tempfile (dev) 依存"
  - phase: 03-testing-ci-automation
    plan: 03
    provides: "pub(crate) struct FakeMcp + impl Mcp for FakeMcp + impl Restartable for FakeMcp（mcp::tests に格上げ済み）"
provides:
  - "webif/src/worker.rs に #[cfg(test)] pub(crate) fn from_parts<M: Mcp + Send>(client, session_id, ht_mcp_path) -> Worker<M> ─ boot/spawn を経由しないテスト用直接ctor"
  - "webif/src/http.rs 末尾の #[cfg(test)] mod tests ─ build_test_state ヘルパ + 3 本の HTTP 統合テスト（パストラバーサル 2 本独立 + happy path 1 本）"
  - "tower::ServiceExt::oneshot による in-process Router 駆動パターン（TcpListener 不要、hermetic）"
affects: [03-05, 03-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "tower::ServiceExt::oneshot で build_router(state) を in-process 駆動（D-08）"
    - "tempdir + 事前配置 status/result ファイル + read_turn 経由で worker_loop spawn 回避（D-09）"
    - "ROADMAP success criteria の verbatim 文面を 2 本の独立テスト関数に分解し、片方の弱体化を他方が catch する構造（regression catch-all 回避）"
    - "FakeMcp + Worker::from_parts による Worker<FakeMcp> 直接組み立て（boot/handshake 経由なし）"
    - "_job_rx 名前バインドで mpsc::Sender drop を防止（channel closed エラー回避）"

key-files:
  created: []
  modified:
    - "webif/src/worker.rs (#[cfg(test)] pub(crate) fn from_parts 追加、汎用 impl<M: Mcp + Send> Worker<M> ブロック内)"
    - "webif/src/http.rs (末尾に #[cfg(test)] mod tests ブロック新設: build_test_state ヘルパ + 3 #[tokio::test])"

key-decisions:
  - "ROADMAP 「../や不正文字を 400 で弾く」を 2 本の独立 #[tokio::test] 関数に分解 ─ verbatim 文面の「OR」を 1 本の弱いテストに圧縮せず、保護対象 (パストラバーサル形式 vs 英字混入形式) ごとに独立 catch を維持"
  - "URI /turns/..%2Fetc%2Fpasswd を必須採用 ─ axum 0.8 の Path extractor は %2F を path 区切りとして扱わないため、ベアな /turns/../etc/passwd ではルーター段階で /etc/passwd に正規化されハンドラに届かない。%2F エンコード版で turn_id = '../etc/passwd' をハンドラに到達させ whitelist の '.' / '/' 弾きを検証"
  - "happy path テストは tempdir に status-<id>.json + result-<id>.txt を事前配置し worker_loop 不在で read_turn を直接検証（D-09 hermetic test、ht-mcp / claude TUI バイナリ不要）"
  - "build_test_state は (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>) のタプルを返す ─ テスト側で _job_rx として保持しないと job_tx 側が channel closed で panic する可能性があるため Sender drop 防止"
  - "Task 1 commit は dead_code 警告を一時的に #[allow(unused_imports, dead_code)] と #[allow(dead_code)] で抑制 ─ Plan 03-03 の FakeMcp 先行投入と同じ future-consumer pattern。Task 2 で消費されるタイミングで allow を解除"

patterns-established:
  - "hermetic HTTP integration test: tower::oneshot + tempdir + FakeMcp で TcpListener / reqwest / 実 ht-mcp なし"
  - "Test-only direct constructor: #[cfg(test)] pub(crate) fn from_parts(...) で boot ロジック迂回（本番 API 不変）"
  - "verbatim regulation の test 分解: ROADMAP の '`X` や `Y` を弾く' を 1 本の OR テストに圧縮せず、X と Y を別関数として独立テスト化"

requirements-completed: [TEST-03]

# Metrics
duration: 4.8min
completed: 2026-05-25
---

# Phase 03 Plan 04: HTTP Integration Tests Summary

**`/turns/{turn_id}` のパストラバーサル拒否 (ASVS V5) と happy path を hermetic に検証する 3 本の HTTP 統合テストを `webif/src/http.rs` に追加。`tower::ServiceExt::oneshot` で TcpListener なしに build_router を駆動、ROADMAP Phase 3 Success #2 の verbatim「`../`や不正文字を 400 で弾く」を 2 本の独立テスト関数として並存させ、片方の弱体化を他方が catch する構造で TEST-03 を完了。`cargo test --release` で 11 passed (5 turn + 3 mcp + 3 http) / 0 failed、clippy warning 0。**

## Performance

- **Duration:** 4.8 min
- **Started:** 2026-05-25T13:41:21Z
- **Completed:** 2026-05-25T13:46:12Z (commit 2da8947)
- **Tasks:** 2 / 2
- **Files modified:** 2 (`webif/src/worker.rs`, `webif/src/http.rs`)

## Accomplishments

- `webif/src/worker.rs` の汎用 `impl<M: Mcp + Send> Worker<M>` ブロック内に `#[cfg(test)] pub(crate) fn from_parts(client: M, session_id: String, ht_mcp_path: String) -> Self` を追加。
- `webif/src/http.rs` 末尾に `#[cfg(test)] mod tests` ブロックを新設し、以下を実装:
  - `build_test_state(turns_dir: PathBuf) -> (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>)` ヘルパ ─ `Worker::<FakeMcp>::from_parts(FakeMcp::new(), "test-session", "/dev/null")` で Worker を組み立て、`Arc::new(AppState { worker, turns_dir, job_tx })` を返す。`job_rx` はタプル戻し（Sender drop 防止）。
  - `#[tokio::test] async fn turn_handler_rejects_path_traversal_via_percent_encoded_slash()` ─ URI `/turns/..%2Fetc%2Fpasswd` → 400 Bad Request。
  - `#[tokio::test] async fn turn_handler_rejects_ascii_letters_in_turn_id()` ─ URI `/turns/abc` → 400 Bad Request。
  - `#[tokio::test] async fn turn_handler_returns_done_when_status_file_exists()` ─ tempdir に `status-{id}.json` + `result-{id}.txt` を事前配置、URI `/turns/{id}` → 200 OK + JSON body の `turn_id` / `status:"done"` / `result:"ok"` を assert。
- `cd webif && cargo test --release` で **11 passed; 0 failed; 0 ignored** (5 turn + 3 mcp + 3 http)。
- `cd webif && cargo clippy --all-targets --release -- -D warnings` exit 0、warning 0。
- 依存追加なし、`webif/tests/` 統合テスト dir 未作成（D-06 遵守）。

## Task Commits

各タスクを atomically コミット:

1. **Task 1: Worker::from_parts ctor 追加 + http.rs 統合テスト用 build_test_state ヘルパ** - `aaa1449` (test)
2. **Task 2: 3 本の HTTP 統合テスト追加（パストラバーサル拒否 2 本独立 + happy path）** - `2da8947` (test)

## Files Created/Modified

- `webif/src/worker.rs` ─ `impl<M: Mcp + Send> Worker<M>` ブロック先頭に `#[cfg(test)] pub(crate) fn from_parts(client, session_id, ht_mcp_path)` を追加（合計 8 行追加）。本番 impl ブロック・既存メソッドは無変更。
- `webif/src/http.rs` ─ `build_router` の直後に `// ── HTTP 統合テスト ─...` セパレータコメント + `#[cfg(test)] mod tests` ブロックを追加（合計 142 行追加）。本体 (lines 1-168) は完全に無変更。

## 採用した 3 テストの URI と関数名

| # | 関数名 | URI | 期待 status | 検証対象 |
|---|---|---|---|---|
| 1 | `turn_handler_rejects_path_traversal_via_percent_encoded_slash` | `/turns/..%2Fetc%2Fpasswd` | 400 Bad Request | ROADMAP Success #2「`../`を 400 で弾く」(ASVS V5)、CONTEXT D-10 #1 verbatim 形式 |
| 2 | `turn_handler_rejects_ascii_letters_in_turn_id` | `/turns/abc` | 400 Bad Request | ROADMAP Success #2「不正文字を 400 で弾く」(ASVS V5)、whitelist 英字弾き |
| 3 | `turn_handler_returns_done_when_status_file_exists` | `/turns/20260525-000000-000` | 200 OK | HT-PROTOCOL §6 status 出現完了センチネル、`{turn_id, status:"done", result:"ok"}` body |

**両保護の独立性:** テスト #1 と #2 は別関数として並存し、片方を弱体化（例: assert を消す / URI を変える）しても他方が独立に落ちる。`/turns/abc` だけで両方カバーするような圧縮はしていない（ROADMAP 「`../`や不正文字」の verbatim 文面に忠実）。

## happy path テストで使った turn_id と body の具体値

- **turn_id:** `"20260525-000000-000"` (HT-PROTOCOL `%Y%m%d-%H%M%S-%3f` 形式、19 文字、3 セグメント全数字)
- **status-{id}.json の中身:** `{"status":"done"}\n`
- **result-{id}.txt の中身:** `"ok"` (改行なし)
- **期待されるレスポンス body:** `{"turn_id":"20260525-000000-000","status":"done","result":"ok"}` (JSON 順序は serde_json 任意、`v.get("...").and_then(Value::as_str)` で順序非依存に検証)
- **HTTP status:** 200 OK
- **body 取得方法:** `axum::body::to_bytes(resp.into_body(), 64 * 1024).await.unwrap()` → `serde_json::from_slice::<Value>(&body_bytes)`

## D-09 通り worker_loop を spawn せず動作することの確認

- `build_test_state` 内では `tokio::spawn(worker_loop(...))` を呼んでいない（`mpsc::channel(64)` で Sender / Receiver を作るのみ、Receiver は `_job_rx` で保持して drop 防止）。
- `turn_handler` 経路は `state.worker.lock()` を取らずに `state.turns_dir` / `read_turn` のみを参照するため、Worker の中身（FakeMcp の scripted reply 状態）は使われない。`FakeMcp::new()` の空インスタンスで十分。
- happy path テストは tempdir に `status-{id}.json` + `result-{id}.txt` を事前配置し、`turn_handler` 内の `status_path.exists()` 分岐 → `read_turn` 呼出 → `tokio::fs::read_to_string` で読み戻す経路だけを叩く。`process_job` / claude TUI / ht-mcp は一切起動しない。
- 確認方法: `grep -c 'tokio::spawn' webif/src/http.rs` = 0（mod tests 内に spawn 呼出なし）。

## Decisions Made

1. **ROADMAP「`../`や不正文字を 400 で弾く」を 2 本の独立テストに分解**
   verbatim 文面は「`../`」と「不正文字」の 2 つを並列に列挙しており、片方だけ守れば success ではない（plan-checker B1 要件の根拠と同じ）。CONTEXT D-10 #1 verbatim も `../etc/passwd` というパストラバーサル形式を例示。1 本の OR テスト（例: `/turns/abc` 1 件で「whitelist が動いている」と確認）に圧縮すると、将来「パストラバーサル形式は通すが英字は弾く」というデグレを検知できなくなる。**両者は別 #[tokio::test] 関数として並存させ、独立に catch する構造を維持**。

2. **URI `/turns/..%2Fetc%2Fpasswd` を必須採用（ベア `/turns/../etc/passwd` 不可）**
   axum 0.8 の Router は HTTP path の `..` セグメントを「path normalization」として処理するため、ベアな `/turns/../etc/passwd` は HTTP 解釈段階で `/etc/passwd` に正規化され、`/turns/{turn_id}` ルートにマッチせず 404 が返る。これでは whitelist の動作確認にならない。`%2F` を使った percent-encoded 形式は axum 0.8 の `Path<String>` extractor が path 区切りに展開しないため、`turn_id = "../etc/passwd"` がそのままハンドラに届き、whitelist `c.is_ascii_digit() || c == '-'` が `.` / `/` を弾いて 400 を返す。これが axum 0.8 で「パストラバーサル文字列をハンドラに届けて whitelist を検証する」唯一の手段。

3. **happy path は tempdir 事前配置 + worker_loop 未起動（D-09）**
   `turn_handler` の経路は `status_path.exists()` の分岐後 `read_turn` を呼ぶだけで Worker / FakeMcp の中身に触れない。`tokio::spawn(worker_loop(...))` を起こさず、テストハーネスを「ファイルが既にある状態」で `read_turn` 経路だけを叩く方が hermetic で 1ms オーダー。Phase 2 で 8 件の curl smoke で worker_loop 含む経路は実証済みなので、Phase 3 では GET 経路の単体カバレッジに集中する判断（CONTEXT D-09 / D-10）。

4. **build_test_state を `(Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>)` のタプル返し**
   `mpsc::channel` は両端を独立に drop できるが、Sender のみ保持して Receiver が drop されると 次の `send().await` で channel closed エラーになる（HTTP ハンドラの prompt_handler は本テストで叩かないため実害はないが、安全側に倒す）。タプル戻しで呼び出し側に `let (state, _job_rx) = build_test_state(...);` の形で保持を強制（CONTEXT "Constraints" line 150 の要件を構造で満たす）。

5. **Task 1 で dead_code 警告を `#[allow(unused_imports, dead_code)]` で一時抑制**
   Task 1 完了時点では `build_test_state` / `from_parts` が消費されないため、`cargo clippy --release -D warnings` を通すために mod tests 全体と Worker::from_parts に `#[allow]` を付けた（Plan 03-03 の FakeMcp 先行投入と同じ future-consumer pattern）。Task 2 で 3 テストが追加されて消費される時点で `#[allow]` を解除した（Worker::from_parts も同様、関数 doc の言及を Task 1 完了時点の文言から Task 2 後の文言に更新）。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] clippy::needless_borrows_for_generic_args 違反**
- **Found during:** Task 2 verification (`cargo clippy --all-targets --release -- -D warnings`)
- **Issue:** `Request::builder()....uri(&format!("/turns/{id}"))` で `&` が不要（`uri()` が `Display` を取るため借用は冗長）。`#[deny(clippy::needless_borrows_for_generic_args)]` でビルドエラー（warning 0 ガード）。
- **Fix:** `&format!(...)` を `format!(...)` に変更（1 箇所、happy path テスト内）。
- **Files modified:** `webif/src/http.rs:288`
- **Verification:** `cargo clippy --all-targets --release -- -D warnings` exit 0、`cargo test --release` 11 passed / 0 failed（テスト挙動は不変）。
- **Committed in:** `2da8947` (Task 2 commit と統合)

---

**Total deviations:** 1 auto-fixed (Rule 1 - clippy lint)
**Impact on plan:** clippy の cross-cutting constraint を満たすための機械的修正のみ。テスト関数の挙動・URI・assertion・happy path の挙動は完全に保たれている。

## Issues Encountered

- Task 1 を atomically commit するために http.rs の Task 2 部分を一時的に削除→Task 1 部分のみで commit→Task 2 部分を復元する手順を踏んだ（編集時に Task 1 と 2 の差分を分離する git の `-p` patch staging が agent 環境で使えないため、ファイル全体の add/commit/再編集の流れで分離）。最終的な diff の累積は Task 1 commit + Task 2 commit で正しく分割されている (`git log --oneline -2`)。
- Task 1 commit 時点で `build_test_state` / `Worker::from_parts` が未消費のため `cargo clippy --release -D warnings` が dead_code で落ちた。Plan 03-03 で FakeMcp に同じ理由で `#[allow(dead_code)]` を付けた前例に従い、Task 1 commit には `#[allow(unused_imports, dead_code)]`（mod tests 全体）と `#[allow(dead_code)]`（Worker::from_parts）を付与。Task 2 commit で消費される時点で両方解除（mod tests の `#[allow]` 行を削除、Worker::from_parts の `#[allow(dead_code)]` 行を削除）。

## Threat Flags

None - 本プランで追加したのは `#[cfg(test)]` 配下の test mod のみで、本番経路（`turn_handler` / `prompt_handler` / `command_handler` / `restart_handler` / `build_router` の挙動）には一切手を入れていない。テストはむしろ Phase 2 で実証済みの ASVS V5 パストラバーサル制御がリグレッションで消えないことを保証する側に立つ（防御機構の固定化）。新たなネットワークエンドポイント、auth path、ファイルアクセスパターン、trust boundary でのスキーマ変更は導入していない。

## Known Stubs

None - 本プランで追加した 3 テストは完全な assertion を持つ。`build_test_state` ヘルパは Sender 保持のため Receiver をタプル戻しするが、これはテスト方針上の必須構造で stub ではない（CONTEXT "Constraints" line 150 が要求する明示的な drop 制御）。FakeMcp の scripted reply キューも Task 2 のテスト 3 本では使わないが、これは Wave 2 (03-03) で確立済みの future-consumer pattern の continuation であり、本プランで stub を導入したわけではない。

## Verification Coverage (TEST-03)

PLAN.md `<verification>` の 9 観点をすべて満たす:

| # | 検証項目 | 結果 |
|---|---|---|
| 1 | `cargo test --release` で `test result.*[1-9][0-9]* passed.*0 failed` がマッチ | ✓ `test result: ok. 11 passed; 0 failed; 0 ignored` |
| 2 | `cargo clippy --all-targets --release -- -D warnings` exit 0 | ✓ warning 0、exit 0 |
| 3 | `cargo build --release` exit 0 / warning 0 | ✓ warning 0 |
| 4 | `grep -c 'tower::ServiceExt' webif/src/http.rs` >= 1 | ✓ 1 (mod tests 内 `use tower::ServiceExt;`) |
| 5 | `grep -c 'fn turn_handler_rejects_path_traversal_via_percent_encoded_slash' webif/src/http.rs` = 1 | ✓ 1 |
| 6 | `grep -c 'fn turn_handler_rejects_ascii_letters_in_turn_id' webif/src/http.rs` = 1 | ✓ 1 |
| 7 | `grep -c 'fn turn_handler_returns_done_when_status_file_exists' webif/src/http.rs` = 1 | ✓ 1 |
| 8 | `grep -c 'fn from_parts' webif/src/worker.rs` >= 1 | ✓ 1 |
| 9 | `grep -q '"/turns/..%2Fetc%2Fpasswd"' webif/src/http.rs` | ✓ 一致 (パストラバーサル URI の literal が存在) |

`cargo test --release` 出力（関連抜粋）:

```
running 11 tests
test mcp::tests::next_id_increments_per_request ... ok
test http::tests::turn_handler_rejects_ascii_letters_in_turn_id ... ok
test http::tests::turn_handler_rejects_path_traversal_via_percent_encoded_slash ... ok
test mcp::tests::request_extracts_result_from_response ... ok
test turn::tests::build_prompt_body_includes_task_and_paths ... ok
test mcp::tests::request_builds_jsonrpc_envelope_with_method_and_params ... ok
test http::tests::turn_handler_returns_done_when_status_file_exists ... ok
test turn::tests::turn_id_formatter_matches_expected_shape ... ok
test turn::tests::read_turn_marks_unknown_when_status_garbled ... ok
test turn::tests::read_turn_returns_empty_result_when_result_file_missing ... ok
test turn::tests::read_turn_returns_done_when_status_complete ... ok

test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

## User Setup Required

None - external configuration / credentials は不要。`cd webif && cargo test --release` を実行できる環境さえあれば誰でも全 11 テストを再現できる。`tower::ServiceExt::oneshot` は in-process なので ht-mcp / claude バイナリも不要、ネットワーク (TcpListener / reqwest) も不要。

## Next Phase Readiness

- **Wave 3 完了:** 本プランで TEST-03 (HTTP 統合テスト) を完了。Phase 3 Success Criterion #2「`/turns/{id}` のパストラバーサル拒否 (`../` や不正文字を 400 で弾く) と happy path (status ファイル出現で完了レスポンス)」を hermetic に保証する 3 本のテストが追加された。
- **Wave 4 (03-05 justfile / 03-06 GitHub Actions CI) 着手可能:** `cargo test --release` が 11 passed で安定、`cargo clippy --all-targets --release -- -D warnings` exit 0。CI ジョブで `cargo fmt --check` / `cargo clippy -- -D warnings` / `cargo test --release` を直列実行する前提を完全に満たす。
- **本番経路への影響:** ゼロ。`#[cfg(test)]` ガードにより `cargo build --release` 時に `Worker::from_parts` / `mod tests` / `build_test_state` はバイナリに含まれない（`grep -c 'from_parts' target/release/ht-webif` = 0 で確認可能、本プラン中は未実施）。

### 03-05 / 03-06 への確認事項

- `cargo test --release` がデフォルトで全 11 テストを実行する（`webif/tests/` 統合テスト dir は未作成）。`#[ignore]` 付きテストもなく、`--ignored` フラグや `RUN_E2E=1` などの opt-in 不要。
- CI ジョブで使う test profile は `--release` で統一（CONTEXT specifics line 160 が dev profile との乖離を防ぐと明記）。dev profile での実行は justfile / CI ともに含めない。

## Self-Check: PASSED

- File exists: `webif/src/worker.rs` (modified, from_parts 追加) ✓
- File exists: `webif/src/http.rs` (modified, mod tests 追加) ✓
- File exists: `.planning/phases/03-testing-ci-automation/03-04-SUMMARY.md` (about to be written) ✓
- Commit `aaa1449` (Task 1): exists ✓
- Commit `2da8947` (Task 2): exists ✓
- Test count: 11 passed; 0 failed (5 turn + 3 mcp + 3 http) ✓
- Clippy: 0 warnings (exit 0) ✓
- Release build: 0 warnings (exit 0) ✓
- D-06 compliance: `webif/tests/` 不在 ✓
- No new dependencies: `git diff webif/Cargo.toml` 空 ✓
- パストラバーサル 2 本独立: テスト関数 `turn_handler_rejects_path_traversal_via_percent_encoded_slash` と `turn_handler_rejects_ascii_letters_in_turn_id` が別 `#[tokio::test]` として並存 ✓
- worker_loop 未起動: `mod tests` 内に `tokio::spawn` 呼出なし ✓

---
*Phase: 03-testing-ci-automation*
*Completed: 2026-05-25*
