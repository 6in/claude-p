---
phase: 04-agent-profile-abstraction
verified: 2026-06-11T08:31:00Z
status: gaps_found
score: 4/6 must-haves verified
gaps:
  - truth: "AGENT=claude ./ht-webif が v1.0 と挙動等価（4 エンドポイント・ready 検知・fresh:true・タイムアウト設定）"
    status: failed
    reason: "CR-01: prompt_handler が worker Mutex をロックして output_covenant を取得するため、ターン実行中（最大 600 秒）は POST /prompt が即時応答できない。v1.0 では covenant が format! リテラルでロック不要だったため、これはこのフェーズが導入した回帰。非同期 API 契約（turn_id を即返す）が破られる。"
    artifacts:
      - path: "src/http.rs"
        issue: "prompt_handler (lines 57-60): state.worker.lock().await で covenant をクローン。worker_loop は process_job 実行中（最大 2×turn_timeout_secs ≒ 600 秒）同じ Mutex を保持 (turn.rs:92)。"
      - path: "src/turn.rs"
        issue: "worker_loop (line 92): let mut w = worker.lock().await — process_job が完了するまでロック解放しない。"
    missing:
      - "AppState に output_covenant（または profile 全体）を直接フィールドとして持たせ、Mutex ロック不要にする（CR-01 の修正方法: pub output_covenant: String を AppState に追加し、main.rs で profile から clone して設定）"
  - truth: "cargo fmt --check が通る（CI の fmt-check ジョブがグリーン）"
    status: failed
    reason: "CR-02: cargo fmt --check が失敗する。src/profile.rs (2 箇所)、src/turn.rs (3 箇所)、src/worker.rs に rustfmt 差分が存在する。CI パイプラインは fmt-check → clippy → test の順で、最初のステップが失敗する。"
    artifacts:
      - path: "src/profile.rs"
        issue: "lines 63-64: toml::from_str チェーンが 100 文字超。lines 71-72: || 条件の折り返し。"
      - path: "src/turn.rs"
        issue: "line 23: build_prompt_body シグネチャが 1 行 100 文字超。lines 40-41: trigger テンプレートのメソッドチェーン。"
      - path: "src/worker.rs"
        issue: "lines 23-34 付近: 長行あり。"
    missing:
      - "cargo fmt を実行してコミット。ロジック変更なし、rustfmt 自動整形のみ。"
human_verification: []
---

# Phase 4: Agent Profile Abstraction Verification Report

**Phase Goal:** 運用者が `agents/claude.toml` を通じて WebIF を設定できる。既存の 4 エンドポイントの挙動が v1.0 と完全に一致する。
**Verified:** 2026-06-11T08:31:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | `AGENT=claude ./ht-webif` が v1.0 と挙動等価（4 エンドポイント・ready 検知・fresh:true・タイムアウト設定） | FAILED | CR-01: prompt_handler が worker Mutex をロックして covenant 取得 (http.rs:57-60)。worker_loop は process_job 実行中ずっと同じ Mutex を保持 (turn.rs:92)。ターン中は POST /prompt が即時応答できない回帰。 |
| SC-2 | `agents/claude.toml` が存在し、ハードコードを完全に置き換えている | VERIFIED | agents/claude.toml 存在確認。ready_pattern="auto mode", clear_command="/clear", fresh_mode="command", output_covenant (両プレースホルダ含む), trigger_template 確認。profile.rs の AgentProfile struct が全フィールド定義済み。 |
| SC-3 | `AGENT=<unknown>` 起動で明確なエラー即終了 | VERIFIED | main.rs:21 の `load_agent_profile(...)?` が load_agent_profile のエラーを ? で伝播。profile.rs:51-61 でエージェント名・探索パス・利用可能一覧を含むエラー文。テスト b が確認済み。 |
| SC-4 | 新しいエージェントプロファイルがファイル追加のみで認識できる（Rust リビルド不要） | VERIFIED | load_agent_profile が agents_dir.join("{name}.toml") を動的解決。固定デシリアライズ型 AgentProfile に deny_unknown_fields あり。ファイル追加のみで load_agent_profile("new-name", &agents_dir) が動く構造を確認。 |
| SC-5 | `cargo test` 全グリーン | VERIFIED | 実行結果: 24 passed; 0 failed（24-01 golden test + 10 profile tests + 既存 13 + http tests）。 |
| SC-6 | CI fmt-check がグリーン（CLAUDE.md 規約: cargo fmt + clippy before commits、CI enforces cargo fmt --check） | FAILED | cargo fmt --check 実行結果: profile.rs 2 箇所・turn.rs 3 箇所・worker.rs に差分。CI 最初のジョブが失敗する。 |

**Score: 4/6 truths verified**

---

### Must-Have Truths (Plan Frontmatter — 04-01 and 04-02 combined)

#### 04-01 Truths

| Truth | Status | Evidence |
|-------|--------|----------|
| AgentProfile が agents/claude.toml をパースし 5 挙動フィールド + 2 任意タイムアウト + 任意 model_flag/model_value を読める | VERIFIED | profile.rs: AgentProfile 全フィールド定義確認。turn.rs golden test が実ロードを確認。 |
| load_agent_profile が不在プロファイルで探索パス + 利用可能一覧を含むエラーを返す | VERIFIED | profile.rs:51-61 実装確認。テスト b (load_agent_profile_errors_on_missing_toml) が agent 名・"agents/"・"claude" を含むことをアサート。 |
| load_agent_profile が output_covenant/trigger_template プレースホルダ欠落を起動時に拒否 | VERIFIED | validate_profile (profile.rs:70-81) 確認。テスト c/c2/d がプレースホルダ欠落をアサート。 |
| load_agent_name が AGENT 未設定時に "claude" を返す | VERIFIED | config.rs:44-45: unwrap_or_else(|_| "claude".to_string()) |
| load_agents_dir が AGENTS_DIR 未設定時に CWD/agents を返す | VERIFIED | config.rs:50-56: current_dir().join("agents") |
| agents/claude.toml が現行ハードコード値を完全に保持する | VERIFIED | claude.toml 全フィールド確認済み。 |
| スキーマは Phase 4 配線フィールドのみ定義（wedge_pattern / prerequisite_check / extra_args フィールドなし） | VERIFIED | AgentProfile struct にそれらフィールドなし。 |
| TOML 値への環境変数上書きなし — env=インフラ / TOML=エージェント挙動の 2 層維持 | VERIFIED | load_agent_profile 内に env 上書きロジックなし。 |

#### 04-02 Truths

| Truth | Status | Evidence |
|-------|--------|----------|
| AGENT=claude ./ht-webif が v1.0 と挙動等価 | FAILED | CR-01 (詳細は SC-1 参照) |
| build_prompt_body が v1.0 format! 出力とバイト一致する（golden test） | VERIFIED | turn.rs:145-168 の build_prompt_body_covenant_matches_v1_output が 24 passed に含まれる。 |
| src/worker.rs に "auto mode" 文字列リテラルが 0 箇所 | VERIFIED | grep 確認: worker.rs / mcp.rs / turn.rs / main.rs / http.rs に "auto mode" リテラルなし（profile.rs のテスト内 ready_pattern 値は除く）。 |
| src/mcp.rs に create_claude_session が 0 箇所 | VERIFIED | grep -rn 'create_claude_session' src/ → 0 件。 |
| fresh:true が profile.fresh_mode に従い command/respawn を分岐する | VERIFIED | turn.rs:47-58: match worker.profile.fresh_mode.as_str() { "command" => submit_line, "respawn" => recreate, other => bail! } |
| 起動時に AGENT 名と turns ディレクトリがログ出力される | VERIFIED | main.rs:22: eprintln!("[profile] エージェント: {agent_name}")、main.rs:31: eprintln!("[profile] ターンディレクトリ: ...") |
| AGENT=<unknown> 起動でプロファイル不在の明確なエラーで即終了 | VERIFIED | main.rs:21: load_agent_profile(...)?、profile.rs エラー文に名前・パス・一覧含む |

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/profile.rs` | AgentProfile struct + load/validate/scan | VERIFIED | 317 行。pub struct AgentProfile, #[serde(deny_unknown_fields)], load_agent_profile, validate_profile, list_available_profiles, 10 tests 全グリーン。 |
| `agents/claude.toml` | 5 ハードコード + タイムアウト/モデルのコメント例 | VERIFIED | ready_pattern="auto mode", command=["claude"], fresh_mode="command", clear_command="/clear", output_covenant (両プレースホルダ), trigger_template ({prompt_path}), コメント例あり。 |
| `Cargo.toml` | toml = "1" 依存 | VERIFIED | line 18: toml = "1" |
| `src/turn.rs` | build_prompt_body(covenant_template) + fresh_mode + golden test | VERIFIED | covenant_template あり、fresh_mode dispatch あり、golden test あり。 |
| `src/worker.rs` | Worker に profile フィールド + 4 ready-pattern サイト profile 化 | VERIFIED | pub profile: AgentProfile フィールド。4 サイト (spawn_session/recreate/restart/ensure_healthy) が profile.ready_pattern と profile.startup_timeout_secs を使用。 |
| `src/main.rs` | プロファイルロード配線 + D-16 turns サブディレクトリ + 起動バナー | VERIFIED | load_agent_profile 呼び出し、turns_base.join(&agent_name)、[profile] バナー確認。 |
| `README.md` | AGENT/AGENTS_DIR 環境変数 + D-16 TURNS_DIR 挙動変更 | VERIFIED | line 269-271: AGENT/AGENTS_DIR 行あり。TURNS_DIR 行に D-16 breaking change 明記。 |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/lib.rs` | `src/profile.rs` | `pub mod profile` | VERIFIED | lib.rs:22 |
| `src/profile.rs` | `agents/claude.toml` | `toml::from_str` | VERIFIED | profile.rs:63 |
| `src/main.rs` | `src/profile.rs` | `load_agent_profile` | VERIFIED | main.rs:21 |
| `src/main.rs` | `Worker::new` | `profile を Worker に渡す` | VERIFIED | main.rs:25: Worker::new(ht_mcp_path, profile) |
| `src/turn.rs` | `worker.profile` | covenant/trigger/fresh_mode/turn_timeout を profile から取得 | VERIFIED | turn.rs:40,47,64: worker.profile.{field} |
| `src/http.rs` | `worker.profile` | output_covenant 取得 | PARTIAL/WIRED-BUT-BLOCKING | http.rs:57-60: ロック取得は成功するが、ターン実行中は 600 秒ブロックする (CR-01)。 |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `src/http.rs` prompt_handler | `covenant` | worker.profile.output_covenant via lock | Real TOML value | HOLLOW — wired but lock contention breaks async API contract |
| `src/turn.rs` process_job | `worker.profile.*` | AgentProfile loaded at startup | Real TOML value | FLOWING — profile data flows correctly into turn execution |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| cargo build succeeds | `cargo build` | compiled 1 crates (1.41s) | PASS |
| cargo test 全グリーン | `cargo test` | 24 passed; 0 failed | PASS |
| cargo fmt --check | `cargo fmt --check` | Diff in profile.rs, turn.rs, worker.rs | FAIL |
| "auto mode" hardcode gone from core files | `grep -rn '"auto mode"' src/worker.rs src/mcp.rs src/turn.rs src/main.rs src/http.rs` | 0 matches | PASS |
| create_claude_session gone | `grep -rn 'create_claude_session' src/` | 0 matches | PASS |
| model_flag/model_value wired into spawn command | `grep -n 'model_flag\|model_value\|spawn_command' src/worker.rs src/mcp.rs` | 0 matches — only profile.rs defines them | FAIL (CR-03) |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PROF-01 | 04-01, 04-02 | agents/<name>.toml でエージェント定義 | SATISFIED | AgentProfile + agents/claude.toml 実装確認 |
| PROF-02 | 04-01 | AGENT env でプロファイル選択、未指定は claude | SATISFIED | load_agent_name, main.rs 配線確認 |
| PROF-03 | 04-02 | claude.toml が現行挙動を再現、4 エンドポイント不変 | PARTIALLY BLOCKED | 4 エンドポイント自体は存在。しかし CR-01 により POST /prompt の非同期契約が回帰。 |
| PROF-04 | 04-02 | fresh_mode に従って動作 | SATISFIED | turn.rs:47-58 の match dispatch 確認 |
| PROF-05 | 04-01, 04-02 | タイムアウト・model 選択をプロファイルで上書き | PARTIALLY SATISFIED | startup_timeout_secs/turn_timeout_secs は配線済み。model_flag/model_value はパースのみで spawn に渡されない (CR-03)。 |
| PROF-06 | 04-01, 04-02 | TOML 追加のみで新エージェント認識 | SATISFIED | 動的パス解決確認。ファイル追加のみで認識可能な構造。 |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| src/http.rs | 57-60 | worker.lock().await で covenant クローン — ターン実行中ブロッキング | BLOCKER | 非同期 POST /prompt が現在のターン完了まで（最大 600s）ブロックされる (CR-01) |
| src/profile.rs | 63-64, 71-72 | rustfmt 差分あり | BLOCKER | CI fmt-check ジョブ失敗 (CR-02) |
| src/turn.rs | 23, 40-41 | rustfmt 差分あり | BLOCKER | CI fmt-check ジョブ失敗 (CR-02) |
| src/worker.rs | 23-34 付近 | rustfmt 差分あり | BLOCKER | CI fmt-check ジョブ失敗 (CR-02) |
| src/worker.rs | 44, 108, 147 | create_session(&profile.command) — model_flag/model_value を使わない | WARNING | model 選択設定が無言で無視される (CR-03) |
| src/config.rs | 7-8 | TURN_TIMEOUT 定数が死蔵化（参照ゼロ、profile.turn_timeout_secs に置き換え済み） | WARNING | 将来の divergence 源 (WR-03) |

---

### Human Verification Required

(none — all gaps are statically observable in code)

---

## Gaps Summary

**2 BLOCKERs preventing goal achievement:**

### BLOCKER 1: CR-01 — POST /prompt ブロッキング回帰

SC-1「AGENT=claude ./ht-webif が v1.0 と挙動等価」が FAILED。

`src/http.rs:57-60` の `prompt_handler` が `state.worker.lock().await` を使って `output_covenant` を取得する。`worker_loop` (`src/turn.rs:92`) はジョブ処理中ずっと同じ Mutex を保持する（最大 2×turn_timeout_secs = 600 秒）。その結果、ターン実行中に届いた POST /prompt は covenant の1文字列取得のためだけに現行ターン完了まで待たされる。v1.0 では covenant は `format!` リテラルでロック不要だったため、これはこのフェーズが導入した純粋な回帰。

修正方法: `AppState` に `pub output_covenant: String`（または `pub profile: Arc<AgentProfile>`）フィールドを追加し、`main.rs` で `profile.output_covenant.clone()` を格納。`prompt_handler` は Mutex を取得せずに `state.output_covenant` を参照する。`build_test_state` も同様に更新。

### BLOCKER 2: CR-02 — cargo fmt --check 失敗、CI ゲート破損

`cargo fmt --check` が `src/profile.rs`（2 箇所）・`src/turn.rs`（3 箇所）・`src/worker.rs` に差分を出力する。CLAUDE.md 規約「cargo fmt + cargo clippy before commits。CI enforces cargo fmt --check」に違反。CI パイプライン（fmt-check → clippy → test）が最初のジョブで失敗する。

修正方法: `cargo fmt` 実行のみ（ロジック変更なし）。

### Notable Non-Blocker: CR-03 — model_flag/model_value が spawn に渡されない

PROF-05 の部分的未達。`model_flag`/`model_value` は TOML でパースされ、`agents/claude.toml` では「使用する場合は両方指定」と機能するかのように文書化されているが、`src/worker.rs:44,108,147` の `create_session(&profile.command)` はこれらを一切参照しない。利用者が設定しても無言で無視される。

PROF-05 の timeout 配線は完了しているため PROF-05 は部分的にのみ満たされる。model 選択は Phase 4 では「コメントアウト例」として TOML に記載されており、PROF-05 の必須要件は「未指定時は現行デフォルト」であるため、model 選択が後続フェーズで実装される場合は Phase 4 的には許容範囲の可能性もある。ただし CR-03 はドキュメントと実装の乖離（無言のノーオプ）として WR 扱いが妥当。

---

_Verified: 2026-06-11T08:31:00Z_
_Verifier: Claude (gsd-verifier)_
