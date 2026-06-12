# Roadmap: ht-webif

## Milestones

- ✅ **v1.0 開発リポジトリ整備** — Phases 1-3 (shipped 2026-06-10)
- 🚧 **v2.0 マルチエージェント対応** — Phases 4-6 (in progress)

## Phases

<details>
<summary>✅ v1.0 開発リポジトリ整備 (Phases 1-3) — SHIPPED 2026-06-10</summary>

- [x] Phase 1: Repository Hygiene (3/3 plans) — completed 2026-05-24
- [x] Phase 2: Module Refactor (4/4 plans) — completed 2026-05-25
- [x] Phase 3: Testing & CI Automation (6/6 plans) — completed 2026-05-25 (human UAT 1 件は繰延、STATE.md Deferred Items 参照)

詳細: [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)

</details>

### 🚧 v2.0 マルチエージェント対応 (In Progress)

**Milestone Goal:** ht-webif を Claude 専用から脱却させ、エージェントプロファイル（`agents/*.toml`）で任意の対話型 CLI エージェントを駆動できるようにし、多重インスタンスによる並列オーケストレーションの土台を作る。

- [x] **Phase 4: Agent Profile Abstraction** - Claude を最初のプロファイルとして再定義する純粋リファクタ（挙動変化なし） (completed 2026-06-11)
- [ ] **Phase 5: Codex CLI and OpenCode Validation** - Codex / OpenCode の実機 E2E 検証とプロファイル確立
- [ ] **Phase 6: Multi-Instance Parallel Foundation** - 観測性エンドポイントと多重インスタンス並列起動の土台

## Phase Details

### Phase 4: Agent Profile Abstraction

**Goal**: 運用者が `agents/claude.toml` を通じて WebIF を設定できる。既存の 4 エンドポイントの挙動が v1.0 と完全に一致する。
**Depends on**: Phase 3
**Requirements**: PROF-01, PROF-02, PROF-03, PROF-04, PROF-05, PROF-06
**Success Criteria** (what must be TRUE):

  1. `AGENT=claude ./ht-webif` が v1.0 と挙動等価（4 エンドポイント・ready 検知・fresh:true・タイムアウト設定）
  2. `agents/claude.toml` が存在し、ハードコードを完全に置き換えている（ready_pattern / clear_command / fresh_mode / output_covenant / timeout 値が TOML で定義済み）
  3. `AGENT=<unknown>` で起動すると、対応するプロファイルファイルが見当たらない旨の明確なエラーで即時終了する
  4. 新しいエージェントプロファイル（`agents/test.toml`）をファイル追加のみで認識できる（Rust リビルド不要）
  5. `cargo test` が全 11 件グリーン（リファクタ前回帰なし）**Plans**: 4 plans (2 original + 2 gap closure)

**Wave 1**

- [x] 04-01-PLAN.md — AgentProfile 契約レイヤー: profile.rs + agents/claude.toml + config ローダー + toml 依存

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 04-02-PLAN.md — 配線: trait リネーム + worker/turn の profile 化 + main.rs(D-16) + http テスト修正 + README

**Gap Closure** *(検証ギャップ修正 — 04-VERIFICATION.md)*

- [x] 04-03-PLAN.md — covenant ロックフリー化 (CR-01) + model_flag/model_value 配線 (CR-03) + TURN_TIMEOUT 削除 (WR-03)
- [x] 04-04-PLAN.md — cargo fmt 適用 (CR-02): CI fmt-check ジョブをグリーン化

### Phase 5: Codex CLI and OpenCode Validation

**Goal**: Codex CLI と OpenCode を実機で駆動し、ターンファイル方式での結果取得が動作することを E2E で確認できる。
**Depends on**: Phase 4
**Requirements**: AGNT-01, AGNT-02, AGNT-03, AGNT-04
**Success Criteria** (what must be TRUE):

  1. `AGENT=codex ./ht-webif` に `POST /prompt` を送ると、`result-<turnId>.txt` に非空の回答が書き込まれ `status-<turnId>.json` に成功ステータスが記録される
  2. `AGENT=codex` で `POST /prompt {"fresh":true}` が `/clear` 送信方式で正常動作する（Codex も in-session `/clear` を持つ — 2026-06-11 修正。実機検証で不安定な場合は respawn 方式へフォールバック）
  3. `AGENT=opencode ./ht-webif` に `POST /prompt` を送ると、同様に result ファイルと status ファイルが作成される
  4. `AGENT=opencode` で `POST /prompt {"fresh":true}` が respawn 方式（セッション kill+再生成）で正常動作する（`/new` はエージェント選択ダイアログのため不採用 — 2026-06-12 実機試行 D-01/D-02 確定）
  5. `agents/codex.toml` と `agents/opencode.toml` が各エージェントの ready_pattern・fresh_mode・prerequisite 手順を正確に記述している（コメントに auth セットアップ手順を含む）

**Plans**: 2 plans

**Wave 1** *(並列 — ファイル重複なし)*

- [x] 05-01-PLAN.md — Codex プロファイル + E2E スクリプト（agents/codex.toml, scripts/e2e-codex.sh; AGNT-01/02）
- [x] 05-02-PLAN.md — OpenCode プロファイル + setup/E2E スクリプト + ドキュメント（agents/opencode.toml, scripts/setup-opencode.sh, scripts/e2e-opencode.sh, README; AGNT-03/04）

**Research flag**: RESOLVED — 05-RESEARCH.md が Codex/OpenCode を実機検証済み（Codex HIGH / OpenCode /turn workaround HIGH）。プロファイル値は確定。

### Phase 6: Multi-Instance Parallel Foundation

**Goal**: 複数エージェントのインスタンスを同時に立ち上げ、各インスタンスの状態を `GET /info` で観測しながら独立して curl で叩ける環境が整う。
**Depends on**: Phase 5
**Requirements**: PARA-01, PARA-02, PARA-03, PARA-04
**Success Criteria** (what must be TRUE):

  1. `GET /info` が稼働中のエージェント名・port・status・uptime・処理ターン数を含む JSON を返す
  2. `scripts/launch-agents.sh`（または `just up-all`）を実行すると、複数インスタンス（例: claude + codex + opencode）が別ポートで一括起動し、各 `/info` がそれぞれの正しいエージェント名を返す
  3. 複数インスタンスが同時に稼働中に 100 ターンを並行実行しても、ターンファイルのコリジョンが発生しない（`TURNS_DIR` 分離で自動保証）
  4. README.md に多重インスタンス起動手順・CODEX_HOME 分離手順・クレデンシャル分離ガイドが記載されている

**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Repository Hygiene | v1.0 | 3/3 | Complete | 2026-05-24 |
| 2. Module Refactor | v1.0 | 4/4 | Complete | 2026-05-25 |
| 3. Testing & CI Automation | v1.0 | 6/6 | Complete | 2026-05-25 |
| 4. Agent Profile Abstraction | v2.0 | 4/4 | Complete    | 2026-06-11 |
| 5. Codex CLI and OpenCode Validation | v2.0 | 2/2 | Complete   | 2026-06-12 |
| 6. Multi-Instance Parallel Foundation | v2.0 | 0/? | Not started | - |

---
*Roadmap created: 2026-05-23*
*Milestone v1.0 shipped: 2026-06-10*
*Milestone v2.0 started: 2026-06-11 — マルチエージェント対応 (Phases 4-6)*
