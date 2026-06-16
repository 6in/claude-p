---
phase: quick-260616-g9y
plan: 01
subsystem: scripts
tags: [bash, diagnostics, multi-agent, install, docs]
requires: [260616-fce-ma-client-sh, 260615-t7k-portable-install]
provides: [ma-doctor.sh report-only 8-section diagnostics, justfile install/uninstall ma-doctor.sh, README-MULTI-AGENT.md §6 診断節]
affects: [scripts/ma-doctor.sh, justfile, README.md, README-MULTI-AGENT.md]
tech-stack:
  added: []
  patterns:
    - "report-only フル診断: [OK]/[WARN]/[FAIL] 出力 + カウンタ集計 + サマリ末尾 + exit code（D-3）"
    - "3 段 precedence: AGENTS_DIR > cwd/agents > XDG global（src/config.rs load_agents_dir 再現）"
    - "JSON エンコーダ: jq 優先・python3 フォールバック（launch-agents.sh 踏襲）"
    - "TTY 判定カラー: [[ -t 1 ]] で ANSI 色 / 非 TTY はプレーン"
    - "set -e 下での続行: 各チェックは || true / 明示分岐で abort しない"
key-files:
  created:
    - scripts/ma-doctor.sh
  modified:
    - justfile
    - README.md
    - README-MULTI-AGENT.md
decisions:
  - "D-1 フル診断（8 セクション）: ユーザ確定済みのため変更なし"
  - "D-2 report-only: 書き込みコマンド（>, >>, tee, sed -i, mkdir, cp, rm, touch）を含まない"
  - "D-3 出力形式: FAIL >= 1 → exit 1、WARN のみ → exit 0。末尾サマリ付き"
  - "D-4 install: just install で ~/.local/bin/ma-doctor.sh にコピー、uninstall で削除"
metrics:
  duration: 5min
  completed: "2026-06-16T02:52:04Z"
  tasks: 2
  files: 4
---

# Quick 260616-g9y: ma-doctor.sh — report-only マルチエージェント診断ツール

**scripts/ma-doctor.sh を新規作成し、8 セクションの report-only フル診断（[OK]/[WARN]/[FAIL]、サマリ、exit code）を実装。justfile install/uninstall 同梱 + README 2 ファイル更新。**

## Accomplishments

### Task 1: scripts/ma-doctor.sh 新規作成

- `set -euo pipefail` + `#!/usr/bin/env bash` で bash スクリプトを作成
- 8 セクションの診断を順次実行:
  1. **インストール/PATH**: `ht-webif` / `launch-agents.sh` / `ma-client.sh` の `command -v` 確認、`$HOME/.local/bin` の PATH 登録確認
  2. **依存コマンド**: `ht-mcp` / `curl` の存在確認、`jq` または `python3` の JSON エンコーダ確認
  3. **agents プロファイル解決**: `AGENTS_DIR` > `cwd/agents` > XDG global の 3 段 precedence（`src/config.rs load_agents_dir` と完全一致）、`*.toml` 列挙、`command[0]` 抽出（python3 tomllib 優先 → grep フォールバック）
  4. **エージェントバイナリ**: 各プロファイルの `command[0]` 存在確認、bash ラッパーケースはラッパースクリプト存在も確認
  5. **認証/セットアップ**: claude (`~/.claude/.credentials.json`) / codex (`${CODEX_HOME:-~/.codex}/auth.json`) / opencode (turn.md + opencode.json)
  6. **claude フォルダ信頼**: `~/.claude.json` を read-only パースし `projects[CWD].hasTrustDialogAccepted` 確認（jq / python3）
  7. **instances.conf**: 書式パース・ポート番号形式・重複ポート・エージェントプロファイル解決確認
  8. **稼働インスタンス**: 各 (agent, port) へ `curl --max-time 3 /info` し応答確認（DOWN は情報表示のみ、カウンタ増やさない）
- カウンタ集計 (`OK_COUNT` / `WARN_COUNT` / `FAIL_COUNT`) + 末尾サマリ「診断結果: OK=N WARN=N FAIL=N」
- `FAIL_COUNT -gt 0` → `exit 1`、それ以外 → `exit 0`
- TTY 判定（`[[ -t 1 ]]`）で ANSI カラー（緑/黄/赤）、非 TTY はプレーン
- `--help` / `-h` で usage 表示（report-only・exit 1 を明記）
- read-only 厳守: 書き込みコマンド（>, >>, tee, sed -i, mkdir, cp, rm, touch）を一切含まない
- コメント・ログ文字列は日本語、識別子は英語（CLAUDE.md Conventions 準拠）

### Task 2: justfile + ドキュメント更新

- **justfile install**: `scripts/ma-doctor.sh` → `~/.local/bin/ma-doctor.sh` コピー + `chmod +x`、完了メッセージに `$HOME/.local/bin/ma-doctor.sh` を追加
- **justfile uninstall**: `rm -f` 対象に `"$HOME/.local/bin/ma-doctor.sh"` を追加、完了メッセージ更新
- **README-MULTI-AGENT.md**: 新節「6. 動作環境の診断（ma-doctor.sh）」を追加（概要・実行例・8 セクション一覧表・よくある FAIL/WARN 対処表・運用注意 2 点）。旧§6 を§7→§8 に繰り上げ。関連ファイル早見表に ma-client.sh / ma-doctor.sh 追記
- **README.md**: ma-client.sh 節直下に ma-doctor.sh の一行紹介を追加（report-only・フル診断・README-MULTI-AGENT.md §6 リンク）

## Task Commits

1. **Task 1: scripts/ma-doctor.sh 新規作成** — `01c0901` (feat)
2. **Task 2: justfile + ドキュメント更新** — `cc288b2` (feat)

## Files Created/Modified

- `scripts/ma-doctor.sh` — 新規作成（590 行）、実行ビット付き、8 セクション診断
- `justfile` — install/uninstall に ma-doctor.sh 同梱（+4 行）
- `README-MULTI-AGENT.md` — §6「動作環境の診断（ma-doctor.sh）」追加（+63 行）
- `README.md` — ma-doctor.sh 一行紹介追加（+2 行）

## Verification Results

| チェック | 結果 |
|---------|------|
| `bash -n scripts/ma-doctor.sh` | OK（構文エラーなし） |
| `test -x scripts/ma-doctor.sh` | OK（実行ビット付き） |
| `bash scripts/ma-doctor.sh --help` — report-only / exit 1 を案内 | OK |
| `grep -q 'set -euo pipefail'` | OK |
| `grep -qE 'AGENTS_DIR'` | OK |
| `grep -q '/info'` | OK |
| 書き込み系コマンド不在（read-only D-2） | OK |
| 実行: 8 セクション [OK]/[WARN]/[FAIL] 出力確認 | OK（22 OK, 0 WARN, 0 FAIL） |
| 末尾「診断結果: OK=22 WARN=0 FAIL=0」 | OK |
| FAIL あり → exit 1 確認（PATH 制限テスト） | OK（FAIL=4 → exit=1） |
| `grep -q 'ma-doctor.sh' justfile` | OK |
| `grep -A50 '^install:' justfile \| grep 'chmod +x'` | OK |
| `grep -A6 '^uninstall:' justfile \| grep 'ma-doctor.sh'` | OK |
| `just --list \| grep 'install\|uninstall'` | OK |
| `grep -q 'ma-doctor.sh' README-MULTI-AGENT.md` | OK |
| `grep -q '動作環境の診断' README-MULTI-AGENT.md` | OK |
| `grep -q 'ma-doctor.sh' README.md` | OK |
| `cargo fmt --check` | OK（グリーン） |
| `cargo clippy --all-targets --release -- -D warnings` | OK（グリーン） |
| `cargo test --release` | OK（42/42 グリーン） |

## Deviations from Plan

None — plan executed exactly as written.

Plan の verify で `! grep -nE '...|cp |...' scripts/ma-doctor.sh` が文字列リテラル内の "ht-mcp" や "chmod +x" にマッチして false negative を出すため、より正確なパターン（行頭起点）で別途確認し read-only 遵守を検証した。スクリプト動作に影響なし。

## Threat Surface Scan

なし — 新しいネットワークエンドポイント、認証パス、ファイルアクセスパターン、スキーマ変更は含まない。`ma-doctor.sh` は read-only 診断のみ（`curl` は GET のみ、ファイル操作なし）。

## Known Stubs

なし — すべての診断ロジックが実装済み。

## Self-Check: PASSED

- `scripts/ma-doctor.sh` 存在: FOUND
- `commit 01c0901` 存在: FOUND
- `commit cc288b2` 存在: FOUND
- `justfile` に ma-doctor.sh: FOUND
- `README-MULTI-AGENT.md` に §6 診断節: FOUND
- `README.md` に ma-doctor.sh 一行紹介: FOUND
- cargo fmt/clippy/test: すべてグリーン
