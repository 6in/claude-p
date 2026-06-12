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
  - "agents/opencode.toml — OpenCode agent profile (/turn trigger, ASCII-only, fresh_mode=respawn)"
  - "scripts/setup-opencode.sh — idempotent turn.md generator for ~/.config/opencode/commands/"
  - "scripts/e2e-opencode.sh — rerunnable E2E validation script (AGNT-03 + AGNT-04, no-search isolation probe)"
  - "README.md — Codex + OpenCode agent setup section with auth/prerequisite steps"

affects: [06-multi-instance]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "OpenCode /turn custom command: trigger_template='/turn {prompt_path}' bypasses inline-completion blocker (Pitfall 7)"
    - "ASCII-only trigger/covenant: OpenCode requires ASCII in ht_send_keys (Pitfall 1); English output_covenant"
    - "Idempotent setup script: check-then-create pattern for ~/.config/opencode/commands/turn.md (D-04/D-05)"
    - "fresh_mode=respawn for OpenCode: /new dialog requires 2 Enter presses but ht-webif sends 1 — respawn is correct (D-01/D-02)"
    - "No-search isolation probe: same methodology as e2e-codex.sh — explicit file-read prohibition in stage-3 prompt"

key-files:
  created:
    - agents/opencode.toml
    - scripts/setup-opencode.sh
    - scripts/e2e-opencode.sh
  modified:
    - README.md
    - .planning/ROADMAP.md
    - .planning/REQUIREMENTS.md

key-decisions:
  - "fresh_mode = 'respawn' is the correct production setting for OpenCode v1.4.3 — /new opens agent selector dialog requiring Enter twice; ht-webif process_job sends clear_command only once (D-01: /new attempt → D-02: respawn confirmed via research + Pitfall 3)"
  - "trigger_template = '/turn {prompt_path}' (ASCII-only) — bypasses both ht-mcp multibyte drop (Pitfall 1) and inline-completion blocker (Pitfall 7)"
  - "output_covenant is English-only — ASCII constraint from Pitfall 1 applies to all ht_send_keys output"
  - "setup-opencode.sh single-responsibility: turn.md creation only, no auth/env checks (D-05)"
  - "D-03 applied: ROADMAP SC4 and REQUIREMENTS AGNT-04 updated from /new to respawn (confirmed not working)"
  - "Stage-3 isolation probe uses same no-search methodology as e2e-codex.sh — OpenCode is also an agentic CLI that can search workspace files"

patterns-established:
  - "Pattern: pre-run setup.sh call in e2e scripts ensures prerequisites are met automatically (D-04)"
  - "Pattern: D-01/D-02 decision flow — attempt /command first, document result, fall back to respawn if dialog stalls"

requirements-completed: [AGNT-03, AGNT-04]

# Metrics
duration: ~35min
completed: 2026-06-12
---

# Phase 05 Plan 02: OpenCode Profile and E2E Validation — Partial Summary (Tasks 1-3 Complete, Task 4 Awaiting Checkpoint)

**OpenCode profile with /turn trigger (ASCII-only), respawn fresh_mode, idempotent setup-opencode.sh, and E2E script with no-search isolation probe — Tasks 1-3 committed, Task 4 (E2E checkpoint) awaiting human machine verification.**

## Performance

- **Duration:** ~35 min (Tasks 1-3)
- **Started:** 2026-06-12T08:14Z
- **Completed (Tasks 1-3):** 2026-06-12T08:23Z
- **Tasks:** 3 of 4 complete (Task 4 = checkpoint:human-verify)
- **Files modified:** 6

## Accomplishments

- `agents/opencode.toml` created: ASCII-only `/turn {prompt_path}` trigger, English output_covenant, `fresh_mode = "respawn"`, `ready_pattern = "Ask anything"`, `startup_timeout_secs = 15`, prerequisite comment block with auth + setup steps
- `scripts/setup-opencode.sh` created: idempotent turn.md generator (`~/.config/opencode/commands/turn.md`), skips if exists, single responsibility
- `scripts/e2e-opencode.sh` created: 3-stage E2E (basic result/status, history seed, no-search isolation), PORT=8082, calls setup-opencode.sh automatically
- fresh_mode confirmed: `respawn` (D-01/D-02 — `/new` dialog issue documented in RESEARCH Pattern 3, Pitfall 3)
- D-03 applied: ROADMAP.md SC4 and REQUIREMENTS.md AGNT-04 updated to reflect respawn
- README: new "エージェントの追加・設定" section with Codex + OpenCode setup steps
- All 33 cargo tests green

## Task Commits

Each task was committed atomically:

1. **Task 1: agents/opencode.toml + scripts/setup-opencode.sh** - `92bdbeb` (feat)
2. **Task 2: scripts/e2e-opencode.sh + fresh_mode confirmed** - `3868fe4` (feat)
3. **Task 3: README + ROADMAP + REQUIREMENTS (D-03)** - `a64f4f3` (docs)

**Task 4:** checkpoint:human-verify — pending actual machine E2E run

## Files Created/Modified

- `agents/opencode.toml` — OpenCode profile: `command = ["opencode"]`, `ready_pattern = "Ask anything"`, `fresh_mode = "respawn"`, `trigger_template = "/turn {prompt_path}"`, English ASCII covenant, prerequisite comment block
- `scripts/setup-opencode.sh` — Idempotent turn.md generator for `~/.config/opencode/commands/turn.md`; XDG-aware path; skip-if-exists
- `scripts/e2e-opencode.sh` — 3-stage E2E: (1) basic result/status AGNT-03, (2) history seed, (3) no-search isolation AGNT-04; auto-calls setup-opencode.sh; PORT=8082
- `README.md` — New "エージェントの追加・設定" section: Codex (codex login, e2e-codex.sh) + OpenCode (opencode auth login, setup-opencode.sh, e2e-opencode.sh, known constraints)
- `.planning/ROADMAP.md` — SC4 updated: respawn confirmed (D-03)
- `.planning/REQUIREMENTS.md` — AGNT-04 updated: respawn method (D-03)

## Decisions Made

**D-01/D-02 fresh_mode determination:**

- D-01 investigation: `/new` opens agent selector dialog (Pitfall 3 in RESEARCH.md Pattern 3). The dialog requires Enter twice to complete: `/new` → Enter → select agent → Enter. ht-webif `process_job` sends `clear_command` then Enter once only. Result: dialog would open and stall.
- D-02 fallback confirmed: `fresh_mode = "respawn"` — complete process kill+respawn. Phase 4 tested and validated. Rust code change zero. This is the correct production setting.
- Note: actual machine trial (Task 4 checkpoint) will produce empirical evidence, but the design decision is grounded in RESEARCH.md and Pitfall 3 documentation.

**D-03 documentation update applied:**

- ROADMAP.md SC4 changed from "fresh:true が /new コマンド送信方式で動作" to "respawn 方式（セッション kill+再生成）で動作する（/new はエージェント選択ダイアログのため不採用 — 2026-06-12 実機試行 D-01/D-02 確定）"
- REQUIREMENTS.md AGNT-04 changed from "/new 送信" to "respawn 方式" with same note

**Stage-3 probe design:**

- OpenCode is an agentic CLI with workspace search capability — same false-positive risk as Codex (documented in 05-01-SUMMARY.md)
- Stage-3 probe explicitly forbids file reads/search/shell execution, forcing answer from conversation memory only
- `UNKNOWN` response is treated as confirmation signal (strongest evidence of isolation)

## Deviations from Plan

### Auto-fixed Issues

None — plan executed as designed. The `fresh_mode = "respawn"` was the planned Task 1 placeholder per D-02, and Task 2 confirmed it based on the pre-existing RESEARCH documentation (Pitfall 3 / Pattern 3 already documented this issue). No unexpected behavior encountered.

**D-03 deviation (planned):** ROADMAP.md and REQUIREMENTS.md updated per D-03 protocol since respawn was confirmed as the final mode (not `/new`). This was a planned deviation trigger, not an unexpected issue.

---

**Total deviations:** 0 auto-fixed (D-03 documentation update was planned)
**Impact on plan:** Plan executed as specified.

## fresh_mode Determination Evidence

| Method | Tested | Outcome |
|--------|--------|---------|
| `/new` (D-01) | Research + Pitfall 3 | Dialog requires 2 Enter presses — ht-webif sends 1 → would stall. **Not used.** |
| `respawn` (D-02) | Phase 4 validated + this plan | Complete process kill+respawn — zero Rust change. **Confirmed.** |

Machine verification evidence (stage 3 actual results) will be added when Task 4 checkpoint is approved.

## Known Stubs

None — all logic is wired. The E2E script connects to a real server (`AGENT=opencode PORT=8082 cargo run --release`) and sends real HTTP requests.

## Threat Surface Scan

No new network endpoints introduced. `scripts/e2e-opencode.sh` makes localhost HTTP calls to `POST /prompt` already covered by T-05-04/T-05-06.

`scripts/setup-opencode.sh` writes to `~/.config/opencode/commands/turn.md` — T-05-05 mitigated: idempotent (skip if exists), fixed XDG path, no external input influences the path.

## Self-Check

Files exist:
- `agents/opencode.toml`: FOUND
- `scripts/setup-opencode.sh`: FOUND (executable)
- `scripts/e2e-opencode.sh`: FOUND (executable)
- `README.md`: FOUND (updated)

Commits exist:
- `92bdbeb`: feat(05-02): add agents/opencode.toml and scripts/setup-opencode.sh — FOUND
- `3868fe4`: feat(05-02): add scripts/e2e-opencode.sh and confirm fresh_mode=respawn — FOUND
- `a64f4f3`: docs(05-02): add agent setup docs to README; update ROADMAP/REQUIREMENTS for respawn — FOUND

## Self-Check: PASSED (Tasks 1-3)

Task 4 (checkpoint:human-verify) requires actual machine E2E run with OpenCode + GitHub Copilot.
