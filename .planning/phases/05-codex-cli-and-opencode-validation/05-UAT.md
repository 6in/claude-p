---
status: complete
phase: 05-codex-cli-and-opencode-validation
source: [05-VERIFICATION.md]
started: 2026-06-15T00:00:00Z
updated: 2026-06-15T02:30:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Normal AGNT-04 E2E run (live)
expected: `bash scripts/e2e-opencode.sh` on a host with opencode + ht-mcp + GitHub Copilot auth — stage 2.5 records UNKNOWN (no continuity), stage 3 logs recreate_delta == 1, script exits 0.
result: pass

### 2. Falsifiability proof (break fresh_mode=respawn)
expected: Set `fresh_mode = "bogus"` (or otherwise disable respawn) in agents/opencode.toml and run `bash scripts/e2e-opencode.sh` — the script exits 1 at stage 3 (recreate_delta == 0 gate fires, or status != done), NOT at stage 1/2. Confirms the AGNT-04 gate is genuinely falsifiable.
result: pass
note: "fresh_mode=bogus 実機実行 (2026-06-15 02:26): 段階1/2/2.5 全 PASS、段階3で status=failed (`未知の fresh_mode: bogus`) → exit 1。stage 1/2 ではなく stage 3 で落ちることを確認。toml は respawn に復元済み。"

### 3. delta == 1 assumption holds at runtime
expected: During the stage-3 fresh:true turn, ensure_healthy() sees a healthy session ("OpenCodeRunner ready") and does NOT fire its own recreate(); only the fresh_mode=respawn path calls recreate() once → recreate_delta == 1. (If ensure_healthy() ever fires recreate() in the same turn, delta would be 2 and stage 3 would conservatively FAIL — confirm this does not happen in normal operation.)
result: pass
note: "Test 1 正常実行ログで実証 (before=0 → after=1, 増分 1)。stage 3 が PASS = 374行目 recreate_delta!=1 ゲートを通過 = delta はちょうど 1。ensure_healthy() 由来の recreate 混入があれば delta>=2 で FAIL するため、混入なしを背理法的に確認。"

## Summary

total: 3
passed: 3
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
