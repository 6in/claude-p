---
phase: 06-multi-instance-parallel-foundation
plan: 01
subsystem: api
tags: [rust, axum, atomic, lock-free, observability, multi-instance]

# Dependency graph
requires:
  - phase: 05-codex-cli-and-opencode-validation
    provides: "validated agent profiles, turn pipeline, worker_loop baseline"
provides:
  - "InstanceInfo struct (agent_name/port/started_at/is_busy/turns_processed) in src/http.rs"
  - "AppState.instance_info: Arc<InstanceInfo> field — lock-free, CR-01 pattern"
  - "info_handler<M> — GET /info returning 5-field JSON, zero Mutex acquisition (D-02)"
  - "worker_loop gains instance_info param, is_busy toggle on job start/end (D-01), turns_processed.fetch_add per completion (D-04)"
  - "main.rs: InstanceInfo construction with load_port() moved early, single load, wired to AppState + worker_loop"
  - "co-located test asserting /info returns agent/port/status/uptime_secs/turns_processed with correct initial values"
affects: [06-02-launcher, 06-03-justfile, future-multi-agent-orchestration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "InstanceInfo lock-free pattern: AtomicBool + AtomicU64 inside Arc<InstanceInfo>; handler reads directly without acquiring worker Mutex (D-02/D-05, extends CR-01)"
    - "Ordering::Relaxed for all atomic reads/writes in /info path — no cross-thread ordering guarantee required for status poll"
    - "load_port() moved before InstanceInfo construction to avoid duplicate env lookup; addr binding reuses same port binding"

key-files:
  created: []
  modified:
    - src/http.rs
    - src/turn.rs
    - src/main.rs

key-decisions:
  - "InstanceInfo placed in src/http.rs alongside AppState (not a new src/instance.rs) — minimizes file count, co-located with handler that uses it"
  - "turns_processed counts both successful and failed turn completions (D-05 Discretion: total attempts, not success-only)"
  - "std::time::Instant used for started_at (not chrono::DateTime) — wall clock is sufficient for uptime_secs, no JSON serialization needed"
  - "info_handler returns Json<Value> (not Result<Json<Value>, ...>) — handler cannot fail, ise helper not needed"
  - "is_busy.store(true) placed before worker.lock() — indicates pending/processing state from the moment a job is dequeued, not just when worker lock is acquired"

patterns-established:
  - "Pattern: AppState lock-free field for hot-path read (CR-01) extended to atomic metrics — clone Arc into AppState + worker_loop, read directly in handler"
  - "Pattern: worker_loop wraps process_job result in local binding; atomic updates happen after process_job returns (success or failure) before if let Err dispatch"

requirements-completed: [PARA-01, PARA-02]

# Metrics
duration: 6min
completed: 2026-06-15
---

# Phase 6 Plan 01: GET /info Endpoint — lock-free instance observability with AtomicBool/AtomicU64 status and turn counter

**lock-free GET /info endpoint returning agent/port/status(idle|busy)/uptime_secs/turns_processed via Arc<InstanceInfo> with AtomicBool/AtomicU64, zero worker Mutex acquisition**

## Performance

- **Duration:** 6 min
- **Started:** 2026-06-15T07:31:36Z
- **Completed:** 2026-06-15T07:36:00Z
- **Tasks:** 2
- **Files modified:** 3 (src/http.rs, src/turn.rs, src/main.rs)

## Accomplishments

- `InstanceInfo` struct with 5 fields (agent_name/port/started_at/is_busy AtomicBool/turns_processed AtomicU64) added to src/http.rs
- `info_handler` returns D-03 5-field JSON without ever calling `state.worker.lock()` — observable even during 600s turns (D-02)
- `worker_loop` wraps each job with `is_busy` toggle (D-01) and `turns_processed.fetch_add` (D-04); both success and failure paths increment counter
- `main.rs` wires InstanceInfo with load_port() moved early, Arc cloned to AppState + worker_loop
- All 34 tests green (27 prior + 7 http tests including new /info test), clippy clean, fmt clean

## Task Commits

Each task was committed atomically:

1. **Task 1: InstanceInfo struct + info_handler + /info route + AppState field** - `8b83d9b` (feat)
2. **Task 2: worker_loop status toggle + turns counter + main.rs wiring** - `b73bff0` (feat)

## Files Created/Modified

- `src/http.rs` — InstanceInfo struct, AppState.instance_info field, info_handler, /info route in build_router, build_test_state extended, co-located test
- `src/turn.rs` — worker_loop gains instance_info param + is_busy toggle + turns_processed.fetch_add
- `src/main.rs` — load_port() moved before InstanceInfo construction; InstanceInfo built and passed to AppState + worker_loop; startup banner includes /info

## Decisions Made

- InstanceInfo placed in src/http.rs alongside AppState (not a new module) — minimizes file proliferation, co-located with handler that reads it
- `turns_processed` counts total turn completions including failures — consistent with D-05 Discretion (total, not success-only)
- `std::time::Instant` for `started_at` (not chrono) — wall clock sufficient for uptime_secs integer, avoids extra serialization logic
- `info_handler` returns `Json<Value>` without `Result` wrapper — infallible by design, no `ise` needed
- `is_busy.store(true)` placed before `worker.lock().await` — indicates processing intent from job dequeue, not just lock acquisition

## Deviations from Plan

None - plan executed exactly as written. The `tokio::time::Instant` import in http.rs was replaced by `std::time::Instant` during `cargo fmt` formatting (Instant was already in scope from `std::time`); this is a correct substitution since `prompt_handler` uses `Instant::now() + Duration` which works with std Instant identically.

## Threat Surface Scan

No new threat surface beyond what the plan's threat_model already covers:
- T-06-01 mitigated: /info response limited to exactly the 5 minimum fields (agent/port/status/uptime_secs/turns_processed); no session_id, credentials, or file paths exposed
- T-06-02 accepted: info_handler is lock-free atomic read only; no amplification vector; loopback bind only

## Issues Encountered

None - all tasks compiled and tested on first attempt.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- GET /info is live — Plan 02 launcher can use it as a readiness probe (D-09): poll `/info` until `agent` field matches expected name
- `instance_info.is_busy` / `turns_processed` expose runtime metrics for multi-instance observability
- Ready for Phase 6 Plan 02: launch-agents.sh multi-instance orchestrator

---
*Phase: 06-multi-instance-parallel-foundation*
*Completed: 2026-06-15*
