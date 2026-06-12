# Requirements: ht-webif — Milestone v2.0 マルチエージェント対応

**Defined:** 2026-06-11
**Core Value:** `-p` を避けつつ curl で Claude を実行できる（サブスクリプション課金を維持）— v2.0 ではこの仕組みを Claude 以外の対話型 CLI エージェントへ一般化する

## v2.0 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### プロファイル機構（PROF）

- [x] **PROF-01**: 運用者は `agents/<name>.toml` でエージェントの spawn コマンド・引数・環境変数・ready_pattern・clear 手順を定義できる
- [x] **PROF-02**: 運用者は起動時に `AGENT=<name>` 環境変数でプロファイルを選択できる（未指定時は `claude` で後方互換）
- [x] **PROF-03**: `agents/claude.toml` が現行ハードコード挙動（"auto mode" ready 検知・`/clear`・25s 起動待ち）を再現し、既存 4 エンドポイントの挙動が変わらない
- [x] **PROF-04**: `fresh:true` がプロファイルの `fresh_mode` に従って動作する（`command` = clear コマンド送信 / `respawn` = セッション kill+再生成）
- [x] **PROF-05**: `startup_timeout_secs`・`turn_timeout_secs`・model 選択（flag/value）をプロファイルで上書きできる（未指定時は現行デフォルト）
- [x] **PROF-06**: 新エージェントの追加が TOML ファイル追加のみで完結する（Rust コード変更・リビルド不要）

### エージェント対応（AGNT）

- [x] **AGNT-01**: Codex CLI プロファイル（`agents/codex.toml`）で `POST /prompt` → result 取得が実機 E2E で動作する
- [x] **AGNT-02**: Codex CLI で `fresh:true`（`/clear` 送信）が実機 E2E 動作する（Codex も in-session `/clear` を持つ — 2026-06-11 修正。実機検証で不安定な場合は `fresh_mode = "respawn"` へフォールバック）
- [x] **AGNT-03**: OpenCode プロファイル（`agents/opencode.toml`）で `POST /prompt` → result 取得が実機 E2E で動作する
- [x] **AGNT-04**: OpenCode で `fresh:true`（respawn 方式: セッション kill+再生成）が実機 E2E 動作する（`/new` はエージェント選択ダイアログのため不採用 — 2026-06-12 実機試行 D-01/D-02 確定）

### 観測性・並列駆動土台（PARA）

- [ ] **PARA-01**: `GET /info` が稼働中のエージェント名・port・status を JSON で返す
- [ ] **PARA-02**: `/info` が uptime・処理ターン数を含む
- [ ] **PARA-03**: launcher script（`scripts/launch-agents.sh` 等）で複数インスタンス（エージェント×ポート）を一括起動し、`/info` ポーリングで起動確認できる
- [ ] **PARA-04**: 複数インスタンスが `PORT`/`TURNS_DIR` 分離で衝突なく並列動作する（Codex の credential 分離 = per-instance `CODEX_HOME` 含め手順をドキュメント化）

## Future Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### エージェント追加

- **FUT-01**: Gemini CLI プロファイル（TUI 挙動の安定・文書化を待って追加 — プロファイル機構で後付け可能なことが v2.0 のゴール）

### 運用

- **FUT-02**: プロファイル hot-reload（現状は `POST /restart` または新ポートでの新インスタンス起動で代替）
- v1.0 からの繰延: OPS-01（turns/ ローテーション）、OPS-02（tracing 構造化ロギング）、SEC-01（HTTP 認証）、SCALE-01（同一プロセス内並列ワーカー）、DEPLOY-01（Docker 化）

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| リクエスト単位のエージェント切替（`POST /prompt {"agent":...}`） | 1プロセス=1エージェントの invariant を壊し、worker pool 管理・ロック競合・セッション状態の複雑さを持ち込む。インスタンス単位選択とユーザが判断 |
| WebIF 内ルーティング/ファンアウト/パイプライン | WebIF は薄いブリッジに徹する。エージェントの組み合わせは呼び出し側（シェルスクリプト等）の責務 |
| エージェントレジストリ/サービスディスカバリ | 別サービスの関心事。各インスタンスの `/info` + 呼び出し側のポートマップで十分 |
| JSON Schema 等によるプロファイルバリデーション | 起動時 1 回の読み込みに `anyhow` コンテキスト付きエラーで十分（運用者向け） |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROF-01 | Phase 4 | Complete |
| PROF-02 | Phase 4 | Complete |
| PROF-03 | Phase 4 | Complete |
| PROF-04 | Phase 4 | Complete |
| PROF-05 | Phase 4 | Complete |
| PROF-06 | Phase 4 | Complete |
| AGNT-01 | Phase 5 | Complete |
| AGNT-02 | Phase 5 | Complete |
| AGNT-03 | Phase 5 | Complete |
| AGNT-04 | Phase 5 | Complete |
| PARA-01 | Phase 6 | Pending |
| PARA-02 | Phase 6 | Pending |
| PARA-03 | Phase 6 | Pending |
| PARA-04 | Phase 6 | Pending |

**Coverage:**
- v2.0 requirements: 14 total
- Mapped to phases: 14
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-11*
*Last updated: 2026-06-11 — traceability mapped after roadmap creation (Phases 4-6)*
