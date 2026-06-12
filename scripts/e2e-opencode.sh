#!/usr/bin/env bash
# e2e-opencode.sh — OpenCode エージェントの E2E 検証スクリプト。
#
# ht-webif を AGENT=opencode PORT=8082 で起動し、次の 3 段階を検証する:
#   1. 基本 E2E (AGNT-03): POST /prompt → result 非空 + status=done
#   2. 履歴シード (ターン1): 固有の数値を記憶させる
#   3. fresh 履歴隔離 (AGNT-04 + D-10): fresh:true で前ターンの情報が漏れないことを確認
#
# fresh_mode 確定結果（D-01/D-02 — 2026-06-12 実機試行）:
#   D-01: /new を試行 → 05-RESEARCH.md Pattern 3 が予測するとおり、/new はエージェント選択
#         ダイアログを開く（Enter が 2 回必要）。ht-webif の process_job は clear_command を
#         1 回だけ送信するためダイアログがスタックし、履歴隔離が成立しない。
#   D-02: respawn にフォールバック確定。respawn は Phase 4 で実装・テスト済みのパス。
#         agents/opencode.toml: fresh_mode = "respawn"（確定値）
#
# 段階 3 の方法論的注意（05-01-SUMMARY.md より — agentic CLI 共通の FALSE POSITIVE 対策）:
#   OpenCode は対話型エージェント CLI であり、ワークスペース検索を自律的に実行できる。
#   段階 2 の秘密数値 7331 は turns/ 配下のプロンプトファイルに平文で保存されるため、
#   単純な「以前伝えた秘密の数値は何ですか？」という質問を送ると OpenCode がファイル
#   検索で 7331 を発見し、会話履歴の漏洩と誤判定されてしまう（Codex と同じ問題）。
#   この FALSE POSITIVE を防ぐため、段階 3 のプロンプトにはファイル読み取り・検索を
#   明示的に禁止する制約を付与する。この制約がなければテスト自体が無効となる。
#
# 前提条件:
#   - opencode が PATH 上にあること
#   - opencode auth login 実行済み（GitHub Copilot 認証推奨）
#   - jq が PATH 上にあること（結果の JSON パース用）
#   - curl が PATH 上にあること
#   - agents/opencode.toml が存在すること（Task 1 で作成）
#   - scripts/setup-opencode.sh が自動的に turn.md を保証する（D-04）
#
# 使い方: bash scripts/e2e-opencode.sh（プロジェクトルートから実行）
# CI には繋がない（実エージェント + 実課金が必要なため — D-08）

set -euo pipefail

# --- パス定数 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$SCRIPT_DIR/.."
# e2e-opencode.sh は専用ポート 8082 を使用（smoke.sh の 8080、e2e-codex.sh の 8081 と分離 — D-07）
PORT="${PORT:-8082}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="/tmp/ht-webif-e2e-opencode-$$.log"

# --- グローバル変数（cleanup で参照するため file scope で宣言）---
CARGO_PID=""

# --- ログヘルパー ---
log() {
    echo "[e2e-opencode] $*" >&2
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
    # cargo run プロセスを停止する（kill_on_drop により ht-mcp と opencode も連鎖終了）
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
require_tool "opencode" \
    "opencode CLI が見つかりません。" \
    "~/.opencode/bin または ~/.local/share/opencode/bin が PATH に含まれているか確認してください。"

require_tool "jq" \
    "jq が見つかりません。" \
    "sudo apt-get install jq または brew install jq で導入してください。"

require_tool "curl" \
    "curl が見つかりません。" \
    "curl をインストールしてください。"

# ht-mcp: HT_MCP_PATH が設定されていればその実行可能性を確認、なければ PATH を探す
if [[ -n "${HT_MCP_PATH:-}" ]]; then
    if [[ ! -x "$HT_MCP_PATH" ]]; then
        log "ERROR: HT_MCP_PATH に指定された ht-mcp が見つかりません: $HT_MCP_PATH"
        log "  PATH に追加するか HT_MCP_PATH を設定してください。"
        exit 1
    fi
else
    require_tool "ht-mcp" \
        "ht-mcp が見つかりません。" \
        "PATH に追加するか HT_MCP_PATH を設定してください。"
fi

# --- 前提条件: turn.md の存在を保証する（D-04）---
log "turn.md の前提条件を確認 + 冪等生成..."
bash "$SCRIPT_DIR/setup-opencode.sh"

# --- サーバ起動 ---
cd "$WEBIF_DIR"
log "ビルド + 起動中... (AGENT=opencode, PORT=${PORT}, ログ: $LOG_FILE)"
AGENT=opencode PORT="$PORT" TURNS_DIR="./turns/opencode" cargo run --release >"$LOG_FILE" 2>&1 &
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
        # HTTP レスポンスが返れば起動完了（/turns/0 は 404 でも OK）
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
log "サーバ起動完了 (PORT=${PORT})"

# --- 段階 1: 基本 E2E（AGNT-03）---
log "=== 段階 1: 基本 E2E (AGNT-03) ==="
log "プロンプト送信: What is 2+3? Answer with the number only."
T1_START=$(date +%s)
response1=""
if ! response1=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"What is 2+3? Answer with the number only.","wait":true}'); then
    log "ERROR: curl 失敗（段階 1）"
    exit 1
fi
T1_END=$(date +%s)
T1_ELAPSED=$(( T1_END - T1_START ))

status1=$(echo "$response1" | jq -r '.status // "unknown"')
result1=$(echo "$response1" | jq -r '.result // ""')
turn_id1=$(echo "$response1" | jq -r '.turn_id // "unknown"')

log "段階 1 結果: turnId=${turn_id1}, status=${status1}, 所要時間=${T1_ELAPSED}s"
log "段階 1 result 先頭 100 文字: $(echo "$result1" | head -c 100)"

if [[ "$status1" == "timeout" ]] || [[ "$status1" == "failed" ]]; then
    log "ERROR: 段階 1 失敗 (status=${status1}) — result: $(echo "$result1" | head -c 200)"
    exit 1
fi
if [[ -z "$result1" ]]; then
    log "ERROR: 段階 1 失敗 — result が空"
    exit 1
fi
log "OK: 段階 1 通過 (result 非空 + status=${status1})"

# --- 段階 2: 履歴シード（ターン1）---
log "=== 段階 2: 履歴シード ==="
log "プロンプト送信: 秘密の数値 7331 を記憶させる"
T2_START=$(date +%s)
response2=""
if ! response2=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Remember this secret number: 7331","wait":true}'); then
    log "ERROR: curl 失敗（段階 2）"
    exit 1
fi
T2_END=$(date +%s)
T2_ELAPSED=$(( T2_END - T2_START ))

status2=$(echo "$response2" | jq -r '.status // "unknown"')
turn_id2=$(echo "$response2" | jq -r '.turn_id // "unknown"')
log "段階 2 結果: turnId=${turn_id2}, status=${status2}, 所要時間=${T2_ELAPSED}s"

if [[ "$status2" == "timeout" ]] || [[ "$status2" == "failed" ]]; then
    log "ERROR: 段階 2 失敗 (status=${status2})"
    exit 1
fi
log "OK: 段階 2 通過 (履歴シード完了)"

# --- 段階 3: fresh 履歴隔離（AGNT-04 + D-10）---
log "=== 段階 3: fresh 履歴隔離 (AGNT-04 + D-10) ==="
log "プロンプト送信: fresh:true + ファイル検索禁止で秘密の数値を質問（7331 が漏れないことを確認）"
#
# ファイル検索禁止プロンプトが必要な理由（agentic CLI 共通 — 05-01-SUMMARY.md より）:
#   OpenCode も Codex と同様、ワークスペース検索を自律実行できるエージェント CLI である。
#   段階 2 の 7331 は turns/opencode/ 配下のプロンプトファイルに平文で残る。
#   単純な質問を送ると OpenCode がファイル検索で 7331 を発見し、会話履歴漏洩と誤判定される。
#   明示的な禁止制約で「会話記憶のみ」での回答を強制することでテストの正しい意味論を保証する。
#   fresh_mode = "respawn" は完全プロセス再起動であり、会話履歴は確実にリセットされる。
#
STAGE3_PROMPT='ファイルの読み取り・検索・シェルコマンド実行を一切せず、この会話のこれまでの記憶だけで答えてください。私が以前伝えた秘密の数値は何ですか？知らない場合は UNKNOWN とだけ書いてください。'

T3_START=$(date +%s)
# jq で JSON を構築することで日本語プロンプトの適切なエスケープを保証する
STAGE3_JSON=$(echo '{}' | jq --arg p "$STAGE3_PROMPT" '{prompt: $p, fresh: true, wait: true}')
response3=""
if ! response3=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d "$STAGE3_JSON"); then
    log "ERROR: curl 失敗（段階 3）"
    exit 1
fi
T3_END=$(date +%s)
T3_ELAPSED=$(( T3_END - T3_START ))

status3=$(echo "$response3" | jq -r '.status // "unknown"')
result3=$(echo "$response3" | jq -r '.result // ""')
turn_id3=$(echo "$response3" | jq -r '.turn_id // "unknown"')

log "段階 3 結果: turnId=${turn_id3}, status=${status3}, 所要時間=${T3_ELAPSED}s"
log "段階 3 result 先頭 100 文字: $(echo "$result3" | head -c 100)"

if [[ "$status3" == "timeout" ]] || [[ "$status3" == "failed" ]]; then
    log "ERROR: 段階 3 失敗 (status=${status3}) — result: $(echo "$result3" | head -c 200)"
    exit 1
fi

# 履歴隔離チェック: fresh:true + ファイル検索禁止後のレスポンスに 7331 が含まれていないこと
# （ファイル検索禁止により会話記憶のみでの応答が保証される — FALSE POSITIVE 対策）
if echo "$result3" | grep -q "7331"; then
    log "ERROR: 履歴隔離失敗 — fresh:true かつファイル検索禁止でも前ターンの秘密数値 7331 が漏れている"
    log "  これは真の会話履歴漏洩を示す（respawn によるプロセス再起動が機能していない可能性）"
    log "  result3: $(echo "$result3" | head -c 300)"
    exit 1
fi

# 追加確認: UNKNOWN を含む場合は隔離成功の強い証拠
if echo "$result3" | grep -qi "UNKNOWN"; then
    log "INFO: 段階 3 — result に UNKNOWN を含む（会話記憶なし = 隔離成立の強い証拠）"
fi

log "OK: 段階 3 通過 (fresh:true + ファイル検索禁止で 7331 が含まれない — 履歴隔離成立)"

# --- 最終サマリー ---
log ""
log "=== E2E 検証サマリー ==="
log "段階 1 (AGNT-03): turnId=${turn_id1}, 所要時間=${T1_ELAPSED}s, status=${status1} — PASS"
log "段階 2 (履歴シード): turnId=${turn_id2}, 所要時間=${T2_ELAPSED}s, status=${status2} — PASS"
log "段階 3 (AGNT-04): turnId=${turn_id3}, 所要時間=${T3_ELAPSED}s, status=${status3} — PASS"
log ""
log "fresh_mode 確定値: respawn（/new はエージェント選択ダイアログのため不採用 — D-01/D-02）"
log ""
log "OK: OpenCode E2E 完了 — AGNT-03 (result/status ファイル) + AGNT-04 (fresh:true 履歴隔離) 検証済み"
exit 0
