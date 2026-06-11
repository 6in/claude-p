---
phase: 04-agent-profile-abstraction
plan: 03
subsystem: api
tags: [rust, axum, worker, profile, http, gap-closure]

# Dependency graph
requires:
  - phase: 04-02
    provides: "AppState, Worker<M> with pub profile, prompt_handler with worker.lock covenant fetch"
provides:
  - "AppState<M> に pub output_covenant: String フィールド — ロックフリーで prompt_handler が参照"
  - "AgentProfile::spawn_command() — model_flag/model_value 両指定時に spawn コマンドへ反映"
  - "config.rs から TURN_TIMEOUT 死蔵定数を削除"
affects: [05-agent-validation, future-multi-agent]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ロックフリー静的フィールドパターン: 起動後イミュータブルな値は AppState に直接持たせ worker Mutex を回避（CR-01）"
    - "spawn_command() ファクトリパターン: コマンド組み立てをプロファイルに集約し、呼び出し側は spawn_command() を呼ぶだけ（CR-03）"
    - "D-13 片方無視ルール: model_flag/model_value は両方 Some の場合のみ有効"

key-files:
  created: []
  modified:
    - src/http.rs
    - src/main.rs
    - src/profile.rs
    - src/worker.rs
    - src/config.rs

key-decisions:
  - "AppState に output_covenant を直接持たせることで prompt_handler の worker.lock().await を完全排除（CR-01）"
  - "spawn_command() は profile.rs の impl AgentProfile ブロックに配置 — worker.rs 呼び出し側は常に spawn_command() 経由（CR-03）"
  - "TURN_TIMEOUT は参照ゼロ確認済みのため config.rs から削除（WR-03）"

patterns-established:
  - "パターン: 起動後イミュータブルな設定値は AppState フィールドに昇格し Mutex を経由しない"
  - "パターン: spawn コマンド組み立ては AgentProfile::spawn_command() に集約"

requirements-completed: [PROF-03, PROF-05]

# Metrics
duration: 8min
completed: 2026-06-11
---

# Phase 4 Plan 03: Gap Closure (CR-01 / CR-03 / WR-03) Summary

**ロックフリー output_covenant でターン実行中の POST /prompt 即返しを回復し、model_flag/model_value を spawn コマンドへ実際に配線した**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-11T09:13:00Z
- **Completed:** 2026-06-11T09:19:36Z
- **Tasks:** 2
- **Files modified:** 5 (src/http.rs, src/main.rs, src/profile.rs, src/worker.rs, src/config.rs)

## Accomplishments

- `src/http.rs`: `AppState<M>` に `pub output_covenant: String` を追加。`prompt_handler` の `worker.lock().await` で covenant を取得するブロックを削除し `&state.output_covenant` を直接参照（CR-01 解消）
- `src/profile.rs`: `AgentProfile::spawn_command()` メソッドを実装。model_flag/model_value 両方 Some の場合のみフラグと値を末尾に追加。単体テスト 3 ケース追加（未指定/両方指定/片方のみ）
- `src/worker.rs`: create_session 呼び出し 3 箇所（spawn_session / recreate / restart）を `spawn_command()` 経由に統一（CR-03 解消）
- `src/config.rs`: 参照ゼロの死蔵定数 `TURN_TIMEOUT` を削除（WR-03 解消）。`MCP_TIMEOUT` と `use std::time::Duration` は残存
- テスト: 24 → 27（spawn_command 3 ケース追加）、全 27 テストグリーン

## Task Commits

Each task was committed atomically:

1. **Task 1: AppState に output_covenant を追加しロックフリー化（CR-01）** - `4e69068` (feat)
2. **Task 2: model_flag/model_value を spawn コマンドに配線（CR-03）＋ TURN_TIMEOUT 削除（WR-03）** - `6e95406` (feat)

## Files Created/Modified

- `src/http.rs` — AppState に `pub output_covenant: String` 追加; prompt_handler のロック取得ブロック削除; build_test_state に output_covenant 追加
- `src/main.rs` — Worker::new の前に `output_covenant = profile.output_covenant.clone()` を取り出す; AppState 構築時に output_covenant を渡す
- `src/profile.rs` — `impl AgentProfile` ブロックに `pub fn spawn_command(&self) -> Vec<String>` 追加; spawn_command テスト 3 ケース追加
- `src/worker.rs` — create_session 呼び出し 3 箇所を `profile.spawn_command()` / `self.profile.spawn_command()` に変更
- `src/config.rs` — `pub const TURN_TIMEOUT: Duration` を削除（3 行削除）

## Decisions Made

- `output_covenant` を AppState に昇格させ worker.lock().await を prompt_handler から完全排除。プロファイルは起動後イミュータブルなので Mutex 越しの取得は不要（CR-01）
- `spawn_command()` を profile.rs の `impl AgentProfile` に配置し、worker.rs 呼び出し側は spawn コマンドの組み立てロジックを持たない（Single Responsibility）
- D-13 原則通り: model_flag/model_value は両方指定時のみ有効（片方 Some は追加なし）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 04 全 3 ギャップ（CR-01 / CR-03 / WR-03）解消済み
- POST /prompt の API 契約（turn_id 即返し）が v1.0 等価に回復（PROF-03 充足）
- model 選択設定が実際に機能（PROF-05 完全充足）
- Phase 5 への準備: multi-agent validation / Codex CLI / OpenCode プロファイル検証

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes beyond the plan's threat_model. T-04-07 (output_covenant ロックなし読み取り) と T-04-08 (prompt_handler DoS 様回帰解消) はいずれも計画通り対処済み。

## Self-Check: PASSED

- `src/http.rs` has `pub output_covenant: String` — FOUND
- `src/main.rs` has `output_covenant` in AppState — FOUND
- `grep -c TURN_TIMEOUT src/config.rs` → 0 — CONFIRMED
- `grep -c 'spawn_command()' src/worker.rs` → 3 — CONFIRMED
- Commits 4e69068 and 6e95406 — FOUND
- `cargo test` 27 passed — CONFIRMED

---
*Phase: 04-agent-profile-abstraction*
*Completed: 2026-06-11*
