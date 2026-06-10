---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: 開発リポジトリ整備
status: Awaiting next milestone
stopped_at: Completed 03-05 (justfile, TOOL-01)
last_updated: "2026-06-10T15:04:31.967Z"
last_activity: 2026-06-10 — Milestone v1.0 completed and archived
progress:
  total_phases: 3
  completed_phases: 3
  total_plans: 13
  completed_plans: 13
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-23)

**Core value:** `-p` を避けつつ curl で Claude を実行できる（サブスクリプション課金を維持）
**Current focus:** Planning next milestone (v1.0 shipped 2026-06-10)

## Current Position

Phase: Milestone v1.0 complete
Plan: —
Status: Awaiting next milestone
Last activity: 2026-06-10 — Milestone v1.0 completed and archived

## Performance Metrics

**Velocity:**

- Total plans completed: 9
- Average duration: —
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Repository Hygiene | 0 | — | — |
| 2. Module Refactor | 0 | — | — |
| 3. Testing & CI Automation | 0 | — | — |
| 01 | 3 | - | - |
| 03 | 6 | - | - |

**Recent Trend:**

- Last 5 plans: —
- Trend: — (no data yet)

*Updated after each plan completion*
| Phase 01-repository-hygiene P01 | 1min | 1 tasks | 2 files |
| Phase 02-module-refactor P02-01 | 2.4 | 3 tasks | 8 files |
| Phase 02-module-refactor P02 | 4.5 | 3 tasks | 3 files |
| Phase 02-module-refactor P02-03 | 7.0 | 3 tasks | 3 files |
| Phase 02-module-refactor P02-04 | 10.8 | 3 tasks | 3 files |
| Phase 03-testing-ci-automation P01 | 7.2 | 3 tasks | 6 files |
| Phase 03 P02 | 1.6min | 2 tasks | 1 files |
| Phase 03 P03 | 2.4min | 2 tasks | 1 files |
| Phase 03-testing-ci-automation P04 | 4.8min | 2 tasks | 2 files |
| Phase 03-testing-ci-automation P05 | 1min | 1 tasks | 1 files |
| Phase 03-testing-ci-automation P06 | 2.3 | 2 tasks | 1 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Roadmap structure: 3 phases at coarse granularity, ordered Hygiene → Refactor → Testing+CI so that the module split lands before tests (testing modular code is far cheaper than testing the monolith)
- Phase 2 explicitly requires behavior-preservation across the 4 HTTP endpoints (CODE-02) — refactor は機能変更を含めない
- [Phase ?]: webif/.gitignore 削除: ルートで webif/target/ をカバーするため重複不要
- [Phase ?]: Cargo.lock はバイナリクレートのためトラック維持（.gitignore に含めない）
- [Phase 02-module-refactor]: [02-01] [lib].name=ht_webif (underscore) と [[bin]].name=ht-webif (hyphen) の二重命名で Rust 識別子規則と既存バイナリ名を両立
- [Phase 02-module-refactor]: [02-01] プレースホルダはコード 0 行で統一 — Plan 02-04 までの増分移送を読みやすくするため
- [Phase 02-module-refactor]: [02-01] main.rs の clippy::trim_split_whitespace lint は Plan 02-02（McpClient 移送）で同時修正へ deferred
- [Phase 02-module-refactor]: [02-02] lib/bin 越境のため McpClient と TURN_TIMEOUT を pub 化 — pub(crate) は lib 内部のみ可視で bin crate から使えないため
- [Phase 02-module-refactor]: [02-02] D-02-01 (clippy::trim_split_whitespace) 解消 — mcp.rs 移送時に .trim() を削除
- [Phase ?]: [Phase 02-module-refactor]: [02-03] Worker/turn 主要メソッドを pub に格上げ — lib/bin 越境で main.rs HTTP ハンドラから呼ばれるため (Plan 02-02 パターンの自然拡張)
- [Phase ?]: [Phase 02-module-refactor]: [02-03] 依存方向 turn -> worker -> mcp を確立 — turn.rs::use crate::worker::Worker / worker.rs::use crate::mcp::McpClient で物理 reflect、Plan 04 で http.rs が最終層として import 可能に
- [Phase ?]: [Phase 02-module-refactor]: [02-03] use tokio::sync::{mpsc, Mutex}; を main.rs に保持 — Arc::new(Mutex::new(worker)) と mpsc::channel が main() 内に残るため必須
- [Phase ?]: [Phase 02-module-refactor]: [02-04] build_router(state) -> Router を pub の新規 API として導入 — main.rs から Router::new() を完全排除、HTTP 層改修を main.rs 不変で完結できる土台に
- [Phase ?]: [Phase 02-module-refactor]: [02-04] architecture summary doc コメントを lib.rs に移送 — cargo doc --lib のクレートトップに HT-PROTOCOL データフロー図と回復シナリオが出現
- [Phase ?]: [Phase 02-module-refactor]: [02-04] 8 curl smoke test 全 PASS で 4 エンドポイント挙動完全保存を runtime 実証 — Test 3 (パストラバーサル拒否 HTTP 400 + 不正な turn_id) で唯一の active security control (ASVS V5) が refactor を生き延びた
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-01] trait Restartable: Mcp 新設 (Rule 3 deviation) - restart_handler<M> を成立させるため Worker::restart を Restartable バウンド付きジェネリック impl に格上げ
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-01] McpClient.stdin/lines を Box<dyn AsyncWrite/Read + Send + Unpin> 化 + child を Option<Child> 化 - from_streams (#[cfg(test)] pub) で tokio::io::duplex 経由のテストハーネスを成立させるための単一 struct 化
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-01] Worker<M: Mcp = McpClient> のデフォルト型パラメータで main.rs 完全無変更を達成 - ライブラリ進化時の後方互換典型パターン
- [Phase ?]: Plan 03-02: turn_id formatter テストを turn.rs 内に配置 (chrono 形式検証の純関数集約点として)
- [Phase ?]: Plan 03-02: regex を追加せず std::str::split + chars().all(is_ascii_digit) のみで 19 文字 3 セグメント形式を検証 (依存最小化)
- [Phase ?]: Plan 03-02: garbled JSON テスト入力に not-a-json + 未閉鎖 brace 3 個 を採用 (将来の serde 寛容化に対するリグレッション耐性)
- [Phase ?]: Plan 03-03: mod tests を pub(crate) mod tests に格上げ - Wave 3 で use crate::mcp::tests::FakeMcp; を成立させる privacy 調整 (E0603 回避)
- [Phase ?]: Plan 03-03: make_client_and_harness ヘルパで tokio::io::duplex 2 組のセットアップを集約 (3 テストで共通の DRY)
- [Phase ?]: Plan 03-03: FakeMcp + new() に #[allow(dead_code)] 付与 - 本プランの 3 テストは McpClient のみ使用、Wave 3 で FakeMcp 消費 (future-consumer pattern)
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-04] ROADMAP 「../や不正文字を 400 で弾く」を 2 本の独立 #[tokio::test] 関数に分解 - verbatim OR を 1 本に圧縮せず保護対象ごとに独立 catch (パストラバーサル %2F 形式 vs 英字混入形式)
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-04] URI /turns/..%2Fetc%2Fpasswd を必須採用 - axum 0.8 の Path extractor は %2F を path 区切りとして扱わないためベアな ../ ではハンドラに届かず /etc/passwd に正規化される。%2F エンコード版で turn_id=../etc/passwd をハンドラに到達させ whitelist '0-9 + -' を検証
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-04] Worker::from_parts (#[cfg(test)] pub(crate)) でテスト用直接 ctor を追加 - boot/spawn 経由なし、Plan 03-01 の Worker<M: Mcp = McpClient> ジェネリック化と Plan 03-03 の FakeMcp を消費
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-04] build_test_state は (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>) のタプル返し - _job_rx 保持で Sender drop による channel closed を防ぐ (CONTEXT Constraints line 150)
- [Phase 03-testing-ci-automation]: [03-05] justfile に set working-directory := 'webif' を採用 — DRY と just --list の見やすさを優先（各レシピで cd webif && を繰り返す代替案を不採用）
- [Phase 03-testing-ci-automation]: [03-05] default レシピを置かず 6 レシピを fully explicit に保つ（D-15 厳守）— 意図しないビルド連鎖を防ぐ
- [Phase 03-testing-ci-automation]: [03-05] test レシピは cargo test --release（dev profile ではなく）— CI と同 profile に揃え dev/release リグレッション差を早期検知
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-06] CI ワークフロー .github/workflows/ci.yml 新規追加 — D-16..D-23 全反映、ubuntu-latest 単一 / stable / Swatinem/rust-cache@v2 / 単一 check ジョブで fmt-check → clippy → test 直列 / defaults.run.working-directory: webif / justfile 不使用
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-06] Task 2 human-verify は resume-signal 'skip' を採用 — リモート push 権限なし、プラン許可済み、ローカル静的検証 (YAML parse + 11 件 grep) で PASS
- [Phase ?]: [Phase 03-testing-ci-automation]: [03-06] cargo fmt --all -- --check の pre-existing drift (20 箇所、03-01..03-04 由来) を deferred-items.md に記録 — 03-06 の files_modified 外、scope boundary に従い別 commit へ deferred

### Pending Todos

None yet.

### Blockers/Concerns

- Git layout: 親 `ht-mcp-sample/` には `.git/` がなく、`webif/.git/` は 0 commit。Phase 1 で `.gitignore` を整備する際に「どちらを git ルートにするか」を決める必要がある（CONCERNS.md の "Nested-repo / mis-rooted git layout" 参照）
- `turns/` のコミット混入リスク: `.gitignore` 設計時に `turns/`・`.env` を必ず除外する（SEC: `.env` の初回コミット流出を防ぐ）

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260526-b7m | マルチOSビルド対応Makefile (cross経由でlinux/windows AMD64+ARM64、macOSはCI matrix委譲) | 2026-05-26 | cd59f2a | [260526-b7m-os-makefile-cross-linux-windows-amd64-ar](./quick/260526-b7m-os-makefile-cross-linux-windows-amd64-ar/) |
| 260526-qm5 | merge Makefile cross-build recipes into justfile and remove Makefile (supersedes 260526-b7m D-02/D-03 revised) | 2026-05-26 | 2cfbf8d | [260526-qm5-merge-makefile-into-justfile](./quick/260526-qm5-merge-makefile-into-justfile/) |
| 260526-voj | add smoke test script for ht-webif (webif/scripts/smoke.sh) | 2026-05-26 | 9c0153e | [260526-voj-add-smoke-test-script-for-ht-webif](./quick/260526-voj-add-smoke-test-script-for-ht-webif/) |
| 260527-00i | make PORT and TURNS_DIR configurable via env var (phase 1 multi-instance support) | 2026-05-27 | b9befc3 | [260527-00i-make-port-and-turns-dir-configurable](./quick/260527-00i-make-port-and-turns-dir-configurable/) |
| 260527-gp0 | add claude-p wrapper script (daemonized ht-webif + async + 30s polling) | 2026-05-27 | 767a3e5 | [260527-gp0-add-claude-p-wrapper](./quick/260527-gp0-add-claude-p-wrapper/) |
| 260527-lb8 | add CORS support to ht-webif HTTP API (tower-http CorsLayer + CORS_ORIGINS env var) | 2026-05-27 | 9bed812 | [260527-lb8-add-cors-support](./quick/260527-lb8-add-cors-support/) |
| 260527-pa6 | ht-webif 紹介ブログ（Zenn、~1,500字、Max サブスク維持 × curl 駆動主軸）の骨子作成 | 2026-05-27 | (pending) | [260527-pa6-blog-outline-tool-intro](./quick/260527-pa6-blog-outline-tool-intro/) |
| 260528-iav | CLAUDE.md整理: slim TL;DR + docs/ split (STACK.md/CONVENTIONS.md/ARCHITECTURE.md) | 2026-05-28 | e6a56b0 | [260528-iav-claude-md-gsd-tl-dr-docs](./quick/260528-iav-claude-md-gsd-tl-dr-docs/) |

## Deferred Items

Items acknowledged and deferred at milestone v1.0 close on 2026-06-10:

| Category | Item | Status |
| uat_gap | Phase 03: 03-HUMAN-UAT.md — GitHub 上での CI red/green 挙動確認 1 シナリオ | partial |
| verification_gap | Phase 03: 03-VERIFICATION.md | human_needed |
| quick_task | 260526-b7m-os-makefile-cross-linux-windows-amd64-ar | status metadata 未記録（実装済み cd59f2a） |
| quick_task | 260526-qm5-merge-makefile-into-justfile | status metadata 未記録（実装済み 2cfbf8d） |
| quick_task | 260526-voj-add-smoke-test-script-for-ht-webif | status metadata 未記録（実装済み 9c0153e） |
| quick_task | 260527-00i-make-port-and-turns-dir-configurable | status metadata 未記録（実装済み b9befc3） |
| quick_task | 260527-gp0-add-claude-p-wrapper | status metadata 未記録（実装済み 767a3e5） |
| quick_task | 260527-lb8-add-cors-support | status metadata 未記録（実装済み 9bed812） |
| quick_task | 260528-iav-claude-md-gsd-tl-dr-docs | status metadata 未記録（実装済み e6a56b0） |

v1 で扱わない要件（v2 以降に再評価）:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| Operations | OPS-01: turns/ rotation | Deferred to v2 | 2026-05-23 |
| Operations | OPS-02: tracing structured logging | Deferred to v2 | 2026-05-23 |
| Security | SEC-01: HTTP auth (bearer token) | Deferred to v2 | 2026-05-23 |
| Scaling | SCALE-01: parallel workers | Deferred to v2 | 2026-05-23 |
| Deploy | DEPLOY-01: Docker packaging | Deferred to v2 | 2026-05-23 |

## Session Continuity

Last session: 2026-05-25T14:01:49.956Z
Stopped at: Completed 03-05 (justfile, TOOL-01)
Resume file: None

## Operator Next Steps

- Start the next milestone with /gsd-new-milestone
