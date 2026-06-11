---
phase: 04-agent-profile-abstraction
verified: 2026-06-11T09:38:00Z
status: passed
score: 6/6 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 4/6
  gaps_closed:
    - "CR-01: prompt_handler worker Mutex ブロッキング回帰 — AppState.output_covenant ロックフリー化で解消"
    - "CR-02: cargo fmt --check 失敗 / CI ゲート破損 — cargo fmt 適用で解消"
    - "CR-03: model_flag/model_value が spawn に渡されない — AgentProfile::spawn_command() 配線で解消"
    - "WR-03: config.rs の TURN_TIMEOUT 死蔵定数 — 削除で解消"
  gaps_remaining: []
  regressions: []
---

# Phase 4: Agent Profile Abstraction — Re-Verification Report

**Phase Goal:** 運用者が `agents/claude.toml` を通じて WebIF を設定できる。既存の 4 エンドポイントの挙動が v1.0 と完全に一致する。
**Verified:** 2026-06-11T09:38:00Z
**Status:** passed
**Re-verification:** Yes — after gap closure plans 04-03 and 04-04

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | `AGENT=claude ./ht-webif` が v1.0 と挙動等価（4 エンドポイント・ready 検知・fresh:true・タイムアウト設定） | VERIFIED | prompt_handler は `state.output_covenant` を直接参照（lock-free、http.rs:66）。worker.lock().await は command_handler / restart_handler にのみ存在。4 ルート全確認。fresh_mode dispatch (turn.rs:47-58)、profile.startup_timeout_secs / turn_timeout_secs 使用、起動バナー出力確認。 |
| SC-2 | `agents/claude.toml` が存在し、ハードコードを完全に置き換えている | VERIFIED | agents/claude.toml 実ファイル確認: ready_pattern="auto mode", clear_command="/clear", fresh_mode="command", output_covenant（{result_path}/{status_path} 両プレースホルダ含む）, trigger_template（{prompt_path} 含む）。profile.rs の AgentProfile struct が deny_unknown_fields で全フィールドを TOML から読む。 |
| SC-3 | `AGENT=<unknown>` 起動で明確なエラー即終了 | VERIFIED | main.rs:24 の `load_agent_profile(&agent_name, &agents_dir)?` が ? で伝播。profile.rs:67-78 のエラー文にエージェント名・探索パス・利用可能一覧を含む。テスト (b) load_agent_profile_errors_on_missing_toml が 27 passed に含まれる。 |
| SC-4 | 新エージェントプロファイルがファイル追加のみで認識できる（Rust リビルド不要） | VERIFIED | load_agent_profile(name, agents_dir) は `agents_dir.join("{name}.toml")` を動的解決。固定マッチ・enum なし。TOML ファイル追加のみで新プロファイルが認識される構造。 |
| SC-5 | `cargo test` 全グリーン（27 件） | VERIFIED | `cargo test` 実行結果: 27 passed; 0 failed（プロファイル 13 tests + spawn_command 3 tests + turn 5 tests + http 5 tests + mcp 1 test）。 |
| SC-6 | `cargo fmt --check` が exit 0（CI fmt-check ジョブがグリーン） | VERIFIED | `cargo fmt --check` 出力なし（exit 0）。`cargo clippy --all-targets` 警告なし。commits 7c73d17 (style: apply cargo fmt) により CR-02 解消。 |

**Score: 6/6 truths verified**

---

### Gap Closure Verification (Re-verification Focus)

#### CR-01 — prompt_handler ロックフリー化

**Status:** CLOSED

- `AppState<M>` に `pub output_covenant: String` フィールドを追加済み（http.rs:29）
- prompt_handler 内に worker.lock().await による covenant 取得なし（確認済み）
- prompt_handler は `&state.output_covenant` を build_prompt_body に直接渡す（http.rs:66）
- main.rs:30 で `profile.output_covenant.clone()` を Worker::new の前に取り出し、AppState 構築時に渡す（main.rs:51）
- build_test_state も output_covenant を同様のパターンで設定（http.rs:236-249）

#### CR-02 — cargo fmt --check グリーン化

**Status:** CLOSED

- commit 7c73d17 (style(04-04): apply cargo fmt) で src/profile.rs, src/turn.rs, src/worker.rs, src/http.rs, src/main.rs を一括整形
- `cargo fmt --check` が差分なし exit 0 を確認
- `cargo clippy --all-targets` も警告なし

#### CR-03 — model_flag/model_value spawn 配線

**Status:** CLOSED

- `AgentProfile::spawn_command()` メソッドを profile.rs:51-58 に実装
- model_flag / model_value 両方 Some の場合のみ末尾に追加（D-13 準拠）
- worker.rs の create_session 呼び出し 3 箇所すべてが spawn_command() 経由に変更済み：
  - spawn_session (worker.rs:50): `client.create_session(&profile.spawn_command())`
  - recreate (worker.rs:118): `let cmd = self.profile.spawn_command();`
  - restart (worker.rs:157): `let cmd = self.profile.spawn_command();`

#### WR-03 — TURN_TIMEOUT 死蔵定数削除

**Status:** CLOSED

- `grep -n 'TURN_TIMEOUT' src/config.rs` → 0 件（確認済み）
- config.rs は MCP_TIMEOUT と use std::time::Duration のみ残存

---

### Must-Have Truths (Plan Frontmatter — 04-01 through 04-04 combined)

#### 04-01 Truths (初期フェーズ — 前回 VERIFIED のまま regression なし)

| Truth | Status | Evidence |
|-------|--------|----------|
| AgentProfile が agents/claude.toml をパースし全フィールドを読める | VERIFIED | AgentProfile struct (profile.rs:12-35) 全フィールド定義確認 |
| load_agent_profile が不在プロファイルで探索パス + 利用可能一覧を含むエラーを返す | VERIFIED | profile.rs:67-78 確認。27 tests 通過 |
| load_agent_profile が output_covenant/trigger_template プレースホルダ欠落を起動時に拒否 | VERIFIED | validate_profile (profile.rs:86-97) 確認 |
| load_agent_name が AGENT 未設定時に "claude" を返す | VERIFIED | config.rs:42: unwrap_or_else(|_| "claude".to_string()) |
| load_agents_dir が AGENTS_DIR 未設定時に CWD/agents を返す | VERIFIED | config.rs:47-53 |
| agents/claude.toml が現行ハードコード値を完全に保持する | VERIFIED | claude.toml 全フィールド確認済み |

#### 04-02 Truths (配線フェーズ — 前回 VERIFIED のまま regression なし)

| Truth | Status | Evidence |
|-------|--------|----------|
| build_prompt_body が v1.0 format! 出力とバイト一致する（golden test） | VERIFIED | turn.rs golden test が 27 passed に含まれる |
| src/worker.rs に "auto mode" 文字列リテラルが 0 箇所 | VERIFIED | worker.rs に "auto mode" リテラルなし（profile 経由） |
| src/mcp.rs に create_claude_session が 0 箇所 | VERIFIED | grep 0 件 |
| fresh:true が profile.fresh_mode に従い command/respawn を分岐する | VERIFIED | turn.rs:47-58 の match dispatch 確認 |
| 起動時に AGENT 名と turns ディレクトリがログ出力される | VERIFIED | main.rs:25, main.rs:39 |

#### 04-03 Truths (gap closure — 本 re-verification で新規 VERIFIED)

| Truth | Status | Evidence |
|-------|--------|----------|
| ターン実行中でも POST /prompt が turn_id を即返す（worker Mutex をブロックしない） | VERIFIED | http.rs:62-66: build_prompt_body が &state.output_covenant を直接使用。prompt_handler に worker.lock なし |
| prompt_handler は worker.lock() を取得せずに output_covenant を読む | VERIFIED | http.rs:48-98 全体確認。worker.lock は command_handler/restart_handler にのみ |
| model_flag と model_value の両方が設定されたプロファイルでは spawn コマンドにフラグと値が追加される | VERIFIED | profile.rs:51-58 spawn_command() + テスト h2 (spawn_command_appends_flag_and_value_when_both_specified) |
| 未参照の TURN_TIMEOUT 定数が config.rs から削除されている | VERIFIED | grep TURN_TIMEOUT src/config.rs → 0 件 |

#### 04-04 Truths (fmt gap closure — 本 re-verification で新規 VERIFIED)

| Truth | Status | Evidence |
|-------|--------|----------|
| cargo fmt --check が exit 0 で通る（CI の fmt-check ジョブがグリーン） | VERIFIED | cargo fmt --check 出力なし（exit 0）。commit 7c73d17 |
| rustfmt の自動整形のみでロジック変更がない（cargo test が依然グリーン） | VERIFIED | 27 passed; 0 failed（変更前の 24 + 新規 spawn_command 3 テスト） |

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/profile.rs` | AgentProfile struct + load/validate/scan + spawn_command() | VERIFIED | 391 行。spawn_command() 実装済み、テスト 13 ケース（h1/h2/h3 含む）全グリーン |
| `src/http.rs` | AppState に output_covenant フィールド、ロックフリー prompt_handler | VERIFIED | AppState.output_covenant: String (line 29)、prompt_handler lock-free (line 62-66) |
| `agents/claude.toml` | 5 ハードコード + タイムアウト/モデルのコメント例 | VERIFIED | 全フィールド確認。model_flag/model_value はコメントアウト例として存在 |
| `Cargo.toml` | toml = "1" 依存 | VERIFIED | toml = "1" 確認済み（前回 VERIFICATION より regression なし） |
| `src/turn.rs` | build_prompt_body(covenant_template) + fresh_mode + golden test | VERIFIED | 前回 VERIFIED、regression なし |
| `src/worker.rs` | Worker に profile フィールド + spawn_command() 経由 3 箇所 | VERIFIED | spawn_command() 呼び出し 3 箇所確認 (lines 50, 118, 157) |
| `src/main.rs` | プロファイルロード + output_covenant 取り出し + AppState 組み立て | VERIFIED | lines 22-24, 30, 47-52 確認 |
| `src/config.rs` | TURN_TIMEOUT 削除、MCP_TIMEOUT / Duration 残存 | VERIFIED | TURN_TIMEOUT 0 件確認、MCP_TIMEOUT と Duration 残存確認 |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/http.rs` prompt_handler | `state.output_covenant` | ロックフリーフィールド参照 | VERIFIED | http.rs:66 `&state.output_covenant` — worker.lock なし |
| `src/main.rs` | AppState.output_covenant | profile.output_covenant.clone() | VERIFIED | main.rs:30, 51 — Worker::new の前にクローン |
| `src/worker.rs` 3 箇所 | profile.spawn_command() | create_session 引数 | VERIFIED | lines 50, 118, 157 全確認 |
| `src/lib.rs` | `src/profile.rs` | `pub mod profile` | VERIFIED | lib.rs:22 |
| `src/profile.rs` | `agents/claude.toml` | toml::from_str | VERIFIED | profile.rs:79-80 |
| `src/main.rs` | `src/profile.rs` | load_agent_profile | VERIFIED | main.rs:24 |
| `src/main.rs` | Worker::new | profile を Worker に渡す | VERIFIED | main.rs:33 |
| `src/turn.rs` | worker.profile | covenant/trigger/fresh_mode/turn_timeout | VERIFIED | turn.rs:40, 47, 64 |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `src/http.rs` prompt_handler | `state.output_covenant` | profile.output_covenant at startup | Real TOML value | FLOWING — lock-free read from AppState, no mutex contention |
| `src/turn.rs` process_job | `worker.profile.*` | AgentProfile loaded at startup | Real TOML value | FLOWING — profile data flows correctly |
| `src/worker.rs` spawn_session/recreate/restart | spawn command | `profile.spawn_command()` | Real TOML + model fields | FLOWING — model_flag/model_value both wired |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| cargo test 27 グリーン | `cargo test` | 27 passed; 0 failed | PASS |
| cargo fmt --check | `cargo fmt --check` | 出力なし（exit 0） | PASS |
| cargo clippy --all-targets | `cargo clippy --all-targets` | 警告なし（exit 0） | PASS |
| TURN_TIMEOUT 削除確認 | `grep -n 'TURN_TIMEOUT' src/config.rs` | 0 件 | PASS |
| spawn_command() 3 箇所配線 | `grep -n 'spawn_command' src/worker.rs` | lines 50, 118, 157 | PASS |
| prompt_handler に worker.lock なし | `grep -n 'worker\.lock.*await' src/http.rs` | command_handler (141), restart_handler (169) のみ — prompt_handler 外 | PASS |
| output_covenant AppState フィールド | `grep -n 'pub output_covenant: String' src/http.rs` | line 29 | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PROF-01 | 04-01, 04-02 | agents/<name>.toml でエージェント定義 | SATISFIED | AgentProfile + agents/claude.toml 実装確認。deny_unknown_fields。 |
| PROF-02 | 04-01 | AGENT env でプロファイル選択、未指定は claude | SATISFIED | load_agent_name (config.rs:41-43)、main.rs:22-24 配線確認 |
| PROF-03 | 04-02, 04-03, 04-04 | claude.toml が現行挙動を再現、4 エンドポイント不変 | SATISFIED | lock-free covenant (CR-01)、fmt clean (CR-02)、4 エンドポイント確認。v1.0 等価を回復。 |
| PROF-04 | 04-02 | fresh_mode に従って動作 | SATISFIED | turn.rs:47-58 の match dispatch 確認 |
| PROF-05 | 04-01, 04-02, 04-03 | タイムアウト・model 選択をプロファイルで上書き | SATISFIED | startup_timeout_secs/turn_timeout_secs 配線済み。model_flag/model_value が spawn_command() 経由で有効（CR-03 解消）。 |
| PROF-06 | 04-01, 04-02 | TOML 追加のみで新エージェント認識 | SATISFIED | load_agent_profile が動的パス解決。ファイル追加のみで認識可能な構造確認。 |

**全 6 要件 SATISFIED**

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | — | — | — | — |

前回 VERIFICATION の 4 つの BLOCKER / WARNING はすべて解消された:
- CR-01 (BLOCKER): 解消 — AppState.output_covenant ロックフリー化
- CR-02 (BLOCKER): 解消 — cargo fmt 適用
- CR-03 (WARNING): 解消 — spawn_command() 配線
- WR-03 (WARNING): 解消 — TURN_TIMEOUT 削除

---

### Human Verification Required

(none — all gaps are statically verified in code; behavioral equivalence with v1.0 is confirmed by unit tests and code inspection)

---

## Gaps Summary

No gaps. All 6 success criteria verified. Phase goal achieved.

Gap closure plans 04-03 and 04-04 successfully closed all 4 identified gaps:
- CR-01 / CR-03 / WR-03: resolved in commit 4e69068 + 6e95406 (04-03)
- CR-02: resolved in commit 7c73d17 (04-04)

---

_Verified: 2026-06-11T09:38:00Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification after gap closure plans 04-03 and 04-04_
