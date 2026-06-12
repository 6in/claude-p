---
phase: 05-codex-cli-and-opencode-validation
reviewed: 2026-06-12T10:00:59Z
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
  warning: 9
  info: 5
  total: 15
status: issues_found
---

# Phase 5: Code Review Report

**Reviewed:** 2026-06-12T10:00:59Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Reviewed the Codex CLI / OpenCode validation deliverables: two agent profiles, three shell scripts (E2E x2, runner, setup), and the three Rust modules they exercise (`profile.rs`, `turn.rs`, `worker.rs`). Cross-file facts were verified against `main.rs`, `http.rs`, `config.rs`, and `mcp.rs` (turn_id whitelist exists at `http.rs:106`; `TURNS_DIR/<agent>` join happens in `main.rs`; `submit_line` routes through `ht_send_keys`).

Key concerns:

1. **The OpenCode fresh-isolation E2E (AGNT-04) is vacuous** — given the `opencode run` wrapper architecture, every turn is already a new conversation, so the stage 2 → stage 3 isolation test cannot fail even if `fresh_mode = "respawn"` were completely broken (CR-01).
2. **E2E assertions are weak across both scripts** — `status: "unknown"` passes, and stage 3 passes on an empty result (WR-01, WR-02).
3. **Documented contradiction** between `agents/opencode.toml` Pitfall 1 ("ht_send_keys silently drops multibyte") and `agents/codex.toml`'s Japanese `trigger_template` (WR-04).
4. **`opencode-runner.sh` `eval`s unvalidated PTY input**, which turns the existing `POST /command` endpoint into a direct shell-execution path (WR-05).
5. **`setup-opencode.sh` silently downgrades the user's machine-wide OpenCode security posture** by writing `"bash": "allow"` into the global config (WR-06).

No findings rise to data-loss or remote-compromise level given the loopback-only, intentionally-YOLO threat model, but the Critical finding means a stated phase requirement (AGNT-04) is not actually verified by the artifact that claims to verify it.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: AGNT-04 fresh-isolation test for OpenCode is vacuous — it cannot fail

**File:** `scripts/e2e-opencode.sh:186-262` (stages 2–3), `agents/opencode.toml:55-63`, `scripts/opencode-runner.sh:26-41`
**Issue:** The OpenCode integration runs each turn as a separate `opencode run --command turn <path>` invocation (D-09 wrapper). `opencode run` starts a **new session per invocation** (no `--continue`/`--session` flag is passed), and `agents/opencode.toml:58` itself documents this: "opencode run は1ターンで終了するため、respawn で毎ターン新しいコンテキストになる". Consequently:

- Stage 2 ("Remember this secret number: 7331") seeds memory into a conversation context that is discarded the moment that `opencode run` process exits.
- Stage 3 (`fresh: true`) then asserts 7331 does not leak — but 7331 can **never** leak through conversation history in this architecture, regardless of whether `fresh_mode = "respawn"` works, because non-fresh turns share no history either.

The test labeled "AGNT-04: fresh 履歴隔離" therefore provides false assurance: it would pass identically if `recreate()` were a no-op, if `fresh_mode` were misconfigured, or if the `fresh` flag were silently dropped. A validation deliverable whose pass condition is unfalsifiable is incorrect behavior of the deliverable itself.

This also surfaces an undocumented API-contract divergence: for claude/codex, non-fresh turns continue a conversation; for opencode, they do not. Neither `agents/opencode.toml` nor the runner states that non-fresh history continuity is unsupported for this agent.

**Fix:** Two options, in order of preference:

1. Make the test honest about what it can verify. Add a positive-control stage between 2 and 3 that sends a **non-fresh** "what was the secret number?" query. For opencode this control will show no memory, proving stages 2–3 cannot test isolation; replace the stage-3 assertion with a structural check that `fresh: true` actually triggered respawn (e.g., grep the server log for the `[shared-fate]`/recreate line emitted by `Worker::recreate`, or assert a new runner PID/session id):
```bash
# 段階 2.5: 非 fresh での記憶確認（positive control）
response_ctl=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"What secret number did I tell you earlier in this conversation? Answer UNKNOWN if you do not know.","wait":true}')
# opencode では UNKNOWN が期待値 → 会話継続性がないことを明示的に記録し、
# 段階 3 は「respawn が実際に発火した」ことをサーバログで検証する方式に変更する
```
2. Or give the opencode integration real conversation continuity (e.g., `opencode run --continue` for non-fresh turns, plain `opencode run` for fresh ones), at which point the existing stage 2 → 3 test becomes meaningful. Document the chosen contract in `agents/opencode.toml`.

## Warnings

### WR-01: E2E success assertions accept `status: "unknown"` — should require `"done"`

**File:** `scripts/e2e-codex.sh:165, 193, 234`; `scripts/e2e-opencode.sh:176, 204, 243`
**Issue:** Every stage gate is `if [[ "$status" == "timeout" ]] || [[ "$status" == "failed" ]]`. `read_turn` (`src/turn.rs:117-120`) returns `"unknown"` when the status JSON is garbled or missing a `status` key, and the jq fallback in the script itself produces `"unknown"` for a malformed HTTP body. Both cases sail through the gate and the stage is logged as PASS. A run where the agent writes a corrupt status file is reported as a successful validation.
**Fix:** Invert the check to allowlist the only success value:
```bash
if [[ "$status1" != "done" ]]; then
    log "ERROR: 段階 1 失敗 (status=${status1}, 期待値 done)"
    exit 1
fi
```
Apply to all three stages in both scripts.

### WR-02: Stage 3 passes vacuously on an empty result; codex test lacks a positive control

**File:** `scripts/e2e-codex.sh:241-253`; `scripts/e2e-opencode.sh:250-262`
**Issue:** Two gaps in the isolation check:
1. `echo "$result3" | grep -q "7331"` passes when `result3` is empty or content-free. An agent that writes an empty result file (status still `done`) yields PASS for the headline isolation claim.
2. (codex) There is no positive control proving that non-fresh history persistence works at all. If `ensure_healthy` is silently recreating the session every turn (see WR-03), stage 2's seed never persists and stage 3 passes for the wrong reason. The `UNKNOWN` check at line 249 is informational only (`INFO` log), so it never gates.
**Fix:** Require a non-empty result and require the expected `UNKNOWN` marker as a hard gate; for codex add a non-fresh control turn before stage 3 that must contain `7331`:
```bash
if [[ -z "$result3" ]]; then
    log "ERROR: 段階 3 失敗 — result が空（隔離検証は空回答では成立しない）"
    exit 1
fi
if ! echo "$result3" | grep -qi "UNKNOWN"; then
    log "ERROR: 段階 3 失敗 — UNKNOWN が含まれない（回答の意味論が不明）"
    exit 1
fi
```

### WR-03: `ready_pattern = "YOLO mode"` may scroll off-screen, causing per-turn shared-fate recreation that silently destroys non-fresh history

**File:** `agents/codex.toml:32-35`; `src/worker.rs:109-120`
**Issue:** "YOLO mode" is a startup banner. `ensure_healthy` (`worker.rs:109`) takes a screen snapshot at the start of every job and treats the session as dead if the pattern is absent — and then `recreate()`s it. If the banner scrolls out of the visible PTY screen after a turn produces output (likely for any multi-line answer), every subsequent job triggers `[shared-fate]` recreation, wiping conversation history for **non-fresh** turns with no error surfaced to the client. The E2E suite cannot detect this (see WR-02 — stage 3 expects no memory, so per-turn wipes make it pass). Contrast with `opencode-runner.sh`, which deliberately re-prints its ready string after every turn (`opencode-runner.sh:36`) precisely so the pattern stays at the bottom of the screen.
**Fix:** Verify on a real codex TUI whether a persistent footer/status element exists and use that as `ready_pattern`; otherwise during the E2E assert the server log contains zero `[shared-fate]` lines after startup:
```bash
if grep -q '\[shared-fate\]' "$LOG_FILE"; then
    log "ERROR: ターン間に shared-fate 再生成が発生 — ready_pattern が画面から消えている可能性"
    exit 1
fi
```

### WR-04: Japanese `trigger_template` in codex.toml contradicts documented Pitfall 1 (ht_send_keys drops multibyte)

**File:** `agents/codex.toml:55`; `agents/opencode.toml:24-25`
**Issue:** `agents/opencode.toml` documents as a transport-level fact: "ht-mcp ht_send_keys は日本語/マルチバイト文字を無音で破棄する（Pitfall 1）→ trigger_template は ASCII のみ使用すること". Yet `agents/codex.toml:55` sets `trigger_template = "{prompt_path} を読んで、その指示に従ってください。"` — the trigger is delivered via the same `submit_line → send_keys("ht_send_keys")` path (`src/mcp.rs:224-227`). If Pitfall 1 holds, codex receives only the bare path (Japanese silently stripped) and the E2E "実機検証済み" claim passed by accident (codex happening to read a bare path). If Pitfall 1 does not hold, the opencode.toml documentation is wrong. Both files cannot be correct simultaneously; either way, codex's trigger semantics are luck-dependent.
**Fix:** Make the codex trigger ASCII-only, matching the opencode convention:
```toml
trigger_template = "Read the file {prompt_path} and follow the instructions in it."
```
Or, if multibyte send_keys was re-verified as working, correct the Pitfall 1 note in `agents/opencode.toml` and record the scope (which ht-mcp version/agent).

### WR-05: `opencode-runner.sh` `eval`s unvalidated stdin — turns `POST /command` into direct shell execution and breaks on paths with spaces/metacharacters

**File:** `scripts/opencode-runner.sh:33`
**Issue:** `eval "$trigger" 2>&1 || true` executes any line arriving on the runner's PTY stdin as shell code. Two concrete problems:
1. The existing `POST /command {"text":"..."}` endpoint sends raw text via `submit_line` to the active session. For `AGENT=claude` that means TUI keystrokes; for `AGENT=opencode` the same endpoint now means **arbitrary shell execution as the server user, with no agent guardrails in between**. The endpoint's contract silently changed per-agent. (Mitigated by loopback-only bind and the fact that `/prompt` already grants agent-mediated execution, hence Warning not Critical — but it removes even the agent layer.)
2. The comment at lines 31-32 acknowledges that paths with spaces break. The path is `TURNS_DIR`-derived (operator env, `config.rs:30`); a `TURNS_DIR` containing spaces or shell metacharacters mangles or executes parts of the path. Nothing validates this at startup.
**Fix:** Stop evaluating arbitrary lines. Validate the expected shape and invoke without `eval`:
```bash
if [[ "$trigger" == "opencode run --command turn "* ]]; then
    path="${trigger#opencode run --command turn }"
    opencode run --command turn "$path" 2>&1 || true
else
    echo "[runner] 不正なトリガーを無視: $trigger" >&2
fi
```
(Cleaner still: change `trigger_template` to send only `{prompt_path}` and hardcode the command in the runner.)

### WR-06: `setup-opencode.sh` grants machine-wide `bash`/`edit` auto-approval in the user's global OpenCode config

**File:** `scripts/setup-opencode.sh:56-75`
**Issue:** The script writes `"permission": { "bash": "allow", "edit": "allow", ... }` to `~/.config/opencode/opencode.json` — the user's **global** config. This auto-approves shell execution and file edits for every OpenCode session the user ever runs, in any project, not just ht-webif turns. A prompt-injected or misbehaving model in an unrelated interactive session can then run bash without confirmation. The log message (line 74) names the tools but not the global scope. OpenCode supports project-scoped `opencode.json` at the project root, which would confine the blast radius to this repo.
**Fix:** Write the permission config to the project root (the directory ht-webif runs opencode in) instead of `$XDG_CONFIG_HOME`, or at minimum print an explicit warning that the setting is global and require interactive confirmation:
```bash
OPENCODE_JSON="$WEBIF_DIR/opencode.json"   # プロジェクトスコープに限定
```

### WR-07: `setup-opencode.sh` existence-only idempotency does not actually guarantee preconditions

**File:** `scripts/setup-opencode.sh:30-31, 56-57`
**Issue:** Both artifacts are skipped if the file merely exists. The script's stated purpose ("前提条件を充足する") is not met in two realistic cases:
1. A pre-existing user `opencode.json` without the `permission` block (or with `"ask"` values) is left untouched — turns will then hang on confirmation dialogs and time out, with the setup script having reported success.
2. A pre-existing or drifted `turn.md` whose body lacks `$ARGUMENTS` silently breaks the trigger path.
The E2E script (`e2e-opencode.sh:121`) relies on this setup call to guarantee correctness, so drift produces confusing downstream timeouts rather than a clear setup error.
**Fix:** Validate content when the file exists; fail (or warn loudly) on mismatch:
```bash
if [[ -f "$TURN_CMD_FILE" ]] && ! grep -q '\$ARGUMENTS' "$TURN_CMD_FILE"; then
    log "ERROR: 既存の turn.md に \$ARGUMENTS がありません: $TURN_CMD_FILE"
    exit 1
fi
if [[ -f "$OPENCODE_JSON" ]] && ! jq -e '.permission.bash == "allow"' "$OPENCODE_JSON" >/dev/null 2>&1; then
    log "WARNING: 既存の opencode.json に permission.bash=allow がありません — ターンがタイムアウトする可能性"
fi
```

### WR-08: `fresh_mode` is not validated at profile load; mandatory `clear_command` forces a known-broken value into opencode.toml

**File:** `src/profile.rs:18-20, 91-102`; `src/turn.rs:62-64`; `agents/opencode.toml:60-63`
**Issue:** Two related schema gaps:
1. `validate_profile` checks placeholders but not `fresh_mode`. A typo (`fresh_mode = "comand"`) passes startup validation and only surfaces at the **first `fresh:true` request** as a runtime job failure (`turn.rs:63`). This contradicts the D-11 fail-fast principle the same function exists to enforce.
2. `clear_command` is a required `String` even when `fresh_mode = "respawn"` makes it dead config. As a result `agents/opencode.toml:63` stores `/new` — a value the file's own header (`e2e-opencode.sh:10-12`, D-01) documents as **broken** (it opens an agent-selection dialog and wedges the session). Anyone flipping `fresh_mode` to `"command"` later inherits a silent isolation failure.
**Fix:** In `validate_profile`:
```rust
match p.fresh_mode.as_str() {
    "command" | "respawn" => {}
    other => anyhow::bail!("agents/{name}.toml: 未知の fresh_mode: {other}（command | respawn）"),
}
```
And make `clear_command` an `Option<String>` validated as `Some` only when `fresh_mode == "command"`, removing the `/new` trap from opencode.toml.

### WR-09: `recreate`/`restart` leak the newly created session on ready-timeout error path

**File:** `src/worker.rs:126-157` (recreate, esp. 145-147), `src/worker.rs:172-202` (restart, esp. 191-193)
**Issue:** Both functions call `create_session` and then poll for `ready_pattern`. On timeout they `return Err(...)` **without closing the new session**: the freshly spawned agent TUI (claude/codex/opencode runner) keeps running inside ht-mcp, orphaned, while `self.session_id` still points at the old (likely dead) session. Unlike a startup failure (where `main` exits and `kill_on_drop` reaps everything), `recreate` failures occur mid-life — repeated failures accumulate live agent processes (CPU + potential subscription-session pressure). CLAUDE.md explicitly lists "leaking the old session when creating a new one" as an anti-pattern; this is its mirror image on the error path.
**Fix:** Close the new session before propagating the error, in both functions:
```rust
if Instant::now() > deadline {
    let _ = self.client.close_session(&new_id).await;
    return Err(anyhow!("claude TUI が起動しない:\n{snap}"));
}
```

## Info

### IN-01: Magic 1000ms sleep after fresh reset

**File:** `src/turn.rs:66`
**Issue:** `tokio::time::sleep(Duration::from_millis(1000))` after `clear_command`/`recreate` is an unexplained magic number; whether 1s is sufficient for codex `/clear` processing is asserted nowhere.
**Fix:** Promote to a named constant (`const FRESH_SETTLE: Duration = ...`) or a profile field (parallel to `startup_settle_ms`) with a comment citing the measured basis.

### IN-02: Unexplained `doom_loop` permission key

**File:** `scripts/setup-opencode.sh:70`
**Issue:** `"doom_loop": "allow"` is granted with no comment explaining what tool this is, unlike every other key which maps to a known OpenCode tool. If it is not a real tool key it is dead config; if it is, it deserves the same documentation as the Pitfall 8 notes.
**Fix:** Add a one-line comment citing the OpenCode feature, or remove the key.

### IN-03: Ready-wait polling loop triplicated across `spawn_session`, `recreate`, `restart`

**File:** `src/worker.rs:55-71, 134-149, 180-195`
**Issue:** Three near-identical copies of the snapshot/ready_pattern/settle/deadline loop. They have already drifted cosmetically (eprintln formatting); the WR-09 fix must now be applied in two places, illustrating the maintenance cost.
**Fix:** Extract a single `async fn wait_ready(client: &mut M, session_id: &str, profile: &AgentProfile) -> Result<()>` in the generic impl and call it from all three sites.

### IN-04: `command = ["bash", "scripts/opencode-runner.sh"]` is cwd-dependent

**File:** `agents/opencode.toml:48`
**Issue:** The runner path is relative; it resolves against ht-webif's cwd (inherited by ht-mcp's child). Starting `ht-webif` from any other directory fails at session spawn with the generic "claude TUI が起動しない" snapshot error rather than a clear "runner script not found". claude/codex profiles are immune because they are PATH-resolved binaries.
**Fix:** Document the cwd requirement in the toml header, or resolve the script to an absolute path at profile load.

### IN-05: ~90% duplication between the two E2E scripts; stage-1 log text mismatch in e2e-codex

**File:** `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh` (whole files); `scripts/e2e-codex.sh:146` vs `:151`
**Issue:** The two scripts share cleanup, tool checks, server startup, wait loop, and the three-stage skeleton nearly verbatim — every assertion fix (WR-01/WR-02) must be applied twice. Minor: `e2e-codex.sh:146` logs "プロンプト送信: 2+2 は何？" while the actual payload at line 151 is the English "What is 2+2? Answer with the number only."
**Fix:** Extract shared helpers into `scripts/e2e-lib.sh` (log/cleanup/require_tool/wait_for_server/stage runner) sourced by both; align the log string with the actual prompt.

---

_Reviewed: 2026-06-12T10:00:59Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
