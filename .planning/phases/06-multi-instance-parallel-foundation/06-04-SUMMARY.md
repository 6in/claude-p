---
phase: 06-multi-instance-parallel-foundation
plan: 04
subsystem: http
tags: [rust, turnid, concurrency, allocator, hashing, tdd]

# Dependency graph
requires:
  - phase: 06-01
    provides: "CR-01 worker-Mutex 競合除去 (prompt_handler が worker.lock() を呼ばない)"
  - phase: 06-02
    provides: "AppState.output_covenant lock-free フィールド"
  - phase: 06-03
    provides: "AppState.instance_info lock-free フィールド"
provides:
  - "TurnIdAllocator struct + next_turn_id() — HT-PROTOCOL §3.2 衝突時 -<seq> 連番"
  - "AppState.turn_id_alloc: Arc<TurnIdAllocator> — 採番の単一直列化点"
  - "N=1000 並行採番一意性回帰テスト (3 件)"
  - "src/main.rs TurnIdAllocator 配線"
affects: [prompt_handler, turn_handler, tests, main]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TurnIdAllocator pattern: tokio::sync::Mutex<{last_base, seq}> で base+seq 結合不変条件を単一直列化点で保護"
    - "next_turn_id(): base が変われば seq リセット → base そのまま返す; base 一致なら seq++ → {base}-{seq:03} 返す"
    - "Default impl を追加して clippy new_without_default を満たす"
    - "並行採番テスト: Arc::clone → tokio::spawn × N → JoinHandle::await → HashSet uniqueness assert"

key-files:
  created: []
  modified:
    - src/http.rs
    - src/main.rs

key-decisions:
  - "tokio::sync::Mutex を選択: base と seq の結合不変条件を CAS なしに保護するため。std::sync::Mutex でも可だが CLAUDE.md async/lock 慣習に従い tokio を選択"
  - "サフィックスは -NNN（3 桁ゼロ埋め数値 + ハイフンのみ）: ^[0-9-]+$ ホワイトリスト適合。-w02 のような英字形式は whitelist 違反のため不採用"
  - "Default impl 追加: clippy::new_without_default を -D warnings で満たすため"
  - "main.rs は Task 1 内でもブロックコンパイルエラー対応として先行して wiring を追加（Rule 3 blocking fix）"

# Metrics
duration: 8min
completed: 2026-06-15T09:30:34Z
---

# Phase 6 Plan 04: TurnId Collision Gap Closure Summary

**TurnIdAllocator (tokio::sync::Mutex-guarded base+seq state) with N=1000 concurrent uniqueness regression tests — HT-PROTOCOL §3.2 gap closed**

## Accomplishments

- `src/http.rs`: Added `pub struct TurnIdAllocator` with internal `TurnIdAllocatorState { last_base: String, seq: u32 }` protected by `tokio::sync::Mutex`. `pub async fn next_turn_id(&self) -> String` returns bare base on new millisecond, `{base}-{seq:03}` on collision. `Default` impl added for clippy compliance.
- `src/http.rs`: Added `pub turn_id_alloc: Arc<TurnIdAllocator>` field to `AppState`.
- `src/http.rs`: Replaced `prompt_handler`'s `chrono::Utc::now().format(...)` direct call (line 92, pre-patch) with `state.turn_id_alloc.next_turn_id().await`. Worker Mutex is never acquired for allocation (CR-01 preserved).
- `src/http.rs`: Updated `build_test_state` to include `turn_id_alloc: Arc::new(TurnIdAllocator::new())`.
- `src/http.rs`: Added 3 regression tests (Test 1: N=1000 concurrent uniqueness via HashSet; Test 2: all IDs pass `^[0-9-]+$` whitelist; Test 3: suffixed entries have 3-digit numeric segment).
- `src/main.rs`: Import and wire `Arc::new(TurnIdAllocator::new())` into `AppState` construction.

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | TurnIdAllocator + AppState wiring | `aa9f2b6` | src/http.rs, src/main.rs |
| 2 | N=1000 regression tests + fmt | `1d088b6` | src/http.rs |

## Verification Results

- `cargo build`: clean (0 errors)
- `cargo test`: 37/37 passed (10 http tests incl. 3 new + 27 others)
- N=1000 concurrent `next_turn_id()` tasks: 0 duplicates
- `cargo fmt --check`: no diff
- `cargo clippy -- -D warnings`: 0 warnings

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] main.rs compile error at Task 1 verification**

- **Found during:** Task 1 cargo build
- **Issue:** Adding `turn_id_alloc` field to `AppState` caused `E0063: missing field turn_id_alloc in initializer of AppState<_>` in `src/main.rs:67`. Task 1 acceptance criterion requires `cargo build` to exit 0.
- **Fix:** Added `TurnIdAllocator` import and `turn_id_alloc: Arc::new(TurnIdAllocator::new())` to `AppState` construction in `main.rs` within Task 1 commit. Task 2's plan action for main.rs wiring was subsumed by this fix.
- **Files modified:** src/main.rs
- **Committed in:** aa9f2b6 (Task 1 commit)

**2. [Rule 2 - Missing critical functionality] Missing Default impl for TurnIdAllocator**

- **Found during:** Task 1 `cargo clippy -- -D warnings`
- **Issue:** `TurnIdAllocator::new()` with no args triggers `clippy::new_without_default` under `-D warnings`. CI requires warnings-free.
- **Fix:** Added `impl Default for TurnIdAllocator { fn default() -> Self { Self::new() } }` before the `impl TurnIdAllocator` block.
- **Files modified:** src/http.rs
- **Committed in:** aa9f2b6 (Task 1 commit)

**3. [Rule 1 - Bug] cargo fmt formatting fix**

- **Found during:** Task 2 `cargo fmt --check`
- **Issue:** Multiline `chrono::Utc::now().format(...).to_string()` in `next_turn_id()` exceeded rustfmt's line-break threshold, causing fmt diff.
- **Fix:** `cargo fmt` applied (collapses to single line, fits within column limit).
- **Files modified:** src/http.rs
- **Committed in:** 1d088b6 (Task 2 commit)

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes beyond what the threat model covers.

| Flag | File | Description |
|------|------|-------------|
| (none) | — | T-06-G1/G2/G3/G4 all mitigated as designed: TurnIdAllocator closes §3.2 uniqueness gap; suffix is digits+hyphens only; lock is never held across await |

## Known Stubs

None — all allocated IDs are immediately used for real filesystem paths in `prompt_handler`.

## Self-Check

- [x] `src/http.rs` modified — confirmed exists and contains `TurnIdAllocator`
- [x] `src/main.rs` modified — confirmed exists and imports `TurnIdAllocator`
- [x] Commit `aa9f2b6` — Task 1
- [x] Commit `1d088b6` — Task 2
- [x] 37 tests green, fmt clean, clippy clean

## Self-Check: PASSED
