---
phase: quick-260616-edb
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/profile.rs
  - src/mcp.rs
  - src/worker.rs
  - agents/claude.toml
  - agents/codex.toml
  - README-MULTI-AGENT.md
  - README.md
autonomous: true
requirements: [QUICK-260616-edb]

must_haves:
  truths:
    - "[env] 無しの既存 TOML は従来どおりパースでき、env は空マップになる"
    - "agents/<name>.toml の [env] テーブルが AgentProfile.env (HashMap<String,String>) に読み込まれる"
    - "ht-mcp 子プロセス spawn 時、profile.env の各 (k,v) は環境に未設定のキーのみ適用される（既存 env > profile default）"
    - "respawn（/restart 経路）でも boot と同じ profile.env が ht-mcp 子プロセスに適用される"
    - "${VAR} 等の展開は行わず文字列リテラルがそのまま環境変数値として設定される"
  artifacts:
    - path: "src/profile.rs"
      provides: "AgentProfile.env フィールド (#[serde(default)] HashMap<String,String>) + パーステスト"
      contains: "pub env"
    - path: "src/mcp.rs"
      provides: "McpClient::spawn が env マップを受け取り、未設定キーのみ .env() 適用 + env を保持して respawn で再利用"
      contains: "var_os"
    - path: "src/worker.rs"
      provides: "boot で profile.env を McpClient::spawn に渡す"
  key_links:
    - from: "src/worker.rs"
      to: "McpClient::spawn"
      via: "profile.env をマップ引数として渡す"
      pattern: "spawn\\([^)]*env"
    - from: "src/mcp.rs respawn"
      to: "McpClient::spawn"
      via: "保持した env を再 spawn に渡す"
      pattern: "var_os"
---

<objective>
agents/<name>.toml に `[env]` テーブルを追加し、エージェント spawn 時に環境変数を注入できるようにする。
profile.env を ht-mcp 子プロセスの環境へ「既定値」として適用し、ht-mcp が spawn するエージェントへ継承させる。

Purpose: instances.conf や ambient env で未設定のキーに対してプロファイル単位の既定環境変数を与え、
エージェントごとの設定（例: CODEX_HOME）を TOML で宣言的に管理できるようにする。eval 不使用・リテラルのみ。
Output: AgentProfile.env フィールド、env 注入対応の McpClient::spawn/respawn、worker boot 経路の配線、TOML 例コメント、ドキュメント追記。
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md

# 実装対象（インターフェイス把握済み）
@src/profile.rs
@src/mcp.rs
@src/worker.rs
@agents/claude.toml
@agents/codex.toml
@README-MULTI-AGENT.md
@README.md

# Locked design（変更不可・再検討不要）:
# 1. 書式: [env] テーブル = key=value マップ。serde では HashMap<String,String> に #[serde(default)]。
#    AgentProfile は #[serde(deny_unknown_fields)] なので env を struct フィールドとして追加する。
# 2. 優先順位: profile env は既定値。std::env::var_os(k).is_none() のときだけ .env(k, v)（既存 env > default）。
# 3. 値: リテラルのみ。${VAR} 展開なし。
# 4. 注入機構: profile.env を ht-mcp 子プロセス環境へ設定し、ht-mcp が spawn するエージェントへ継承。
#    ht-mcp API 拡張・create_session 引数変更は不要。
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: AgentProfile.env + McpClient env 注入 + worker 配線</name>
  <files>src/profile.rs, src/mcp.rs, src/worker.rs</files>
  <behavior>
    - profile.rs: [env] 無しの既存 minimal TOML をパースすると profile.env が空マップになる（後方互換）。
    - profile.rs: [env] テーブル（例 FOO="bar", BAZ="qux"）を持つ TOML をパースすると profile.env に 2 エントリが入り値が一致する。
    - profile.rs: deny_unknown_fields 下でも env は既知フィールドとして受理される（パース成功）。
    - mcp.rs: McpClient::spawn に env マップを渡したとき、環境に未設定のキーは適用され、std::env で既に設定済みのキーは上書きしない
      （var_os(k).is_none() のときだけ .env(k,v)）。実プロセス起動を避け、env 適用ロジックを純粋関数に切り出して単体テスト可能にする。
  </behavior>
  <action>
src/profile.rs: AgentProfile に `pub env: std::collections::HashMap<String, String>` を追加し、直前に
`#[serde(default)]` 属性と日本語 doc コメント（「エージェント spawn 時に ht-mcp 子プロセスへ注入する環境変数の既定値マップ。
既存 env（instances.conf / ambient）に存在するキーは上書きしない。リテラルのみ・展開なし」）を付ける。
struct は #[serde(deny_unknown_fields)] のままで良い（env は既知フィールドになる）。
既存テストの minimal_valid_toml は [env] を含まないため、env が空マップになることを確認するテストを追加
（例: `env_defaults_to_empty_when_absent`）。さらに [env] テーブル付き TOML をパースして 2 エントリの値一致を確認するテスト
（例: `env_table_parses_into_map`）を追加する。

src/mcp.rs: `McpClient::spawn` のシグネチャを `pub async fn spawn(program: &str, env: &std::collections::HashMap<String, String>) -> Result<Self>` に変更する。
Command 構築後、env の各 (k,v) について `if std::env::var_os(k).is_none() { cmd.env(k, v); }` を適用してから .spawn() する（locked #2、リテラルそのまま）。
env > default の判定ロジックは純粋関数 `fn apply_env_defaults(cmd: &mut Command, env: &HashMap<String,String>)` 等に切り出し、
実プロセス起動なしで挙動を検証できるようにする（既存 env キーはスキップ・未設定キーは適用、を assert）。
respawn が同じ env を再利用できるよう、McpClient に `env: HashMap<String, String>` フィールドを追加し spawn 時に保存する。
from_streams（#[cfg(test)]）は env: HashMap::new() で初期化する。Restartable::respawn の内部 `McpClient::spawn(ht_mcp_path)` 呼び出しを
`McpClient::spawn(ht_mcp_path, &self.env)` に変更し、新 client が同じ env を引き継ぐ（spawn が再保存するため *self = new で一貫）。
respawn シグネチャ自体は変更不要（self.env を使う）。FakeMcp の respawn は no-op のままで変更不要。
新たな use（std::collections::HashMap）を追加する。日本語コメントを付ける。

src/worker.rs: boot（worker.rs:38）の `McpClient::spawn(ht_mcp_path)` を `McpClient::spawn(ht_mcp_path, &profile.env)` に変更する。
respawn 経路は McpClient が env を保持するため追加変更不要（restart は self.client.respawn を呼ぶだけ）。
日本語コメントで「profile.env を ht-mcp 子プロセスへ既定値として注入」と明記する。
  </action>
  <verify>
    <automated>cargo test --release -p ht-webif 2>/dev/null || cargo test --release</automated>
  </verify>
  <done>
    cargo test --release が全グリーン。profile.env の空マップ後方互換テストと [env] パーステストが pass。
    mcp.rs の env 適用ロジック（未設定キーのみ .env）の単体テストが pass。
    cargo fmt --check と cargo clippy --all-targets -- -D warnings が無警告で通る。
  </done>
</task>

<task type="auto">
  <name>Task 2: agents/*.toml の [env] 例コメント + ドキュメント追記</name>
  <files>agents/claude.toml, agents/codex.toml, README-MULTI-AGENT.md, README.md</files>
  <action>
agents/codex.toml: 「多重インスタンス運用」コメント付近、もしくはモデル選択コメント例の下に、[env] の使用例をコメントで示す。
実値は追加せず（spawn 挙動を変えない）コメント例にとどめる。例:
`# [env] で環境変数を spawn 時に注入できる（未設定キーのみ適用＝既定値、リテラルのみ・展開なし）。`
`# 例: CODEX_HOME を [env] でも指定できる（instances.conf KEY=VALUE が設定済みならそちらが優先）。`
`# [env]`
`# CODEX_HOME = "/home/youruser/.codex-inst1"`
（先頭 # でコメントアウトし既存挙動を変えないこと。ユーザ名はプレースホルダ /home/youruser/...）。
プロファイル先頭コメントの口調・スタイルに合わせる。

agents/claude.toml: テンプレートとして最小の [env] コメント例を末尾（model 選択コメントの下）に追加する。例:
`# 環境変数の注入（任意・未設定キーのみ適用される既定値、リテラルのみ）`
`# [env]`
`# MY_VAR = "value"`
（全行コメントアウト）。

README-MULTI-AGENT.md: 「プロファイルのフィールド」表（51-62行付近）に `[env]` 行を追加する。例:
`| `[env]` | spawn 時に ht-mcp 子プロセスへ注入する環境変数マップ（既定値）。既存 env（instances.conf / ambient）に存在するキーは上書きしない。値はリテラルのみ（${VAR} 展開なし） |`
表の直後、または探索順セクションの前に instances.conf との関係を 1〜2 文で補足する:
「instances.conf の KEY=VALUE は launcher が ht-webif の env に export し、それが既存値として profile [env] より優先される。
profile [env] は未設定キーの既定値として働く（env > default）。」

README.md: 「エージェントの追加・設定」セクション（203 行付近）に profile の env 対応を 1〜2 行で追記する。例:
「`agents/<name>.toml` に `[env]` テーブルを書くと、spawn 時に ht-mcp 子プロセスへ環境変数を既定値として注入できる
（未設定キーのみ・リテラルのみ、`instances.conf` の KEY=VALUE が設定済みならそちらが優先）。」
Codex の CODEX_HOME 記述（157-171 行付近）があれば、[env] でも指定できる旨を 1 行添えてもよい（任意）。
  </action>
  <verify>
    <automated>grep -q 'env' agents/claude.toml && grep -q 'env' agents/codex.toml && grep -q '\[env\]' README-MULTI-AGENT.md && grep -qi 'env' README.md && echo OK</automated>
  </verify>
  <done>
    agents/claude.toml と agents/codex.toml に [env] のコメント例が入り（全行コメントアウトで既存挙動不変）、
    README-MULTI-AGENT.md のフィールド表に [env] 行と instances.conf 優先関係の説明があり、
    README.md に profile env 対応の追記がある。cargo test --release が依然グリーン（TOML が壊れていないこと）。
  </done>
</task>

</tasks>

<verification>
- cargo test --release 全グリーン（既存テスト + 新規 env テスト）。
- cargo fmt --check 通過、cargo clippy --all-targets -- -D warnings 無警告。
- [env] 無しの既存 agents/*.toml が従来どおり起動・パースできる（後方互換）。
- profile.env が未設定キーのみ ht-mcp 子プロセスへ適用される（既存 env を上書きしない）。
</verification>

<success_criteria>
- AgentProfile.env が #[serde(default)] HashMap<String,String> として追加され、[env] 無し TOML が空マップでパースできる。
- McpClient::spawn が env マップを受け取り、std::env::var_os(k).is_none() のキーのみ .env(k,v) を適用する。
- McpClient が env を保持し、respawn（/restart 経路）で同じ env を再利用する。
- worker boot が profile.env を spawn に渡す。
- agents/claude.toml・agents/codex.toml に [env] コメント例、README-MULTI-AGENT.md と README.md に [env] のドキュメント追記。
- 全テスト・fmt・clippy グリーン、既存挙動非互換なし。
</success_criteria>

<output>
Create `.planning/quick/260616-edb-agents-toml-env-spawn/260616-edb-SUMMARY.md` when done
</output>
