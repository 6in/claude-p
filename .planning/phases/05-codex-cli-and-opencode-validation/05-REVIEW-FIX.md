---
phase: 05-codex-cli-and-opencode-validation
fixed_at: 2026-06-15T00:44:30Z
review_path: .planning/phases/05-codex-cli-and-opencode-validation/05-REVIEW.md
iteration: 1
findings_in_scope: 7
fixed: 7
skipped: 0
status: all_fixed
---

# Phase 05: Code Review Fix Report

**Fixed at:** 2026-06-15T00:44:30Z
**Source review:** .planning/phases/05-codex-cli-and-opencode-validation/05-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 7 (1 Critical + 6 Warning)
- Fixed: 7
- Skipped: 0

All fixes were applied to the E2E test scripts and the opencode runner wrapper only.
No Rust source files (`worker.rs`, `turn.rs`, `profile.rs`) were modified, honoring the
plan's zero-Rust-change mandate. Where the reviewer's preferred fix required a Rust
change (WR-01's `[fresh-respawn]` marker), the script-only alternative the reviewer also
offered (exact-delta assertion) was implemented instead, and the limitation is documented
inline.

## Fixed Issues

### CR-01: Stage-3 recreate-delta gate matches `ensure_healthy()` log, defeating the falsifiability fix

**Files modified:** `scripts/e2e-opencode.sh`
**Commit:** 537acf0
**Applied fix:** Replaced both `grep -cE 'shared-fate.*再生成'` counters (baseline and
after) with `grep -cF '[shared-fate] claude セッション再生成:'` — a fixed-string match on
the colon-bearing success prefix emitted only by `recreate()` at `worker.rs:153`. The
`ensure_healthy()` unhealthy-path line at `worker.rs:116`
(`[shared-fate] claude セッション不健全 → 再生成`) lacks the colon and is now excluded, so
health-check failures no longer inflate the counter. Verified against source: only
`worker.rs:153` carries the `再生成:` colon prefix. The explanatory comment block above the
gate was expanded to document the two distinct log lines and why the colon prefix
disambiguates them.

### WR-01: `recreate_before` baseline cannot distinguish health-driven recreations from fresh-driven ones

**Files modified:** `scripts/e2e-opencode.sh`
**Commit:** 9634335
**Applied fix:** Changed the gate from `recreate_after -le recreate_before` (delta > 0) to
an exact-delta assertion: `recreate_delta == 1` is required for the single fresh turn.
Delta 0 means respawn never fired; delta >= 2 means an `ensure_healthy()`-driven recreate
mixed in during the same turn, making attribution to the fresh branch ambiguous — both now
FAIL with distinct diagnostic messages. The reviewer's stronger suggestion (a
`[fresh-respawn]` marker in `src/turn.rs`) was NOT taken because the phase mandates zero
Rust changes; the inline comment documents this and notes the marker as the ultimate
disambiguation. The summary line was updated to reuse the computed `recreate_delta`.
**Note:** This is a gate-condition (logic) change — flagged for human verification that
`== 1` is the correct expected delta for one fresh turn under the current
`ensure_healthy()` behavior.

### WR-02: `opencode-runner.sh` swallows runner exit status with `|| true`, hiding agent-side failures

**Files modified:** `scripts/opencode-runner.sh`
**Commit:** e4ff683
**Applied fix:** Replaced `eval "$trigger" 2>&1 || true` with a form that captures the
real exit code and logs it to stderr (not the PTY stdout that becomes ht-mcp screen
content): `rc=0; eval "$trigger" || rc=$?; if [[ "$rc" -ne 0 ]]; then echo "[opencode-runner]
WARN: trigger 失敗 (rc=${rc}): $trigger" >&2; fi`. The loop still continues so the next
`ready` signal is emitted. The `rc=$?`-inside-`if ! ...` capture trap (which yields 0, not
the command code) was avoided — verified empirically. Removing `2>&1` also stops stderr
from polluting the snapshot screen.

### WR-03: codex stage-3 isolation assertion is structurally weaker than opencode and can pass vacuously

**Files modified:** `scripts/e2e-codex.sh`
**Commit:** 2225b08
**Applied fix:** Mirrored the opencode hard gates in codex stage 3: added an empty-result
FAIL (`[[ -z "$result3" ]]`) before the 7331 check, and promoted the UNKNOWN check from an
INFO to a hard FAIL (`! grep -qi "UNKNOWN"`). Added a comment noting that
`fresh_mode=command` (`/clear`) context reset is not log-observable the way respawn is, so
the result-text gate is the strongest available signal. The PASS log line now states both
"7331 非出現 + UNKNOWN 出現".
**Note:** This adds assertion (logic) gates — flagged for human verification that requiring
UNKNOWN in `result3` matches the intended model behavior for the file-search-prohibited
prompt.

### WR-04: `$(... | head -c N)` under `pipefail` can SIGPIPE-fail on large results

**Files modified:** `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh`
**Commit:** 8e8c7bb
**Applied fix:** Replaced every `$(echo "$resultN" | head -c N)` substitution with
pure-bash parameter slicing `${resultN:0:N}` across both scripts (6 sites in codex, 7 in
opencode), eliminating the pipe and the SIGPIPE/pipefail hazard. Note: slicing is now
character-based rather than byte-based, which is the reviewer's recommended form and is
safer for multibyte Japanese output.

### WR-05: codex `TURNS_DIR="./turns"` override silently depends on the undocumented per-agent join

**Files modified:** `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh`
**Commit:** 92832d7
**Applied fix:** Added a comment block in both scripts referencing D-16 and the codex
path-root constraint (`agents/codex.toml:16-19`, `main.rs:37` `turns_base.join(&agent_name)`)
explaining why `./turns` is forced and that it overrides any `.env` `TURNS_DIR`. Introduced
an `EFFECTIVE_TURNS_DIR="./turns"` variable used in the launch line, plus a `log` line
printing the effective turns directory after build/launch so a misconfig is diagnosable.

### WR-06: stage-2.5 control treats a `7331` leak as a non-fatal WARNING, weakening the control

**Files modified:** `scripts/e2e-opencode.sh`
**Commit:** d830f63
**Applied fix:** Decided intent explicitly: since the stage-2.5 prompt explicitly prohibits
file reads/search/shell, a `7331` here cannot be legitimately "file-search-derived" — it
implies either the prohibition is not honored or non-fresh continuity exists, both of which
destroy the stage-3 methodological premise. Promoted the 7331 case from a WARNING (continue)
to a hard FAIL (checked first, `exit 1`), removed the misleading "ファイル検索由来の可能性が高い"
framing, and expanded the comment to record the rationale.
**Note:** This converts a non-fatal WARNING into a hard FAIL (control-flow/logic change) —
flagged for human verification that failing the run on a stage-2.5 7331 leak matches the
intended methodology.

## Skipped Issues

None — all 7 in-scope findings were fixed.

The 5 Info findings (IN-01 through IN-05) were out of scope (`fix_scope=critical_warning`)
and were not attempted. IN-03 (`opencode.toml clear_command = "/new"` dead/known-broken
config) and IN-04 (`eval` safety comment) overlap with the touched files but were left
unmodified per scope.

---

_Fixed: 2026-06-15T00:44:30Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
