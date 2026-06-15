---
phase: 05-codex-cli-and-opencode-validation
plan: 03
subsystem: e2e-validation
tags: [shell, e2e, agnt-04, falsifiability, gap-closure]
gap_closure: true

dependency_graph:
  requires:
    - phase: 05-02
      provides: "scripts/e2e-opencode.sh (3-stage E2E passing) + D-09 wrapper architecture confirmed"
  provides:
    - "scripts/e2e-opencode.sh: falsifiable AGNT-04 E2E (stage 2.5 positive control + respawn log verification + done allowlist)"
  affects:
    - "AGNT-04 requirement: SC4 (fresh:true respawn) now has a test that fails when respawn is broken"

tech_stack:
  added: []
  patterns:
    - "Respawn log verification: grep -cE 'shared-fate.*再生成' LOG_FILE before/after fresh:true turn; delta >= 1 = hard gate"
    - "Positive control stage: non-fresh turn between seed and isolation check to expose D-09 architecture's lack of continuity"
    - "done allowlist gate: status != 'done' -> exit 1 for all stages (WR-01 pattern)"

key_files:
  created: []
  modified:
    - scripts/e2e-opencode.sh

key_decisions:
  - "Stage 3 pass condition replaced: '7331 not in result' (vacuous under D-09) -> Worker::recreate() log delta >= 1 (structural, falsifiable)"
  - "Stage 2.5 added as positive control: records that D-09 non-fresh turns also have no continuity, making stage 2->3 alone insufficient for isolation proof"
  - "WR-01 and WR-02 resolved together with AGNT-04 falsifiability fix (all 4 stages in one file/commit)"

metrics:
  duration: "3min"
  completed: "2026-06-15"
  tasks: 2
  files_modified: 1
---

# Phase 05 Plan 03: AGNT-04 Falsifiable E2E Summary

**Gap-closure: AGNT-04 fresh-isolation test made falsifiable — Worker::recreate() log delta verification + stage 2.5 positive control + done allowlist gates**

## Accomplishments

- `scripts/e2e-opencode.sh`: Added stage 2.5 (positive control) between stages 2 and 3. Non-fresh turn with file-search-disabled prompt asks for secret number, expects UNKNOWN. Records that D-09 wrapper architecture (each `opencode run` is independent) has no conversation continuity even without `fresh:true`, proving stage 2→3 alone cannot verify isolation.

- Stage 3 pass condition replaced from "7331 not in result" (vacuous — would pass even if `fresh_mode=respawn` is completely broken) to "Worker::recreate() actually fired." Implementation: `recreate_before=$(grep -cE 'shared-fate.*再生成' "$LOG_FILE" || true)` before the fresh:true curl, then `recreate_after` after, then `[[ "$recreate_after" -le "$recreate_before" ]]` → exit 1. If respawn is broken or `fresh` flag is ignored, the delta is 0 and stage 3 fails deterministically.

- WR-01 resolved: All four stages (1, 2, 2.5, 3) now use `status != "done"` allowlist gates. The old `status == "timeout" || status == "failed"` pattern is gone — `status="unknown"` (returned by read_turn on garbled JSON, or jq fallback) no longer passes.

- WR-02 resolved: Stage 3 has two new hard gates: (1) empty result → exit 1; (2) UNKNOWN not in result → exit 1. The old INFO-only log for UNKNOWN is replaced by a hard gate.

- Supplementary check retained: 7331 in result3 still exits 1 as a redundant isolation failure signal.

- Final summary log now includes stage 2.5 line and respawn delta proof line.

- `cargo test`: 33 tests green (Rust unchanged — zero source file modifications).

## Task Commits

1. **Tasks 1+2: AGNT-04 falsifiable E2E** — `ecc5a30` (feat)
   - Stage 2.5 positive control block
   - Stage 3 respawn log verification (recreate_before/recreate_after)
   - WR-01 done allowlist (4 stages)
   - WR-02 hard gates (empty result + UNKNOWN required)

## Files Modified

- `scripts/e2e-opencode.sh` — 121 insertions, 36 deletions

## Decisions Made

- Chosen Option 1 from CR-01 (REVIEW.md): make the test honest about what it can verify rather than adding real conversation continuity (Option 2 would require `--continue`/`--session` support to be confirmed, which is out of scope for this gap-closure plan)
- Stage 2.5 does not fail the test if 7331 appears in the response (it could be file-search-derived, not continuity), but logs a WARNING — the test intent is to record D-09 architecture behavior, not to block on it
- Tasks 1 and 2 committed as one atomic commit because both modify the same file and the changes are interdependent (stage 2.5 added between stage 2 and stage 3 changes; done allowlist spans all stages)

## Deviations from Plan

None — plan executed exactly as written. Both tasks implemented in a single commit due to mutual file dependency (same file, logically inseparable changes).

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes. Shell script only — no Rust modifications.

## Self-Check

Files:
- [x] `scripts/e2e-opencode.sh` — FOUND (modified)
- [x] `bash -n scripts/e2e-opencode.sh` — SYNTAX OK
- [x] `grep -q '段階 2.5'` — FOUND
- [x] `done allowlist count >= 3` — 4 occurrences found
- [x] `recreate_before`/`recreate_after` variables — FOUND
- [x] `shared-fate.*再生成` grep pattern — FOUND
- [x] UNKNOWN hard gate — FOUND
- [x] `cargo test` — 33 passed, 0 failed

Commits:
- [x] `ecc5a30` — feat(05-03): AGNT-04 falsifiable E2E — FOUND

## Self-Check: PASSED
