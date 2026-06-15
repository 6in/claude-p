---
phase: 05-codex-cli-and-opencode-validation
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - agents/codex.toml
  - agents/opencode.toml
  - scripts/e2e-codex.sh
  - scripts/e2e-opencode.sh
  - scripts/opencode-runner.sh
  - scripts/setup-opencode.sh
  - src/profile.rs
  - src/turn.rs
  - src/worker.rs
findings:
  critical: 1
  warning: 6
  info: 5
  total: 12
status: issues_found
---

# Phase 05: Code Review Report

**Reviewed:** 2026-06-15
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Phase 05 validates the Codex and OpenCode agent profiles end-to-end. The most recent
change (plan 05-03) reworked `scripts/e2e-opencode.sh` to make the AGNT-04 `fresh:true`
respawn check falsifiable by gating on a `[shared-fate]` recreate-log delta.

The central problem is in exactly that gate: the grep pattern used to count
`Worker::recreate()` firings (`shared-fate.*再生成`) also matches the
`ensure_healthy()` health-failure log line (`worker.rs:116`), which fires at the start
of **every** turn. This re-opens the falsifiability hole the plan set out to close —
the gate can pass even when the `respawn` fresh path never executes. That is the
BLOCKER (CR-01).

Beyond that, the warnings concern: a baseline-counting weakness in the same gate, an
`eval`-based command runner that silently swallows runner failures, asymmetric and
weaker assertions between the codex and opencode scripts, a `head -c` pipe that can
trip `set -o pipefail` on large results, and a TURNS_DIR override that depends on an
undocumented per-agent join. The Rust source (`profile.rs`, `turn.rs`, `worker.rs`) is
solid; findings there are minor.

## Critical Issues

### CR-01: Stage-3 recreate-delta gate matches `ensure_healthy()` log, defeating the falsifiability fix

**File:** `scripts/e2e-opencode.sh:279,332,335` (gate) / `src/worker.rs:116,153` (logs)

**Issue:**
The whole point of the 05-03 gap-closure is that the stage-3 gate must FAIL if the
`fresh_mode=respawn` path does not actually fire `Worker::recreate()`. The gate counts
log lines matching `shared-fate.*再生成`:

```bash
recreate_before=$(grep -cE 'shared-fate.*再生成' "$LOG_FILE" || true)
...
recreate_after=$(grep -cE 'shared-fate.*再生成' "$LOG_FILE" || true)
if [[ "$recreate_after" -le "$recreate_before" ]]; then ... FAIL
```

But `src/worker.rs` emits **two** distinct `[shared-fate] ... 再生成` lines, and both
match the pattern:

- `worker.rs:116` — `eprintln!("[shared-fate] claude セッション不健全 → 再生成")`
  (printed by `ensure_healthy()` when the health snapshot fails)
- `worker.rs:153` — `eprintln!("[shared-fate] claude セッション再生成: {} ...")`
  (printed at the end of `recreate()` on success)

Critically, `process_job()` calls `worker.ensure_healthy().await?` at the very start of
**every** turn (`src/turn.rs:50`), before the `fresh_mode` dispatch. If the OpenCode
session is judged unhealthy during the stage-3 turn — plausible because the
`opencode-runner.sh` wrapper screen only contains the `ready_pattern`
("OpenCodeRunner ready") between turns and may not match mid-turn — `ensure_healthy()`
prints line 116 and the delta becomes positive even if the `respawn` branch is broken
or `fresh` is ignored. The gate then PASSES for the wrong reason, exactly the
vacuous-pass failure mode the plan was written to eliminate.

Even on the happy path, line 116 is not the success line; matching it means the gate
measures "any shared-fate activity," not "recreate succeeded for the fresh turn."

**Fix:** Anchor the grep to the unambiguous success line only (the one with the colon +
old-session text from `recreate()` at `worker.rs:153`), so health-check failures do not
count:

```bash
# 再生成成功行のみを計数する（ensure_healthy の "不健全 → 再生成" 行を除外）
recreate_before=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
...
recreate_after=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
```

The fixed prefix `[shared-fate] claude セッション再生成:` (note the colon, which line
116 lacks) selects only successful `recreate()` completions and excludes the
`ensure_healthy()` unhealthy-path line. Recommend also asserting the delta equals the
expected count (1 for one fresh turn) rather than just `>`.

## Warnings

### WR-01: `recreate_before` baseline cannot distinguish health-driven recreations from fresh-driven ones

**File:** `scripts/e2e-opencode.sh:279,335`

**Issue:** Even after CR-01 narrows the pattern to the success line, the gate only
proves *some* `recreate()` completed between baseline and after — it does not prove the
fresh/respawn branch caused it. `ensure_healthy()` itself calls `recreate()` (and thus
emits the success line at `worker.rs:153`) whenever the snapshot lacks the ready
pattern. So a stage-3 turn where `fresh` was ignored but the session happened to be
judged unhealthy would still increment the counter and PASS. The `after > before`
comparison is necessary but not sufficient to attribute the recreate to the fresh path.

**Fix:** Assert the delta equals exactly 1 for the single fresh turn, and document that
an `ensure_healthy()`-driven recreate during the same turn would inflate it. Better:
add a distinct log marker on the `fresh`+respawn branch in `src/turn.rs` (e.g.
`eprintln!("[fresh-respawn] ...")`) and gate on that marker so the signal is
unambiguous about *why* recreate fired.

### WR-02: `opencode-runner.sh` swallows runner exit status with `|| true`, hiding agent-side failures

**File:** `scripts/opencode-runner.sh:33`

**Issue:**
```bash
eval "$trigger" 2>&1 || true
```
`opencode run` failures (auth expired, model error, non-zero exit) are silently
discarded and the wrapper re-emits "OpenCodeRunner ready" as if the turn succeeded.
Because the completion signal is the `status-<id>.json` file, a failed `opencode run`
that never wrote the status file surfaces as a 300s turn *timeout* instead of a fast,
diagnosable failure. The `2>&1` also merges stderr into the runner's stdout, which
ht-mcp captures as TUI screen content — error text could coincidentally contain the
`ready_pattern` or pollute snapshot matching.

**Fix:** Keep the loop alive but log the exit code to stderr (not the PTY stdout that
becomes screen content):
```bash
if ! eval "$trigger"; then
    echo "[opencode-runner] WARN: trigger 失敗 (rc=$?): $trigger" >&2
fi
```

### WR-03: codex stage-3 isolation assertion is structurally weaker than opencode and can pass vacuously

**File:** `scripts/e2e-codex.sh:241-253`

**Issue:** The codex stage-3 "history isolation" check is only:
```bash
if echo "$result3" | grep -q "7331"; then ... FAIL
```
There is no hard gate that `result3` is non-empty and no requirement that it contain
`UNKNOWN` (UNKNOWN is only an INFO at line 249). An empty result, or any answer that
simply omits "7331", passes. This is the same vacuous-pass class the opencode script
was explicitly hardened against in stage 3 (`e2e-opencode.sh:308-320` add empty +
UNKNOWN hard gates). For Codex it is arguably worse because the fresh path is
`fresh_mode="command"` (`/clear`), whose actual context reset is not observable from
the result text — a broken `/clear` still passes as long as the model omits 7331. Two
scripts validating the same property (AGNT-02 vs AGNT-04) should not diverge in rigor.

**Fix:** Mirror the opencode hard gates: fail if `result3` is empty, and fail if
`result3` does not contain `UNKNOWN`. Note in a comment that `fresh_mode=command`
isolation is not log-observable the way respawn is, so the result-text gate is the
strongest available signal.

### WR-04: `$(... | head -c N)` under `pipefail` can SIGPIPE-fail on large results

**File:** `scripts/e2e-codex.sh:163,166,232,235,244`; `scripts/e2e-opencode.sh:175,179,240,300,304,318,326`

**Issue:** With `set -o pipefail`, `echo "$resultN" | head -c 100` makes `head` close
the pipe after 100 bytes; for a large `resultN`, `echo` receives SIGPIPE (exit 141) and
the pipeline reports failure. These pipes sit inside `log "...$(...)..."` substitutions,
so in practice they usually do not abort the script, but it is fragile: moving any of
them into an `if`/assignment context, or running under a shell where the substitution
status propagates, causes spurious failures on long agent outputs. A latent hazard
created by combining `pipefail` with truncating consumers.

**Fix:** Use pure-bash slicing, which avoids the pipe entirely:
```bash
log "段階 3 result 先頭 100 文字: ${result3:0:100}"
```

### WR-05: codex `TURNS_DIR="./turns"` override silently depends on the undocumented per-agent join

**File:** `scripts/e2e-codex.sh:115`; `scripts/e2e-opencode.sh:127`

**Issue:** Both scripts launch with `TURNS_DIR="./turns"`. `agents/codex.toml:16-19`
warns that Codex rejects file reads outside the project root and that the default
`./turns/codex/` (D-16) must be used. The scripts rely on `main.rs:37`
(`turns_base.join(&agent_name)`) to expand `./turns` into `./turns/codex`. That is
correct today, but it is hidden coupling: the script hard-codes `./turns` only to land
inside the project root, and the per-agent suffix is applied elsewhere. If D-16
behavior changes the codex path-escape error returns. The override also discards any
`TURNS_DIR` the operator configured in `.env` with no log line stating the E2E forces
`./turns`.

**Fix:** Add a comment in both scripts referencing D-16 and the codex path-root
constraint explaining why `./turns` is forced; optionally `log` the effective turns
directory after server start so a misconfig is diagnosable.

### WR-06: stage-2.5 control treats a `7331` leak as a non-fatal WARNING, weakening the control

**File:** `scripts/e2e-opencode.sh:251-253`

**Issue:** Stage 2.5 is the positive control establishing that the D-09 architecture
has no cross-turn continuity (expected: UNKNOWN). If `7331` appears in the non-fresh
response, the script only logs a WARNING and continues. But a `7331` leak in the
*non-fresh* control directly undermines the stage-3 conclusion: if the architecture
leaks 7331 without fresh, then stage 3's "no 7331" sub-check (line 323) proves nothing,
and the methodology premise ("段階 2→3 の 7331 非出現は隔離の証拠にならない") is the
very thing being demonstrated — yet a positive 7331 here is silently tolerated. The
control can report PASS while quietly recording the condition that invalidates the
file-search-prohibition methodology.

**Fix:** Decide intent explicitly. If the file-search prohibition is supposed to hold,
a `7331` in stage 2.5 should fail the run. If file-search leakage is expected and the
methodology relies only on the log-delta gate, say so and drop the misleading
"ファイル検索由来の可能性が高い" warning in favor of a clear recorded outcome.

## Info

### IN-01: `wait_for_server` would accept a stale server already bound to the port

**File:** `scripts/e2e-codex.sh:128`; `scripts/e2e-opencode.sh:140`

**Issue:** `curl ... "$BASE_URL/turns/0"` returning success is the readiness signal
(404 OK by design). A different process already bound to the dedicated port (e.g. a
stale server from a crashed prior run) would also satisfy this and the test would run
against the wrong server. Low likelihood given dedicated ports 8081/8082.

**Fix:** Optionally probe that the port is free before launching cargo, or correlate the
expected `AGENT`/PID in the readiness check.

### IN-02: Duplicated cleanup / require_tool / wait_for_server boilerplate across the two E2E scripts

**File:** `scripts/e2e-codex.sh:42-139`; `scripts/e2e-opencode.sh:50-151`

**Issue:** `log`, `require_tool`, `cleanup`, and `wait_for_server` are near-identical
copies. Divergence already exists (the status allowlist hardening in WR-03 lives only in
opencode). Shared helpers would prevent the two scripts from drifting in rigor.

**Fix:** Extract a `scripts/e2e-lib.sh` sourced by both, or add a comment
cross-referencing the sibling script so future edits stay in sync.

### IN-03: `opencode.toml` `clear_command = "/new"` is dead config and a known-broken value under `fresh_mode=respawn`

**File:** `agents/opencode.toml:56-57`

**Issue:** `process_job` reads `clear_command` only in the `"command"` branch
(`turn.rs:55-58`), so `/new` is never sent under respawn. Harmless today, but `/new` is
documented (in `e2e-opencode.sh:12-16`) as actively broken (opens an agent-selection
dialog). Keeping a known-broken value in a live field invites a future maintainer to
flip `fresh_mode` back to `command` and silently re-introduce the D-01 dialog-stuck bug.

**Fix:** Set `clear_command = ""` with a comment that respawn ignores it, or add an
inline warning that `/new` must NOT be used with `fresh_mode=command`.

### IN-04: `eval` safety comment in `opencode-runner.sh` understates the real injection guard

**File:** `scripts/opencode-runner.sh:32-33`

**Issue:** The comment justifies `eval` by claiming turnId format has no spaces. `eval`
executes the entire trigger string, which is built from `opencode.toml`'s
`trigger_template` plus the prompt path. The actual safety guarantee is that the path is
derived from a server-allocated turnId whitelisted to `^[0-9-]+$` (CLAUDE.md), not "no
spaces" — "no spaces" would not stop shell metacharacters if the turnId rule loosened.

**Fix:** Update the comment to cite the turnId whitelist (`^[0-9-]+$`) as the injection
guard so the security invariant is tied to the real control.

### IN-05: `process_job` sentinel polling is correct — noted for completeness

**File:** `src/turn.rs:72-80`

**Issue:** The wait loop checks `status_path.exists()` first each iteration, then sleeps
1s. An agent writing status sub-second (before the loop starts) is still caught on
iteration 1, and a status written between checks is picked up next iteration. No bug;
sentinel polling matches HT-PROTOCOL §6.

**Fix:** None required.

---

_Reviewed: 2026-06-15_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
