---
phase: 05-codex-cli-and-opencode-validation
plan: 01
subsystem: config
tags: [agent-profile, codex, e2e, config, toml, bash, investigation]

requires:
  - phase: 04-agent-profile-abstraction
    provides: "AgentProfile struct, load_agent_profile, agents/claude.toml, fresh_mode dispatch"

provides:
  - "agents/codex.toml — Codex CLI agent profile (fresh_mode=command validated, rollout-file evidence)"
  - "scripts/e2e-codex.sh — rerunnable E2E validation script (AGNT-01 + AGNT-02, no-search isolation probe)"

affects: [05-02-opencode-validation, 06-multi-instance]

tech-stack:
  added: []
  patterns:
    - "TOML agent profile following agents/claude.toml style (command field, Japanese comments, prerequisite block)"
    - "E2E bash script following smoke.sh patterns (set -euo pipefail, cleanup+trap, wait_for_server, require_tool)"
    - "No-search isolation probe: 3-stage test with explicit file-read prohibition in fresh-turn prompt (prevents agentic CLI false positives)"
    - "jq for JSON construction of multi-byte prompts in curl payloads"

key-files:
  created:
    - agents/codex.toml
    - scripts/e2e-codex.sh
  modified:
    - agents/codex.toml (respawn rollback to command via investigation)
    - scripts/e2e-codex.sh (stage-3 no-search probe fix)

decisions:
  - "fresh_mode = command (/clear) is the validated production setting for Codex v0.139.0 — rollout file inspection confirms /clear starts a zero-history session (D-10 satisfied)"
  - "Stage-3 isolation probe MUST forbid file search — agentic CLIs with workspace access will find the secret in turns/ prompt files; this is a test methodology requirement, not a Codex limitation"
  - "command = [\"codex\", \"--dangerously-bypass-approvals-and-sandbox\"] — flag-based trust bypass preferred over config.toml trust_level alone"
  - "ready_pattern = \"YOLO mode\" — stable substring from startup banner (empirically confirmed ~3s)"
  - "startup_timeout_secs = 15 — empirical 3s start + 5x safety margin"
  - "PORT=8081 for e2e-codex.sh — isolated from smoke.sh 8080 (D-07)"
  - "TURNS_DIR=./turns/codex — project-root-relative to satisfy Codex lean-ctx file read restriction"

metrics:
  duration: ~90min (includes 2 failed runs + investigation + methodology fix)
  completed: 2026-06-12
---

# Phase 05 Plan 01: Codex CLI Profile and E2E Validation — Complete Summary

**Codex CLI agent profile and E2E script created and fully validated. `fresh_mode="command"` (/clear) confirmed correct via rollout-file inspection; the apparent 7331 leak was a test methodology defect — stage-3 prompt lacked file-search prohibition. After fix: stage 3 returned "UNKNOWN" (strongest isolation evidence).**

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | agents/codex.toml を作成する | 64cc15f | agents/codex.toml |
| 2 | scripts/e2e-codex.sh を作成する | e60eef8 | scripts/e2e-codex.sh |
| 3a | respawn fallback (incorrect diagnosis) | c3a4f5a, 6efea25 | agents/codex.toml |
| 3b | methodology fix + revert to command | 8b892bc | agents/codex.toml, scripts/e2e-codex.sh |
| 3c | E2E re-run: all 3 stages pass | (no code change) | — |

## Investigation Narrative

### Background: Tasks 1 and 2

Task 1 created `agents/codex.toml` with `fresh_mode="command"` and `clear_command="/clear"`.
Task 2 created `scripts/e2e-codex.sh` with a 3-stage E2E: basic result/status check (AGNT-01), a seed turn, and a fresh-isolation probe (AGNT-02).

### Run 1: fresh_mode="command", stage 3 appeared to leak 7331

Stage 3 prompt: `"What secret number did I tell you?"` with `fresh:true`.
Result: Codex returned `7331`.
Suspicion: `/clear` might not isolate conversation history on the server side.

### Run 2: Fallback to fresh_mode="respawn", stage 3 still leaked 7331

Prior executor switched `codex.toml` to `fresh_mode="respawn"` (commits c3a4f5a, 6efea25).
Stage 1 took 330s (cold Cargo build cache warm-up).
Stage 3 still returned `7331`.
Prior executor concluded: "AGNT-02 unachievable — Codex reloads session history." **This diagnosis was wrong.**

### Orchestrator investigation: rollout file inspection

The orchestrator inspected `~/.codex/sessions/2026/06/12/rollout-*.jsonl` for both failed runs.

Key findings:
1. Both stage-3 sessions started with **zero prior conversation history** — confirmed by Codex's own reasoning in the rollout: 「会話内には数字が見えていない」 (no number visible in conversation).
2. In both runs, Codex then **searched the workspace** (`rg`, `ctx_search`) and found `7331` inside the previous turn's prompt file `turns/codex/codex/prompt-20260612-074824-755.txt` (and `075915` in run 2).
3. The `cached_input_tokens: 69120` figure was server-side prompt caching (system prompt + tools), not conversation history reload.

**Conclusion:** History isolation works correctly with both `/clear` and `respawn`. The "leak" was a **false positive caused by flawed test methodology**: ht-webif stores the prompt in `turns/codex/codex/prompt-<turnId>.txt` on disk. An agentic CLI with workspace access autonomously searches the workspace when asked about a number — and finds it.

### Correction 1: Revert agents/codex.toml to fresh_mode="command"

`fresh_mode = "command"` restored as the correct production setting. Comments updated to document the full investigation and confirm that `/clear` correctly isolates conversation history (rollout file evidence). Note that `respawn` also achieves isolation but has higher startup overhead.

### Correction 2: Fix scripts/e2e-codex.sh stage-3 probe

Stage 3 prompt changed to explicitly forbid file search:

> 「ファイルの読み取り・検索・シェルコマンド実行を一切せず、この会話のこれまでの記憶だけで答えてください。私が以前伝えた秘密の数値は何ですか？知らない場合は UNKNOWN とだけ書いてください。」

JSON construction changed from `@Q` (bash shell quoting, invalid JSON) to `jq --arg` (correctly escapes multi-byte Japanese text).

Added `UNKNOWN` detection as a positive confirmation signal (additional confidence).

### Final E2E Run: all 3 stages passed

Run date: 2026-06-12, correction commit: 8b892bc

| Stage | Purpose | turnId | Elapsed | Result | Status |
|-------|---------|--------|---------|--------|--------|
| 1 | Basic E2E (AGNT-01) | 20260612-081024-367 | 26s | "4" | PASS |
| 2 | History seed | 20260612-081050-533 | 29s | (ack) | PASS |
| 3 | Fresh isolation (AGNT-02) | 20260612-081119-766 | 19s | "UNKNOWN" | PASS |

Stage 3 result was exactly "UNKNOWN" — the model had no memory of the secret number from its conversation history and correctly reported it unknown. This is the strongest possible evidence of successful history isolation.

## Key Decision

**`fresh_mode = "command"` with `/clear` is the validated production setting for Codex CLI v0.139.0.**

Evidence: rollout file inspection (`~/.codex/sessions/2026/06/12/rollout-*.jsonl`) proves `/clear` produces a zero-history session. The "leak" was a test artifact — turns/ prompt files persist on disk and an agentic CLI will find them via workspace search. Any isolation test for an agentic CLI MUST explicitly forbid file search in the probe prompt.

## Accomplishments

**agents/codex.toml (final state):**
- `command = ["codex", "--dangerously-bypass-approvals-and-sandbox"]` — trust dialog bypass
- `ready_pattern = "YOLO mode"` — startup banner substring, ~3s empirical
- `fresh_mode = "command"` + `clear_command = "/clear"` — validated via rollout file inspection
- `output_covenant` with `{result_path}` and `{status_path}` placeholders; Japanese text
- `trigger_template` with `{prompt_path}`; Japanese trigger confirmed working
- `startup_timeout_secs = 15` / `turn_timeout_secs = 300`
- Prerequisite comment block: full investigation history, rollout evidence, both modes confirmed

**scripts/e2e-codex.sh (final state):**
- smoke.sh structure: `set -euo pipefail`, `trap cleanup EXIT INT TERM`, `wait_for_server`, `require_tool`
- `AGENT=codex PORT=8081 TURNS_DIR=./turns/codex` server startup
- Stage 3 no-search isolation probe with detailed comment explaining the false-positive risk
- jq-based JSON construction for safe multi-byte prompt encoding
- UNKNOWN detection as confirmation signal
- All syntax checks pass; executable bit set

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Stage-3 isolation probe was methodologically invalid**
- **Found during:** Task 3 — two consecutive E2E failures
- **Issue:** Stage-3 prompt `"What secret number did I tell you?"` allowed Codex to search workspace files, yielding a false positive. Codex had no conversation history but found 7331 in `turns/codex/codex/prompt-*.txt`.
- **Fix:** Added explicit file-read/search prohibition to the stage-3 prompt; jq-based JSON construction for correctness.
- **Files modified:** `scripts/e2e-codex.sh`, `agents/codex.toml` (reverted from respawn to command)
- **Commit:** 8b892bc

**2. [Deviation] Prior executor incorrectly switched fresh_mode to respawn**
- Commits c3a4f5a and 6efea25 changed `fresh_mode = "respawn"` based on wrong diagnosis.
- Reverted to `fresh_mode = "command"` in 8b892bc with full investigation documentation.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. `agents/codex.toml` uses the existing `AgentProfile` schema. `scripts/e2e-codex.sh` makes localhost HTTP calls to `POST /prompt` already covered by the threat model. T-05-01 and T-05-02 accepted as documented.

## Self-Check

Files exist:
- `agents/codex.toml`: FOUND (fresh_mode="command")
- `scripts/e2e-codex.sh`: FOUND (executable, no-search probe)

Commits exist:
- `64cc15f`: feat(05-01): add agents/codex.toml — FOUND
- `e60eef8`: feat(05-01): add scripts/e2e-codex.sh — FOUND
- `c3a4f5a`: fix(05-01): switch fresh_mode to respawn — FOUND (superseded)
- `6efea25`: fix(05-01): retain clear_command field — FOUND (superseded)
- `8b892bc`: fix(05-01): revert fresh_mode to command + fix stage-3 methodology — FOUND

E2E evidence:
- Stage 1 (AGNT-01): turnId=20260612-081024-367, 26s, result="4", status=done — PASS
- Stage 2 (seed): turnId=20260612-081050-533, 29s, status=done — PASS
- Stage 3 (AGNT-02): turnId=20260612-081119-766, 19s, result="UNKNOWN", status=done — PASS

## Self-Check: PASSED
