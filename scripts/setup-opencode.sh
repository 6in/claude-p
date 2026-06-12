#!/usr/bin/env bash
# setup-opencode.sh — OpenCode カスタムコマンド turn.md の冪等生成スクリプト。
#
# ~/.config/opencode/commands/turn.md を一度だけ作成する（既存ならスキップ）。
# ht-webif の AGENT=opencode 運用に必要な前提条件を充足する。
#
# 単一責務: turn.md 生成のみ（D-05）。
# auth 状態の確認や環境チェックは行わない。
#
# 使い方: bash scripts/setup-opencode.sh（プロジェクトルートから実行可）
# または scripts/e2e-opencode.sh の冒頭で自動呼び出しされる。

set -euo pipefail

# --- ログヘルパー ---
log() {
    echo "[setup-opencode] $*" >&2
}

# --- turn.md の配置先（XDG 規約準拠）---
TURN_CMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands"
TURN_CMD_FILE="$TURN_CMD_DIR/turn.md"

# --- 冪等チェック: 既存ならスキップ ---
if [[ -f "$TURN_CMD_FILE" ]]; then
    log "turn.md は既に存在します: $TURN_CMD_FILE (スキップ)"
    exit 0
fi

# --- ディレクトリ作成 ---
mkdir -p "$TURN_CMD_DIR"

# --- turn.md 生成（OpenCode カスタムコマンド定義）---
# 内容は 05-RESEARCH.md Addendum /turn workaround の Working Recipe どおり:
#   - frontmatter: description フィールド
#   - 本文: $ARGUMENTS でパス引数を受け取り、ファイルを読んで指示に従う
cat > "$TURN_CMD_FILE" << 'HEREDOC'
---
description: Read a prompt file and follow the instructions in it
---
Read the file $ARGUMENTS and follow the instructions in it.
HEREDOC

log "OK: turn.md を作成しました: $TURN_CMD_FILE"
exit 0
