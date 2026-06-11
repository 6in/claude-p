---
phase: 260527-gp0
plan: 01
subsystem: scripts
tags: [bash, wrapper, daemon, cli]
dependency_graph:
  requires: []
  provides: [webif/scripts/claude-p]
  affects: [webif/README.md]
tech_stack:
  added: []
  patterns: [nohup-disown daemon pattern, per-port path isolation, async-poll loop]
key_files:
  created:
    - webif/scripts/claude-p
  modified:
    - webif/README.md
decisions:
  - Per-port turns directory (turns-${PORT}) to avoid cross-instance artifact mixing
  - Polling interval 30s x 20 polls = 10 min maximum wait, matching async turn processing
  - JSON_ENCODER auto-detected (jq preferred, python3 fallback) — no hard dependency on jq
  - INT/TERM trap exits wrapper only, server continues independently (per spec)
metrics:
  duration: ~10m
  completed: "2026-05-27T03:07:41Z"
  tasks_completed: 2
  files_changed: 2
---

# Phase 260527-gp0 Plan 01: claude-p Wrapper Script Summary

Bash wrapper script `webif/scripts/claude-p` that auto-starts ht-webif as a daemonized process and drives `POST /prompt` + polling loop so callers don't need raw curl.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create webif/scripts/claude-p | f10453c | webif/scripts/claude-p (new, 100755) |
| 2 | README.md claude-p section | f10453c | webif/README.md (+38 lines) |

Both tasks were committed atomically in a single feat commit.

## Commit Details

- `f10453c` — `feat(scripts): add claude-p wrapper for daemonized curl-less prompt submission`

## What Was Built

`webif/scripts/claude-p` is a ~240-line bash script providing:

- **Auto-start**: If the target port has no running server, spawns `cargo run --release` via `nohup` + `disown`, waits up to 60s for readiness, saves PID to `/tmp/ht-webif-${PORT}.pid`
- **Prompt submission**: `POST /prompt` (async, no `wait:true`) with JSON encoding via jq or python3 fallback
- **Polling**: 30s interval x 20 polls for `GET /turns/{turn_id}`, exits 0 on `done`/`completed`, exits 1 on `failed`/`timeout`
- **`stop` subcommand**: SIGTERM -> 5s wait -> SIGKILL, removes PID file
- **`status` subcommand**: Displays PORT, PID, LOG, TURNS_DIR, server liveness, process alive check, and last 5 log lines
- **Per-port isolation**: `TURNS_DIR=${WEBIF_DIR}/turns-${PORT}` keeps turn artifacts separated per server instance
- **Pipe-friendly**: result to stdout only, progress logs to stderr

Style mirrors `smoke.sh` exactly: `set -euo pipefail`, `[claude-p]` log prefix, `require_tool`, readiness wait loop with `kill -0` early-death detection.

## README Addition

New section `## claude-p — curl 不要の薄いラッパ` inserted between `## 動作確認` and `## API` covering basic usage, stdin form, behavior details, subcommand examples, and caveats about daemon independence.

## Deviations from Plan

None — plan executed exactly as written.

The `subshell spawn` pattern was used for the `nohup` + PID capture (launching in a subshell `( cd "$WEBIF_DIR"; nohup ...; local pid=$!; echo $pid > PID_FILE; disown )`) to cleanly handle the directory change and PID recording without affecting the parent shell's working directory.

## Known Stubs

None.

## Threat Flags

None. This is a local bash wrapper script with no network-exposed surface. It connects only to `127.0.0.1` (loopback) and the ht-webif server it manages is already loopback-only per architecture.

## Self-Check

- [x] `webif/scripts/claude-p` exists: FOUND
- [x] `test -x webif/scripts/claude-p`: executable bit set
- [x] `bash -n webif/scripts/claude-p`: syntax OK
- [x] README section present: FOUND
- [x] Commit `f10453c` exists: FOUND (`git log --oneline -3` confirmed)

## Self-Check: PASSED
