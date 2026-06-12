---
phase: 05-codex-cli-and-opencode-validation
plan: 02
subsystem: config
tags: [agent-profile, opencode, e2e, config, toml, bash, setup-script]

# Dependency graph
requires:
  - phase: 05-01-codex-validation
    provides: "agents/codex.toml, scripts/e2e-codex.sh, no-search isolation probe methodology"
  - phase: 04-agent-profile-abstraction
    provides: "AgentProfile struct, load_agent_profile, deny_unknown_fields, fresh_mode dispatch"

provides:
  - "agents/opencode.toml — OpenCode agent profile (opencode-runner.sh wrapper, fresh_mode=respawn)"
  - "scripts/opencode-runner.sh — shell wrapper that runs opencode run --command turn per turn"
  - "scripts/setup-opencode.sh — idempotent turn.md + opencode.json generator"
  - "scripts/e2e-opencode.sh — rerunnable E2E validation script (AGNT-03 + AGNT-04, no-search isolation probe)"
  - "README.md — Codex + OpenCode agent setup section with auth/prerequisite steps"

affects: [06-multi-instance]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "opencode run non-interactive mode: opencode run --command turn <path> works reliably headless; TUI keystroke injection via ht-mcp PTY does not process /turn commands (Pitfall 9)"
    - "Shell wrapper agent: opencode-runner.sh acts as a long-running stdin listener; avoids TUI entirely; ready_pattern='OpenCodeRunner ready'"
    - "Permission key singular: opencode.json requires 'permission' (singular) not 'permissions' — unrecognized key causes immediate exit (Pitfall 8)"
    - "Idempotent setup script: check-then-create pattern for turn.md and opencode.json (D-04/D-05)"
    - "fresh_mode=respawn for OpenCode: /new dialog requires 2 Enter presses but ht-webif sends 1 — respawn is correct (D-01/D-02)"
    - "No-search isolation probe: same methodology as e2e-codex.sh — explicit file-read prohibition in stage-3 prompt"

key-files:
  created:
    - agents/opencode.toml
    - scripts/setup-opencode.sh
    - scripts/e2e-opencode.sh
    - scripts/opencode-runner.sh
  modified:
    - README.md
    - .planning/ROADMAP.md
    - .planning/REQUIREMENTS.md
    - src/profile.rs
    - src/worker.rs
    - src/turn.rs

key-decisions:
  - "D-09: opencode TUI keystroke injection via ht-mcp PTY does not work — /turn command is sent but OpenCode never creates sessions or calls its internal HTTP API; confirmed by zero sessions in opencode.db during E2E runs 2 and 3"
  - "D-09 fix: opencode-runner.sh shell wrapper uses opencode run --command turn (non-interactive mode) — confirmed working in manual test and E2E attempt 4"
  - "Pitfall 8: opencode.json 'permissions' (plural) is an unrecognized key that causes OpenCode to exit immediately — must use 'permission' (singular)"
  - "fresh_mode = 'respawn' is the correct production setting for OpenCode v1.4.3 — /new opens agent selector dialog requiring Enter twice; ht-webif sends once (D-01/D-02)"
  - "startup_settle_ms added to AgentProfile (Rule 2) — settle delay handles ready_pattern firing before TUI is fully ready"
  - "Stage-3 isolation probe uses no-search methodology — OpenCode is agentic CLI that can search workspace files (false-positive risk same as Codex)"

patterns-established:
  - "Pattern: shell wrapper as long-running agent avoids TUI keystroke injection problems entirely"
  - "Pattern: opencode run --command <cmd> <path> is the reliable headless invocation for OpenCode"
  - "Pattern: pre-run setup.sh call in e2e scripts ensures prerequisites automatically (D-04)"
  - "Pattern: D-01/D-02 decision flow — attempt /command first, document result, fall back to respawn if dialog stalls"

requirements-completed: [AGNT-03, AGNT-04]

# Metrics
duration: ~5h (including 3 failed E2E attempts + diagnosis + fix + 1 passing E2E)
completed: 2026-06-12
---

# Phase 05 Plan 02: OpenCode Profile and E2E Validation Summary

**OpenCode headless E2E validated via opencode-runner.sh wrapper (opencode run non-interactive mode) after diagnosing TUI keystroke injection failure in ht-mcp PTY — all 3 stages pass: result non-empty (status=done), history seed, fresh:true isolation (UNKNOWN returned).**

## Performance

- **Duration:** ~5h (Tasks 1-3 from prior executor + Task 4 diagnosis + D-09 fix + passing E2E)
- **Started:** 2026-06-12T08:14Z
- **Completed:** 2026-06-12T09:48Z
- **Tasks:** 4 of 4 complete
- **Files modified:** 9 (including Rust src + scripts + config)

## Accomplishments

- `agents/opencode.toml` created and updated: shell wrapper approach (D-09), `fresh_mode = "respawn"`, `ready_pattern = "OpenCodeRunner ready"`, `trigger_template = "opencode run --command turn {prompt_path}"`, `startup_settle_ms = 0`, prerequisite comment block
- `scripts/opencode-runner.sh` created: long-running stdin listener that calls `opencode run --command turn <path>` per trigger; emits "OpenCodeRunner ready" as heartbeat; avoids TUI entirely
- `scripts/setup-opencode.sh` created and fixed: idempotent turn.md + opencode.json generator; fixed `permission` (singular) key in opencode.json template (Pitfall 8)
- `scripts/e2e-opencode.sh` created: 3-stage E2E (basic result/status, history seed, no-search isolation), PORT=8082, auto-calls setup-opencode.sh
- Rust changes: `startup_settle_ms` field added to `AgentProfile` (profile.rs, worker.rs, turn.rs) — Rule 2 auto-add for settling delay
- E2E attempt 4 (D-09 wrapper approach): ALL 3 STAGES PASSED
  - Stage 1 (AGNT-03): "What is 2+3?" -> result="5", status=done, 14s
  - Stage 2 (history seed): "Remember 7331" -> status=done, 16s
  - Stage 3 (AGNT-04 fresh isolation): fresh:true + no-search -> result="UNKNOWN", status=done, 19s

## Task Commits

All tasks committed atomically:

1. **Task 1: agents/opencode.toml + scripts/setup-opencode.sh** - `92bdbeb`
2. **Task 2: scripts/e2e-opencode.sh + fresh_mode confirmed** - `3868fe4`
3. **Task 3: README + ROADMAP + REQUIREMENTS (D-03)** - `a64f4f3`
4. **Task 4 (part A): startup_settle_ms Rust fields** - `5e52e71`
5. **Task 4 (part B): opencode-runner.sh + D-09 fix** - `d304bf7`

## E2E Attempt History

| Attempt | Approach | Outcome | Root Cause |
|---------|----------|---------|------------|
| 1 | TUI keystroke injection | FAIL (blank screen 10 min) | startup_settle_ms missing — ready_pattern fired before TUI stable |
| 2 | TUI + settle delay (7000ms) | FAIL (server exits in 1s) | opencode.json "permissions" (plural) — unrecognized key, OpenCode exits immediately |
| 3 | TUI + settle + fixed config | FAIL (timeout 300s) | TUI /turn command sent but never processed — no sessions in opencode.db |
| 4 | opencode-runner.sh wrapper | PASS (all 3 stages) | D-09: non-interactive opencode run mode works reliably |

## Diagnosis Evidence (E2E Attempt 3 Analysis)

After attempt 3 timed out, diagnosed by:
- `sqlite3 ~/.local/share/opencode/opencode.db` — zero sessions created during E2E window
- Checked `~/.local/share/opencode/log/` — no new log files during E2E window
- Confirmed `opencode run --command turn <relative_path>` works manually (result="5", status=done)
- Conclusion: ht-mcp PTY sends keystrokes to opencode TUI terminal but TUI does not dispatch them to its internal HTTP API in this context

## Files Created/Modified

- `scripts/opencode-runner.sh` (NEW) — Shell wrapper: stdin listener -> `opencode run --command turn <path>` per turn; ready_pattern = "OpenCodeRunner ready"
- `agents/opencode.toml` (MODIFIED x2) — Final: command=opencode-runner.sh, ready_pattern=OpenCodeRunner ready, trigger_template=opencode run --command turn, startup_settle_ms=0, startup_timeout_secs=5
- `scripts/setup-opencode.sh` (NEW + FIXED) — Idempotent turn.md + opencode.json; fixed `permission` (singular)
- `scripts/e2e-opencode.sh` (NEW) — 3-stage E2E with no-search isolation probe, PORT=8082
- `README.md` — New agent setup section
- `.planning/ROADMAP.md` — SC4 updated: respawn confirmed (D-03)
- `.planning/REQUIREMENTS.md` — AGNT-04 updated: respawn method (D-03)
- `src/profile.rs` — `startup_settle_ms: u64` field added to AgentProfile
- `src/worker.rs` — settle delay applied in spawn_session, recreate(), restart()
- `src/turn.rs` — test helper make_profile() updated with startup_settle_ms=0

## Decisions Made

**D-01/D-02 fresh_mode determination:**

- `/new` opens agent selector dialog (Pitfall 3) — requires Enter twice; ht-webif sends once -> stalls
- `fresh_mode = "respawn"` confirmed: complete process kill+respawn, zero Rust change

**Pitfall 8 — opencode.json key spelling:**

- `"permissions"` (plural) = unrecognized key -> OpenCode exits immediately with config error
- Fix: `"permission"` (singular) in both user config and setup-opencode.sh template

**D-09 — TUI keystroke injection failure:**

- Root cause: ht-mcp PTY receives keystrokes but opencode TUI does not dispatch to its internal HTTP API (`POST /session/<id>/message`)
- Confirmed via: zero sessions in opencode.db, zero log files created during 3 E2E attempts with TUI approach
- Fix: `opencode run --command turn <path>` non-interactive mode via opencode-runner.sh wrapper

**startup_settle_ms (Rule 2 auto-add):**

- Added to AgentProfile to handle settling period after ready_pattern
- Set to 0 in opencode.toml (wrapper is instant) — retains field for future agents needing settle time

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical Functionality] startup_settle_ms field for AgentProfile**
- **Found during:** Task 4, E2E attempt 1 diagnosis
- **Issue:** ready_pattern fired before OpenCode TUI was fully ready; trigger sent during blank period was lost
- **Fix:** Added `startup_settle_ms: u64` field to AgentProfile (profile.rs), applied settle delay in worker.rs, updated test helper in turn.rs
- **Files modified:** src/profile.rs, src/worker.rs, src/turn.rs
- **Commit:** 5e52e71

**2. [Rule 1 - Bug] opencode.json 'permissions' plural key (Pitfall 8)**
- **Found during:** Task 4, E2E attempt 2 diagnosis
- **Issue:** `/home/parallels/.config/opencode/opencode.json` had `"permissions"` (plural) — OpenCode v1.4.3 treats this as unrecognized key and exits immediately
- **Fix:** Changed to `"permission"` (singular) in user config; fixed `scripts/setup-opencode.sh` template
- **Files modified:** scripts/setup-opencode.sh (repo); ~/.config/opencode/opencode.json (host-only, not in repo)
- **Commit:** d304bf7 (setup-opencode.sh fix included)

**3. [Rule 1 - Bug] TUI keystroke injection failure -> opencode-runner.sh (D-09)**
- **Found during:** Task 4, E2E attempts 1-3 + diagnosis
- **Issue:** opencode TUI does not process /turn command when delivered via ht-mcp PTY keystrokes; confirmed by zero sessions in opencode.db after 3 E2E runs
- **Fix:** Created `scripts/opencode-runner.sh` shell wrapper; updated `agents/opencode.toml` to use wrapper with `opencode run` non-interactive mode; no Rust changes needed
- **Files modified:** scripts/opencode-runner.sh (new), agents/opencode.toml
- **Commit:** d304bf7

## Known Stubs

None — all logic is wired. E2E runs against real opencode (GitHub Copilot / Claude Haiku 4.5).

## Threat Surface Scan

No new network endpoints. `scripts/setup-opencode.sh` writes to `~/.config/opencode/` — fixed path, no external input influences path (T-05-05 mitigated). `opencode-runner.sh` runs `eval "$trigger"` — trigger is controlled by ht-webif (trusted, localhost-only boundary per HT-PROTOCOL §7).

## Self-Check

Files exist:
- `agents/opencode.toml`: FOUND
- `scripts/opencode-runner.sh`: FOUND (executable)
- `scripts/setup-opencode.sh`: FOUND (executable)
- `scripts/e2e-opencode.sh`: FOUND (executable)
- `README.md`: FOUND (updated)
- `src/profile.rs`: FOUND (startup_settle_ms added)
- `src/worker.rs`: FOUND (settle delay applied)

Commits exist:
- `92bdbeb`: feat(05-02) Task 1 - FOUND
- `3868fe4`: feat(05-02) Task 2 - FOUND
- `a64f4f3`: docs(05-02) Task 3 - FOUND
- `5e52e71`: fix(05-02) startup_settle_ms - FOUND
- `d304bf7`: feat(05-02) opencode-runner.sh D-09 - FOUND

## Self-Check: PASSED
