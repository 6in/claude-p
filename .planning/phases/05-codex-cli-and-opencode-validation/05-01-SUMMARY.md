---
phase: 05-codex-cli-and-opencode-validation
plan: 01
subsystem: config
tags: [agent-profile, codex, e2e, config, toml, bash]

requires:
  - phase: 04-agent-profile-abstraction
    provides: "AgentProfile struct, load_agent_profile, agents/claude.toml, fresh_mode dispatch"

provides:
  - "agents/codex.toml — Codex CLI agent profile (command/ready_pattern/fresh_mode/timeouts/prerequisite comments)"
  - "scripts/e2e-codex.sh — rerunnable E2E validation script (AGNT-01 + AGNT-02)"

affects: [05-02-opencode-validation, 06-multi-instance]

tech-stack:
  added: []
  patterns:
    - "TOML agent profile following agents/claude.toml style (command field, Japanese comments, prerequisite block)"
    - "E2E bash script following smoke.sh patterns (set -euo pipefail, cleanup+trap, wait_for_server, require_tool)"
    - "3-stage history isolation test: seed fixed value → fresh:true query → assert value absent from response"

key-files:
  created:
    - agents/codex.toml
    - scripts/e2e-codex.sh
  modified: []

decisions:
  - "command = [\"codex\", \"--dangerously-bypass-approvals-and-sandbox\"] — flag-based trust bypass preferred over config.toml trust_level alone (more reliable for headless automation)"
  - "ready_pattern = \"YOLO mode\" — stable substring from startup banner (empirically confirmed present at ~3s)"
  - "startup_timeout_secs = 15 — empirical 3s start + 5x safety margin"
  - "PORT=8081 for e2e-codex.sh — isolated from smoke.sh 8080 to allow concurrent runs (D-07)"
  - "TURNS_DIR=./turns/codex — project-root-relative to satisfy Codex lean-ctx file read restriction (Pitfall 5)"

metrics:
  duration: 8min
  completed: 2026-06-12
---

# Phase 05 Plan 01: Codex CLI Profile and E2E Script

**Codex CLI agent profile (`agents/codex.toml`) and E2E validation script (`scripts/e2e-codex.sh`) created; awaiting human E2E verification at checkpoint (Task 3).**

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | agents/codex.toml を作成する | 64cc15f | agents/codex.toml |
| 2 | scripts/e2e-codex.sh を作成する | e60eef8 | scripts/e2e-codex.sh |

## Accomplishments

**Task 1 — `agents/codex.toml`:**
- `command = ["codex", "--dangerously-bypass-approvals-and-sandbox"]` — trust dialog bypass flag
- `ready_pattern = "YOLO mode"` — from startup banner, confirmed stable at ~3s (empirical)
- `fresh_mode = "command"` + `clear_command = "/clear"` — verified: /clear resets context without dialog (no second Enter needed, unlike OpenCode /new)
- `output_covenant` contains both `{result_path}` and `{status_path}` placeholders; Japanese text (Codex handles Japanese reliably)
- `trigger_template` with `{prompt_path}` placeholder; Japanese path trigger confirmed working
- `startup_timeout_secs = 15` / `turn_timeout_secs = 300` (empirical: 3s start / 18-27s E2E)
- Prerequisite comment block: `codex login`, `trust_level`, `CODEX_HOME` multi-instance note, TURNS_DIR lean-ctx restriction
- `deny_unknown_fields` + `validate_profile` verified via `cargo test --lib profile` (13 tests pass)
- All 33 cargo tests green (no Rust code changes — regression check passed)

**Task 2 — `scripts/e2e-codex.sh`:**
- smoke.sh structure followed: `set -euo pipefail`, `trap cleanup EXIT INT TERM`, `wait_for_server` polling, `require_tool`
- `AGENT=codex PORT=8081 TURNS_DIR=./turns/codex` server startup (D-07 isolated port)
- 3-stage validation:
  1. Basic E2E (AGNT-01): `POST /prompt` → `.status == "done"` + `.result` non-empty
  2. History seed: seeds secret number `7331`
  3. Fresh isolation (AGNT-02 + D-10): `fresh:true` → verifies `7331` absent from response
- Per-stage evidence logged: turnId, elapsed seconds, result excerpt
- `bash -n` syntax check: pass; executable bit: set; `test -x`: pass

## Checkpoint: Task 3 Pending

**Status:** Awaiting human E2E verification (`bash scripts/e2e-codex.sh`)

Task 3 is a `checkpoint:human-verify` with `gate="blocking"`. The script requires:
- Live `codex` CLI + ChatGPT Plus authentication
- CI is excluded (D-08)

**Evidence to record after verification:**
- Stage 1 turnId, elapsed time, result content
- Stage 2 turnId, elapsed time
- Stage 3 turnId, elapsed time, fresh isolation pass/fail
- Any fresh_mode fallback (respawn) if /clear was unstable

## Deviations from Plan

None — plan executed exactly as written for Tasks 1 and 2.

Key clarification during execution: the RESEARCH.md TOML examples used `cmd` as the field name, but the plan correctly specified `command` as the field name matching `src/profile.rs` struct field `pub command: Vec<String>`. The `agents/claude.toml` template also uses `command`, confirming correctness.

## Known Stubs

None — `agents/codex.toml` has real values (not placeholders). `scripts/e2e-codex.sh` is complete and syntactically valid. Both artifacts are ready for live E2E execution.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. `agents/codex.toml` uses the existing `AgentProfile` schema without modification. `scripts/e2e-codex.sh` makes localhost HTTP calls to the same `POST /prompt` endpoint already covered by the threat model. T-05-01 (dangerously-bypass-approvals-and-sandbox) and T-05-02 (covenant file writes) are accepted as documented in the plan threat model.

## Self-Check

Files exist:
- `agents/codex.toml`: FOUND
- `scripts/e2e-codex.sh`: FOUND (executable)

Commits exist:
- `64cc15f`: feat(05-01): add agents/codex.toml — FOUND
- `e60eef8`: feat(05-01): add scripts/e2e-codex.sh — FOUND

## Self-Check: PASSED
