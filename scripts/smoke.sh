#!/usr/bin/env bash
# smoke.sh — ht-webif エンドツーエンドの動作確認スクリプト。
# cargo run でサーバを起動し、curl 1発で POST /prompt (wait:true) を叩き、
# Claude の回答が返ってくることを確認する。
# 使い方: ./webif/scripts/smoke.sh（任意の CWD から実行可）

set -euo pipefail

# --- パス定数 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$SCRIPT_DIR/.."
# PORT は ht-webif が読むのと同じ env var。未設定なら既定値 8080。
# TURNS_DIR を設定した場合は cargo run の子プロセスに自動で伝播するため、
# このスクリプト側では何もしない（env は exec 時にそのまま継承される）。
PORT="${PORT:-8080}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="/tmp/ht-webif-smoke-$$.log"

# --- グローバル変数（cleanup で参照するため file scope で宣言）---
# shellcheck disable=SC2034  # EXIT_CODE は将来の拡張用に予約
CARGO_PID=""
EXIT_CODE=0

# --- ログヘルパー ---
log() {
    echo "[smoke] $*" >&2
}

# --- ツール存在チェックヘルパー ---
require_tool() {
    local cmd="$1"
    local msg="$2"
    local hint="$3"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: $msg"
        log "  $hint"
        exit 1
    fi
}

# --- クリーンアップ処理（EXIT / INT / TERM で呼ばれる）---
cleanup() {
    local rc=$?
    # cargo run プロセスを停止する（kill_on_drop により ht-mcp と claude も連鎖終了）
    if [[ -n "$CARGO_PID" ]] && kill -0 "$CARGO_PID" 2>/dev/null; then
        kill -TERM "$CARGO_PID" 2>/dev/null || true
        # 最大 5 秒待つ
        for _ in 1 2 3 4 5; do
            kill -0 "$CARGO_PID" 2>/dev/null || break
            sleep 1
        done
        # まだ生きていれば強制終了
        kill -0 "$CARGO_PID" 2>/dev/null && kill -KILL "$CARGO_PID" 2>/dev/null || true
    fi
    # 失敗時はビルドログ末尾を表示する
    if [[ $rc -ne 0 ]] && [[ -f "$LOG_FILE" ]]; then
        log "失敗ログ (末尾 40 行):"
        tail -n 40 "$LOG_FILE" >&2
    fi
    # 成功時はログファイルを削除する
    if [[ $rc -eq 0 ]] && [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
    fi
    return $rc
}

trap cleanup EXIT INT TERM

# --- 前提ツール確認 ---
require_tool "claude" \
    "claude CLI が見つかりません。" \
    "インストール後に PATH を通すか、README.md の「前提依存」セクションを参照してください。"

# ht-mcp: HT_MCP_PATH が設定されていればその実行可能性を確認、なければ PATH を探す
if [[ -n "${HT_MCP_PATH:-}" ]]; then
    if [[ ! -x "$HT_MCP_PATH" ]]; then
        log "ERROR: ht-mcp が見つかりません。"
        log "  PATH に追加するか HT_MCP_PATH を設定してください。"
        exit 1
    fi
else
    require_tool "ht-mcp" \
        "ht-mcp が見つかりません。" \
        "PATH に追加するか HT_MCP_PATH を設定してください。"
fi

# --- サーバ起動 ---
cd "$WEBIF_DIR"
log "ビルド + 起動中... (PORT=${PORT}, ログ: $LOG_FILE)"
cargo run --release >"$LOG_FILE" 2>&1 &
CARGO_PID=$!

# --- 起動待機（最大 60 秒）---
wait_for_server() {
    local i
    for i in $(seq 1 60); do
        # cargo プロセスが死んでいればビルド失敗かポート競合
        if ! kill -0 "$CARGO_PID" 2>/dev/null; then
            log "ERROR: cargo run プロセスが終了しました (ビルド失敗かポート競合の可能性)"
            exit 1
        fi
        # HTTP レスポンスが返れば起動完了（/turns/0 は 404 でも OK）。
        # curl は接続失敗時も -w "%{http_code}" で "000" を出力するため、
        # 出力ではなく終了コードで判定する（exit 0 = 接続成功＝何らかの HTTP ステータス受信）。
        if curl -s -o /dev/null --max-time 2 "$BASE_URL/turns/0" 2>/dev/null; then
            return 0
        fi
        # 5 秒ごとに進捗を表示する
        if (( i % 5 == 0 )); then
            log "サーバ起動待機中 (${i}s/60s)..."
        fi
        sleep 1
    done
    log "ERROR: 60 秒待ってもサーバが応答しませんでした"
    exit 1
}

wait_for_server

# --- プロンプト送信 ---
log "プロンプト送信: 2 + 2 は何？"
response=""
if ! response=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "2 + 2 は何？", "wait": true}'); then
    log "ERROR: curl 失敗"
    exit 1
fi

# --- 結果の確認と表示 ---
log "結果:"
status=""
result=""
if command -v jq >/dev/null 2>&1; then
    echo "$response" | jq .
    status=$(echo "$response" | jq -r '.status // "unknown"')
    result=$(echo "$response" | jq -r '.result // empty')
else
    echo "$response"
    status=$(echo "$response" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

if [[ "$status" == "timeout" ]] || [[ "$status" == "failed" ]]; then
    log "ERROR: ターン失敗 (status=$status)"
    exit 1
fi

if [[ "$status" == "completed" ]] && command -v jq >/dev/null 2>&1 && [[ -n "$result" ]]; then
    log "Claude の回答:"
    printf '%s\n' "$result"
fi

log "OK: 動作確認完了"
exit 0
