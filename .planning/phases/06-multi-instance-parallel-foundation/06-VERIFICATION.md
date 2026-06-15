---
phase: 06-multi-instance-parallel-foundation
verified: 2026-06-15T09:42:00Z
status: human_needed
score: 9/9
overrides_applied: 0
re_verification:
  previous_status: human_needed
  previous_score: 4/4
  gaps_closed:
    - "同一インスタンスへ同一ミリ秒に並行 POST /prompt しても turnId が全件一意になる（HT-PROTOCOL §3.2 -<seq> 連番ガード）"
    - "ベースタイムスタンプ衝突時に単調増加の数値サフィックス -<seq> が付与される"
    - "壁時計後退時に過去 turnId を再発番しない（CR-01 単調非減少クランプ）"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "複数インスタンスを実際に同時起動し、各 /info が正しいエージェント名を返すことを確認"
    expected: "just up-all 実行後、curl localhost:8080/info が {\"agent\":\"claude\",...}、curl localhost:8081/info が {\"agent\":\"codex\",...}、curl localhost:8082/info が {\"agent\":\"opencode\",...} を返す"
    why_human: "ht-mcp + claude/codex/opencode の実バイナリが必要。cargo テストでは代替不可。"
  - test: "/info の status フィールドがターン実行中は busy、完了後は idle になることを確認（WR-03 セマンティクス）"
    expected: "POST /prompt 直後の GET /info で status=busy、ターン完了後に status=idle が返る。in_flight 方式（キュー投入時点で busy）が意図したロードバランサ契約に合っているか確認"
    why_human: "WR-03 で busy の定義がデキューからキュー投入に変わった（in_flight > 0 で判定）。この変更がスケジューラ/ロードバランサ用途として正しい契約かは運用者の判断が必要。テストは初期値（in_flight=0 → idle）しか検証していない。"
---

# Phase 6: Multi-Instance Parallel Foundation — Verification Report (Re-verification)

**Phase Goal:** 複数エージェントのインスタンスを同時に立ち上げ、各インスタンスの状態を `GET /info` で観測しながら独立して curl で叩ける環境が整う。
**Verified:** 2026-06-15T09:42:00Z
**Status:** human_needed
**Re-verification:** Yes — after 06-04 gap closure (turnId collision fix + CR-01 backward-clock clamp)

## Re-verification Scope

This re-verification focuses exclusively on the 06-04 gap-closure must-haves. All truths from
the initial 06-VERIFICATION.md (score 4/4) are carried forward as VERIFIED without regression;
regression checks below confirm no regressions were introduced.

The UAT Test 2 gap was: same-instance, same-millisecond concurrent `POST /prompt` produced
colliding turnIds (`YYYYMMDD-HHMMSS-mmm`) that overwrote each other's prompt/result/status
files. Plan 06-04 introduced `TurnIdAllocator` to close this gap. A subsequent code review
(06-04-REVIEW.md) identified CR-01: the initial implementation used `base != last_base` as
its branching condition, which allows NTP clock regression to re-emit a previously-issued bare
turnId. The fix was to replace with `base > last_base` (strictly-greater), clamping backward
clock movements to the existing `last_base` and incrementing `seq`.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `GET /info` が稼働中のエージェント名・port・status・uptime・処理ターン数を含む JSON を返す | VERIFIED (carried) | 初回検証 VERIFIED。info_handler 実装変更なし。38テスト全グリーンで回帰なし |
| 2 | `scripts/launch-agents.sh up` が instances.conf の各行を別ポートで一括起動し、各 `/info` が正しいエージェント名を返す | VERIFIED (code) / NEEDS HUMAN (runtime) | 初回検証と変わらず。06-04 はスクリプトを変更しない |
| 3 | 複数インスタンス同時稼働中のターンファイルコリジョン非発生（`TURNS_DIR` 分離で保証） | VERIFIED (code) / NEEDS HUMAN (runtime) | クロスインスタンス分離: UAT で確認済み。同一インスタンス内コリジョン: TurnIdAllocator で解消（下記 06-04 Truths 1-5 参照） |
| 4 | README に多重インスタンス起動手順・CODEX_HOME 分離手順・クレデンシャル分離ガイドが記載されている | VERIFIED (carried) | 06-04 はドキュメントを変更しない。回帰なし |
| 5 | 同一インスタンスへ同一ミリ秒に N 並行 POST /prompt しても turnId が全件一意（HT-PROTOCOL §3.2 -<seq> 連番ガード） | VERIFIED | `next_turn_id()` が `tokio::sync::Mutex<TurnIdAllocatorState>` を単一直列化点として、`base > s.last_base` 分岐でリセットか連番を決定。N=1000 並行採番テスト(multi_thread, 4 workers)が 38/38 passed で 0 重複確認 |
| 6 | ベースタイムスタンプ衝突時に単調増加の数値サフィックス -<seq>（例 20260615-090456-080-001）が付与される | VERIFIED | `else` 分岐: `s.seq.checked_add(1)` + `format!("{}-{:03}", s.last_base, s.seq)` (http.rs:112-115)。Test 3 が `with_seed("29991231-235959-999",0)` で全件クランプ経路に強制し、4セグメント・全数字サフィックスを決定論的に検証 |
| 7 | 採番後の turn_id が既存ホワイトリスト `^[0-9-]+$` を満たす（英字なし） | VERIFIED | bare base: `YYYYMMDD-HHMMSS-mmm` = 数字+ハイフンのみ。サフィックス付き: `{base}-{seq:03}` = 数字+ハイフンのみ（英字形式 `-w02` は不採用）。Test 2 が N=1000 全件に `c.is_ascii_digit() \|\| c == '-'` を assert |
| 8 | prompt_handler が採番のために worker Mutex を取得しない（CR-01 維持） | VERIFIED | `prompt_handler`(http.rs:187-244) は `state.turn_id_alloc.next_turn_id().await` のみで採番。`worker.lock()` 呼び出しは `command_handler`(line 287) と `restart_handler`(line 315) にのみ存在。既存テスト `prompt_handler_returns_turn_id_immediately_while_worker_mutex_is_held` が worker Mutex 保持中に 2 秒以内で 200 を返すことを検証(green) |
| 9 | 壁時計が後退（NTP 補正等）しても過去 turnId を再発番しない（CR-01 単調非減少クランプ） | VERIFIED | `if base > s.last_base` (http.rs:100) — 厳密に大きい場合のみ新 base を採用。それ以外（同一 ms および後退）は `else` ブランチで `last_base` を維持し `seq` を進める。後退クランプ回帰テスト `turn_id_allocator_clamps_on_backward_clock_no_bare_reemit` が `with_seed("29991231-235959-999",0)` で 50 回採番し全件が seed より辞書順で大きく 4 セグメントであることを assert (green) |

**Score:** 9/9 truths verified (2 runtime truths carried as NEEDS HUMAN)

## 06-04 Gap-Closure Artifacts

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/http.rs` | `TurnIdAllocator` struct + `next_turn_id()` + `AppState.turn_id_alloc` + `prompt_handler` 採番置換 + 並行採番テスト + 後退クランプテスト | VERIFIED | `pub struct TurnIdAllocator` (line 46), `pub async fn next_turn_id` (line 96), `pub turn_id_alloc: Arc<TurnIdAllocator>` in AppState (line 146), `state.turn_id_alloc.next_turn_id().await` in prompt_handler (line 192), 4 tests (lines 716, 753, 789, 851) |
| `src/main.rs` | `TurnIdAllocator` import + `AppState.turn_id_alloc` 配線 | VERIFIED | `use ht_webif::http::{..., TurnIdAllocator}` (line 12), `turn_id_alloc: Arc::new(TurnIdAllocator::new())` in AppState (line 74) |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/http.rs prompt_handler` | `AppState.turn_id_alloc` | `state.turn_id_alloc.next_turn_id().await` (line 192) | VERIFIED | worker.lock() not called in prompt_handler (confirmed by grep: lines 287, 315 belong to command_handler and restart_handler) |
| `src/main.rs` | `AppState.turn_id_alloc` | `Arc::new(TurnIdAllocator::new())` (line 74) | VERIFIED | Import on line 12, construction on line 74 |

### Behavioral Spot-Checks (06-04 scope)

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| 全38テストグリーン（新規4テスト含む） | `cargo test` | 38 passed, 0 failed, finished in 1.02s | PASS |
| `cargo fmt --check` 差分なし | `cargo fmt --check` | exit 0, FMT_CLEAN | PASS |
| `cargo clippy -- -D warnings` 警告なし | `cargo clippy -- -D warnings` | Finished, 0 warnings | PASS |
| N=1000 並行採番一意性（multi_thread, 4 workers） | test `turn_id_allocator_concurrent_uniqueness_n1000` | passed | PASS |
| 全採番結果が `^[0-9-]+$` を満たす | test `turn_id_allocator_all_ids_pass_whitelist` | passed | PASS |
| サフィックス付き ID が `<base>-NNN` 形式（決定論的） | test `turn_id_allocator_suffix_segment_is_three_digit_numeric` | passed | PASS |
| 壁時計後退時に過去 turnId を再発番しない | test `turn_id_allocator_clamps_on_backward_clock_no_bare_reemit` | passed | PASS |
| prompt_handler が worker Mutex を取得しない | test `prompt_handler_returns_turn_id_immediately_while_worker_mutex_is_held` | passed | PASS |

### CR-01 (Code Review Finding) — Backward-Clock Clamp Verification

The code review (06-04-REVIEW.md) identified that the original `base != last_base` condition
allowed NTP clock regression to re-emit a previously-issued bare turnId. The fix required
changing to `base > last_base` (strictly-greater monotonic check).

**Verified at src/http.rs:100:**
```rust
if base > s.last_base {          // CORRECT: strictly greater → new base, seq reset
    s.last_base = base.clone();
    s.seq = 0;
    base
} else {
    // same-ms OR backward clock: clamp to last_base, increment seq
    s.seq = s.seq.checked_add(1).expect(...);
    format!("{}-{:03}", s.last_base, s.seq)
}
```

The condition is `base > s.last_base` — not `base != s.last_base`. Both `==` (same-ms) and
`<` (backward clock) fall into the `else` branch. The `with_seed("29991231-235959-999", 0)`
regression test forces all 50 sequential calls into the clamp path and asserts every result
is lexicographically greater than the seed (i.e., no bare re-emission of the seed itself).

### WR-01 (u32 Overflow) Verification

`s.seq = s.seq.checked_add(1).expect(...)` at line 112. Silent release-mode wrap is
impossible; overflow panics with a Japanese-language message. VERIFIED.

### WR-02 (Test 3 determinism) Verification

Test 3 (`turn_id_allocator_suffix_segment_is_three_digit_numeric`) now seeds `last_base =
"29991231-235959-999"` via `TurnIdAllocator::with_seed`, ensuring all N=1000 calls fall into
the clamp path. `assert!(!suffixed.is_empty())` prevents no-op pass. VERIFIED.

### WR-03 (multi_thread flavor) Verification

Tests 1 and 2 annotated with `#[tokio::test(flavor = "multi_thread", worker_threads = 4)]`,
exercising genuine OS-thread Mutex contention rather than cooperative single-thread
interleaving. VERIFIED.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PARA-01 | Plan 01 | `GET /info` がエージェント名・port・status を JSON で返す | SATISFIED | 初回検証から変更なし |
| PARA-02 | Plan 01 | `/info` が uptime・処理ターン数を含む | SATISFIED | 初回検証から変更なし |
| PARA-03 | Plan 02, 04 | launcher で複数インスタンス一括起動＋turnId コリジョン防止 | SATISFIED (code) | launch-agents.sh 実装確認（初回）+ TurnIdAllocator による同一インスタンス内 turnId 一意性（06-04）。実動作は human 検証 |
| PARA-04 | Plans 02+03 | PORT/TURNS_DIR 分離で並列動作、Codex credential 分離ドキュメント | SATISFIED | 初回検証から変更なし |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none found in 06-04 modified files) | — | — | — | — |

Debt-marker scan on `src/http.rs` and `src/main.rs`: no TBD/FIXME/XXX markers found.

### Human Verification Required

The UAT Test 2 gap (same-instance turnId collision) is now CLOSED in code and verified by
automated tests. The two remaining human verification items are carried forward from the
initial verification — they are unaffected by 06-04:

#### 1. 複数インスタンス同時起動と /info エージェント名確認

**Test:** `just up-all` を実行し、起動後に各ポートへ `curl -s localhost:808{0,1,2}/info | jq .agent` を実行する
**Expected:** `"claude"`, `"codex"`, `"opencode"` がそれぞれ返る
**Why human:** ht-mcp + claude/codex/opencode の実バイナリが必要。UAT Test 1 で claude と opencode は確認済み。codex は CODEX_HOME 設定後に確認必要

#### 2. /info の busy セマンティクス確認（WR-03 変更後）

**Test:** `POST /prompt {"prompt":"..."}` 投入直後（worker がまだデキューしていないタイミング）に `GET /info` を呼ぶ
**Expected:** `status: "busy"` が返る（in_flight = 1 のため）。ターン完了後に `status: "idle"` に戻る
**Why human:** WR-03 で `status` の判定が `is_busy`（デキュー時）から `in_flight > 0`（キュー投入時）に変更。この変更がロードバランサとして期待する契約と一致するか運用者の確認が必要。UAT Test 3 で確認済みだが、運用者の明示的承認が記録されていない

### Gaps Summary

No technical gaps. The 06-04 gap (UAT Test 2: same-instance turnId collision) is fully
closed:

- `TurnIdAllocator` exists, is substantive, is wired into `AppState` and `prompt_handler`,
  and data flows through it for every `POST /prompt`
- The backward-clock clamp (CR-01 review finding) is implemented with the correct `base >
  s.last_base` condition (strictly-greater), not the weaker `!=` condition
- All code-review findings (CR-01, WR-01, WR-02, WR-03) are resolved per 06-04-REVIEW.md
  frontmatter (`status: clean`, `resolved_in: 6bf2f98`)
- 38/38 tests pass including 4 new TurnIdAllocator regression tests and all pre-existing tests
- `cargo fmt --check` clean, `cargo clippy -- -D warnings` 0 warnings

The `human_needed` status reflects 2 runtime behaviors that require real agent binaries or
operator judgment — not any code deficiency.

---

_Verified: 2026-06-15T09:42:00Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — 06-04 gap closure_
