---
phase: 05-codex-cli-and-opencode-validation
verified: 2026-06-15T01:10:00Z
status: human_needed
score: 5/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 4/5
  gaps_closed:
    - "AGNT-04 E2E falsifiability: scripts/e2e-opencode.sh now gates on Worker::recreate() log delta == 1 (stage 3) + stage 2.5 positive control + done allowlist (WR-01 in opencode) + UNKNOWN/empty hard gates (WR-02 in opencode)"
  gaps_remaining: []
  regressions:
    - "e2e-codex.sh stages 1 and 2 still use old `== timeout || failed` status gate (not `!= done` allowlist) — WR-01 from initial VERIFICATION was not in scope for 05-03 plan or 05-REVIEW-FIX; does not affect AGNT-04 gap closure"
human_verification:
  - test: "Run bash scripts/e2e-opencode.sh on a host with opencode + ht-mcp + GitHub Copilot auth"
    expected: "Stage 2.5 returns UNKNOWN (no continuity), stage 3 shows recreate_delta == 1 in log and exits 0"
    why_human: "Requires live opencode agent with real API credentials; cannot be verified programmatically"
  - test: "Deliberately break fresh_mode=respawn (e.g., set fresh_mode = 'bogus' in agents/opencode.toml) and run bash scripts/e2e-opencode.sh"
    expected: "Script exits 1 at stage 3 (not at stage 1 or 2) — either status != done (if bogus mode causes a failed turn) or recreate_delta == 0 gate fires"
    why_human: "Falsifiability proof requires a real run; structural analysis confirms it should FAIL but live execution is the authoritative test"
  - test: "Verify recreate_delta == 1 is the correct expected delta for a single fresh turn under normal opencode-runner.sh behavior"
    expected: "ensure_healthy() at turn start sees 'OpenCodeRunner ready' (session healthy), so does NOT call recreate(). Then fresh_mode=respawn calls recreate() once. Delta = 1."
    why_human: "Depends on runtime readiness-snapshot content — must be confirmed during a live run; if ensure_healthy() ever fires its own recreate(), delta would be 2 and the gate would false-negative"
---

# Phase 05: Codex CLI and OpenCode Validation — Verification Report (Re-verification)

**Phase Goal:** Codex CLI と OpenCode を実機で駆動し、ターンファイル方式での結果取得が動作することを E2E で確認できる。
**Verified:** 2026-06-15T01:10:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure (05-03 plan + 05-REVIEW-FIX)

## Re-verification Summary

Previous status: `gaps_found` (score 4/5, AGNT-04 vacuous E2E)

Gap closure plan 05-03 + code review fix pass (commits ecc5a30 → d830f63) modified `scripts/e2e-opencode.sh`, `scripts/e2e-codex.sh`, and `scripts/opencode-runner.sh`. This re-verification focuses on the failed AGNT-04 truth and performs regression checks on previously-passed items.

**Gap closed:** AGNT-04 E2E is now structurally falsifiable. The previously-vacuous "7331 non-presence" gate has been replaced by a Worker::recreate() log-delta gate that fails deterministically when the respawn path is broken.

**No regressions found** in previously-verified items (AGNT-01, AGNT-02, AGNT-03, SC5, artifacts).

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `AGENT=codex ./ht-webif` に POST /prompt を送ると result 非空 + status=done (AGNT-01) | ✓ VERIFIED (regression) | Prior live E2E confirmed; e2e-codex.sh syntax ok, 33 cargo tests green, no regressions in file |
| 2 | `AGENT=codex` で fresh:true が /clear 方式で動作し履歴隔離が成立する (AGNT-02) | ✓ VERIFIED (regression) | Stage-3 now has WR-03 hard gates (empty+UNKNOWN). Prior live E2E evidence unchanged. |
| 3 | `AGENT=opencode ./ht-webif` に POST /prompt を送ると result 非空 + status=done (AGNT-03) | ✓ VERIFIED (regression) | Prior live E2E confirmed; no changes to opencode basic E2E path |
| 4 | `AGENT=opencode` で fresh:true が respawn 方式で動作し Worker::recreate() 発火をログで証明できる (AGNT-04) | ✓ VERIFIED (static) + ? HUMAN | grep -cF pattern confirmed to match only worker.rs:153 (colon-bearing success line), not line 116; delta-ne-1 gate wired; live run needed for runtime confirmation |
| 5 | 両 agents/\*.toml が ready_pattern/fresh_mode/prerequisite 手順を正確に記述している (SC5) | ✓ VERIFIED (regression) | No changes to agent TOML files; prior verification stands |

**Score:** 5/5 ROADMAP Success Criteria (SC1-SC5 all VERIFIED at static/structural level; SC4/AGNT-04 has human verification items)

### ROADMAP Success Criteria Coverage

| SC | Text | Status | Note |
|----|------|--------|------|
| SC1 | `AGENT=codex` POST /prompt → result/status ファイル生成 | ✓ VERIFIED | Prior live evidence + no regression |
| SC2 | `AGENT=codex` fresh:true で /clear 送信正常動作 | ✓ VERIFIED | WR-03 hard gates added; prior live evidence |
| SC3 | `AGENT=opencode` POST /prompt → result/status ファイル生成 | ✓ VERIFIED | Prior live evidence + no regression |
| SC4 | `AGENT=opencode` fresh:true で respawn 方式正常動作 | ✓ VERIFIED (static) | Falsifiable gate wired; live confirmation needed |
| SC5 | 両 TOML が ready_pattern/fresh_mode/prerequisite 手順を正確に記述 | ✓ VERIFIED | Unchanged |

## AGNT-04 Falsifiability Assessment (Primary Gap)

### The Old Vacuous Test (prior VERIFICATION)

The old stage 3 checked only "7331 not in result." Under D-09 architecture (each `opencode run` invocation is a new conversation), the stage-2 seed is discarded before stage-3 runs — even if `fresh_mode=respawn` is completely disabled or misconfigured. The test always passed for an architectural reason unrelated to the respawn mechanism.

### The New Falsifiable Test (05-03 gap closure + CR-01 fix)

**Stage 2.5 (positive control):** Added between stages 2 and 3. Non-fresh turn with file-search-prohibited prompt asks for secret number. Expected UNKNOWN (D-09 non-continuity). If 7331 appears in stage-2.5 response → hard FAIL (WR-06 fix: methodological premise destroyed). This makes explicit what was implicit: the 7331 test in stage 3 is meaningless as an isolation signal.

**Stage 3 main gate — recreate() log delta:**
```bash
recreate_before=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
# ... fresh:true curl ...
recreate_after=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
recreate_delta=$(( recreate_after - recreate_before ))
if [[ "$recreate_delta" -ne 1 ]]; then exit 1; fi
```

**CR-01 fix verified:** The grep pattern is `grep -cF '[shared-fate] claude セッション再生成:'` (fixed-string, colon-bearing prefix).
- worker.rs:116: `"[shared-fate] claude セッション不健全 → 再生成"` — NO colon after 再生成, does NOT match.
- worker.rs:153: `"[shared-fate] claude セッション再生成: {} ..."` — HAS colon, MATCHES.

Empirically confirmed with `printf` pipe test: pattern counts exactly 1 for line 153, 0 for line 116.

**Falsifiability proof (static analysis):**

| Failure scenario | Effect on stage 3 | Gate result |
|-----------------|-------------------|-------------|
| `fresh_mode = "bogus"` in opencode.toml | process_job returns Err → status="failed" | status != "done" → FAIL |
| fresh:true ignored (job.fresh never true) | recreate() not called → delta 0 | delta -ne 1 → FAIL |
| `worker.recreate()` made no-op (no log emit) | success line not emitted → delta 0 | delta -ne 1 → FAIL |
| Correct respawn path executes | recreate() logs success line → delta 1 | delta == 1 → PASS |

**Known limitation (documented inline in script):** If `ensure_healthy()` at turn start finds the session UNHEALTHY, it calls `recreate()` itself → emits success line → delta becomes 2 → gate fails (false negative). The exact-delta-1 requirement catches this ambiguity conservatively. The ultimate fix (a `[fresh-respawn]` distinct marker in src/turn.rs) requires Rust modification and is out of scope for this phase (zero-Rust-change mandate). The limitation is documented in a 10-line comment block at line 364-373 of the script.

**WR-01 (done allowlist) in opencode script:** All 4 stages (1, 2, 2.5, 3) use `!= "done"` gate. `status="unknown"` (garbled JSON) no longer passes. VERIFIED.

**WR-02 (hard gates) in stage 3:** Empty result and UNKNOWN-not-present both exit 1. VERIFIED.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `agents/codex.toml` | Codex CLI エージェントプロファイル | ✓ VERIFIED | Unchanged from prior verification; all fields confirmed |
| `scripts/e2e-codex.sh` | Codex E2E 検証スクリプト | ✓ VERIFIED | bash -n OK; WR-03 hard gates (empty+UNKNOWN) added to stage 3; WR-04 head -c replaced with ${:0:N}; WR-05 TURNS_DIR comment added |
| `agents/opencode.toml` | OpenCode エージェントプロファイル | ✓ VERIFIED | fresh_mode = "respawn"; ready_pattern = "OpenCodeRunner ready"; trigger_template = "opencode run --command turn {prompt_path}"; all fields intact |
| `scripts/setup-opencode.sh` | turn.md 冪等生成スクリプト | ✓ VERIFIED | Unchanged; bash -n OK; prior verification stands |
| `scripts/e2e-opencode.sh` | OpenCode E2E 検証スクリプト (gap-closed) | ✓ VERIFIED | bash -n OK; stage 2.5 present; recreate_before/after/delta present; grep -cF colon-anchored; delta-ne-1 hard gate; all 4 stages use != "done" allowlist; UNKNOWN + empty hard gates in stage 3; WR-06 7331 hard FAIL in stage 2.5; head -c → ${:0:N} |
| `scripts/opencode-runner.sh` | OpenCode ラッパースクリプト | ✓ VERIFIED | WR-02 fix: rc=0; eval "$trigger" \|\| rc=$?; logs to stderr not stdout; loop continues |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| scripts/e2e-opencode.sh stage 3 | src/worker.rs Worker::recreate() success log | grep -cF '[shared-fate] claude セッション再生成:' in LOG_FILE | ✓ WIRED | Fixed-string pattern confirmed to match worker.rs:153 only; colon disambiguates from line 116 |
| scripts/e2e-opencode.sh stage 2.5 | POST /prompt (non-fresh) | curl with no fresh flag; UNKNOWN expected | ✓ WIRED | Non-fresh turn wired to server; 7331 FAIL gate wired |
| turn.rs process_job fresh_mode=respawn branch | worker.recreate() | lines 59-61: match "respawn" => worker.recreate().await? | ✓ WIRED | Confirmed in source; cargo test process_job_fresh_mode_respawn_calls_recreate passes |
| worker.recreate() | log line worker.rs:153 | eprintln! call confirmed at line 152-155 | ✓ WIRED | Exact string: "[shared-fate] claude セッション再生成: {} （旧 {} を閉鎖）" |
| LOG_FILE (cargo run stderr redirect) | e2e-opencode.sh grep | `cargo run --release >"$LOG_FILE" 2>&1` — stderr captured | ✓ WIRED | eprintln! goes to stderr; 2>&1 redirects to LOG_FILE; grep reads LOG_FILE |

### Data-Flow Trace (Level 4)

The data-flow path is unchanged from prior verification (FLOWING for both agents). The new data flow for AGNT-04 verification:

| Step | Source | Sink | Evidence |
|------|--------|------|----------|
| fresh:true job | POST /prompt body `{"fresh":true}` | job.fresh = true in process_job | http.rs parses fresh field |
| fresh dispatch | process_job line 52-65 | worker.recreate() called | match "respawn" → recreate() |
| recreate log | worker.rs:152-155 eprintln! | LOG_FILE via stderr redirect | 2>&1 in cargo run launch |
| log count | grep -cF on LOG_FILE | recreate_delta variable | Exact colon-anchored pattern |
| delta gate | recreate_delta -ne 1 | exit 1 | Hard gate at line 374 |

### Behavioral Spot-Checks

Step 7b is SKIPPED for this phase — requires live opencode/codex agents with real credentials and API auth. Structural analysis substitutes where possible (see AGNT-04 falsifiability table above).

Cargo test: 33 passed, 0 failed (confirmed in this re-verification session).

Static checks run in this session:
- `bash -n scripts/e2e-opencode.sh` → SYNTAX OK
- `bash -n scripts/e2e-codex.sh` → SYNTAX OK
- `grep -cF` pattern discriminates worker.rs:153 vs :116 → confirmed empirically

### Probe Execution

No `scripts/*/tests/probe-*.sh` files found. E2E scripts are the verification mechanism. Prior live run evidence (from 05-02 orchestrator context) is the existing runtime proof. The stage-3 live run is flagged as human verification.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| AGNT-01 | 05-01-PLAN.md | Codex CLI POST /prompt → result E2E | ✓ SATISFIED | Prior live E2E + no regression in scripts |
| AGNT-02 | 05-01-PLAN.md | Codex CLI fresh:true E2E (WR-03 gates added) | ✓ SATISFIED | WR-03 hard gates added; prior live evidence + stage-3 now requires UNKNOWN |
| AGNT-03 | 05-02-PLAN.md | OpenCode POST /prompt → result E2E | ✓ SATISFIED | Prior live E2E + no regression |
| AGNT-04 | 05-02-PLAN.md | OpenCode fresh:true respawn E2E (gap closed) | ✓ SATISFIED (static) | Falsifiable gate wired and confirmed; live human verification needed for runtime proof |

### Anti-Patterns Found

#### Remaining (acceptable — scope-limited)

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/e2e-codex.sh | 173, 201 | `status == "timeout" \|\| "failed"` (not `!= "done"` allowlist) in stages 1-2 | Warning | status="unknown" on garbled JSON would PASS stages 1-2 of codex. Stage 3 now has full hard gates (WR-03). This was NOT in scope for 05-03 plan or 05-REVIEW-FIX (which covered WR-03 = codex stage-3 weakness only). Affects AGNT-01/AGNT-02 codex test quality but not AGNT-04 gap closure. |
| agents/opencode.toml | 57 | `clear_command = "/new"` is dead config and a known-broken value (IN-03) | Info | Harmless under respawn; documented in REVIEW as out-of-fix-scope |
| scripts/opencode-runner.sh | 41 | `eval "$trigger"` safety comment references "no spaces" not the turnId whitelist (IN-04) | Info | REVIEW noted as out-of-fix-scope |

#### Resolved in this gap-closure pass

| Finding | Resolution |
|---------|------------|
| CR-01: recreate gate matched ensure_healthy log | Fixed: grep -cF colon-anchored to worker.rs:153 only (commit 537acf0) |
| WR-01 (REVIEW): baseline ambiguity | Fixed: delta -ne 1 exact gate instead of delta > 0 (commit 9634335) |
| WR-02 (REVIEW): opencode-runner.sh swallows exit code | Fixed: rc capture + stderr log (commit e4ff683) |
| WR-03 (REVIEW): codex stage-3 weaker than opencode | Fixed: empty+UNKNOWN hard gates added (commit 2225b08) |
| WR-04 (REVIEW): head -c pipefail hazard | Fixed: ${:0:N} slicing in both scripts (commit 8e8c7bb) |
| WR-05 (REVIEW): TURNS_DIR coupling undocumented | Fixed: EFFECTIVE_TURNS_DIR variable + log line in both scripts (commit 92832d7) |
| WR-06 (REVIEW): stage-2.5 7331 leak non-fatal | Fixed: hard FAIL gate promoted (commit d830f63) |
| WR-01 (initial VERIFICATION): done allowlist in opencode | Fixed: all 4 opencode stages use != "done" (commit ecc5a30) |
| WR-02 (initial VERIFICATION): UNKNOWN not hard gate | Fixed: UNKNOWN required in stage 3 + empty gate (commit ecc5a30) |

No TBD/FIXME/XXX markers found in any files modified by this phase.

### Human Verification Required

#### 1. AGNT-04 Live E2E — Normal Run

**Test:** Run `bash scripts/e2e-opencode.sh` from project root with opencode authenticated and ht-mcp on PATH.

**Expected:**
- Stage 1: result non-empty, status=done
- Stage 2: status=done (seed turn)
- Stage 2.5: status=done, result contains UNKNOWN or is UNKNOWN-like (not 7331)
- Stage 3: status=done, result non-empty, result contains UNKNOWN, result does not contain 7331, `recreate_delta == 1` logged in summary

**Why human:** Requires live opencode agent with real GitHub Copilot auth. Cannot run without real agent + credentials.

#### 2. AGNT-04 Falsifiability Proof — Break the Respawn Path

**Test:** Temporarily set `fresh_mode = "invalid_value"` in `agents/opencode.toml`. Run `bash scripts/e2e-opencode.sh`. Restore the original value.

**Expected:** Script exits 1 at stage 3 (status gate or recreate_delta gate fires), not at stage 1 or 2. This proves the test cannot be vacuously passed when the respawn mechanism is broken.

**Why human:** Requires live execution; the static falsifiability proof above confirms it SHOULD fail, but runtime confirmation is the authoritative test.

#### 3. Confirm `recreate_delta == 1` Assumption at Runtime

**Test:** During a normal AGNT-04 run, verify in the summary log that `recreate_delta = 1` (not 2+).

**Expected:** The opencode-runner.sh wrapper emits "OpenCodeRunner ready" immediately on startup, so `ensure_healthy()` at stage-3 turn start finds the snapshot healthy → does NOT call recreate() → delta stays at 1 after the fresh_mode=respawn call.

**Why human:** The exact-delta-1 gate is correct in the happy path but could false-negative if the session is deemed unhealthy at the moment of stage-3 turn processing. Runtime confirmation validates the assumption.

### Gaps Summary

No blocking gaps remain. The single gap from the prior verification (AGNT-04 vacuous E2E) has been closed structurally:

1. The stage-3 gate now depends on a property (Worker::recreate() log emission) that is uniquely coupled to the respawn path. Breaking the respawn mechanism causes delta = 0 → deterministic FAIL.

2. Stage 2.5 makes the D-09 architecture's non-continuity explicit and records it, so the test is honest about what it measures.

3. The CR-01 false-positive risk (ensure_healthy log matching) was eliminated by anchoring to the colon-bearing success line only.

The residual codex WR-01 (stages 1-2 status gates) is a WARNING affecting AGNT-01/AGNT-02 test quality but does not affect AGNT-04 and is not a blocker for the phase goal.

Human verification items (live run confirmation, falsifiability proof by breaking the path, delta-1 assumption) are the reason status is `human_needed` rather than `passed`. All automated checks pass.

---

_Verified: 2026-06-15T01:10:00Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — after 05-03 gap-closure plan + 05-REVIEW-FIX_
