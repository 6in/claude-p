---
phase: 260526-voj
plan: "01"
subsystem: webif/scripts
tags: [smoke-test, shell, dx]
dependency_graph:
  requires: []
  provides: [SMOKE-01]
  affects: [webif/README.md]
tech_stack:
  added: []
  patterns: [bash strict-mode, trap cleanup, curl readiness probe]
key_files:
  created:
    - webif/scripts/smoke.sh
  modified:
    - webif/README.md
decisions:
  - Used `seq 1 60` for loop counter to keep `bash -n` clean and shellcheck-happy
  - Cleanup trap returns original exit code via `return $rc` for clean failure propagation
  - Loop variable named `_` in wait-kill inner loop to avoid SC2034 (unused variable)
metrics:
  duration: "~5 min"
  completed: "2026-05-26"
  tasks_completed: 2
  files_changed: 2
---

# Phase 260526-voj Plan 01: Add Smoke Test Script for ht-webif Summary

**One-liner:** Single bash smoke test (`scripts/smoke.sh`) driving a full
cargo-build → readiness-wait → POST /prompt (wait:true) → result-check cycle
with Japanese `[smoke]` log messages, pre-flight dependency checks, and
cleanup trap for process reaping.

## How to Run

```bash
./webif/scripts/smoke.sh
```

Requires: logged-in `claude` CLI on PATH + `ht-mcp` on PATH (or `HT_MCP_PATH`
env pointing to the binary). No other setup needed.

## Artefacts Produced

### `webif/scripts/smoke.sh` (new, mode 0755)

150-line bash script implementing an end-to-end smoke test:

1. **Pre-flight checks** — verifies `claude` CLI and `ht-mcp`/`HT_MCP_PATH`
   before touching cargo.
2. **Server launch** — `cargo run --release` from `webif/` (so `dotenvy` finds
   `.env`), log redirected to `/tmp/ht-webif-smoke-$$.log`.
3. **Readiness loop** — polls `GET /turns/0` up to 60 s; also checks the cargo
   process is still alive (catches build failures and port conflicts within ~1 s
   of them occurring).
4. **Prompt submission** — `POST /prompt` with `{"wait": true}`, 720 s
   `--max-time`.
5. **Result inspection** — `jq` if available, sed fallback otherwise; fails on
   `status=timeout|failed`.
6. **Cleanup trap** — on EXIT/INT/TERM: SIGTERM → 5 s grace → SIGKILL the cargo
   process (Rust's `kill_on_drop` cascades to `ht-mcp` and the `claude` TUI);
   dumps last 40 log lines on failure; removes log on success.

### `webif/README.md` (modified)

Added `## 動作確認` section between `## 起動` and `## API`. The section is 7
content lines (including the fenced code block), pointing at `./scripts/smoke.sh`
with a brief description of what it does.

## Deviations from Plan

None — plan executed exactly as written.

One implementation detail worth noting: the inner kill-wait loop uses `_` as
the loop variable (`for _ in 1 2 3 4 5`) to avoid shellcheck SC2034 ("variable
assigned but not used"). No `# shellcheck disable` directive was needed. The
global `CARGO_PID=""` declaration comment references SC2034 in case a future
shellcheck installation is stricter about it; the disable is preemptive.

shellcheck was not installed on this machine, so only `bash -n` syntax validation
was performed. The script was written to be shellcheck-clean (no intentional
violations; the one `# shellcheck disable=SC2034` is conservative/preemptive).

## Verification Results

| Check | Result |
|-------|--------|
| `bash -n webif/scripts/smoke.sh` | PASSED |
| `[ -x webif/scripts/smoke.sh ]` | PASSED (mode 0755) |
| `grep -q "^## 動作確認$" webif/README.md` | PASSED |
| `grep -q "scripts/smoke.sh" webif/README.md` | PASSED |
| Heading order: 起動 → 動作確認 → API | PASSED (lines 36 → 71 → 83) |
| shellcheck | Not installed — `bash -n` substituted |

## Commits

| Task | Commit | Message |
|------|--------|---------|
| Task 1: Create smoke.sh | `8fd95c5` | `feat(quick-260526-voj): add smoke test script for ht-webif` |
| Task 2: README update | `9c0153e` | `docs(quick-260526-voj): document smoke.sh in README` |

## Self-Check: PASSED

- `/home/parallels/workspaces/ht-mcp-sample/webif/scripts/smoke.sh` exists and is executable
- Commits `8fd95c5` and `9c0153e` exist in git log
- `## 動作確認` section present in README.md between 起動 and API headings
