---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: マルチエージェント対応
status: planning
stopped_at: Phase 6 context gathered
last_updated: "2026-06-15T05:52:57.434Z"
last_activity: 2026-06-15
progress:
  total_phases: 3
  completed_phases: 2
  total_plans: 7
  completed_plans: 7
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-11)

**Core value:** `-p` を避けつつ curl で Claude を実行できる（サブスクリプション課金を維持）— v2.0 でこの仕組みを Claude 以外の対話型 CLI エージェントへ一般化する
**Current focus:** Phase 06 — multi-instance-parallel-foundation

## Current Position

Phase: 6
Plan: Not started
Status: Ready to plan
Last activity: 2026-06-15

Progress: [█████████████░░░░░░░] 2/3 phases (67%)

## Performance Metrics

**Velocity:**

- Total plans completed: 7 (v2.0); 13 (v1.0 cumulative)
- Average duration: —
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 4. Agent Profile Abstraction | TBD | — | — |
| 5. Codex CLI and OpenCode Validation | TBD | — | — |
| 6. Multi-Instance Parallel Foundation | TBD | — | — |
| 04 | 4 | - | - |
| 5 | 3 | - | - |

**Recent Trend:**

- Last 5 plans: —
- Trend: — (no data yet)

*Updated after each plan completion*
| Phase 04-agent-profile-abstraction P02 | 12min | 3 tasks | 6 files |
| Phase 04-agent-profile-abstraction P03 | 8min | 2 tasks | 5 files |
| Phase 05-codex-cli-and-opencode-validation P01 | 90 | 3 tasks | 2 files |
| Phase 05-codex-cli-and-opencode-validation P02 | 35 | 3 tasks | 6 files |
| Phase 05-codex-cli-and-opencode-validation P02 | 18000 | 4 tasks | 9 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [v2.0 roadmap]: 3 phases at coarse granularity — Profile Abstraction → Agent Validation → Parallel Foundation. Order ensures Rust refactor is validated before empirical agent testing, and both agents work before multi-instance tooling.
- [v2.0 roadmap]: Phase 5 has a research flag — ready_pattern values and output_covenant behavior for Codex/OpenCode must be discovered empirically. Use `/gsd-plan-phase --research-phase 5`.
- [v2.0 roadmap]: TURNS_DIR default changed to `./turns/<agent-name>/` in Phase 4 to prevent cross-instance collisions from day one (Pitfall 5 from research).
- [v1.0]: Roadmap structure decisions archived in previous milestone — see milestones/v1.0-ROADMAP.md and v1.0-phases/.
- [Phase 04]: ---

phase: 04-agent-profile-abstraction
plan: 02
subsystem: config
tags: [rust, agent-profile, mcp, worker, refactor, golden-test]

# Dependency graph

requires:

  - phase: 04-01
    provides: "AgentProfile struct, load_agent_profile, agents/claude.toml, load_agent_name/load_agents_dir"
provides:

  - "create_session(cmd) trait method — create_claude_session renamed in trait Mcp, McpClient, FakeMcp"
  - "Worker<M> gains pub profile: AgentProfile field + new/boot/spawn_session/from_parts profile param"
  - "4 ready-pattern sites in worker.rs profile-driven (ready_pattern, startup_timeout_secs)"
  - "build_prompt_body(task, result, status, covenant_template) — 4-arg covenant-template signature"
  - "process_job: trigger from trigger_template, fresh_mode dispatch command/respawn/bail, turn_timeout from profile"
  - "Golden test build_prompt_body_covenant_matches_v1_output (D-12) fixing v1.0 byte identity"
  - "main.rs: AGENT/AGENTS_DIR startup sequence, [profile] banner, D-16 turns/<agent-name>/ subdir"
  - "README: AGENT/AGENTS_DIR env vars, D-16 TURNS_DIR breaking-change documentation"

affects: [05-agent-validation, future-multi-agent]

# Tech tracking

tech-stack:
  added: []
  patterns:

    - "Profile-driven dispatch: worker.profile.{field} drives all hardcode sites; no new constants needed"
    - "Golden test pattern: const EXPECTED captures v1.0 byte string; load_agent_profile loads real TOML; assert_eq! fixes byte identity (D-12)"
    - "fresh_mode match dispatch: 'command'/'respawn'/other→bail covers all current and future modes safely"
    - "D-16 subdirectory: turns_base.join(&agent_name) in main.rs; http.rs test bypasses this (Pitfall 4)"

key-files:
  created: []
  modified:

    - src/mcp.rs
    - src/worker.rs
    - src/turn.rs
    - src/main.rs
    - src/http.rs
    - README.md

key-decisions:

  - "D-16 enforced: turns_dir = turns_base.join(&agent_name) — always <TURNS_DIR>/<agent-name>/; http.rs tests bypass this (Pitfall 4 correctly applied)"
  - "Worker.profile accessed as worker.profile.{field} in process_job — no signature change to process_job needed (RESEARCH Open Questions 1 recommendation)"
  - "http.rs prompt_handler: output_covenant fetched via short lock (worker.lock().await / clone / unlock) to avoid holding lock over file I/O"
  - "Task 1 includes minimal main.rs stub so cargo build exits 0 (binary required for build acceptance criterion)"
  - "Task 2 includes http.rs build_test_state fix (profile arg to from_parts) so cargo test --lib turn compiles"

patterns-established:

  - "Pattern: profile.ready_pattern replaces all 'auto mode' literals; profile.startup_timeout_secs replaces 25s hardcode"
  - "Pattern: profile.turn_timeout_secs replaces TURN_TIMEOUT constant (config.rs constant preserved, turn.rs no longer imports it)"
  - "Pattern: trigger_template.replace(\"{prompt_path}\", ...) and covenant_template.replace(\"{result_path}\", ...) — str::replace only (D-09)"

requirements-completed: [PROF-01, PROF-03, PROF-04, PROF-05, PROF-06]

# Metrics

duration: 12min
completed: 2026-06-11
---

# Phase 4 Plan 02: Agent Profile Abstraction — Wiring Summary

**AgentProfile wired into all 5 source files: create_session(cmd) rename, 4 ready-pattern sites profile-driven, build_prompt_body covenant-parameterized with D-12 golden test, fresh_mode dispatch, D-16 turns/<agent-name>/ subdir**

- [Phase ?]: ロックフリー化
- [Phase ?]: spawn_command メソッド追加
- [Phase ?]: TURN_TIMEOUT 削除
- [Phase ?]: D-09: opencode-runner.sh wrapper with opencode run non-interactive mode confirmed for OpenCode headless operation

## Performance

- **Duration:** 12 min
- **Started:** 2026-06-11T08:05:56Z
- **Completed:** 2026-06-11T08:17:36Z
- **Tasks:** 3
- **Files modified:** 6 (src/mcp.rs, src/worker.rs, src/turn.rs, src/main.rs, src/http.rs, README.md)

## Accomplishments

- `src/mcp.rs`: `create_claude_session` → `create_session(&mut self, cmd: &[String])` across trait, McpClient, FakeMcp — zero occurrences of `create_claude_session` remain
- `src/worker.rs`: `Worker<M>` gains `pub profile: AgentProfile`; all 4 ready-pattern sites (`spawn_session`, `recreate`, `restart`, `ensure_healthy`) now use `profile.ready_pattern` and `profile.startup_timeout_secs`
- `src/turn.rs`: `build_prompt_body` gains `covenant_template: &str` param; `process_job` uses `trigger_template`, `fresh_mode` dispatch, and `turn_timeout_secs`; golden test `build_prompt_body_covenant_matches_v1_output` asserts byte identity with v1.0 output (D-12)
- `src/main.rs`: Full startup sequence with `[profile]` banner, `load_agent_profile` wired, D-16 `turns_base.join(&agent_name)` subdir; `AGENT=<unknown>` exits immediately via `?` propagation
- `src/http.rs`: `build_test_state` passes profile to `from_parts`; `prompt_handler` fetches `output_covenant` via short lock
- `README.md`: `AGENT`/`AGENTS_DIR` env vars documented; D-16 TURNS_DIR breaking-change noted; multiple-instance section updated
- All 24 tests green (23 baseline + 1 D-12 golden test)

## Task Commits

Each task was committed atomically:

1. **Task 1: mcp.rs trait rename + worker.rs profile wiring** - `a217755` (feat)
2. **Task 2: turn.rs build_prompt_body covenant param + fresh_mode dispatch + golden test** - `f427d55` (feat)
3. **Task 3: main.rs full wiring + D-16 turns subdir + README** - `5f93c77` (feat)

## Files Created/Modified

- `src/mcp.rs` — `create_session(cmd: &[String])` replaces `create_claude_session()` in trait + 2 impls
- `src/worker.rs` — `pub profile: AgentProfile` field; 4 ready-pattern sites; all `create_session` calls pass `profile.command`
- `src/turn.rs` — `build_prompt_body` 4-arg covenant signature; `process_job` trigger/fresh/timeout profile-driven; golden test
- `src/main.rs` — complete startup sequence: AGENT/AGENTS_DIR load → profile → Worker::new(profile) → D-16 turns subdir → [profile] banner
- `src/http.rs` — `build_test_state` profile arg; `prompt_handler` covenant via short lock
- `README.md` — AGENT/AGENTS_DIR env var table rows; D-16 breaking-change note; multi-instance section update

## Decisions Made

- Worker.profile accessed as `worker.profile.{field}` in `process_job` — no signature change to `process_job` function itself (RESEARCH Open Questions 1 recommendation upheld)
- `http.rs` `prompt_handler` fetches `output_covenant` via a short `worker.lock().await` before file I/O, avoids holding lock across `tokio::fs::write`
- D-16 turns subdirectory is applied only in `main.rs`; `http.rs` `build_test_state` passes `turns_dir` directly (Pitfall 4: tests don't go through the `main.rs` subdirectory logic, so existing tests remain valid)
- `Task 1` includes minimal `main.rs` import stub so `cargo build` (binary) exits 0 — required by Task 1 acceptance criterion; fully expanded in Task 3
- Task 2 includes `http.rs` `build_test_state` fix because `cargo test --lib turn` compiles the whole lib including http.rs tests

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Field name discrepancy: profile.cmd vs profile.command**

- **Found during:** Task 1 (cargo build failure)
- **Issue:** PATTERNS.md showed `profile.cmd` but actual `src/profile.rs` struct has `pub command: Vec<String>`. Using `profile.cmd` caused E0609 compile errors.
- **Fix:** Used `profile.command` throughout `worker.rs` (3 sites)
- **Files modified:** src/worker.rs
- **Verification:** `cargo build` exits 0
- **Committed in:** a217755 (Task 1 commit)

**2. [Rule 3 - Blocking] main.rs binary fails cargo build before Task 3**

- **Found during:** Task 1 (cargo build shows E0061 for Worker::new missing profile arg)
- **Issue:** Task 1 acceptance criterion requires `cargo build` exit 0, but Task 3 is where main.rs is fully wired. Binary can't compile with old `Worker::new(ht_mcp_path)` call.
- **Fix:** Added minimal profile loading stub to main.rs in Task 1 commit (just imports + load_agent_profile + pass to Worker::new, without D-16 turns or startup banner). Task 3 expands to full implementation.
- **Files modified:** src/main.rs (Task 1), src/main.rs (Task 3 — full replacement)
- **Verification:** `cargo build` exits 0 after Task 1
- **Committed in:** a217755 (Task 1), 5f93c77 (Task 3 full expansion)

**3. [Rule 3 - Blocking] http.rs tests fail `cargo test --lib turn` due to from_parts missing profile arg**

- **Found during:** Task 2 (cargo test --lib turn compile error)
- **Issue:** Task 2 acceptance criterion requires `cargo test --lib turn` exit 0, but lib compiles http.rs tests which call `from_parts` with 3 args (Task 1 changed it to 4). Also `build_prompt_body` gained a 4th arg.
- **Fix:** Fixed `build_test_state` in Task 2 commit to pass profile (via `load_agent_profile("claude", Path::new("agents"))`), and fixed `prompt_handler` in http.rs to fetch covenant from worker.
- **Files modified:** src/http.rs
- **Verification:** `cargo test --lib turn` exits 0 with 9 tests green
- **Committed in:** f427d55 (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (1 bug, 2 blocking)
**Impact on plan:** All three are natural cascading fixes from the sequential task structure. No scope creep. The plan's intermediate acceptance criteria (cargo build / cargo test per task) required touching adjacent files earlier than their scheduled task.

## Threat Surface Scan

| Flag | File | Description |
|------|------|-------------|
| (none) | — | No new network endpoints, auth paths, file access patterns, or schema changes beyond what the threat_model already covers. T-04-03 (golden test for covenant), T-04-04 (fresh_mode bail), T-04-05 (startup banner) all mitigated as planned. |

## Issues Encountered

None — all issues were auto-fixed via deviation rules.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 4 complete: AgentProfile contract (04-01) fully wired (04-02)
- `AGENT=claude ./ht-webif` is v1.0 behavior-equivalent (4 endpoints, ready detection, fresh:true, timeouts)
- `AGENT=<unknown>` produces clear error and exits immediately
- Golden test (D-12) fixes v1.0 output covenant byte identity in CI
- Ready for Phase 5: multi-agent validation / additional profiles

---
*Phase: 04-agent-profile-abstraction*
*Completed: 2026-06-11*

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 5 is empirically gated: Codex CLI and OpenCode must be installed and authenticated on the host before Phase 5 can be validated. Codex needs `--yolo` trust-dialog suppression confirmed; OpenCode needs `opencode auth login` run beforehand.
- Phase 5 output covenant compliance is MEDIUM confidence for non-Claude models (GPT-4o/o3 may not reliably follow the file-write instruction — must be tested).

## Deferred Items

Items carried forward from v1.0 close (2026-06-10):

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| uat_gap | Phase 03: GitHub CI red/green 挙動確認 1 シナリオ | partial | 2026-06-10 |
| operations | OPS-01: turns/ rotation/archive | Deferred to v3+ | 2026-05-23 |
| operations | OPS-02: tracing structured logging | Deferred to v3+ | 2026-05-23 |
| security | SEC-01: HTTP auth (bearer token) | Deferred to v3+ | 2026-05-23 |
| scaling | SCALE-01: parallel workers (same-process) | Deferred to v3+ | 2026-05-23 |
| deploy | DEPLOY-01: Docker packaging | Deferred to v3+ | 2026-05-23 |

## Session Continuity

Last session: 2026-06-15T05:52:57.421Z
Stopped at: Phase 6 context gathered
Resume file: .planning/phases/06-multi-instance-parallel-foundation/06-CONTEXT.md

## Operator Next Steps

- Plan Phase 4: `/gsd-plan-phase 4`
- Phase 5 needs research first: `/gsd-plan-phase --research-phase 5`
