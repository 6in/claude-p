---
phase: 05-codex-cli-and-opencode-validation
verified: 2026-06-12T10:20:00Z
status: gaps_found
score: 4/5 must-haves verified
overrides_applied: 0
gaps:
  - truth: "AGENT=opencode で POST /prompt {\"fresh\":true} がセッションリセット方式（respawn）で動作し履歴隔離が成立する (AGNT-04, D-10)"
    status: partial
    reason: "opencode-runner.sh の D-09 ラッパーアーキテクチャでは opencode run が呼び出しごとに新しい会話を開始するため、非 fresh ターンも fresh:true ターンも等しく新規コンテキストになる。その結果 e2e-opencode.sh の stage2→stage3 隔離テストは unfalsifiable（常に PASS）であり、fresh_mode=respawn が機能しているかどうかを実際には検証していない。REQUIREMENTS.md の AGNT-04 文面（respawn 方式: セッション kill+再生成）は達成されているが、その達成が意味ある隔離を提供することの検証は vacuous。コードレビュー CR-01 が同一問題を Critical として記録している。"
    artifacts:
      - path: "scripts/e2e-opencode.sh"
        issue: "stage2→stage3 の履歴隔離テストは構造的に unfalsifiable: D-09 アーキテクチャでは全ターンが独立した opencode run 呼び出しになるため、fresh_mode が壊れていても stage3 は常に PASS する"
      - path: "agents/opencode.toml"
        issue: "line 53 のコメントが空洞性を自己文書化している: 'opencode run は1ターンで終了するため、respawn で毎ターン新しいコンテキストになる' — これは非 fresh ターン間に会話継続性が存在しないことを意味し、AGNT-04 の検証前提を崩している"
    missing:
      - "e2e-opencode.sh の stage 2.5（非 fresh での正の対照実験）: 非 fresh ターンでも 7331 が返らないことを確認し、それをもって継続性が存在しないことを明示的に記録する"
      - "あるいは: opencode run --continue / --session フラグで非 fresh ターン間の会話継続性を確立し、そのうえで fresh:true の respawn 隔離を検証する（意味ある AGNT-04 テストの前提）"
      - "あるいは: fresh:true が実際に Worker::recreate() を呼び出したことをサーバログで検証する（respawn 機構の発火証明）"
---

# Phase 05: Codex CLI and OpenCode Validation — Verification Report

**Phase Goal:** Codex CLI と OpenCode を実機で駆動し、ターンファイル方式での結果取得が動作することを E2E で確認できる。
**Verified:** 2026-06-12T10:20:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `AGENT=codex ./ht-webif` に POST /prompt を送ると result-<turnId>.txt に非空回答 + status-<turnId>.json に done が書かれる (AGNT-01) | ✓ VERIFIED | 実機 E2E stage1: turnId=20260612-081024-367, result="4", status=done, 26s。scripts/e2e-codex.sh stage1 が result 非空 + status != timeout/failed を確認 |
| 2 | `AGENT=codex` で POST /prompt {"fresh":true} が /clear 送信方式で動作し履歴隔離が成立する (AGNT-02, D-10) | ✓ VERIFIED | 実機 E2E stage3: turnId=20260612-081119-766, result="UNKNOWN", status=done, 19s。rollout ファイル検査で /clear 後の零履歴を確認。no-search probe 方法論で FALSE POSITIVE 排除済み |
| 3 | `agents/codex.toml` が ready_pattern=YOLO mode / fresh_mode=command / clear_command=/clear / prerequisite 手順コメントを正確に記述している (SC5) | ✓ VERIFIED | `ready_pattern = "YOLO mode"`, `fresh_mode = "command"`, `clear_command = "/clear"` 存在確認。`# 前提条件:` ブロックに `codex login` を含む。output_covenant に {result_path}/{status_path}、trigger_template に {prompt_path} 含有確認 |
| 4 | `scripts/e2e-codex.sh` が再実行可能で、result 非空 + status=done + 履歴隔離 2 ターンテストを検証する (D-07, D-10) | ✓ VERIFIED | bash -n 通過。実行ビット +x 確認。AGENT=codex PORT=8081 起動。3段階検証（stage1 result非空+status/stage2 seed/stage3 no-search probe with 7331 grep）。set -euo pipefail + trap cleanup EXIT INT TERM + wait_for_server 含有確認 |
| 5 | `AGENT=opencode ./ht-webif` で POST /prompt を送ると result-<turnId>.txt に非空回答 + status-<turnId>.json に done が書かれる (AGNT-03) | ✓ VERIFIED | 実機 E2E attempt4 stage1: result="5", status=done, 14s。orchestrator context で確認 |
| 6 | `AGENT=opencode` で POST /prompt {"fresh":true} がセッションリセット方式（respawn）で動作し履歴隔離が成立する (AGNT-04, D-10) | ✗ PARTIAL | 実機 E2E stage3: result="UNKNOWN", status=done, 19s — しかし D-09 アーキテクチャにより全ターンが独立した opencode run 呼び出しになるため、テストは構造的に unfalsifiable。fresh_mode=respawn が正しく設定され実際に呼び出されることは確認できるが、隔離が機能することの意味ある証明は提供されていない (CR-01) |
| 7 | `agents/opencode.toml` が trigger_template=/turn {prompt_path}（ASCII のみ）/ ready_pattern=Ask anything / prerequisite 手順コメントを正確に記述している (SC5) | ✓ VERIFIED (deviation) | trigger_template は "opencode run --command turn {prompt_path}"（ASCII のみ確認済み）。ready_pattern は "OpenCodeRunner ready"（D-09 ラッパー方式への移行で変更、SC5 の intent を満たす）。`# 前提条件:` ブロックに opencode auth login と bash scripts/setup-opencode.sh 参照を含む |
| 8 | `scripts/setup-opencode.sh` が ~/.config/opencode/commands/turn.md を冪等生成する (D-04) | ✓ VERIFIED | bash -n 通過。実行ビット +x。既存時スキップロジック確認。turn.md の description フロントマターと $ARGUMENTS 本文を正確に生成 |
| 9 | fresh_mode 確定値が実機挙動に基づき決定され、フォールバック時は ROADMAP SC4 と AGNT-04 文面が実測で更新される (D-01/D-02/D-03) | ✓ VERIFIED | /new → respawn フォールバック確定（D-01/D-02）。ROADMAP.md SC4 に「/new はエージェント選択ダイアログのため不採用 — 2026-06-12 実機試行 D-01/D-02 確定」追記確認。REQUIREMENTS.md AGNT-04 同様に更新確認（D-03） |

**Score:** 4/5 ROADMAP Success Criteria verified (SC1/SC2/SC3/SC5 VERIFIED; SC4 = PARTIAL)

Note: Must-haves count 9 items across 2 plans; ROADMAP has 5 success criteria. SC4 = AGNT-04 = must-have #6 above = PARTIAL.

### ROADMAP Success Criteria Coverage

| SC | Text | Status | Note |
|----|------|--------|------|
| SC1 | `AGENT=codex` POST /prompt → result/status ファイル生成 | ✓ VERIFIED | turnId=20260612-081024-367 |
| SC2 | `AGENT=codex` fresh:true で /clear 送信正常動作 | ✓ VERIFIED | rollout 証拠あり、UNKNOWN 返答 |
| SC3 | `AGENT=opencode` POST /prompt → result/status ファイル生成 | ✓ VERIFIED | result="5", status=done |
| SC4 | `AGENT=opencode` fresh:true で respawn 方式正常動作 | ✗ PARTIAL | respawn 設定は正しいが E2E テストが vacuous (CR-01) |
| SC5 | 両 TOML が ready_pattern/fresh_mode/prerequisite 手順を正確に記述 | ✓ VERIFIED | 両ファイル確認済み |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `agents/codex.toml` | Codex CLI エージェントプロファイル | ✓ VERIFIED | command/ready_pattern/fresh_mode/clear_command/output_covenant/trigger_template/timeouts 全確認 |
| `scripts/e2e-codex.sh` | Codex E2E 検証スクリプト | ✓ VERIFIED | 実行可能、bash -n OK、3段階検証、no-search probe |
| `agents/opencode.toml` | OpenCode エージェントプロファイル | ✓ VERIFIED (deviation) | D-09 に伴い command=opencode-runner.sh, ready_pattern=OpenCodeRunner ready に変更 |
| `scripts/setup-opencode.sh` | turn.md 冪等生成スクリプト | ✓ VERIFIED | 実行可能、bash -n OK、冪等スキップロジック確認 |
| `scripts/e2e-opencode.sh` | OpenCode E2E 検証スクリプト | ✓ VERIFIED (partial) | 実行可能、bash -n OK、3段階構造、しかし stage3 は structurally vacuous |
| `scripts/opencode-runner.sh` | OpenCode ラッパースクリプト（D-09 追加） | ✓ VERIFIED | 実行可能、stdin listener → opencode run 呼び出し、ready_pattern 再送出 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| scripts/e2e-codex.sh | agents/codex.toml | `AGENT=codex` 起動 → load_agent_profile が codex.toml を読む | ✓ WIRED | `AGENT=codex PORT="$PORT" TURNS_DIR="./turns" cargo run` 確認 |
| agents/codex.toml | src/profile.rs AgentProfile | toml::from_str デシリアライズ | ✓ WIRED | cargo test 33件グリーン、deny_unknown_fields + validate_profile 通過 |
| scripts/e2e-opencode.sh | agents/opencode.toml | `AGENT=opencode` 起動 → load_agent_profile が opencode.toml を読む | ✓ WIRED | `AGENT=opencode PORT="$PORT" TURNS_DIR="./turns" cargo run` 確認 |
| scripts/e2e-opencode.sh | scripts/setup-opencode.sh | `bash "$SCRIPT_DIR/setup-opencode.sh"` 明示呼び出し | ✓ WIRED | line 121 確認 |
| agents/opencode.toml | scripts/opencode-runner.sh | command = ["bash", "scripts/opencode-runner.sh"] | ✓ WIRED | cwd 依存（IN-04）— プロジェクトルートからの起動が前提 |
| agents/opencode.toml | ~/.config/opencode/commands/turn.md | trigger_template "/turn" → カスタムコマンド展開 | ✗ NOT_WIRED | D-09 アーキテクチャで trigger_template は "opencode run --command turn {prompt_path}" に変更済み。/turn カスタムコマンドは不使用になったが setup-opencode.sh が依然として turn.md を生成する。opencode run --command turn が turn.md を呼び出すため間接的には使用されている |

### Data-Flow Trace (Level 4)

Turn-file data flow: POST /prompt → prompt-<turnId>.txt → trigger → agent writes result-<turnId>.txt + status-<turnId>.json → GET /turns/{id} reads files.

| Agent | Data Source | Produces Real Data | Status |
|-------|-------------|--------------------|--------|
| codex | opencode run or codex TUI → writes result/status files | Yes (実機 E2E 確認済み) | ✓ FLOWING |
| opencode | opencode run --command turn → writes result/status files | Yes (実機 E2E attempt4 確認済み) | ✓ FLOWING |

### Behavioral Spot-Checks

Step 7b is SKIPPED for this phase — these are agent E2E scripts that require real running agents (codex, opencode) with real API credentials. The orchestrator's live E2E evidence substitutes. Spot-checks of static artifacts (syntax, file existence, field values) are covered in Steps 3-5 above.

Cargo test: 33 passed, 0 failed (verified above).

### Probe Execution

Step 7c: No conventional `scripts/*/tests/probe-*.sh` files exist. The phase's verification mechanism is the E2E scripts themselves. Orchestrator context records live execution results:

| Script | Run | Stage 1 | Stage 2 | Stage 3 | Status |
|--------|-----|---------|---------|---------|--------|
| scripts/e2e-codex.sh | 2026-06-12 final run | result="4", done, 26s | seed done | result="UNKNOWN", done, 19s | PASS |
| scripts/e2e-opencode.sh | attempt 4 (2026-06-12) | result="5", done, 14s | seed done, 16s | result="UNKNOWN", done, 19s | PASS (vacuous for AGNT-04) |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| AGNT-01 | 05-01-PLAN.md | Codex CLI で POST /prompt → result 取得が実機 E2E で動作 | ✓ SATISFIED | 実機 E2E stage1 pass + agents/codex.toml + scripts/e2e-codex.sh |
| AGNT-02 | 05-01-PLAN.md | Codex CLI で fresh:true（/clear 送信）が実機 E2E 動作 | ✓ SATISFIED | rollout ファイル証拠 + no-search probe UNKNOWN 返答 + fresh_mode=command 確認 |
| AGNT-03 | 05-02-PLAN.md | OpenCode で POST /prompt → result 取得が実機 E2E で動作 | ✓ SATISFIED | 実機 E2E attempt4 stage1 pass + agents/opencode.toml + opencode-runner.sh |
| AGNT-04 | 05-02-PLAN.md | OpenCode で fresh:true（respawn 方式）が実機 E2E 動作 | ✗ PARTIAL | respawn 設定は正しく実機 PASS したが、テスト自体が unfalsifiable (CR-01) |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/e2e-codex.sh | 165, 193, 234 | `status != "done"` でなく `status == "timeout" or failed` のみ拒否（WR-01） | Warning | status="unknown"（ガーブル時）がPASSになる |
| scripts/e2e-opencode.sh | 176, 204, 243 | 同上（WR-01） | Warning | 同上 |
| scripts/e2e-codex.sh | 249 | stage3 UNKNOWN 検出が INFO ログのみ（hard gate でない）（WR-02） | Warning | 空結果でも隔離 PASS になる |
| scripts/e2e-opencode.sh | 258 | 同上（WR-02） | Warning | 同上 |
| agents/codex.toml | 58 | trigger_template に日本語含有 — opencode.toml Pitfall 1 が同パスでマルチバイト破棄を文書化（WR-04） | Warning | 実機 E2E は PASS しているが trigger 意味論が実行時依存 |
| scripts/opencode-runner.sh | 33 | `eval "$trigger"` で未検証 PTY 入力を実行（WR-05） | Warning | POST /command が実質的に任意シェル実行パスになる（loopback限定でmitigation済み） |
| scripts/setup-opencode.sh | 56-74 | `bash:allow` をグローバル opencode.json に書く（WR-06） | Warning | 全 opencode セッションで bash 自動承認になる |
| src/worker.rs | 126-157, 172-202 | recreate/restart の ready-timeout エラーパスで新規セッションをリークする（WR-09） | Warning | 連続障害時に孤立エージェントプロセスが蓄積する可能性 |

No TBD/FIXME/XXX markers found in phase 05 files.

### Gaps Summary

**1 gap blocks clean passage (AGNT-04 vacuous test):**

The critical finding (code review CR-01) is confirmed: the OpenCode fresh-isolation E2E test is structurally unfalsifiable. The root cause is architectural — D-09 adopted `opencode run --command turn <path>` which creates a new conversation per invocation. This means stage 2 seeds memory into a context that is discarded the moment `opencode run` exits, so stage 3 (`fresh:true`) asserting no memory is guaranteed to pass regardless of whether `fresh_mode = "respawn"` works, is misconfigured, or is silently dropped.

The REQUIREMENTS.md AGNT-04 text ("respawn 方式: セッション kill+再生成 が実機 E2E 動作する") is consistent with the implementation, and `fresh_mode = "respawn"` is correctly set. However, the verification artifact (`e2e-opencode.sh`) does not actually test that the respawn mechanism fires on `fresh:true` — it passes for a structurally unrelated reason.

**The practical consequence:** If `fresh_mode` in opencode.toml were changed to an invalid string, or if the `fresh:true` flag path in the Rust worker were broken for the opencode agent, `e2e-opencode.sh` stage 3 would still pass. The test provides no discriminating power.

**Resolution options (in order of preference):**
1. Add a positive-control turn (stage 2.5: non-fresh query must return UNKNOWN, proving no continuity exists) and replace stage-3 with a server-log check that `[recreate]` fired. This makes the test honest about its limits while still verifying the respawn trigger.
2. Add `opencode run --continue <session_id>` support for non-fresh turns to establish real conversation continuity, making stage 2→3 meaningful.

The phase's primary goal ("ターンファイル方式での結果取得が動作することを E2E で確認できる") is substantially achieved for both agents. The gap is specifically in AGNT-04's verification quality, not in the runtime behavior itself.

---

_Verified: 2026-06-12T10:20:00Z_
_Verifier: Claude (gsd-verifier)_
