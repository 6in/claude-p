---
phase: 06-multi-instance-parallel-foundation
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - src/http.rs
  - src/turn.rs
  - src/main.rs
  - scripts/launch-agents.sh
findings:
  critical: 1
  warning: 6
  info: 3
  total: 10
status: issues_found
---

# Phase 6: Code Review Report

**Reviewed:** 2026-06-15T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Phase 6 adds a lock-free `GET /info` endpoint (`InstanceInfo` with `AtomicBool`/`AtomicU64`
metrics wired through `worker_loop`) and a config-driven multi-instance launcher
(`scripts/launch-agents.sh` with `up`/`down-all`/`status`).

The Rust side is largely sound: the lock-free contract is honored (`info_handler` never
takes the worker `Mutex`), the path-traversal whitelist is preserved on `/turns/{id}`, and
the atomics use `Relaxed` ordering appropriately for advisory metrics. No command-injection
vector reaches a shell `eval` — the launcher's `export "$kv"` guard is real.

The dominant defect is a **TURNS_DIR contract divergence** between the launcher and the
server: the launcher pre-creates and reports `turns-${port}/`, but `main.rs` (D-16) writes
turn artifacts to `turns-${port}/<agent>/`. The launcher's `status` output and operator
guidance point at the wrong directory, and same-agent multi-instance collision-avoidance is
weaker than the design claims. Secondary concerns: `down-all` targets the `cargo run` wrapper
PID (orphans the real server + ht-mcp + claude on SIGTERM), credential values containing
spaces are silently split, and the `is_busy` toggle has a queued-but-not-dequeued blind spot.

## Critical Issues

### CR-01: down-all sends SIGTERM to the `cargo run` wrapper, orphaning the real server

**File:** `scripts/launch-agents.sh:134-138`, `scripts/launch-agents.sh:225-247`
**Issue:** `cmd_up` spawns the instance as `nohup env ... cargo run --release ... &` and records
`$!` — which is the PID of the **`cargo`** wrapper process, not the compiled `ht-webif` binary.
`cargo run` execs/forks the built binary as a child and does **not** forward signals to it nor
place it in a distinct process group. When `cmd_down_all` does `kill -TERM "$pid"`, only `cargo`
receives the signal; the `ht-webif` binary (and the `ht-mcp` + `claude` TUI grandchildren it
spawned) are left orphaned and running. The follow-up `kill -KILL "$pid"` then `rm -f "$pid_file"`
removes the only handle to those leaked processes, so the next `up` will bind-fail on the port
(or worse, two live servers race the same `turns-${port}/<agent>/` directory). This silently
defeats `down-all` and breaks restart/teardown of every instance.

This pattern is inherited from `scripts/claude-p:137`, but Phase 6 multiplies it across N
instances and adds `down-all` as a first-class command that users will rely on for cleanup, so
it must be correct here.

**Fix:** Either run the prebuilt binary directly (so `$!` is the server), building first:
```bash
# build once, up-front, outside the per-instance loop
cargo build --release
# ... then per instance:
nohup env PORT="${port}" TURNS_DIR="${WEBIF_DIR}/turns-${port}" AGENT="${agent}" \
    "${WEBIF_DIR}/target/release/ht-webif" >"${log_file}" 2>&1 &
local pid=$!
```
or, if `cargo run` must stay, launch the whole instance in its own process group and signal the
group on teardown:
```bash
setsid nohup env ... cargo run --release >"${log_file}" 2>&1 &
local pid=$!            # this is the group leader
echo "$pid" > "${pid_file}"
# teardown:
kill -TERM -- "-${pid}" 2>/dev/null || true   # negative pid = process group
```

## Warnings

### WR-01: TURNS_DIR contract divergence — launcher reports/creates `turns-${port}/`, server writes `turns-${port}/<agent>/`

**File:** `scripts/launch-agents.sh:98,116,134,276,279`; cross-ref `src/main.rs:50-52`
**Issue:** The launcher exports `TURNS_DIR=${WEBIF_DIR}/turns-${port}` and pre-creates that
directory (line 116), and `cmd_status` reports `TURNS_DIR: ${turns_dir}` = `turns-${port}`
(lines 276, 279). But `main.rs:51` applies D-16 unconditionally:
`let turns_dir = turns_base.join(&agent_name);` — so the server actually reads/writes
`turns-${port}/<agent>/`. Consequences: (1) the pre-created `turns-${port}/` is unused noise;
(2) the `status` output points operators at the wrong directory (artifacts are one level
deeper); (3) the design's same-agent collision-avoidance story is misstated — two instances of
the *same* agent on different ports are isolated **only** because the launcher injects distinct
`turns-${port}` per port, not because of D-16 (D-16's `<agent>/` suffix is identical for both).
This is a correctness/observability defect, not cosmetic: anyone scripting against the reported
TURNS_DIR will read an empty directory.

**Fix:** Make the launcher agree with the server's effective path. Either resolve and report the
real directory:
```bash
local turns_dir="${WEBIF_DIR}/turns-${port}/${agent}"
mkdir -p "$turns_dir"
```
or stop pre-creating the wrong dir (server already `create_dir_all`s it) and fix only the
`status` display string to include `/${agent}`.

### WR-02: Credential env values containing spaces are silently split and dropped

**File:** `scripts/launch-agents.sh:122-131`
**Issue:** `extra_tokens` is whitespace-split via `tr ' ' '\n'`, so a single `KEY=VALUE` whose
value contains spaces (e.g. `CODEX_HOME="/home/user/My Configs/.codex"`) is broken into multiple
tokens. Only `CODEX_HOME=/home/user/My` is exported; the remaining tokens (`Configs/.codex`)
fail the `^[A-Za-z_][A-Za-z0-9_]*=` guard and are dropped with a misleading "不正な env トークン"
warning. The instance then launches with a truncated `CODEX_HOME`, silently using the wrong (or
default) credential directory — exactly the credential-isolation failure this config column
exists to prevent.

**Fix:** Preserve token boundaries instead of re-splitting on spaces. Read the KEY=VALUE tokens
directly from the original fields rather than re-joining and re-splitting:
```bash
# parse once, keep array semantics
read -ra fields <<< "$line"
agent="${fields[0]}"; port="${fields[1]}"
extra_kvs=("${fields[@]:2}")     # tokens 3..N, space-delimited per conf format
# ... later, inside the subshell:
for kv in "${extra_kvs[@]}"; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && export "$kv"
done
```
Document in `instances.conf` that values themselves may not contain spaces (whitespace is the
column separator), or switch to a quoting-aware parser if spaces must be supported.

### WR-03: `is_busy` reports "idle" while a turn is queued but not yet dequeued

**File:** `src/turn.rs:101-103`; cross-ref `src/http.rs:55-59,104-111`
**Issue:** `is_busy.store(true)` happens only when `worker_loop` dequeues a job
(`turn.rs:103`), but a job becomes observable as soon as `prompt_handler` writes the prompt file
and enqueues it (`http.rs:101-111`). Between enqueue and dequeue — and for the entire duration a
prior turn is still running while N more sit in the bounded(64) mpsc — `GET /info` returns
`status:"idle"` despite work being pending. A scheduler/load-balancer that uses `/info` to pick a
"free" instance (the stated purpose of this endpoint) will pile multiple prompts onto one busy
worker, serializing behind a 300s+ turn while truly idle instances sit unused. This is a logic
defect in the load-signal, not just a display nit.

**Fix:** Track depth at the queue boundary, e.g. flip `is_busy` (or add a `queued`/`pending`
counter) in `prompt_handler` on successful `job_tx.send`, and clear/decrement in `worker_loop`
after the turn completes. A simple `AtomicU64 in_flight` incremented at enqueue and decremented
after `process_job` gives an accurate busy signal:
```rust
// http.rs prompt_handler, after successful send:
state.instance_info.in_flight.fetch_add(1, Ordering::Relaxed);
// turn.rs worker_loop, after process_job:
let remaining = instance_info.in_flight.fetch_sub(1, Ordering::Relaxed) - 1;
instance_info.is_busy.store(remaining > 0, Ordering::Relaxed);
```

### WR-04: `cmd_up` exits the whole run on the first slow/failed instance

**File:** `scripts/launch-agents.sh:153-156,185-192`
**Issue:** Inside the `while read` loop over `instances.conf`, both the missing-PID branch (156)
and the readiness-timeout branch (191) call `exit 1`. Under `set -euo pipefail`, this aborts the
entire `up` command mid-iteration. If `instances.conf` lists claude/codex/opencode and codex is
slow to come up (or its `CODEX_HOME` is misconfigured per WR-02), the loop dies before reaching
opencode, leaving a partially-started fleet with no rollback. The launcher cannot bring up "the
instances that can start" and report the rest as failed.

**Fix:** Track failures per-instance and continue, then exit non-zero once at the end:
```bash
local failures=0
# replace per-instance `exit 1` with:
log "ERROR: ... (agent=${agent} port=${port})"; failures=$((failures+1)); continue
# after the loop:
[[ $failures -gt 0 ]] && { log "ERROR: ${failures} 件のインスタンスが起動失敗"; exit 1; }
```

### WR-05: PID files are read without validating they contain a numeric PID

**File:** `scripts/launch-agents.sh:105,223,286`
**Issue:** `existing_pid=$(cat "$pid_file")`, `pid=$(cat "$pid_file")` are fed directly into
`kill -0 "$existing_pid"` / `kill -TERM "$pid"` / `kill -KILL "$pid"`. A truncated or corrupted
PID file (e.g. a partial write, or an empty file if a prior `up` crashed between `touch` and
`echo`) yields an empty or non-numeric string. `kill -0 ""` is a no-op-ish error swallowed by
`2>/dev/null`, but a PID file containing something like `-1` would expand to `kill -TERM -- -1`
semantics in other contexts and a stray leading `-` could be misparsed. More practically, an
empty PID makes `down-all` silently believe the process is "already stopped" and `rm` the file,
abandoning a live server.

**Fix:** Validate after reading:
```bash
pid=$(cat "$pid_file" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    log "WARN: 不正な PID ファイル: ${pid_file} (内容: ${pid:-<empty>})"; rm -f "$pid_file"; continue
fi
```

### WR-06: Readiness poll cannot distinguish "wrong agent on this port" from "not ready yet"

**File:** `scripts/launch-agents.sh:62-73,174,185`
**Issue:** `check_info_agent` only returns success when `/info`'s `agent` field equals the
expected agent. If an unrelated `ht-webif` (or a previously-leaked instance — see CR-01) is
already bound to `${port}` with a *different* agent, `check_info_agent` returns false for the
full 60s, the loop times out, and `cmd_up` reports "60 秒待ってもインスタンスが応答しませんでした"
— a misleading "no response" message for what is actually a port collision with a *responding*
server. The operator gets the wrong diagnosis.

**Fix:** When `/info` responds but the agent mismatches, fail fast with a distinct message:
```bash
actual=$(json_get_field "$resp" "agent") || return 1
if [[ -n "$actual" && "$actual" != "$expected_agent" ]]; then
    log "ERROR: port ${port} は別エージェント '${actual}' が使用中（期待: ${expected_agent}）"
    return 2
fi
[[ "$actual" == "$expected_agent" ]]
```
and have the caller treat return code 2 as a hard, immediate failure.

## Info

### IN-01: `turns_processed` increment and `is_busy=false` are non-atomic, briefly inconsistent

**File:** `src/turn.rs:107-111`
**Issue:** `is_busy.store(false)` (107) and `turns_processed.fetch_add(1)` (111) are separate
`Relaxed` operations. A `GET /info` interleaved between them observes `idle` with the prior
turn count. This is acceptable for advisory metrics (and `Relaxed` is the right choice here), but
worth a one-line comment so a future reader does not assume `/info` is a consistent snapshot.
**Fix:** Add a comment noting `/info` fields are independently-updated advisory metrics, not a
transactional snapshot; or store both under the same brief critical section if a coherent
snapshot is ever required.

### IN-02: Magic constants for timeouts/retries are scattered as literals

**File:** `src/http.rs:115` (`700`), `src/turn.rs:53` (`1..=2u32`), `scripts/launch-agents.sh:144` (`5`), `:162` (`seq 1 60`)
**Issue:** The 700s sync deadline, the hard-coded 2-attempt retry bound, the 5s PID-wait, and the
60s readiness window are bare literals. The Rust timeouts are documented in CLAUDE.md but not
named in code; the shell windows are undocumented. Drift between `TURN_TIMEOUT`/attempt-count and
the 700s handler deadline can silently make `wait:true` time out before the worker exhausts its
retries.
**Fix:** Promote to named constants (`const SYNC_WAIT_DEADLINE_SECS: u64 = 700;`,
`MAX_TURN_ATTEMPTS`) and shell `readonly READINESS_TIMEOUT=60`, with a comment tying the sync
deadline to `2 * turn_timeout_secs + slack`.

### IN-03: `python3` JSON path is injection-fragile if field names ever become dynamic

**File:** `scripts/launch-agents.sh:53-55`
**Issue:** `json_get_field`'s python3 branch interpolates `${field}` directly into the python
source string (`d.get('${field}', '')`). Today `field` is only ever the hard-coded literals
`agent`/`status`/`uptime_secs`/`turns_processed`, so there is no live vulnerability. But this is
a latent code-injection footgun: if a future caller ever passes a field name derived from
`/info` output or config, a value like `x'); __import__('os').system('...'); ('` would execute.
**Fix:** Pass the field via argv instead of string interpolation:
```bash
echo "$json" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get(sys.argv[1],""))' "$field"
```

---

_Reviewed: 2026-06-15T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
