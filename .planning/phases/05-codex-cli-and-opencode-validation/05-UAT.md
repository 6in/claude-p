---
status: testing
phase: 05-codex-cli-and-opencode-validation
source: [05-VERIFICATION.md]
started: 2026-06-15T00:00:00Z
updated: 2026-06-15T00:00:00Z
---

## Current Test

number: 1
name: Run scripts/e2e-opencode.sh on a live host (opencode + ht-mcp + GitHub Copilot auth)
expected: |
  Stage 2.5 returns UNKNOWN (no conversational continuity), and stage 3 shows
  recreate_delta == 1 in the summary log and the script exits 0 (all stages PASS).
awaiting: user response

## Tests

### 1. Normal AGNT-04 E2E run (live)
expected: `bash scripts/e2e-opencode.sh` on a host with opencode + ht-mcp + GitHub Copilot auth — stage 2.5 records UNKNOWN (no continuity), stage 3 logs recreate_delta == 1, script exits 0.
result: [pending]

### 2. Falsifiability proof (break fresh_mode=respawn)
expected: Set `fresh_mode = "bogus"` (or otherwise disable respawn) in agents/opencode.toml and run `bash scripts/e2e-opencode.sh` — the script exits 1 at stage 3 (recreate_delta == 0 gate fires, or status != done), NOT at stage 1/2. Confirms the AGNT-04 gate is genuinely falsifiable.
result: [pending]

### 3. delta == 1 assumption holds at runtime
expected: During the stage-3 fresh:true turn, ensure_healthy() sees a healthy session ("OpenCodeRunner ready") and does NOT fire its own recreate(); only the fresh_mode=respawn path calls recreate() once → recreate_delta == 1. (If ensure_healthy() ever fires recreate() in the same turn, delta would be 2 and stage 3 would conservatively FAIL — confirm this does not happen in normal operation.)
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
