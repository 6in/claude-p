---
phase: 04-agent-profile-abstraction
reviewed: 2026-06-11T09:35:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - agents/claude.toml
  - src/config.rs
  - src/http.rs
  - src/lib.rs
  - src/main.rs
  - src/mcp.rs
  - src/profile.rs
  - src/turn.rs
  - src/worker.rs
findings:
  critical: 0
  warning: 7
  info: 7
  total: 14
status: issues_found
---

# Phase 4: Code Review Report (Re-review after gap closure 04-03/04-04)

**Reviewed:** 2026-06-11T09:35:00Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Re-review of agent-profile-abstraction after gap-closure plans 04-03/04-04. The four
findings targeted by those plans — CR-01 (lock-held `output_covenant`), CR-02 (fmt
diff), CR-03 (model selection not wired), and the dead `TURN_TIMEOUT` const — are all
**verified fixed** (evidence below). `cargo fmt --check` is clean,
`cargo clippy --all-targets -- -D warnings` is clean, all 27 tests pass.

No Critical issues remain. However, the gap-closure plans addressed only those four
findings: **five findings from the previous review remain open** (WR-01, WR-02, WR-03,
WR-04, WR-07 plus four Info items below), and this re-review adds two new Warnings
(WR-05 restart-lock starvation, WR-06 permissive CORS default) and three new Info
items. The highest-leverage open items are WR-02 (AGENT env var reaches the
filesystem unvalidated, violating the project's own whitelisting convention) and
WR-03 (the 700s sync-wait deadline is now incoherent with the profile-configurable
turn timeout this phase introduced).

## Prior Findings Verification

| Prior finding | Status | Evidence |
|---|---|---|
| CR-01 — lock-held `output_covenant` read in `prompt_handler` | **FIXED** | `AppState.output_covenant: String` (src/http.rs:29); `prompt_handler` reads `&state.output_covenant` with no `worker.lock()`; src/main.rs:31 clones the covenant before `Worker::new` moves the profile. Test helper `build_test_state` mirrors the pattern (src/http.rs:236). |
| CR-02 — cargo fmt diff | **FIXED** | `cargo fmt --check` exits clean (run during this review). Commit 7c73d17. |
| CR-03 — `model_flag`/`model_value` parsed but never used | **FIXED** | `AgentProfile::spawn_command()` (src/profile.rs:51-58) is called at all three `create_session` sites: `spawn_session` (src/worker.rs:50), `recreate` (src/worker.rs:118-119), `restart` (src/worker.rs:157-158). D-13 both-or-neither semantics covered by tests (h)/(h2)/(h3) at src/profile.rs:332-390. |
| WR (prior) — dead `config::TURN_TIMEOUT` const | **FIXED** | No `TURN_TIMEOUT` remains anywhere in src/; `process_job` uses `worker.profile.turn_timeout_secs` (src/turn.rs:71). `MCP_TIMEOUT` in config.rs is still live (used by mcp.rs). |

Consistency check: `agents/claude.toml` field names (`command`, `ready_pattern`,
`fresh_mode`, `clear_command`, `output_covenant`, `trigger_template`) exactly match
the `#[serde(deny_unknown_fields)]` struct, and the golden test
(src/turn.rs:157-191) proves byte-identity of the covenant output with v1.0.

## Warnings

### WR-01: `fresh_mode` not validated at startup — invalid values undetected until a fresh job arrives (CARRIED, still open)

**File:** `src/profile.rs:86-97` (gap), `src/turn.rs:63` (late failure site)
**Issue:** `validate_profile` enforces placeholder presence (D-11) but accepts any
string for `fresh_mode`. Only `"command"` and `"respawn"` are honored
(src/turn.rs:54-64); anything else hits `anyhow::bail!("未知の fresh_mode: {other}")`
at runtime, after the job is queued and the prompt file written. A typo like
`fresh_mode = "respwan"` boots a healthy-looking server where every `fresh:true`
request fails. Contradicts the phase's own fail-fast principle.
**Fix:** Add to `validate_profile`:
```rust
if p.fresh_mode != "command" && p.fresh_mode != "respawn" {
    anyhow::bail!(
        "agents/{name}.toml: fresh_mode は \"command\" か \"respawn\" のみ（指定値: {}）",
        p.fresh_mode
    );
}
```

### WR-02: AGENT env var flows unvalidated into filesystem paths — violates project whitelisting convention (CARRIED, still open)

**File:** `src/config.rs:44` (source), `src/profile.rs:66`, `src/main.rs:37` (sinks)
**Issue:** `load_agent_name()` returns the raw `AGENT` env value, which is then
joined into two filesystem paths: `agents_dir.join(format!("{name}.toml"))`
(src/profile.rs:66) and `turns_base.join(&agent_name)` (src/main.rs:37). A value
like `AGENT=../../etc/passwd` traverses outside `agents/`, and the turns subdir
(D-16) is created at an attacker-chosen location via `create_dir_all`. The threat
actor is the operator/environment, so impact is limited — but CLAUDE.md's convention
is explicit: "any identifier that hits the filesystem MUST be whitelisted". The new
`agent_name` identifier introduced by this phase is not.
**Fix:** Whitelist at load time in `load_agent_name` (or `load_agent_profile`):
```rust
if name.is_empty()
    || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
{
    anyhow::bail!("AGENT 名が不正です（許可: 英数字・ハイフン・アンダースコア）: {name:?}");
}
```

### WR-03: Hardcoded 700s `wait:true` deadline not derived from `profile.turn_timeout_secs` (CARRIED, still open)

**File:** `src/http.rs:82`
**Issue:** This phase made the per-turn timeout configurable (src/profile.rs:30,
consumed at src/turn.rs:71), but the synchronous wait deadline is still the magic
constant 700 — sized for the old fixed 300s timeout (2 attempts x 300 + margin). A
profile with `turn_timeout_secs = 600` (a value the test suite itself exercises,
src/profile.rs:265) allows ~1200s+ worst case per job, so `wait:true` returns 504
while the turn is still legitimately in flight. Queue depth ahead of the new job
makes this worse even at defaults. The knob this phase added is silently
disconnected from the sync contract.
**Fix:** Carry the value into `AppState` (same pattern as `output_covenant`):
```rust
// AppState
pub turn_timeout_secs: u64,
// prompt_handler
let deadline = Instant::now() + Duration::from_secs(state.turn_timeout_secs * 2 + 100);
```

### WR-04: Empty `command = []` passes validation and fails opaquely at session creation (CARRIED, still open)

**File:** `src/profile.rs:86-97` (gap), `src/worker.rs:50` (failure site)
**Issue:** `validate_profile` does not check that `command` is non-empty. A profile
with `command = []` parses cleanly, passes validation, and only fails when
`ht_create_session` receives an empty command array — surfacing as an inscrutable
MCP error at boot instead of a clear config error.
**Fix:** Add to `validate_profile`:
```rust
if p.command.is_empty() {
    anyhow::bail!("agents/{name}.toml: command は空にできません");
}
```

### WR-05: POST /restart (the recovery endpoint) is blocked behind the worker mutex for the full duration of a wedged turn (NEW)

**File:** `src/turn.rs:99` (lock held across `process_job`), `src/http.rs:169` (restart contention)
**Issue:** `worker_loop` holds the `Arc<Mutex<Worker>>` for the entire
`process_job` — up to 2 x `turn_timeout_secs` plus two session recreations (~10+
minutes at defaults; unbounded if a profile raises the timeout). `restart_handler`
must acquire that same mutex. The documented recovery story for a wedged ht-mcp is
"full /restart", yet during precisely that failure mode (status file never appears
because ht-mcp/claude is wedged) the endpoint cannot run until the in-flight attempt
cycle drains. `command_handler` (src/http.rs:141) is similarly blocked and
additionally sleeps 1500ms while holding the lock. Pre-existing architecture, but
the profile-configurable `turn_timeout_secs` introduced by this phase now lets
profiles widen the unrecoverable window arbitrarily.
**Fix:** Give `process_job` a cancellation path — e.g. a `tokio::sync::Notify` or
`watch::channel` signaled by `restart_handler` that the 1s status-poll loop
(src/turn.rs:72-79) checks, so a restart aborts the in-flight wait promptly. At
minimum, document the blocking window on `/restart`.

### WR-06: Default CORS `*` permits cross-origin drive-by prompt execution from any website (NEW)

**File:** `src/config.rs:60-75` (default), `src/http.rs:184-188` (wildcard layer)
**Issue:** `load_cors_origins` defaults to `vec!["*"]`, and `build_router` then sets
`allow_origin(Any)` + `allow_headers([CONTENT_TYPE])` + POST. JSON POSTs are
non-simple requests, so a restrictive policy would stop them at preflight — but the
wildcard default makes the preflight succeed for every origin. Any web page open in
a browser on the same host can `fetch("http://127.0.0.1:8080/prompt", {method:"POST",
...})`, drive the local Claude session (which has filesystem access), and read the
result back. Loopback binding does not mitigate this: the victim's browser is the
confused deputy. Pre-existing default, but `config.rs` is in scope and the exposure
compounds with the prompt-execution capability.
**Fix:** Default to deny (empty allow list) or localhost origins only, requiring an
explicit `CORS_ORIGINS=*` opt-in. At minimum, emit a prominent startup warning when
running with `*`.

### WR-07: ready-wait polling loop triplicated across worker.rs (CARRIED, still open)

**File:** `src/worker.rs:52-61`, `src/worker.rs:123-132`, `src/worker.rs:162-171`
**Issue:** The snapshot / `contains(ready_pattern)` / deadline / sleep(700ms) loop is
copy-pasted three times (`spawn_session`, `recreate`, `restart`). Three copies invite
drift — a future timeout or pattern tweak applied to only one site silently changes
recovery behavior relative to boot behavior.
**Fix:** Extract a helper callable from all three sites, e.g.
`async fn wait_ready<M: Mcp>(client: &mut M, session_id: &str, ready_pattern: &str, startup_timeout_secs: u64) -> Result<()>`.

## Info

### IN-01: Tests load the real profile via CWD-relative `"agents"` path (CARRIED, still open)

**File:** `src/http.rs:233`, `src/turn.rs:164`
**Issue:** `load_agent_profile("claude", Path::new("agents"))` depends on the test
process CWD being the crate root. `cargo test` guarantees this today, but running
the tests from another directory (or a future workspace re-layout) breaks them with
a confusing "claude.toml が見つかりません".
**Fix:** Anchor on the manifest dir:
`Path::new(env!("CARGO_MANIFEST_DIR")).join("agents")`.

### IN-02: CORS startup log line is tagged `[profile]` (CARRIED, still open)

**File:** `src/main.rs:54`
**Issue:** `eprintln!("[profile] CORS 許可オリジン: ...")` — CORS configuration is
not profile-related; the bracketed-tag logging convention loses meaning when tags
are inaccurate.
**Fix:** Use `[cors]` (or `[http]`).

### IN-03: `deny_unknown_fields` test assertion is vacuous (CARRIED, still open)

**File:** `src/profile.rs:293-296`
**Issue:** The test asserts `!err.to_string().is_empty()` — any error message
passes, so the test would still pass if `deny_unknown_fields` were removed and the
failure came from somewhere else entirely. It verifies *an* error occurs, not the
guarded behavior.
**Fix:** Assert the message mentions the offending key:
`assert!(err.to_string().contains("unknown_field"))` (toml's serde error includes
the field name).

### IN-04: `clear_command` is mandatory even for `fresh_mode = "respawn"` profiles (CARRIED, still open)

**File:** `src/profile.rs:20`
**Issue:** `clear_command: String` has no default and is unused when
`fresh_mode = "respawn"` — respawn-style agent profiles must supply a meaningless
value to satisfy the deserializer.
**Fix:** Make it `Option<String>` (or `#[serde(default)]`) and require it in
`validate_profile` only when `fresh_mode == "command"` (pairs with WR-01's fix).

### IN-05: turn_id collision possible under concurrent POST /prompt within the same millisecond (NEW)

**File:** `src/http.rs:53`
**Issue:** `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` is the sole uniqueness
source. axum serves requests concurrently, so two POSTs in the same millisecond
produce identical turn_ids: the second `tokio::fs::write` overwrites the first
prompt file and two jobs with the same id enter the queue — cross-contaminated
results. Low probability, silent corruption when it hits.
**Fix:** Add a process-wide `AtomicU64` sequence suffix, or create the prompt file
with `OpenOptions::create_new` and regenerate the id on `AlreadyExists`.

### IN-06: Double session recreation on retry when `fresh_mode = "respawn"` (NEW)

**File:** `src/turn.rs:60` and `src/turn.rs:85`
**Issue:** On attempt-1 timeout, `process_job` calls `worker.recreate()` (line 85);
attempt 2 then immediately calls `recreate()` again via the `"respawn"` fresh branch
(line 60). Two back-to-back full session startups (each up to
`startup_timeout_secs`) where one suffices. Correctness unaffected.
**Fix:** Track a `just_recreated` flag across the attempt loop and skip the
fresh-respawn recreate when set, or accept and document the cost.

### IN-07: Blocking `Path::exists()` stat calls inside async handlers/loops (NEW)

**File:** `src/http.rs:83`, `src/http.rs:111`, `src/turn.rs:73`
**Issue:** `std::path::Path::exists()` performs synchronous I/O on the tokio runtime
thread. These are cheap local `stat`s in 1s-interval loops, so impact is negligible
today; noted for consistency with the codebase's otherwise-async fs usage
(`tokio::fs` everywhere else).
**Fix:** `tokio::fs::try_exists(&path).await.unwrap_or(false)` when touching these
lines anyway.

---

_Reviewed: 2026-06-11T09:35:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
