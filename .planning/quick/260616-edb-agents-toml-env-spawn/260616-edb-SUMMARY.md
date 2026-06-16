---
phase: quick-260616-edb
plan: 01
subsystem: config
tags: [rust, agent-profile, env-injection, mcp, spawn]

dependency_graph:
  requires:
    - phase: 04-01
      provides: "AgentProfile struct"
    - phase: 04-02
      provides: "McpClient::spawn, Worker::boot"
  provides:
    - "AgentProfile.env フィールド (HashMap<String,String>, #[serde(default)])"
    - "apply_env_defaults() — var_os チェックで未設定キーのみ .env() 適用"
    - "McpClient::spawn(program, env) — env 引数追加・フィールド保持"
    - "McpClient::respawn — self.env を再利用して同一 env で再 spawn"
    - "Worker::boot — profile.env を McpClient::spawn に渡す"
  affects:
    - src/profile.rs
    - src/mcp.rs
    - src/worker.rs
    - agents/claude.toml
    - agents/codex.toml
    - README-MULTI-AGENT.md
    - README.md

tech_stack:
  added: []
  patterns:
    - "profile.env (#[serde(default)] HashMap<String,String>) — [env] テーブルなし TOML が空マップになる後方互換"
    - "apply_env_defaults(cmd, env): var_os(k).is_none() のキーのみ .env(k,v) — 既存 env > profile default"
    - "McpClient.env フィールドで spawn 時の env を保持し respawn で再利用"

key_files:
  created: []
  modified:
    - src/profile.rs
    - src/mcp.rs
    - src/worker.rs
    - src/turn.rs
    - agents/claude.toml
    - agents/codex.toml
    - README-MULTI-AGENT.md
    - README.md

key_decisions:
  - "apply_env_defaults を mcp.rs の pub(crate) 純粋関数として切り出し、単体テストを実プロセス起動なしで実施"
  - "McpClient に env: HashMap<String,String> フィールドを追加し spawn 時に保存、respawn で clone して再利用"
  - "turn.rs の make_profile ヘルパーに env: HashMap::new() を追加（コンパイル修正・Rule 3）"

metrics:
  duration: "約 10 分"
  completed: "2026-06-16"
  tasks_completed: 2
  files_modified: 8
---

# Quick Task 260616-edb: agents/toml [env] spawn 注入 Summary

**AgentProfile.env フィールド追加と McpClient::spawn への env 引数導入で、agents/<name>.toml の [env] テーブルから ht-mcp 子プロセスへ環境変数を既定値として注入できるようになった**

---

## Accomplishments

### Task 1: AgentProfile.env + McpClient env 注入 + worker 配線 (`0c77cfd`)

- **src/profile.rs:** `pub env: HashMap<String, String>` を `#[serde(default)]` 付きで追加。`deny_unknown_fields` 下でも `env` は既知フィールドとして受理。
  - テスト `env_defaults_to_empty_when_absent`: [env] なし TOML → 空マップ確認（後方互換）
  - テスト `env_table_parses_into_map`: [env] テーブル付き TOML → 2 エントリ値一致確認
- **src/mcp.rs:** `apply_env_defaults(cmd: &mut Command, env: &HashMap<String,String>)` を `pub(crate)` 関数として追加。`var_os(k).is_none()` のキーのみ `.env(k,v)` 適用（リテラルのみ・展開なし）。
  - `McpClient::spawn` シグネチャを `spawn(program: &str, env: &HashMap<String,String>)` に変更
  - `McpClient` に `env: HashMap<String, String>` フィールドを追加し spawn 時に保存
  - `respawn` は `self.env.clone()` を新 spawn に渡し、同一 env を継承
  - `from_streams`（#[cfg(test)]）は `env: HashMap::new()` で初期化
  - テスト `apply_env_defaults_skips_already_set_keys_and_applies_unset_keys`: 設定済みキーはスキップ・未設定キーは適用を検証
- **src/worker.rs:** `boot()` 内の `McpClient::spawn(ht_mcp_path)` を `McpClient::spawn(ht_mcp_path, &profile.env)` に変更。respawn 経路は McpClient が env を保持するため追加変更不要。

### Task 2: agents/*.toml コメント例 + ドキュメント追記 (`3668892`)

- **agents/claude.toml:** `[env]` の使用例コメント（MY_VAR = "value"）を末尾に追加（全行コメントアウト）
- **agents/codex.toml:** `[env]` コメント例と CODEX_HOME 利用例を末尾に追加（全行コメントアウト）
- **README-MULTI-AGENT.md:** プロファイルフィールド表に `[env]` 行追加。instances.conf との優先関係（`instances.conf` > profile `[env]`）を補足
- **README.md:** 「エージェントの追加・設定」セクションに profile env 対応の説明（2 文）を追記

---

## Verification Results

| Check | Result |
|-------|--------|
| `cargo test --release` 全グリーン | 42/42 pass |
| `env_defaults_to_empty_when_absent` | PASS |
| `env_table_parses_into_map` | PASS |
| `apply_env_defaults_skips_already_set_keys_and_applies_unset_keys` | PASS |
| `cargo fmt --check` | 無警告 |
| `cargo clippy --all-targets --release -- -D warnings` | 無警告 |
| `grep -q 'env' agents/claude.toml && grep -q 'env' agents/codex.toml && grep -q '\[env\]' README-MULTI-AGENT.md && grep -qi 'env' README.md` | OK |

---

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | AgentProfile.env + McpClient env 注入 + worker 配線 | `0c77cfd` | src/profile.rs, src/mcp.rs, src/worker.rs, src/turn.rs |
| 2 | agents/*.toml コメント例 + ドキュメント追記 | `3668892` | agents/claude.toml, agents/codex.toml, README-MULTI-AGENT.md, README.md |

---

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] turn.rs の make_profile ヘルパーが AgentProfile::env フィールド不足でコンパイルエラー**

- **Found during:** Task 1 (`cargo test --release`)
- **Issue:** `src/turn.rs` の `make_profile` ヘルパーが AgentProfile を struct リテラルで構築しており、`env` フィールド追加後に E0063 コンパイルエラーが発生。
- **Fix:** `make_profile` に `env: std::collections::HashMap::new()` を追加
- **Files modified:** src/turn.rs
- **Committed in:** 0c77cfd (Task 1 コミットに含む)

**2. [Rule 1 - Bug] 新規テスト `env_table_parses_into_map` で `cmd` キーを使用していたが実フィールド名は `command`**

- **Found during:** Task 1 (`cargo test --release` で 1 テスト失敗)
- **Issue:** テスト内の TOML に `cmd = ["claude"]` と書いたが、`deny_unknown_fields` 下で `cmd` は未知フィールドとして拒否される（正しくは `command`）。
- **Fix:** テスト TOML を `command = ["claude"]` に修正
- **Files modified:** src/profile.rs
- **Committed in:** 0c77cfd

---

## Known Stubs

なし — [env] テーブルは実機能として完全に配線済み。TOML コメント例は `#` でコメントアウトされており意図的な非アクティブ状態（既存挙動に影響なし）。

## Threat Surface Scan

新規ネットワークエンドポイント・認証パス・スキーマ変更なし。`apply_env_defaults` は `var_os` チェックのみで書き込みは `.env()` 呼び出しのみ（子プロセス spawn 前）。環境変数の値はリテラルのみで `eval` 不使用 — コマンドインジェクション面はなし。

## Self-Check: PASSED

- src/profile.rs: FOUND
- src/mcp.rs: FOUND
- src/worker.rs: FOUND
- agents/claude.toml: FOUND
- agents/codex.toml: FOUND
- README-MULTI-AGENT.md: FOUND
- README.md: FOUND
- commit 0c77cfd: FOUND
- commit 3668892: FOUND
