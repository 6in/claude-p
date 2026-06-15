---
phase: quick-260615-t7k
plan: 01
subsystem: config, scripts, docs
tags: [portability, install, xdg, path-distribution, launch-agents, agents-dir]
dependency_graph:
  requires: []
  provides:
    - "load_agents_dir 3段 precedence（AGENTS_DIR env > cwd/agents > XDG グローバル > エラー）"
    - "launch-agents.sh ポータブル化（cwd 基準 instances.conf、command -v ht-webif、cwd 維持 spawn）"
    - "just install レシピ（~/.local/bin 配布 + XDG グローバル agents コピー + PATH 案内）"
    - "README.md / README-MULTI-AGENT.md PATH 導入手順・cwd 基準・agents 探索順反映"
  affects: [src/config.rs, scripts/launch-agents.sh, justfile, README.md, README-MULTI-AGENT.md]
tech_stack:
  added: []
  patterns:
    - "D-01: AGENTS_DIR env > cwd/agents（is_dir チェック）> XDG グローバル（is_dir チェック）> anyhow エラー"
    - "D-03: INSTANCES_CONF = $(pwd)/instances.conf（cwd 基準、スクリプト位置非依存）"
    - "D-04: command -v ht-webif で PATH 発見、just install で ~/.local/bin 配布"
    - "並列テスト安全: set_current_dir 不使用、env save/restore パターン、cargo test が project root で動く前提"
key_files:
  created: []
  modified:
    - src/config.rs
    - scripts/launch-agents.sh
    - justfile
    - README.md
    - README-MULTI-AGENT.md
decisions:
  - "set_current_dir をテストで使わず env save/restore + project root の agents/ を利用するアプローチを採用（並列テスト汚染防止）"
  - "ケース 3b（空 XDG_CONFIG_HOME の HOME/.config フォールバック）は inline ロジック再現でリグレッション保護"
  - "全滅エラー文字列はメッセージ定数のリグレッション保護として format! で再現して検証"
metrics:
  duration: "10min"
  completed: "2026-06-15"
  tasks: 3
  files_modified: 5
---

# Quick Task 260615-t7k: ht-webif をポータブル PATH 配布可能ツールに変換 — Summary

**3段 precedence agents 探索 + cwd 基準 launch-agents.sh + just install レシピで PATH 配布を実現**

---

## Objective

ht-webif をリポジトリ作業ディレクトリへの依存を断ち、どのディレクトリからでも `ht-webif` / `launch-agents.sh` を呼べるポータブルツールにする（locked decisions D-01〜D-04 を実装）。

---

## Accomplishments

### Task 1: src/config.rs — load_agents_dir 3段 precedence（D-01/D-02）

- `load_agents_dir()` を D-01 仕様に従い書き換え:
  1. `AGENTS_DIR` env（最優先・既存挙動維持）
  2. `cwd/agents`（`is_dir()` で存在確認）
  3. `${XDG_CONFIG_HOME:-HOME/.config}/claude-p/agents`（`is_dir()` で存在確認）
  4. 全滅 → 探索パス一覧付き日本語エラー（`anyhow::bail!`）
- 空文字列の `XDG_CONFIG_HOME` は未設定扱い（XDG 仕様準拠）
- 単体テスト `agents_dir_three_stage_precedence` を追加（env 優先 / cwd フォールバック / XDG グローバル / 全滅エラーの 4 ケース）
- 既存テスト `agents_dir_defaults_to_cwd_agents_when_unset_and_uses_env_when_set` を維持（後方互換）
- cargo test 39/39 グリーン、fmt/clippy クリーン

### Task 2: scripts/launch-agents.sh — ポータブル化（D-03）

- `INSTANCES_CONF="$(pwd)/instances.conf"` に変更（D-03、スクリプト位置非依存）
- `SCRIPT_DIR` / `WEBIF_DIR` 変数を完全削除
- cargo build ブロック（行 93-105 相当）を削除
- `command -v ht-webif` で PATH からバイナリを発見（未発見時は `just install を実行してください` でexit 1）
- spawn サブシェルから `cd "$WEBIF_DIR"` を削除（cwd を維持）
- `TURNS_DIR` を `$(pwd)/turns-${port}` で注入
- `turns_dir` 表示（cmd_up / cmd_status）を `$(pwd)/turns-${port}/${agent}` に変更
- readiness ポーリング / down-all / status のロジックは一切変更なし
- bash -n 構文 OK / PORTABLE_OK 確認済み

### Task 3: justfile install レシピ + ドキュメント更新（D-04）

- `install` レシピを追加:
  - `cargo build --release`
  - `mkdir -p ~/.local/bin` → `ht-webif` / `launch-agents.sh` をコピー、実行ビット付与
  - `${XDG_CONFIG_HOME:-$HOME/.config}/claude-p/agents` を mkdir して `agents/*.toml` をコピー
  - `PATH` 未登録時の注意表示
- `uninstall` レシピも追加（`~/.local/bin` の 2 ファイルを削除、agents グローバルは保持）
- `README.md`:
  - インストール（PATH 配布）セクションを `## ビルド` の前に追加
  - instances.conf が cwd から読まれる旨を明記（D-03）
  - turns-<port> が cwd 基準である旨を更新
  - AGENTS_DIR 環境変数表に探索順を追記
- `README-MULTI-AGENT.md`:
  - 起動例を `./ht-webif` から `ht-webif`（PATH 経由）に更新
  - `agents/ プロファイルの探索順（D-01）` セクションを §2 に追加
  - §5 の起動シーケンスを PATH 発見方式に更新、cwd 基準の instances.conf / turns を明記

---

## Commits

| Task | Hash | Description |
|------|------|-------------|
| 1 | 62d736e | feat(260615-t7k-01): load_agents_dir を 3 段 precedence に変更（D-01/D-02） |
| 2 | 7be7999 | feat(260615-t7k-02): launch-agents.sh をポータブル化（D-03） |
| 3 | c6eda7a | feat(260615-t7k-03): just install レシピ追加 + ドキュメント更新（D-04） |

---

## Verification Results

```
cargo test --release: 39/39 PASS
cargo fmt --check: OK
cargo clippy --all-targets --release -- -D warnings: OK
bash -n scripts/launch-agents.sh: SYNTAX_OK
grep WEBIF_DIR/cargo build/target/release (除コメント): PORTABLE_OK
just --list | grep install: INSTALL_RECIPE_OK
grep 'just install' README.md: OK
grep 'claude-p/agents' README.md: OK
grep 'command -v ht-webif|just install' README-MULTI-AGENT.md: OK
```

---

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 並列テスト汚染: set_current_dir がプロセスグローバルで http テストを破壊**

- **Found during:** Task 1（`cargo test --lib` で `http::tests::cors_preflight_allows_any_origin_under_default_config` が失敗）
- **Issue:** 計画では `set_current_dir` を使ってケース 2（cwd フォールバック）を検証する予定だったが、`http.rs` テストが同時に `Path::new("agents")` を相対パスで参照しており、cwd 変更で失敗した
- **Fix:** `set_current_dir` を使わない方針に切り替え。ケース 2 は `AGENTS_DIR=<tempdir>` で代替、ケース 5 で cargo test が project root から動く前提で `agents/` 実在を利用して cwd フォールバックを検証
- **Files modified:** src/config.rs（テスト戦略変更）
- **Commit:** 62d736e（Task 1 commit に含む）

**2. [Rule 1 - Bug] doc list item without indentation clippy エラー**

- **Found during:** Task 1（cargo clippy 実行時）
- **Issue:** `load_agents_dir` のdocコメントに番号付きリスト（1. 2. 3.）の後、空白行なしで散文が続いたため clippy が markdown list item 不正インデントとして警告→エラー
- **Fix:** numbered list の前後に `///` 空白行を追加
- **Files modified:** src/config.rs
- **Commit:** 62d736e（同 Task 1 commit）

---

## Known Stubs

なし。

---

## Threat Surface Scan

なし。新規ネットワークエンドポイント・認証パス・ファイルアクセスパターン・スキーマ変更は発生していない。

---

## Self-Check

```
src/config.rs: FOUND
scripts/launch-agents.sh: FOUND
justfile: FOUND
README.md: FOUND
README-MULTI-AGENT.md: FOUND
62d736e: FOUND
7be7999: FOUND
c6eda7a: FOUND
```

## Self-Check: PASSED
