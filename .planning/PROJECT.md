# ht-webif

## What This Is

`curl` 1発で Claude にタスクを送って結果を受け取れる、軽量な HTTP WebIF。`claude -p`（API クレジット課金）を回避し、対話型 Claude Code TUI を `ht-mcp`（headless terminal MCP サーバ）越しに駆動することで **Max サブスクリプション課金のまま** Claude をプログラマブルに呼び出せる。Rust + axum で実装し、リクエストはターン方式で直列処理する。利用者は自分のシェルスクリプト・自動化ループ・Web UI から `POST /prompt` するだけで Claude を扱える。

## Core Value

**`-p` を避けつつ curl で Claude を実行できる。** これがすべての設計判断の原点。サブスクリプション課金の維持、対話型 TUI の駆動、ファイル経由の入出力、自己回復機構 — どれもこの一点を成立させるために存在する。

## Requirements

### Validated

<!-- このセッションで実装＆動作確認済み。webif/ 配下のコードで動いている。 -->

- ✓ **WEBIF-01**: `curl` で HTTP JSON-RPC 風に Claude へタスク投入できる — phase 0（プロトタイピング）
- ✓ **WEBIF-02**: `POST /prompt` が非同期既定（`turn_id` 即返し）で動作 — phase 0
- ✓ **WEBIF-03**: `GET /turns/{turn_id}` でターンの状態・結果を取得できる — phase 0
- ✓ **WEBIF-04**: `POST /prompt {"wait":true}` で同期ブロッキング実行ができる — phase 0
- ✓ **WEBIF-05**: `POST /prompt {"fresh":true}` で実行前 `/clear`、stateless 一発実行になる — phase 0
- ✓ **WEBIF-06**: `POST /command` で claude TUI に生のスラッシュコマンドを送れる — phase 0
- ✓ **WEBIF-07**: `POST /restart` で ht-mcp プロセスごと再起動できる — phase 0
- ✓ **WEBIF-08**: HT-PROTOCOL v1.1 のターンファイル方式（`prompt-/result-/status-<turnId>`）で長さ無制限の結果を取得できる — phase 0
- ✓ **WEBIF-09**: claude セッション死亡時に WebIF が自動再生成する（ensure_healthy） — phase 0
- ✓ **WEBIF-10**: ターンが 300s で完了しないとき、セッション再生成＋1回リトライ — phase 0
- ✓ **WEBIF-11**: MCP 呼び出しに 30s タイムアウト（ht-mcp の wedge 対策） — phase 0
- ✓ **WEBIF-12**: `HT_MCP_PATH` を環境変数 / `.env` から読み込める — phase 0
- ✓ **WEBIF-13**: 子プロセス（ht-mcp）が `kill_on_drop` で確実に後始末される — phase 0
- ✓ **REPO-01**: README.md を整備（プロジェクト概要・ビルド方法・起動方法・API 例） — Phase 1 (Repository Hygiene)
- ✓ **REPO-02**: LICENSE を追加（MIT 全文、SPDX 識別子は Cargo.toml と一致） — Phase 1
- ✓ **REPO-03**: `.gitignore` を整備（`target/`、`turns/`、`.env`、IDE 関連、OS 生成物） — Phase 1
- ✓ **REPO-05**: `Cargo.toml` メタデータ整備（description、repository、license、authors、readme、edition） — Phase 1（REQUIREMENTS.md の REPO-04 に対応）
- ✓ **REPO-04**: `webif/src/main.rs`（~500行）をモジュール分割（`mcp`、`worker`、`http`、`turn`、`config`、`lib.rs`） — Phase 2 (Module Refactor)（main.rs は 52 行の wiring-only に縮小）
- ✓ **REPO-06 / TEST-01..03**: `#[cfg(test)] mod tests` 形式で 11 本のテスト（純粋関数 5 + MCP クライアント 3 + HTTP 統合 3） — Phase 3 (Testing & CI Automation)
- ✓ **REPO-07 / TOOL-01**: リポジトリ直下に `justfile`（build / run / test / fmt / clippy / clean の 6 レシピ、`set working-directory := 'webif'`） — Phase 3
- ✓ **REPO-08 / TOOL-02**: `.github/workflows/ci.yml`（push/PR トリガ、ubuntu-latest 単一 `check` ジョブで `cargo fmt --check` → `clippy -D warnings` → `test` 直列、`Swatinem/rust-cache@v2`） — Phase 3

### Active

<!-- これから取り組む。Phase 3 で REPO-06/07/08（TEST-*/TOOL-*）が完了。次は OPS / SEC / SCALE 等の運用系。 -->

- [ ] **OPS-01**: `turns/` のローテーション/アーカイブ運用（hot ディレクトリと archive を分離）
- [ ] **OPS-02**: 構造化ロギング（tracing crate）と最低限の観測性
- [ ] **SEC-01**: HTTP エンドポイントの認証（最低限 bearer token、ローカル外公開時の前提）
- [ ] **SCALE-01**: 並列ワーカー（複数 ht-mcp / claude セッション）
- [ ] **DEPLOY-01**: Docker 化（claude を含むコンテナ + 認証情報マウント）

### Out of Scope

<!-- 入れない理由を明示。後で誰かが「やろう」と提案したときに即答できるように。 -->

- **`claude -p` の利用** — Core Value に反する（サブスクリプション課金が変わる、と判断）。WebIF の存在意義そのものを否定する選択肢。
- **MCP プロトコルそのものの拡張・改造** — ht-mcp は外部依存。本プロジェクトは MCP クライアント実装に留め、上流の MCP/ht-mcp 仕様には影響しない。
- **claude TUI の機能拡張** — 同上。Claude Code は別プロジェクト。本 WebIF は薄いブリッジに徹する。
- **マルチホスト分散** — 現状のスコープ外。単一ホスト前提。将来 SCALE-01 を超えて必要になったら別途検討。
- **GUI / Web UI（フロントエンド）** — HTTP/JSON API までが本プロジェクトの責務。UI は別レイヤ（呼び出し側）で。

## Context

**Current state (v1.0 shipped 2026-06-10)**: 開発リポジトリとしての土台が完成。モジュール分割済み（main.rs ~52 行 + config/mcp/worker/turn/http/lib.rs）、テスト 11 本 green、justfile + GitHub Actions CI 稼働。次マイルストーンは OPS / SEC / SCALE / DEPLOY 系（PROJECT.md Active 参照）から選定する。

**技術環境**: Rust（edition 2021）、tokio 非同期ランタイム、axum 0.8、anyhow、serde、chrono、dotenvy。外部依存として `ht-mcp` バイナリ（Rust 製、別プロジェクト）と `claude`（Claude Code CLI、Anthropic 公式）が必要。

**実行環境**: 開発・運用とも Linux 単一ホスト。Claude Code は Max サブスクリプション認証（`~/.claude/.credentials.json` の OAuth トークン）で動作。

**生成経緯**: 2026-05-22 の1セッションで設計・実装・検証を一気に進めた急造プロトタイプ。`-p` の課金挙動を懸念した結果、対話型 TUI を `ht-mcp` 経由で操作するアーキテクチャに辿り着いた。HT-PROTOCOL v1.1（ターンファイル方式）はその過程で派生して設計された内部規約。

**既知の負債** (詳細は `.planning/codebase/CONCERNS.md`):
- `turns/` 無制限蓄積
- `/restart` は ht-mcp が wedge した場合に worker ロック越しでブロックされる余地（MCP タイムアウトで部分緩和済み）
- HTTP 認証なし（localhost 限定で運用前提）
- Phase 3 コードレビュー warnings: `Worker::restart` の partial-failure window（respawn 成功後 create_claude_session 失敗で session_id がスタック）、`prompt_handler` の prompt ファイル先書き → enqueue 失敗時の孤児ファイル — 詳細は `.planning/phases/03-testing-ci-automation/03-REVIEW.md`

**プロジェクトのレイアウト上の特殊性**:
- 親 `ht-mcp-sample/` を git ルートとし、メインの Rust コードは `webif/` サブディレクトリにある。
- `HT-PROTOCOL.md`、`.env`、`.mcp.json`、`turns/` は親に置いている（webif/ に取り込むかは REPO-XX の議論対象）。

## Constraints

- **Tech stack**: Rust（言語の堅牢性・単一バイナリ・パフォーマンス）— このプロジェクトの方針。
- **MCP transport**: stdio MCP（ht-mcp が stdio 専用）— `ht-mcp` を子プロセスで `spawn` し、newline 区切り JSON-RPC で会話。
- **Billing**: 必ず Max サブスクリプション経由 — `claude -p` 不使用、`ANTHROPIC_API_KEY` 不使用、`~/.claude/.credentials.json` の OAuth に依存。
- **Concurrency**: 同一プロセス内 1 worker = 1 claude TUI = 同時 1 ターン（直列）。並列化は worker 増設で対応する設計。
- **Auth context**: ホストの `claude` バイナリが既に Max でログイン済みである必要がある。
- **Single host**: 現状は WebIF と ht-mcp と claude が同一ホスト＝同一ファイルシステム。HT-PROTOCOL §7 はこの前提のもとで成立している。

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| `claude -p` を使わない | 課金（サブスク vs API クレジット）が変わるとユーザが判断。本 WebIF の存在意義そのもの | ✓ Good — Core Value として確定 |
| 対話型 TUI を ht-mcp 越しに駆動 | `-p` 回避の唯一の手段。ht-mcp は既存の Rust MCP サーバで再利用可能 | ✓ Good — 動作確認済み |
| HT-PROTOCOL v1.1（ターンファイル方式）採用 | スナップショットでは ~30行を超える回答が切り捨てられる。ファイル経由なら長さ無制限 | ✓ Good — 150行テストで実証 |
| 非同期 API を既定に（`wait:true` はオプション） | HTTP タイムアウトの懸念回避、ターン状態をファイルシステムで管理できる | ✓ Good — 検証済み |
| `fresh:true` で `/clear` 統合（"-p 相当"を 1 コール化） | 「文脈リセット + 実行」を 2 コール（`/command` `/clear` → `/prompt`）から 1 コールに | ✓ Good — 設計と動作一致 |
| ht-mcp 自前 MCP クライアント（rmcp 不使用） | stdio + newline-delimited JSON-RPC で十分。依存を増やさない | ✓ Good — 簡潔・動作 |
| GSD のプロジェクトルートを親 `ht-mcp-sample/` に置く | Claude Code の cwd と一致、`webif/.git` は空だったので親 git に統合 | — Pending — 運用してから評価 |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-10 after v1.0 milestone — マイルストーン「開発リポジトリ整備」をクローズ（3 phases / 13 plans / 11 requirements validated）。繰延 9 件（human UAT 1・verification 1・quick task メタデータ 7）は STATE.md Deferred Items に記録。*
