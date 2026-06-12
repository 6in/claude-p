# Phase 5: Codex CLI and OpenCode Validation - Context

**Gathered:** 2026-06-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Codex CLI（v0.139.0）と OpenCode（v1.4.3）を実機で駆動し、ターンファイル方式での結果取得を **実際の `ht-webif` バイナリ + `POST /prompt` 経由の E2E** で確認する。成果物は `agents/codex.toml` / `agents/opencode.toml`（auth セットアップ手順コメント付き）、`scripts/setup-opencode.sh`、`scripts/e2e-codex.sh` / `scripts/e2e-opencode.sh`。対象要件は AGNT-01〜04。

**重要な前提:** `05-RESEARCH.md` の実証は Python スクリプトで ht-mcp を直叩きしたもの。トリガー方式・ready_pattern・covenant 遵守は HIGH confidence で検証済みだが、**ht-webif 経由のフル E2E は本フェーズで初めて通す**。

原則 **config-only フェーズ**（新規 Rust コード変更なし、`cargo test` 27 件はリグレッションチェックのみ）。`GET /info`・多重インスタンス tooling・CODEX_HOME 分離検証は Phase 6。Gemini CLI は FUT-01（将来）。

</domain>

<decisions>
## Implementation Decisions

### OpenCode fresh:true 方式（AGNT-04 / Success Criterion 4）
- **D-01:** まず実機で `clear_command = "/new"`（現行スキーマの1回送信）を試行する。研究の予想ではエージェント選択ダイアログが開いてスタックする（Enter 2回必要 — Pitfall 3）が、ht-webif 経由での実挙動を記録してから判断する。
- **D-02:** `/new` が不成立なら `fresh_mode = "respawn"` にフォールバックする。respawn は Phase 4 で実装・テスト済みのパスで Rust 変更ゼロ。clear_command の複数キー化などのスキーマ拡張は**行わない**。
- **D-03:** フォールバック確定時は ROADMAP Success Criterion 4 と REQUIREMENTS AGNT-04 の文面を**実測結果で更新**する（例:「fresh:true が respawn 方式で正常動作。/new はダイアログ要因で不採用 — 2026-06-XX 実測」）。Codex の基準 2 が既にフォールバック条項を持つのと同じパターン。ドキュメントと実態の乖離を残さない。

### /turn 前提条件の管理（AGNT-03）
- **D-04:** OpenCode のトリガーは研究で検証済みの `trigger_template = "/turn {prompt_path}"`（カスタムコマンド方式）を採用。前提となる `~/.config/opencode/commands/turn.md` は **`scripts/setup-opencode.sh` を同梱して冪等生成**する（存在すれば何もしない）。
- **D-05:** スクリプトのスコープは **turn.md 生成のみ**（単一責務）。auth 状態の確認（`codex login` / `opencode auth login` / providers 確認）は README と TOML コメントの手順記載に留める。doctor 的な環境検査スクリプトは作らない。
- **D-06:** TOML コメントには Success Criterion 5 のとおり prerequisite 手順（auth セットアップ + turn.md。`bash scripts/setup-opencode.sh` への参照）を記載する。

### E2E 検証の形態（AGNT-01〜04 の検証方法）
- **D-07:** **コミットする bash スクリプト** `scripts/e2e-codex.sh` / `scripts/e2e-opencode.sh` で検証する。各スクリプトは ht-webif を起動（`AGENT=<name>`、専用 PORT）→ `curl POST /prompt` → result/status ファイルを検査して pass/fail を返す。再実行可能で Phase 6（多重インスタンス検証）でも再利用する。
- **D-08:** CI には繋がない（実エージェント + 実課金が必要なため）。`cargo test` 27 件グリーンの維持はリグレッションチェックとして各プランで実施。
- **D-09:** 検証エビデンス（turnId・所要時間・result 内容）は GSD 標準どおり SUMMARY / VERIFICATION に記録。turns/ 配下の成果物自体はコミットしない（gitignore 済み）。

### fresh:true 合格基準（AGNT-02 / AGNT-04 の深さ）
- **D-10:** ready 復帰だけでなく**履歴隔離を実証**する: ターン1で固有の事実を伝え → `fresh:true` のターン2で「直前に何を伝えたか」を質問し、知らないことを確認する 2ターンテスト。fresh は「-p 相当（文脈リセット + 実行）」という Core Value の代理機能なので、見た目のリセットでは不十分。
- **D-11:** 履歴隔離テストは両エージェント（codex の `/clear`、opencode の `/new` または respawn）に適用し、E2E スクリプトに組み込む。研究 OQ-3（/new が本当に履歴をクリアするか）はこのテストで決着する。

### プロファイル内容（研究で確定済み — 再議論不要）
- **D-12:** `agents/codex.toml`: `cmd = ["codex", "--dangerously-bypass-approvals-and-sandbox"]`、`ready_pattern = "YOLO mode"`、`fresh_mode = "command"` + `clear_command = "/clear"`、トリガー・covenant は日本語可（実証済み）、`startup_timeout_secs = 15`。05-RESEARCH.md の Pattern 1 の TOML をベースにする。
- **D-13:** `agents/opencode.toml`: `cmd = ["opencode"]`、`ready_pattern = "Ask anything"`、`trigger_template = "/turn {prompt_path}"`、トリガー・covenant は **ASCII のみ**（ht-mcp が OpenCode 向けマルチバイトを無音破棄 — Pitfall 1）、`startup_timeout_secs = 15`。05-RESEARCH.md の Pattern 2 の TOML をベースにする（fresh_mode は D-01/D-02 の結果で確定）。

### Claude's Discretion
- E2E スクリプトの内部設計（共通部の関数化 vs 2 ファイル独立、PORT 番号の選択、タイムアウト値、wait:true と非同期ポーリングのどちらで検査するか）
- setup-opencode.sh の実装詳細（heredoc での turn.md 生成、`$XDG_CONFIG_HOME` 考慮など）
- `/new` 試行の記録形式（SUMMARY 内のセクション構成）
- TOML コメントの文言（日本語、既存 claude.toml / 研究のサンプルに準拠）
- README への追記構成（エージェント追加手順・前提条件の章立て）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 5 実証データ（最重要 — プロファイル値の出典）
- `.planning/phases/05-codex-cli-and-opencode-validation/05-RESEARCH.md` — Codex/OpenCode の実機検証結果すべて。Pattern 1/2 の TOML 草案、Pitfall 1〜7（マルチバイト破棄・/new ダイアログ・lean-ctx パス制約・inline-completion ブロックと /turn 回避策）、OQ-1〜4 の解決状況。プロファイル値はここが正

### Phase boundary / requirements
- `.planning/ROADMAP.md` §"Phase 5: Codex CLI and OpenCode Validation" — Goal / Success Criteria 5 件（D-03 で基準 4 の文面更新あり）
- `.planning/REQUIREMENTS.md` §"エージェント対応（AGNT）" — AGNT-01〜04 の文面（D-03 で AGNT-04 更新あり）

### Phase 4 の決定事項（プロファイル機構の前提）
- `.planning/phases/04-agent-profile-abstraction/04-CONTEXT.md` — D-05（ready_pattern 部分文字列）、D-08（スキーマ拡張は必要確定後）、D-09〜11（プレースホルダ規約と起動時検証）、D-16（turns は常に `./turns/<agent>/`）。Phase 5 はこのスキーマを**変更しない**
- `agents/claude.toml` — プロファイルのテンプレート（コメントスタイルの手本）
- `src/profile.rs` — AgentProfile スキーマと検証ロジック（deny_unknown_fields — 新フィールドは書けない）

### Project-level invariants
- `.planning/PROJECT.md` §"Constraints" / §"Out of Scope" — 1 worker = 1 TUI、リクエスト単位エージェント切替なし、WebIF 内ルーティングなし
- `HT-PROTOCOL.md` §3-§7 — turnId 規格・3 ファイル方式・status 出現 = 完了センチネル（エージェントが変わっても不変）

### 既知のドキュメント齟齬（Phase 4 から引き継ぎ）
- `.planning/codebase/*.md` は v1.0 時点の `webif/src/` パスを参照しているが、現在コードはリポジトリ直下 `src/` にある。ファイル/行参照は現物が正

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **AgentProfile 機構一式**（`src/profile.rs`）— Phase 4 完成済み。`load_agent_profile` / `validate_profile` / `list_available_profiles`。新 TOML を `agents/` に置くだけで認識（PROF-06 検証済み）
- **fresh_mode 両ディスパッチ**（`src/turn.rs`）— `"command"`（clear_command 送信）と `"respawn"`（kill+再生成）の両方が実装・テスト済み。D-01/D-02 の試行→フォールバックはプロファイル値の書き換えだけで切り替え可能
- **D-16 の turns サブディレクトリ** — `./turns/codex/` は自動的にプロジェクトルート内になり、Codex の lean-ctx パス制約（Pitfall 5: プロジェクト外読み取り拒否）を構造的に満たす
- **既存 27 テスト** — Rust 変更なしの前提なので全グリーン維持はリグレッションチェックのみ

### Established Patterns
- プロファイル TOML のコメント様式は `agents/claude.toml` が手本（各フィールドの説明 + コメントアウト例）
- 環境変数は env > .env > デフォルト（`AGENT` / `PORT` / `TURNS_DIR`）— E2E スクリプトはこのパターンで専用 PORT / AGENT を指定して起動する
- justfile / scripts の流儀: リポジトリ直下 `scripts/` は新設（既存は justfile のみ）。bash + `set -e` 程度の簡素な作り

### Integration Points
- `agents/codex.toml` / `agents/opencode.toml` — 新規ファイル追加のみ（Rust 変更なし）
- `scripts/setup-opencode.sh` / `scripts/e2e-codex.sh` / `scripts/e2e-opencode.sh` — 新規ディレクトリ `scripts/`
- README.md — エージェント追加手順・auth 前提・setup-opencode.sh への参照を追記
- D-03 発動時: `.planning/ROADMAP.md`（Success Criterion 4）と `.planning/REQUIREMENTS.md`（AGNT-04）の文面更新

</code_context>

<specifics>
## Specific Ideas

- E2E スクリプトの検査内容: result が非空であること + status が `{"status":"done"}` であること + （D-10）履歴隔離 2ターンテスト
- `/new` 試行（D-01）はタイムアウトを短めに設定して試し、スタックした場合のスナップショット/挙動を SUMMARY に記録してから respawn に切り替える（ターン浪費を抑える）
- turn.md の内容は研究の Working recipe どおり: frontmatter `description` + 本文 `Read the file $ARGUMENTS and follow the instructions in it.`
- 研究の実測値を TOML コメントに残す（Codex 起動 ~3s / E2E 18-27s、OpenCode 起動 4-8s / E2E ~13s）— 運用時のタイムアウト調整の参考になる

</specifics>

<deferred>
## Deferred Ideas

- **`wedge_pattern` / `prerequisite_check` スキーマフィールド** — Phase 4 D-08 で繰延。今回 prerequisite はセットアップスクリプトで対応（D-04/D-05）するため、本フェーズでもスキーマ追加しない。必要性が再浮上したら将来フェーズで
- **ready_pattern の regex 化 + ANSI ストリップ** — 研究で ANSI 分断は実測されず（部分文字列一致で両エージェント動作）。実害が出るまで現状維持（Phase 4 D-05 の条件は不成立で決着）
- **`mcp_timeout_secs` のプロファイル化** — 30s 超の snapshot は実測されず。現状維持
- **clear_command の複数キーシーケンス対応** — `/new` のダイアログ突破用スキーマ拡張案。D-02 で respawn フォールバックを選んだため不採用。将来「command 方式での /new」が必要になったら再検討
- **CODEX_HOME / OpenCode のインスタンス分離検証** — Phase 6（PARA-04）。研究 A2/A3 は Phase 6 で解決
- **ht-mcp の非ブロッキングキー注入 API（upstream issue）** — inline-completion ブロックの根本対策は ht-mcp 上流の関心事。本プロジェクトは /turn 回避策で十分（PROJECT.md Out of Scope「MCP 拡張」整合）
- **result ファイル存在チェック（covenant 沈黙失敗の検出）** — Phase 4 から繰延。E2E スクリプトがタイムアウト + ファイル検査で代替検知するため本フェーズではコード変更しない。運用上の必要が出たら将来フェーズで

</deferred>

---

*Phase: 5-codex-cli-and-opencode-validation*
*Context gathered: 2026-06-12*
