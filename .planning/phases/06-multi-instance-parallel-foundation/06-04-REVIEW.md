---
phase: 06-multi-instance-parallel-foundation
plan: 06-04-turnid-collision
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - src/http.rs
  - src/main.rs
findings:
  critical: 1
  warning: 3
  info: 1
  total: 5
status: issues_found
---

# Phase 06 / Plan 06-04: Code Review Report (turnId collision fix)

**Reviewed:** 2026-06-15
**Depth:** standard
**Files Reviewed:** 2 (src/http.rs, src/main.rs)
**Status:** issues_found

> Note: this is the gap-closure review for plan 06-04 (turnId collision). The broader
> phase-06 review lives in `06-REVIEW.md`; this artifact is scoped to commits
> `aa9f2b6` and `1d088b6`.

## Summary

This gap-closure introduces `TurnIdAllocator`, a `tokio::sync::Mutex`-guarded single
serialization point that appends a `-<seq>` numeric suffix on same-millisecond timestamp
collisions, wires it into `AppState` / `main.rs`, and adds three N=1000 concurrency
regression tests.

The invariants that were the *stated* goal of the change are met:
- **Same-process concurrent uniqueness** holds. The lock makes the
  `compare base → reset/increment seq → format` step atomic, so two concurrent callers
  landing on the same millisecond receive `base` and `base-001` (never the same string).
- **Whitelist conformance** holds. Both bare (`YYYYMMDD-HHMMSS-mmm`) and suffixed
  (`...-NNN`) forms contain only digits and hyphens, satisfying `^[0-9-]+$` at
  turn_handler:226. Even >999 same-ms collisions (4+ digit suffix) stay whitelist-safe.
- **CR-01 preserved.** The allocator is a separate `Mutex` from the worker `Mutex`; the
  guard is held only across in-memory string formatting (http.rs:80–90) and dropped
  before any `.await`. `prompt_handler` awaits `next_turn_id()` and only then touches the
  filesystem — no worker-Mutex contention is reintroduced.

However, the uniqueness guarantee rests on an unstated and false assumption — that
`chrono::Utc::now()` is monotonic. It is not. Under wall-clock regression the allocator
re-emits a previously-issued bare turnId, silently defeating the very invariant this plan
exists to protect. The N=1000 same-process test cannot detect this because it never moves
the clock backward. That is the central finding below.

## Critical Issues

### CR-01: Wall-clock regression re-emits a previously-issued turnId (uniqueness broken)

**File:** `src/http.rs:78-91`
**Issue:**
`next_turn_id()` derives `base` from `chrono::Utc::now()`, a non-monotonic wall clock.
The uniqueness invariant only holds if the formatted millisecond string is monotonically
non-decreasing across the *lifetime* of the allocator. It is not: NTP step adjustments,
manual clock changes, VM clock resync after suspend/migrate, or leap-second smearing can
move `Utc::now()` backward by more than one millisecond.

Concrete failure:

1. t = `20260615-090456-080` → new base, `seq=0`, returns bare `20260615-090456-080`.
2. clock steps backward (NTP) so a later call again formats to `20260615-090456-080`.
3. `base != s.last_base` is **true** (last_base now holds a later value), so the branch
   resets `seq=0` and returns the bare `20260615-090456-080` **again** — a duplicate of
   step 1.

A duplicate turnId means `prompt-<id>.txt` / `result-<id>.txt` / `status-<id>.json` from
the earlier turn are overwritten by the later one (files are keyed solely by path on
turn_id), so the first turn's result/status are clobbered and a GET /turns/{id} for the
first turn returns the second turn's data. This is data loss + cross-turn result
confusion — exactly the class of bug 06-04 was opened to eliminate. The collision-fix
only closed the *same-millisecond forward* case, not the *clock-goes-backward* case.

The `last_base != base` equality check is the wrong invariant. The allocator must enforce
*monotonic non-decreasing* base, not merely *different from the immediately previous* base.

**Fix:** When the freshly read `base` sorts strictly *before* `last_base` (lexicographic
compare is valid for the fixed-width `YYYYMMDD-HHMMSS-mmm` format), clamp to `last_base`
and continue the existing seq rather than resetting:

```rust
pub async fn next_turn_id(&self) -> String {
    let now = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();
    let mut s = self.state.lock().await;
    if now > s.last_base {
        // 時計が前進: 新 base、seq リセット、サフィックス無しで後方互換
        s.last_base = now.clone();
        s.seq = 0;
        now
    } else {
        // 同一 ms または時計が後退（NTP 補正等）: 直前 base に張り付けて連番継続。
        // これで Utc::now() が単調でなくても turnId は単調かつ一意になる。
        s.seq += 1;
        format!("{}-{:03}", s.last_base, s.seq)
    }
}
```

This also subsumes the same-ms case (`now == s.last_base` falls into the `else` branch).
Add a regression test that seeds `last_base` to a future timestamp and asserts the next ID
neither duplicates nor sorts before it.

## Warnings

### WR-01: `seq` u32 overflow wraps (release) / panics (debug) at the boundary

**File:** `src/http.rs:88`
**Issue:**
`s.seq += 1` on a `u32`. After `u32::MAX` increments within a single base run it panics in
debug builds and silently wraps to `0` in release builds. The trigger (≈4.29 billion
allocations pinned to one base) is unreachable under normal wall-clock advance, but with
the CR-01 fix that pins many IDs to a stuck `last_base` during a long backward-clock
excursion, the seq space becomes the *sole* uniqueness guarantee, so unbounded silent
growth is no longer purely theoretical.

**Fix:** Use `checked_add` (or widen to `u64`) so the wrap can never be silent:
```rust
s.seq = s.seq.checked_add(1).expect("turnId seq が u32 を溢れた（同一 base 連番が異常）");
```

### WR-02: Test 3 can silently pass without exercising the suffix path

**File:** `src/http.rs:759-797`
**Issue:**
`turn_id_allocator_suffix_segment_is_three_digit_numeric` filters for 4-segment
(suffixed) IDs and only asserts on those. The test's own comment admits that if all 1000
allocations land on distinct milliseconds, `suffixed` is empty and the loop body never
runs — the test passes green while asserting nothing. The collision this whole plan
targets is precisely the same-ms case, so its regression test must *guarantee* it fires;
relying on timing makes it a non-deterministic no-op that gives false confidence.

**Fix:** Force the collision deterministically (test-only constructor seeding `last_base`,
or a `#[cfg(test)]` state setter), then assert the next `next_turn_id()` is suffixed.
Alternatively assert `!suffixed.is_empty()` so it fails loudly when it cannot reproduce.

### WR-03: Same-ms collision under genuine multi-thread parallelism is untested

**File:** `src/http.rs:688-717`
**Issue:**
`turn_id_allocator_concurrent_uniqueness_n1000` runs under the default `#[tokio::test]`
(single-threaded current-thread runtime), so the 1000 spawned tasks are cooperatively
interleaved on one OS thread, not truly parallel. The Mutex-contention path and any data
race are not exercised the way real concurrent threads would, yet "並行採番" implies exactly
that. The test demonstrates interleaving safety, not multi-thread safety.

**Fix:** Annotate the uniqueness tests with
`#[tokio::test(flavor = "multi_thread", worker_threads = 4)]` to genuinely contend the lock
across threads.

## Info

### IN-01: Doc comment implies a fixed 3-digit suffix width

**File:** `src/http.rs:72-75`
**Issue:**
The rustdoc says the suffix is "3 桁ゼロ埋め" without noting that >999 same-base collisions
produce a 4+ digit suffix (still whitelist-valid). With CR-01/WR-01 able to pin many IDs to
one base, a future reader could wrongly assume fixed width when parsing IDs back into
segments.

**Fix:** Reword to "最小 3 桁ゼロ埋め（衝突が 999 を超えた場合は 4 桁以上に伸長。いずれも
英字を含まずホワイトリスト適合）".

---

_Reviewed: 2026-06-15_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
