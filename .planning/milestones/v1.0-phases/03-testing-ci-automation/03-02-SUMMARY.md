---
phase: 03-testing-ci-automation
plan: 02
subsystem: testing
tags: [rust, unit-test, tokio-test, tempfile, chrono, pure-function, co-location]

# Dependency graph
requires:
  - phase: 03-testing-ci-automation
    plan: 01
    provides: "lib/bin 分離済み、[dev-dependencies] に tempfile = 3 が入った Cargo.toml、ジェネリック化後の turn.rs (build_prompt_body / read_turn の signature は不変)"
provides:
  - "webif/src/turn.rs 末尾の #[cfg(test)] mod tests ─ 純関数テスト 5 本"
  - "turn_id formatter (%Y%m%d-%H%M%S-%3f) の形式検証パターン（依存追加なし）"
  - "read_turn の 3 分岐（done / unknown / 空文字）テストカバレッジ"
  - "tempfile::tempdir + #[tokio::test] のテンプレ（Phase 3 後続テストが参照可能）"
affects: [03-04, 03-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "co-located #[cfg(test)] mod tests ─ webif/tests/ 統合テスト dir は作らない (D-06)"
    - "shape-only formatter assertion ─ regex を使わず str::split + len + chars().all(is_ascii_digit) で形式検証"
    - "tempfile::tempdir で turns/ 相当を都度新設、TempDir Drop で teardown"
    - "garbled JSON のテストデータ: \"not a json{{{\" で serde_json::from_str を確実に Err にする"

key-files:
  created: []
  modified:
    - "webif/src/turn.rs (末尾に #[cfg(test)] mod tests 追加、5 テスト関数)"

key-decisions:
  - "turn_id formatter テストを turn.rs 内に配置 ─ http.rs (line 48) で実際に呼ばれているが、テスト対象は format 文字列パターンそのもの。formatter logic は chrono の責務でモジュールに紐づかないため、純関数テストの集約場所として turn.rs の mod tests に同居（PLAN.md interfaces 注釈に従う）"
  - "regex クレートを追加しない ─ str::split('-') と chars().all(is_ascii_digit) で十分。CONTEXT.md specifics line 159 の最小化方針と CLAUDE.md の Constraints「単一バイナリ」志向に整合"
  - "garbled 文字列を \"not a json{{{\" に決定 ─ \"not a json\" 単独だと serde が文字列リテラルとしてパース通すリスクがあるため、未閉鎖の { を 3 個付けて確実に serde_json::from_str::<Value> を Err にする（read_turn の .ok() → unwrap_or_else (\"unknown\") パスを発火）"

patterns-established:
  - "純関数の co-located 単体テスト: タスクの本文・パス・マーカーをすべて assert!.contains で確認"
  - "ファイル前提の async テスト: tempdir + write で予置 → read_turn → JSON Value の get/and_then/as_str チェーンで取り出し"
  - "形式検証は標準ライブラリで: len + split + chars().all で十分（依存最小化）"

requirements-completed: [TEST-01]

# Metrics
duration: 1.6min
completed: 2026-05-25
---

# Phase 03 Plan 02: Pure Function Unit Tests Summary

**`webif/src/turn.rs` 末尾に co-located な `#[cfg(test)] mod tests` を追加し、`build_prompt_body` / `read_turn` の 3 分岐 / `turn_id` formatter の形式検証 — 計 5 本の純関数単体テストを実装。`cargo test --release` で全 green、clippy warning 0、依存追加なし、`webif/tests/` 統合テスト dir も非作成（D-06 遵守）**

## Performance

- **Duration:** 1.6 min
- **Started:** 2026-05-25T13:28:32Z
- **Tasks:** 2 / 2
- **Files modified:** 1 (webif/src/turn.rs)

## Accomplishments

- `webif/src/turn.rs` 末尾に `#[cfg(test)] mod tests` ブロックを新規追加。
- 純関数テスト 2 本（Task 1）:
  - `build_prompt_body_includes_task_and_paths` — タスク本文・result パス・status パス・「【ht-webif 出力規約】」マーカーの 4 要素を `assert!(body.contains(...))` で検証
  - `turn_id_formatter_matches_expected_shape` — `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` の結果が 19 文字 / 3 セグメント / 各 8 + 6 + 3 桁の全数字であることを標準ライブラリのみで検証
- 非同期テスト 3 本（Task 2、`read_turn` 3 分岐カバレッジ）:
  - `read_turn_returns_done_when_status_complete` — 完全な `{"status":"done"}` + result 存在の happy path
  - `read_turn_marks_unknown_when_status_garbled` — `"not a json{{{"` の garbled 入力で `.unwrap_or_else(|| "unknown".to_string())` フォールバックを発火
  - `read_turn_returns_empty_result_when_result_file_missing` — `result-Y.txt` 未配置で `tokio::fs::read_to_string` の `.unwrap_or_default()` パスを発火
- `cd webif && cargo test --release` で **5 passed; 0 failed; 0 ignored**。
- `cd webif && cargo clippy --all-targets --release -- -D warnings` warning 0、exit 0。
- 依存追加なし（regex 不要、`tempfile` は 03-01 で既導入の `[dev-dependencies]` をそのまま流用）。
- `webif/tests/` 統合テスト dir は作成せず、D-06 co-location 規約を厳守。

## Task Commits

各タスクを atomically コミット:

1. **Task 1: build_prompt_body と turn_id formatter の単体テスト追加** - `0b64c73` (test)
2. **Task 2: read_turn の 3 パターン単体テスト（done / unknown / result 不在）追加** - `433da6b` (test)

## Files Created/Modified

- `webif/src/turn.rs` - 末尾に `#[cfg(test)] mod tests { use super::*; use std::path::PathBuf; use tempfile::tempdir; ... }` ブロックを追加。5 テスト関数（`build_prompt_body_includes_task_and_paths`, `turn_id_formatter_matches_expected_shape`, `read_turn_returns_done_when_status_complete`, `read_turn_marks_unknown_when_status_garbled`, `read_turn_returns_empty_result_when_result_file_missing`）。本体（lines 1-114）は完全に無変更。

## 追加した 5 テストの名前一覧

| # | テスト関数名 | 種別 | 検証対象 |
|---|---|---|---|
| 1 | `build_prompt_body_includes_task_and_paths` | `#[test]` | `build_prompt_body` が task / result path / status path / 「【ht-webif 出力規約】」マーカーの 4 要素を含むこと |
| 2 | `turn_id_formatter_matches_expected_shape` | `#[test]` | `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` が 19 文字 / 3 セグメント / 全数字（8+6+3）であること |
| 3 | `read_turn_returns_done_when_status_complete` | `#[tokio::test]` | 完全な status JSON + result ファイル両方ある時、`{turn_id, status:"done", result:"回答本文"}` を返すこと |
| 4 | `read_turn_marks_unknown_when_status_garbled` | `#[tokio::test]` | status JSON が garbled な時、`.unwrap_or_else(\|\| "unknown".to_string())` で `status:"unknown"` を返すこと |
| 5 | `read_turn_returns_empty_result_when_result_file_missing` | `#[tokio::test]` | result ファイル不在時、`.unwrap_or_default()` で `result:""` を返すこと |

## read_turn の `unknown` フォールバックを発火させた garbled 文字列の具体例

```
"not a json{{{"
```

- `not a json` 単独だと `serde_json::from_str::<Value>` がエラーになるとはいえ、JSON 仕様の bare token 解釈や将来の serde の寛容化リスクを考慮し、未閉鎖の `{` を 3 個続けて確実に構文エラーにする文字列を採用。
- これにより `serde_json::from_str::<Value>(&status_raw)` → `Err(...)` → `.ok()` → `None` → `.and_then(...)` → `None` → `.unwrap_or_else(|| "unknown".to_string())` の分岐が実走する。

## `cargo test --release` の最終出力（test result 行）

```
$ cd webif && cargo test --release
   Compiling ht-webif v0.1.0 (/home/parallels/workspaces/ht-mcp-sample/webif)
    Finished `release` profile [optimized] target(s) in 0.98s
     Running unittests src/lib.rs (target/release/deps/ht_webif-948c5992343616ee)

running 5 tests
test turn::tests::build_prompt_body_includes_task_and_paths ... ok
test turn::tests::turn_id_formatter_matches_expected_shape ... ok
test turn::tests::read_turn_returns_empty_result_when_result_file_missing ... ok
test turn::tests::read_turn_returns_done_when_status_complete ... ok
test turn::tests::read_turn_marks_unknown_when_status_garbled ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running unittests src/main.rs (target/release/deps/ht_webif-af71d3a66d9cbdc1)

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests ht_webif

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

`cargo clippy --all-targets --release -- -D warnings` も warning 0 / exit 0 を確認済み。

## 依存追加なしで turn_id 形式チェックを実装できたこと

PLAN.md `<action>` で「regex クレート追加禁止」と明示されており、これを満たすため:

```rust
let id = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();
assert_eq!(id.len(), 19);                                       // 8+1+6+1+3
let parts: Vec<&str> = id.split('-').collect();
assert_eq!(parts.len(), 3);
assert_eq!(parts[0].len(), 8); assert!(parts[0].chars().all(|c| c.is_ascii_digit()));
assert_eq!(parts[1].len(), 6); assert!(parts[1].chars().all(|c| c.is_ascii_digit()));
assert_eq!(parts[2].len(), 3); assert!(parts[2].chars().all(|c| c.is_ascii_digit()));
```

`std::str` の `split` / `len` / `chars` と `char::is_ascii_digit` のみで HT-PROTOCOL §3 turn_id 規格（`YYYYMMDD-HHMMSS-mmm`）への形式適合を完全検証。`webif/Cargo.toml` の `[dependencies]` / `[dev-dependencies]` 共に変更なし（`grep -E '^regex' webif/Cargo.toml` 空）。これは CONTEXT.md specifics line 159 の依存最小化方針と CLAUDE.md `## Constraints` の「単一バイナリ」志向に整合する。

## Decisions Made

1. **turn_id formatter テストを turn.rs 内に配置**
   PLAN.md interfaces 注釈で「`turn.rs` の mod tests 内に書く（または `chrono` を直接呼んでフォーマット結果をチェック）」と提示されていたため、formatter logic そのものは chrono の責務（モジュールに紐づかない）であることを踏まえ、純関数テストの集約場所として `turn.rs` の `mod tests` に同居させる方を採用。`http.rs` 側にテストを置くと `http.rs` の test mod を Phase 3 後続プラン（03-04）で追加する際に小さな摩擦を生むのを避けたかった。

2. **garbled 文字列を `"not a json{{{"` に決定**
   PLAN.md `<action>` 注で「`not a json{{{` が該当」と例示されていた通りに採用。`not a json` 単独でも現行 serde_json は構文エラーを返すが、未閉鎖の `{` を 3 個付けることで「JSON 入力途中で予期せず EOF」型の確実な Err となり、将来の serde 寛容化や parser 差し替えに対するリグレッション耐性が高まる。

3. **regex を追加せず標準ライブラリのみで形式検証**
   PLAN.md `<action>` で「依存追加禁止: regex クレートは追加しない」と明示されていたため、`str::split('-')` + `Vec::len` + `str::len` + `str::chars().all(char::is_ascii_digit)` の組み合わせで 19 文字 / 3 セグメント / 各セグメント全数字を検証。コード量も 5 行で済んだ。

## Deviations from Plan

None - 計画どおりに 2 タスクを実行し、5 テストが全て passed。プラン acceptance criteria を完全に満たしている。

- regex 未追加 ✓
- `webif/tests/` 未作成 ✓
- `#[cfg(test)] mod tests` 1 個、`use super::*;` 含む ✓
- 5 テスト関数すべて存在、`#[tokio::test]` 3 本（read_turn 系）+ `#[test]` 2 本（build_prompt_body / turn_id formatter）✓
- `cargo test --release` で 5 passed / 0 failed ✓
- `cargo clippy --all-targets --release -- -D warnings` exit 0 ✓

## Issues Encountered

なし。03-01 で `[dev-dependencies]` に `tempfile = "3"` が既に追加済みだったため、本プランで Cargo.toml に触れる必要が一切なく、純粋に `webif/src/turn.rs` のテキスト追加のみで完了した（1 ファイル変更、2 コミット）。

## Threat Flags

None - 本プランで追加したのは `#[cfg(test)]` 配下の単体テストのみで、本番経路（`process_job` / `worker_loop` / `build_prompt_body` / `read_turn` 本体）には一切手を入れていない。新たなネットワークエンドポイント、auth path、ファイルアクセスパターン、trust boundary でのスキーマ変更は導入していない。テストは tempdir 内のみで完結し、本番 turns/ ディレクトリには触れない。

## Verification Coverage (TEST-01)

PLAN.md `<verification>` の 4 観点をすべて満たす:

1. **`build_prompt_body`** — タスク・両パス・規約マーカーの 4 要素 → 1 テスト関数で全 4 要素を `assert!.contains` でチェック ✓
2. **`read_turn`** — done / unknown / result 不在 の 3 パターン → 3 つの `#[tokio::test]` 関数で各分岐を独立に発火 ✓
3. **turn_id formatter** — 19 文字 / 3 セグメント / 全数字 → 1 テスト関数で 6 つの assert を直列実行 ✓

検証コマンドの実行結果:

| コマンド | 結果 |
|---|---|
| `cd webif && cargo test --release` | `test result: ok. 5 passed; 0 failed; 0 ignored` |
| `cd webif && cargo clippy --all-targets --release -- -D warnings` | exit 0、warning 0 |
| `grep -c '^#\[cfg(test)\]' webif/src/turn.rs` | `1` |
| `grep -c 'fn build_prompt_body_includes_task_and_paths\|fn turn_id_formatter_matches_expected_shape\|fn read_turn_returns_done\|fn read_turn_marks_unknown\|fn read_turn_returns_empty_result' webif/src/turn.rs` | `5` |
| `[ -d webif/tests ]` | absent ✓ |
| `grep -E '^regex' webif/Cargo.toml` | empty ✓ |

## User Setup Required

None - external configuration / credentials は不要。`cargo test --release` を実行できる環境さえあれば誰でも全テストを再現できる。

## Next Phase Readiness

- **Wave 2 並走の 03-03 (mcp.rs テスト)**: 本プランは `turn.rs` のみを触っており、03-03 が触る `mcp.rs` とは完全に独立。マージ衝突なし。
- **Wave 3 (03-04 http.rs テスト)**: 本プランで導入した「tempfile::tempdir + #[tokio::test] + tokio::fs::write による turns/ 予置」パターンが、03-04 の `http.rs` HTTP 統合テスト（`turn_handler_returns_done_when_status_file_exists`）でそのまま再利用できる。
- **Wave 4 (03-05 / 03-06 justfile / CI)**: 本プランの実装によりリポジトリ全体の `cargo test --release` が 0 passed → 5 passed に増えた。CI（`.github/workflows/ci.yml`）が `cargo test --release` を実行すれば、テストカウントが目に見える形で増える（D-06 の co-location 規約が CI ログでも一目でわかる）。

## Self-Check: PASSED

- File exists: `webif/src/turn.rs` (modified, 5 test functions added)
- Commit `0b64c73`: exists (Task 1 — `git log` 確認済み)
- Commit `433da6b`: exists (Task 2 — `git log` 確認済み)
- Test count: 5 passed; 0 failed (test result 行で確認)
- Clippy: 0 warnings (exit 0)
- D-06 compliance: `webif/tests/` 不在 ✓
- No new dependencies: `grep -E '^regex' webif/Cargo.toml` 空 ✓

---
*Phase: 03-testing-ci-automation*
*Completed: 2026-05-25*
