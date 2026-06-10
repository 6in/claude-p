# Milestones

## v1.0 開発リポジトリ整備 (Shipped: 2026-06-10)

**Phases completed:** 3 phases, 13 plans, 14 tasks

**Delivered:** 動作済みプロトタイプ ht-webif を「他人が触れる開発リポジトリ」へ昇格 — リポジトリ体裁・モジュール構造・テスト・CI の土台を整備。

**Key accomplishments:**

- リポジトリ体裁の確立: README.md（概要・前提依存・ビルド/起動・4 エンドポイント curl 例）、MIT LICENSE、ルート `.gitignore`（target/・turns/・.env）、Cargo.toml メタデータ 6 フィールド
- 単一ファイル main.rs（~561 行）を `config` / `mcp` / `worker` / `turn` / `http` / `lib.rs` へモジュール分割、main.rs を wiring のみの ~52 行に縮小。8 curl smoke test で 4 エンドポイントの挙動完全保存を実証
- trait `Mcp` / `Restartable` 抽出と `Worker<M: Mcp>` ジェネリック化でテスト可能な構造を確立（main.rs 無変更）
- 11 本のテスト整備: 純粋関数 5（turn.rs）+ MCP JSON-RPC 3（mcp.rs、FakeMcp + duplex）+ HTTP 統合 3（http.rs、パストラバーサル拒否 400 / happy path）
- 開発ツール自動化: justfile 6 レシピ（build/run/test/fmt/clippy/clean）+ GitHub Actions CI（push/PR で fmt-check → clippy -D warnings → test）
- Quick tasks 7 件: claude-p ラッパー、CORS サポート、PORT/TURNS_DIR env 化、smoke.sh、cross-build justfile レシピ、CLAUDE.md slim 化 + docs/ 分割

**Known deferred items at close:** 9 (see STATE.md Deferred Items) — Phase 3 の human UAT 1 シナリオ（GitHub 上での CI red/green 確認）と verification の human_needed、および quick task 7 件のステータスメタデータ未記録（実装自体はコミット済み）。

---
