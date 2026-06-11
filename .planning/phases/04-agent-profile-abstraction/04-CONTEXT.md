# Phase 4: Agent Profile Abstraction - Context

**Gathered:** 2026-06-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Claude 固有のハードコードを `agents/claude.toml` プロファイルに抽出する**純粋リファクタ（挙動変化なし）**。`AGENT=<name>` 環境変数でプロファイルを選択し、TOML ファイル追加のみ（Rust リビルド不要）で新エージェントを認識できる状態にする。対象要件は PROF-01〜06。

抽出対象のハードコードは **5 箇所**（研究の 4 箇所 + 議論で発見した 1 箇所）:
1. spawn コマンド `["claude"]` — `src/mcp.rs:194`
2. ready 検知 `contains("auto mode")` + 起動待ち 25s — `src/worker.rs:42,45`（同パターン計 3 instance）
3. `fresh:true` → `/clear` 送信 — `src/turn.rs:55`
4. 出力規約（output covenant）日本語フッタ — `src/turn.rs:27-31`
5. **トリガーメッセージ** `"{prompt_path} を読んで、その指示に従ってください。"` — `src/turn.rs:47-50`（議論で追加決定）

Codex/OpenCode の実プロファイル作成・実機検証は Phase 5、`GET /info` と多重インスタンス tooling は Phase 6。本フェーズには含めない。

**注意（既知のドキュメント齟齬）:** `.planning/codebase/*.md` のマップは v1.0 時点の `webif/src/` パスを参照しているが、現在コードはリポジトリ直下 `src/` にある。`.planning/research/ARCHITECTURE.md` のファイル/行参照が現状と一致する正。

</domain>

<decisions>
## Implementation Decisions

### プロファイル探索・解決
- **D-01:** 探索場所は CWD 相対 `./agents/<name>.toml` を既定とし、`AGENTS_DIR` 環境変数で上書き可能。`.env` / `TURNS_DIR` と同じ「env 優先 + CWD 相対デフォルト」パターンに揃える。
- **D-02:** `agents/claude.toml` が見つからない場合も（unknown エージェントと同様に）**即エラー終了**。組み込みフォールバック（`include_str!` 等）は作らない — TOML ファイルが唯一の真実源で、二重管理ドリフトを構造的に排除する。
- **D-03:** プロファイル不在エラーには **探索パス + 利用可能プロファイル一覧**（`agents/` をスキャンして `<name>` 列挙）を含める。スキャン自体が失敗したら探索パスのみ表示にフォールバック。
- **D-04:** `agents/test.toml`（Success Criteria 4 検証用）はリポジトリにコミットせず、**テスト内で tempdir に動的生成**して hermetic に検証（Phase 3 の FakeMcp/tempfile パターン踏襲）。リポの `agents/` は `claude.toml` のみ。UAT では手動で bash 等を spawn する test.toml を置いて確認する。

### TOML スキーマ設計
- **D-05:** `ready_pattern` は**部分文字列一致**（現行 `contains()` と同一セマンティクス）。regex クレートは追加しない — 新規依存は `toml = "1"` のみという research/STACK.md の方針を維持。Phase 5 で ANSI 分断が実測されたらその時点で regex 化を検討（TOML 値はそのまま流用可能）。
- **D-06:** 必須/任意の線引きは「**挙動フィールド必須・チューニング値任意**」: `command` / `ready_pattern` / `fresh_mode` / `clear_command` / `output_covenant` / `trigger_template` は必須（デフォルトで Claude の値が漏れ出ることがない）。`startup_timeout_secs`（デフォルト 25）/ `turn_timeout_secs`（デフォルト 300）は任意 + 現行デフォルト（PROF-05 の文面通り）。
- **D-07:** serde `deny_unknown_fields` で**未知キーは起動時に拒否**（typo 即検出）。プロファイルはバイナリと同一リポでバージョン管理されるため前方互換の懸念は実質なし。
- **D-08:** スキーマは **Phase 4 で配線するフィールドのみ**定義。`wedge_pattern` / `prerequisite_check` は Phase 5 の実機検証で必要性と仕様が確定してから追加（serde の任意フィールド追加は後方互換）。`extra_args` 専用フィールドは作らない — `command` が `Vec<String>` なので `["codex", "--yolo"]` のように配列に直接書く。

### output_covenant / trigger_template テンプレート
- **D-09:** プレースホルダ記法は `{result_path}` / `{status_path}` / `{prompt_path}`（現行 `format!` と同じ見た目）。実装は `str::replace` のみ — テンプレートエンジン不要。TOML 側は basic multiline string (`"""..."""`)。
- **D-10:** トリガーメッセージ（`src/turn.rs:47-50`）も `trigger_template` として**必須フィールド化**。エージェントに見える文字列を漏れなく TOML に集約し、Phase 5 で Codex 向けに英語化できるようにする（PROF-06 の「TOML 追加だけで新エージェント」理念に整合）。
- **D-11:** **起動時にプレースホルダ存在を検証**: `output_covenant` に `{result_path}` と `{status_path}`、`trigger_template` に `{prompt_path}` が無ければ anyhow エラーで即終了。欠落するとタイムアウトとして顕在化する最悪の事故パターンを起動時に殺す。
- **D-12:** **ゴールデンテストで v1.0 同一性を固定**: v1.0 の `format!` 出力を期待値としてテストに埋め込み、`agents/claude.toml` 経由の `build_prompt_body` 出力（およびトリガー文）がバイト一致することを assert。既存の build_prompt_body テスト（v1.0 D-11）の自然な拡張。

### 上書きフィールドの形 (PROF-05)
- **D-13:** model 選択は任意フィールド `model_flag` + `model_value`（例 `"--model"` / `"opus"`）。指定時のみ spawn コマンドへ追加、未指定なら何も付加しない（現行デフォルト）。`agents/claude.toml` にはコメントアウト例として記載。
- **D-14:** `MCP_TIMEOUT`（30s）は**グローバル定数のまま**。ht-mcp トランスポート層の wedge 対策でありエージェントの個性ではない。プロファイルは「エージェント固有の挙動」だけを持つ境界を維持。
- **D-15:** **TOML 値への環境変数上書きは設けない**。env = インスタンスのインフラ（`AGENT` / `AGENTS_DIR` / `PORT` / `TURNS_DIR` / `HT_MCP_PATH` / `CORS_ORIGINS`）、TOML = エージェントの挙動、の 2 層で固定。「この値はどこで決まる？」が常に一意。
- **D-16:** `TURNS_DIR` は**明示指定時も常に `<agent-name>` サブディレクトリを付与**（`TURNS_DIR=/data/turns` → 実際の書き込み先 `/data/turns/claude/`）。未設定時デフォルトは `./turns/<agent-name>/`。コリジョン安全性を構造的に保証する一貫方針（ユーザが推奨案を退けて選択）。**v1.0 の明示 TURNS_DIR 運用とは非互換** — README に挙動変更を明記すること。起動バナー等で実際の turns ディレクトリをログ出力すると驚きを軽減できる。

### Claude's Discretion
- `AgentProfile` 構造体のフィールド順・doc コメント・モジュール内部構成（`src/profile.rs`）
- ゴールデンテストの配置（profile.rs / turn.rs のどちらの `#[cfg(test)]` に置くか）
- エラーメッセージの具体的文言（日本語、`anyhow` コンテキスト — 既存 conventions 準拠）
- `fresh_mode = "respawn"` の実装詳細（PROF-04 で要求される kill+再生成パス。FakeMcp でのテスト方法含む）
- 利用可能プロファイル一覧スキャンの実装（`std::fs::read_dir` で十分）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase boundary / requirements
- `.planning/ROADMAP.md` §"Phase 4: Agent Profile Abstraction" — Goal / Success Criteria 5 件（挙動等価・TOML 置換・unknown エラー・リビルド不要・11 テストグリーン）
- `.planning/REQUIREMENTS.md` §"プロファイル機構（PROF）" — PROF-01〜06 の文面 + Out of Scope（per-request 切替・JSON Schema バリデーション）

### v2.0 リサーチ（実装指針 — 最重要）
- `.planning/research/SUMMARY.md` — 推奨アプローチ全体像。`AgentProfile` 値型・`toml = "1"` 唯一の新規依存・Phase 1 exit criterion
- `.planning/research/ARCHITECTURE.md` — ファイル/行レベルの変更マップ（`src/profile.rs` 新規、`worker.rs`/`turn.rs`/`mcp.rs`/`config.rs` 修正、`create_session(command: &[String])` trait 変更）。**注: 現コードは `src/` 直下（`webif/` プレフィックスなし）**
- `.planning/research/STACK.md` — `toml = "1"` 採用根拠と代替案（figment/config crate）棄却理由
- `.planning/research/PITFALLS.md` — Pitfall 1（ready 検知の脆さ）/ 2（covenant 非可搬）/ 4（fresh divergence）/ 5（turns/ コリジョン）が Phase 4 設計に直結
- `.planning/research/FEATURES.md` — プロファイルスキーマのフィールド一覧と複雑度

### Project-level invariants
- `.planning/PROJECT.md` §"Constraints" / §"Key Decisions" — `-p` 不使用・stdio MCP・1 worker = 1 TUI・単一ホスト
- `HT-PROTOCOL.md` §3-§7 — turnId 規格・3 ファイル方式・status 出現 = 完了センチネル（プロファイル化しても不変のプロトコル）

### Existing implementation surface（現行ハードコード位置）
- `src/mcp.rs:192-195` — `create_claude_session` / `ht_create_session` の `["claude"]`（trait シグネチャ変更対象）
- `src/worker.rs:38-50` — `spawn_session` の 25s deadline + `"auto mode"` 検知（ready_pattern / startup_timeout_secs 化対象）
- `src/turn.rs:22-36` — `build_prompt_body` の出力規約フッタ（output_covenant 化対象 + ゴールデンテスト期待値の出典）
- `src/turn.rs:47-58` — トリガーメッセージ + `fresh` 時の `/clear`（trigger_template / clear_command / fresh_mode 化対象）
- `src/config.rs` — `TURN_TIMEOUT` / `MCP_TIMEOUT` 定数と `load_*` 関数群（`load_agent_name` / `AGENTS_DIR` 読み込みの追加位置、env 読みパターンの手本）

### Prior phase decisions（テスト構造の前提）
- `.planning/milestones/v1.0-phases/03-testing-ci-automation/03-CONTEXT.md` — trait Mcp 境界（D-01〜04）・FakeMcp scripted reply 方式（D-07）・`#[cfg(test)] mod tests` co-locate 方針（D-06）・tower oneshot 統合テスト（D-08〜10）。Phase 4 のテスト追加はこの構造に従う

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **trait Mcp + FakeMcp**（`src/mcp.rs`）— `create_claude_session` → `create_session(command: &[String])` のシグネチャ変更で両実装を更新。FakeMcp の scripted reply 方式はプロファイル駆動テストにそのまま使える
- **`Worker<M: Mcp>` ジェネリック**（`src/worker.rs`）— `profile: AgentProfile` フィールド追加先。コンパイル時ディスパッチ構造は変更不要
- **`config.rs` の `load_*` パターン** — `load_agent_name()` / `load_agents_dir()` は `load_port()` / `load_turns_dir()` と同型で書ける（env > .env > デフォルト、anyhow コンテキスト）
- **既存 11 テスト** — 全部グリーン維持が Success Criteria 5。build_prompt_body テストはゴールデンテスト（D-12）の土台

### Established Patterns
- 設定は env > `.env` > デフォルトの優先順位（dotenvy、CWD 相対）— AGENTS_DIR / AGENT もこれに従う（D-01）
- エラーは `anyhow::Result` + 日本語コンテキストメッセージ — プロファイルロードエラーも同様（バリデーションは anyhow で十分、JSON Schema 不使用は REQUIREMENTS で確定）
- 識別子英語・コメント/ログ/エラー文言は日本語
- `eprintln!` + ブラケットタグ（`[worker]` 等）のログ慣行 — プロファイルロード時のログは `[profile]` タグが自然

### Integration Points
- `src/profile.rs`（新規）→ `lib.rs` にモジュール宣言追加
- `main.rs` 起動シーケンス: dotenvy → `load_agent_name()` → プロファイルロード（失敗 = 即終了）→ `Worker::new` に profile を渡す → turns ディレクトリは `<turns_base>/<agent_name>/` で作成（D-16）
- `Cargo.toml` に `toml = "1"` 追加（唯一の新規依存）
- 起動バナー（`main.rs:42-51`）にエージェント名と実際の turns パスを出すと D-16 の驚き軽減になる

</code_context>

<specifics>
## Specific Ideas

- エラーメッセージ例（D-03 の方向性）: `agents/foo.toml が見つかりません（探索: /path/to/agents/）。利用可能: claude`
- `agents/claude.toml` には各フィールドの説明コメントと `model_flag` / `model_value` のコメントアウト例を含め、新プロファイル作成時のテンプレートとして機能させる（Phase 5 で codex.toml / opencode.toml の手本になる）
- ゴールデンテストの期待値は現行 `src/turn.rs:23-35` の format! 出力をそのまま文字列リテラル化する（書き換え前にコピーしておくこと）

</specifics>

<deferred>
## Deferred Ideas

- **`wedge_pattern` / `prerequisite_check` フィールド** — Phase 5 の実機検証で仕様が固まってから追加（D-08）
- **ready_pattern の regex 化 + ANSI ストリップ** — Phase 5 で Codex の ANSI 分断が実測された場合に検討（D-05）
- **`mcp_timeout_secs` のプロファイル化** — 遅いエージェントで 30s 超の snapshot が実測されたら Phase 5 で追加（D-14）
- **タイムアウトの env 上書き（3 層化）** — 必要になったら後付け可能（D-15）
- **`GET /info` エンドポイント** — research は Phase 1 に含めていたが ROADMAP で Phase 6（PARA-01/02）に確定済み
- **result ファイル存在チェック（covenant 沈黙失敗の検出）** — research の Phase 1 推奨だが ROADMAP の Phase 4 Success Criteria 外。Phase 5 の covenant 検証と合わせて扱うのが自然
- **プロファイル hot-reload** — FUT-02 として将来マイルストーン（REQUIREMENTS 確定済み）

</deferred>

---

*Phase: 4-agent-profile-abstraction*
*Context gathered: 2026-06-11*
