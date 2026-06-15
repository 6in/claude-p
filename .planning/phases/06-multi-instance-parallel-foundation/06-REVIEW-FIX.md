---
phase: 06-multi-instance-parallel-foundation
fixed_at: 2026-06-15T08:09:00Z
review_path: .planning/phases/06-multi-instance-parallel-foundation/06-REVIEW.md
iteration: 1
findings_in_scope: 7
fixed: 7
skipped: 0
status: all_fixed
---

# Phase 6: Code Review Fix Report

**Fixed at:** 2026-06-15T08:09:00Z
**Source review:** .planning/phases/06-multi-instance-parallel-foundation/06-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 7 (CR-01 + WR-01..06)
- Fixed: 7
- Skipped: 0
- Info findings (IN-01..03): intentionally out of scope, untouched.

**Gate results after all fixes:**
- `cargo build --release`: clean
- `cargo test --release`: 34 passed, 0 failed
- `cargo clippy --release --all-targets`: no warnings/errors
- `bash -n scripts/launch-agents.sh`: clean

## Fixed Issues

### CR-01: down-all sends SIGTERM to the `cargo run` wrapper, orphaning the real server

**Files modified:** `scripts/launch-agents.sh`
**Commit:** 379eb68
**Applied fix:** Switched from `cargo run --release` to launching the prebuilt binary
`${WEBIF_DIR}/target/release/ht-webif` directly. `cmd_up` now runs `cargo build --release`
once up-front (before the per-instance loop) and verifies the binary is executable. Because
the server is spawned directly, `$!` is the real `ht-webif` PID, so `down-all`'s
`kill -TERM`/`kill -KILL` reach the actual server (and its ht-mcp/claude children are no
longer orphaned). Chose the "run prebuilt binary" option from the review over the `setsid`
process-group option because it is simpler and removes the wrapper entirely.

### WR-01: TURNS_DIR contract divergence — launcher reports `turns-${port}/`, server writes `turns-${port}/<agent>/`

**Files modified:** `scripts/launch-agents.sh`
**Commit:** 1f0be1e
**Applied fix:** Reconciled launcher reporting with the server's effective path. `main.rs:51`
applies D-16 (`turns_base.join(&agent_name)`), so the real artifact directory is
`turns-${port}/<agent>/`. Changes: (1) `cmd_up` and `cmd_status` now compute and report
`turns_dir="${WEBIF_DIR}/turns-${port}/${agent}"`; (2) the `TURNS_DIR` env passed to the
server stays `turns-${port}` (the server appends `<agent>`); (3) removed the redundant/wrong
`mkdir -p turns-${port}` pre-creation (the server `create_dir_all`s the real path);
(4) corrected the header-comment collision-avoidance claim to state that port isolation comes
from the launcher injecting distinct `turns-${port}` per port, not from D-16's `<agent>/`
suffix (which is identical across same-agent instances).

### WR-02: Credential env values containing spaces are silently split and dropped

**Files modified:** `scripts/launch-agents.sh`, `instances.conf`
**Commit:** f4749ae
**Applied fix:** Replaced the awk-rejoin + `tr ' ' '\n'` re-split with a single array parse:
`read -ra fields <<< "$line"` then `extra_kvs=("${fields[@]:2}")`. The subshell export loop
now iterates the array directly (`for kv in "${extra_kvs[@]}"`), preserving token boundaries
so a `KEY=VALUE` token is no longer corrupted by re-splitting. Documented in `instances.conf`
(per the review's recommendation) that the column separator is whitespace, so a VALUE itself
may not contain spaces; suggested symlinking around space-containing paths. (A full
quoting-aware parser was not added — the documented constraint matches the conf format.)

### WR-03: `is_busy` reports "idle" while a turn is queued but not yet dequeued

**Files modified:** `src/http.rs`, `src/turn.rs`, `src/main.rs`
**Commit:** 07aa30c
**Status:** fixed — requires human verification (logic/load-signal change)
**Applied fix:** Added `in_flight: AtomicU64` to `InstanceInfo`. `prompt_handler` increments
it after a successful `job_tx.send`; `worker_loop` decrements it after `process_job`. The
`/info` `status` field is now derived from `in_flight > 0` instead of `is_busy`, so a job that
is enqueued-but-not-yet-dequeued (and any backlog in the bounded(64) mpsc) is reported as
`busy`. The lock-free contract is preserved: `info_handler` still never takes the worker
`Mutex` — `in_flight` is a `Relaxed` atomic. `is_busy` is retained as the "actively running"
flag. Constructors in `main.rs` and the http test helper were updated for the new field.
Flagged for human verification because this changes the semantic meaning of the load signal
(busy now includes queue depth, not just active execution) — confirm this matches the intended
scheduler/load-balancer contract.

### WR-04: `cmd_up` exits the whole run on the first slow/failed instance

**Files modified:** `scripts/launch-agents.sh`
**Commit:** e839e30
**Applied fix:** Introduced a `failures` counter before the instance loop. The three in-loop
`exit 1` sites (PID file not created, early process death, readiness timeout) now increment
`failures` and `continue` to the next instance instead of aborting. The early-death case is
inside the `for i in $(seq 1 60)` readiness loop, so it uses `continue 2` to skip to the next
instance in the outer `while`. After the loop, `cmd_up` exits non-zero once if
`failures > 0`, reporting the count. This lets the launcher bring up the instances that can
start and report the rest as failed.

### WR-05: PID files are read without validating they contain a numeric PID

**Files modified:** `scripts/launch-agents.sh`
**Commit:** 34845dd
**Applied fix:** Added `^[0-9]+$` validation after every `cat "$pid_file"` (made tolerant with
`2>/dev/null || true`) at all three read sites — `cmd_up` (existing-PID check), `cmd_down_all`,
and `cmd_status`. Empty/non-numeric PID files (partial writes, crash-truncated files) are now
logged and removed rather than passed to `kill`. This closes the gap where an empty PID made
`down-all` believe a live server was "already stopped" and `rm` its PID file, abandoning the
running process.

### WR-06: Readiness poll cannot distinguish "wrong agent on this port" from "not ready yet"

**Files modified:** `scripts/launch-agents.sh`
**Commit:** 72909b1
**Applied fix:** `check_info_agent` now returns a tri-state: `0` = ready (agent matches),
`1` = not responding / no agent field (still starting), `2` = `/info` responds but reports a
different agent (port collision). The `cmd_up` readiness loop captures the return code via the
`rc=0; check_info_agent ... || rc=$?` idiom (set -e safe) and treats `2` as an immediate hard
failure: it logs a distinct "port is in use by a different agent" message, cleans up only the
PID it spawned (`kill -TERM "$pid"` + `rm` the pid file), counts the failure (WR-04), and
`continue 2` to the next instance. The post-loop timeout check also distinguishes `2` from a
plain no-response timeout. Operators now get the correct diagnosis for a responding-but-wrong
server instead of a misleading "no response" message.

## Skipped Issues

None — all in-scope findings were fixed.

---

_Fixed: 2026-06-15T08:09:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
