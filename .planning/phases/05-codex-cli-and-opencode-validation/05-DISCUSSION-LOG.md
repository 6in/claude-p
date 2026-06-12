# Phase 5: Codex CLI and OpenCode Validation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-12
**Phase:** 5-codex-cli-and-opencode-validation
**Areas discussed:** OpenCode fresh 方式, /turn 前提条件の管理, E2E 検証の形態, fresh 合格基準の深さ

---

## OpenCode fresh 方式

### Q1: OpenCode の fresh:true（AGNT-04）をどの方式で成立させますか？

| Option | Description | Selected |
|---|---|---|
| respawn 採用 (Recommended) | fresh_mode="respawn"。Phase 4 で実装・テスト済み、Rust 変更ゼロ、研究推奨。ROADMAP 文面は respawn に修正 | |
| スキーマ拡張で /new | clear_command を複数キー列対応に拡張して /new → Enter → Enter を送る。Rust 変更が発生、config-only でなくなる | |
| 実機で /new 試行→ダメなら respawn | まず 1回送信の /new を実機で試し、失敗を記録したうえで respawn にフォールバック | ✓ |

**User's choice:** 実機で /new 試行→ダメなら respawn
**Notes:** 検証エビデンスを残すことを優先。予想ではダイアログでスタック（研究 Pitfall 3）。

### Q2: /new 失敗→respawn フォールバック時、ROADMAP Success Criterion 4 / AGNT-04 の文面は？

| Option | Description | Selected |
|---|---|---|
| 実測結果で文面を更新 (Recommended) | 検証結果が出た時点で ROADMAP/REQUIREMENTS を実態に書き換える。Codex 基準 2 と同じパターン | ✓ |
| 今すぐフォールバック条項を追記 | 試行前に「不安定なら respawn へ」を基準 4 に追記しておく | |
| 文面はそのまま、SUMMARY に記録 | ドキュメントは触らず乖離を SUMMARY/VERIFICATION に記録 | |

**User's choice:** 実測結果で文面を更新

---

## /turn 前提条件の管理

### Q1: ~/.config/opencode/commands/turn.md の前提条件はどう管理しますか？

| Option | Description | Selected |
|---|---|---|
| セットアップスクリプト同梱 (Recommended) | scripts/setup-opencode.sh（冪等）で turn.md を生成。README/TOML コメントから参照。Rust 変更ゼロ | ✓ |
| ドキュメントのみ | TOML コメント + README に手順記載だけ。セットアップ忘れは実行時の劣化動作でしか気づけない | |
| 起動時 prerequisite チェック実装 | Phase 4 繰延の prerequisite_check フィールドを実装。最も堅牢だが Rust 変更が発生 | |

**User's choice:** セットアップスクリプト同梱

### Q2: セットアップスクリプトのスコープは？

| Option | Description | Selected |
|---|---|---|
| turn.md 生成のみ (Recommended) | 単一責務。auth 確認は README の手順記載に留める | ✓ |
| doctor 的な環境検査も含む | バイナリ PATH 確認・auth ファイル存在確認などを含む総合スクリプト | |

**User's choice:** turn.md 生成のみ

---

## E2E 検証の形態

### Q1: 実機 E2E 検証（AGNT-01〜04）はどういう形で実施・残しますか？

| Option | Description | Selected |
|---|---|---|
| コミットする bash スクリプト (Recommended) | scripts/e2e-codex.sh / e2e-opencode.sh。ht-webif 起動 + curl + result/status 検査で pass/fail。Phase 6 でも再利用 | ✓ |
| PLAN 内の手動手順 | 検証手順を PLAN の受け入れ基準として書き、結果を SUMMARY に記録。リポにスクリプトは残らない | |
| cargo test に #[ignore] 統合 | ライブ E2E を #[ignore] 付き Rust テストに。型安全だがハーネス実装コストが config-only フェーズの範囲を超える | |

**User's choice:** コミットする bash スクリプト
**Notes:** CI には繋がない（実エージェント・実課金が必要）。エビデンスは SUMMARY/VERIFICATION に記録。

---

## fresh 合格基準の深さ

### Q1: fresh:true の合格基準はどこまで深くしますか？

| Option | Description | Selected |
|---|---|---|
| 履歴隔離を実証 (Recommended) | 2ターンテスト: ターン1で固有の事実→fresh ターン2で「直前に何を伝えたか」を質問し、知らないことを確認。E2E スクリプトに組み込む | ✓ |
| ready 復帰のみ | fresh 後に ready 状態へ戻り次ターンが正常完了すれば合格（研究 OQ-3 の推奨と同等） | |
| エージェントごとに使い分け | respawn 採用エージェントは ready 復帰のみ、/clear 系は履歴隔離テスト | |

**User's choice:** 履歴隔離を実証
**Notes:** fresh は「-p 相当」という Core Value の代理機能のため、見た目のリセットでは不十分という判断。研究 OQ-3（/new が本当に履歴をクリアするか）もこのテストで決着する。

---

## Claude's Discretion

- E2E スクリプトの内部設計（共通化・PORT 選択・wait:true vs ポーリング）
- setup-opencode.sh の実装詳細（XDG_CONFIG_HOME 考慮など）
- `/new` 試行の記録形式
- TOML コメント文言（claude.toml / 研究サンプル準拠）
- README 追記の章立て

## Deferred Ideas

- wedge_pattern / prerequisite_check スキーマフィールド（Phase 4 D-08 繰延の継続）
- ready_pattern regex 化 + ANSI ストリップ（実測で不要と決着、実害が出るまで現状維持）
- mcp_timeout_secs プロファイル化（現状維持）
- clear_command 複数キーシーケンス対応（respawn フォールバック採用により不採用）
- CODEX_HOME / OpenCode インスタンス分離検証（Phase 6 PARA-04）
- ht-mcp 非ブロッキングキー注入 API（upstream の関心事）
- result ファイル存在チェック（covenant 沈黙失敗検出 — 将来フェーズ）
