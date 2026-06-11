---
phase: 4
slug: agent-profile-abstraction
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-06-11
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Reconstructed retroactively by /gsd-validate-phase (State B: phase executed without VALIDATION.md).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Rust built-in test harness (`cargo test`), tokio for async tests |
| **Config file** | none — co-located `#[cfg(test)] mod tests` per source file; `tempfile` for hermetic fixtures; `FakeMcp` (src/mcp.rs) for MCP scripting |
| **Quick run command** | `cargo test --lib <module>` (e.g. `cargo test --lib profile`) |
| **Full suite command** | `cargo test` |
| **Estimated runtime** | ~1–2 seconds (33 tests) |

---

## Sampling Rate

- **After every task commit:** Run `cargo test --lib <touched module>`
- **After every plan wave:** Run `cargo test`
- **Before `/gsd-verify-work`:** Full suite must be green + `cargo fmt --check` + `cargo clippy --all-targets`
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | PROF-01 | T-04-SC | toml = "1" only new dependency | unit | `cargo test --lib profile` | ✅ | ✅ green |
| 04-01-02 | 01 | 1 | PROF-01, PROF-05, PROF-06 | T-04-01 | deny_unknown_fields + placeholder validation reject bad TOML at startup | unit | `cargo test --lib profile` (10 tests: parse, missing-toml diagnostics, placeholder bails, timeout defaults, unknown-key rejection, model fields) | ✅ | ✅ green |
| 04-01-03 | 01 | 1 | PROF-02 | T-04-02 | AGENT/AGENTS_DIR are operator-controlled env, read-only file access | unit | `cargo test --lib config` (`agent_name_defaults_to_claude_when_env_unset_and_returns_env_value_when_set`, `agents_dir_defaults_to_cwd_agents_when_unset_and_uses_env_when_set`) | ✅ | ✅ green |
| 04-02-01 | 02 | 2 | PROF-03, PROF-06 | — | N/A | unit | `cargo test --lib mcp` + zero-occurrence greps (`create_claude_session`, `"auto mode"`) | ✅ | ✅ green |
| 04-02-02 | 02 | 2 | PROF-03, PROF-04, PROF-05 | T-04-03, T-04-04 | golden test fixes v1.0 byte identity; unknown fresh_mode bails loudly | unit | `cargo test --lib turn` (`build_prompt_body_covenant_matches_v1_output` golden test + fresh_mode dispatch tests) | ✅ | ✅ green |
| 04-02-03 | 02 | 2 | PROF-02, PROF-03 | T-04-05 | startup banner discloses no secrets (localhost, operator log) | unit + manual | `cargo test` (AGENT=&lt;unknown&gt; error path covered by `load_agent_profile_errors_on_missing_toml`; main.rs wiring is `?` propagation) | ✅ | ✅ green |
| 04-03-01 | 03 | 1 | PROF-03 | T-04-07, T-04-08 | lock-free covenant read removes turn-duration DoS on POST /prompt | integration | `cargo test --lib http` (`prompt_handler_returns_turn_id_immediately_while_worker_mutex_is_held`) | ✅ | ✅ green |
| 04-03-02 | 03 | 1 | PROF-05 | T-04-06 | model args passed as Vec&lt;String&gt; to ht-mcp, no shell — injection structurally impossible | unit | `cargo test --lib profile` (`spawn_command_without_model_equals_command`, `spawn_command_appends_flag_and_value_when_both_specified`, `spawn_command_does_not_append_when_only_flag_specified`) | ✅ | ✅ green |
| 04-04-01 | 04 | 2 | PROF-03 | T-04-09 | rustfmt changes whitespace only; `cargo test` guards logic | static | `cargo fmt --check` + `cargo clippy --all-targets` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

### Requirement Coverage Summary

| Requirement | Status | Evidence |
|-------------|--------|----------|
| PROF-01 | ✅ COVERED | 10 profile.rs parse/validation tests |
| PROF-02 | ✅ COVERED | 2 config.rs env-default tests (added by validation audit) |
| PROF-03 | ✅ COVERED | golden byte-identity test + lock-free prompt_handler test (added) + http endpoint tests + fmt/clippy gates |
| PROF-04 | ✅ COVERED | 3 process_job fresh_mode dispatch tests (added): command / respawn / unknown-bail |
| PROF-05 | ✅ COVERED | timeout default/override tests + 3 spawn_command tests |
| PROF-06 | ✅ COVERED | loader tests use arbitrary profile names (`myagent`, `custom`, `defaults`) from tempdirs |

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live end-to-end turn with real `ht-mcp` + `claude` TUI (`AGENT=claude ./ht-webif`, POST /prompt, result/status files appear under `turns/claude/`) | PROF-03 | Requires logged-in Max-subscription `claude` binary and `ht-mcp` on PATH; not reproducible in CI | Start server, `curl -X POST localhost:8080/prompt -d '{"prompt":"..."}'`, confirm turn_id returned immediately and `status-<turnId>.json` appears; verify `[profile]` startup banner shows agent name and `turns/claude` directory |

---

## Validation Audit 2026-06-11

| Metric | Count |
|--------|-------|
| Gaps found | 3 |
| Resolved | 3 |
| Escalated | 0 |

Gap detail (all resolved by gsd-nyquist-auditor, baseline 27 → 33 tests):

1. **PROF-02 (MISSING → resolved)** — `load_agent_name` / `load_agents_dir` defaults untested. Added 2 tests in `src/config.rs`.
2. **PROF-03 (PARTIAL → resolved)** — CR-01 lock-free covenant fix had no guarding test. Added `prompt_handler_returns_turn_id_immediately_while_worker_mutex_is_held` in `src/http.rs` (holds worker Mutex while POSTing /prompt).
3. **PROF-04 (MISSING → resolved)** — fresh_mode dispatch (src/turn.rs:52-65) untested. Added 3 `process_job` tests in `src/turn.rs` using `FakeMcp` (command / respawn / unknown-bail).

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (none required)
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-11
