#!/usr/bin/env bash
# e2e-codex.sh — Codex CLI エージェントの E2E 検証スクリプト。
#
# ht-webif を AGENT=codex PORT=8081 で起動し、次の 3 段階を検証する:
#   1. 基本 E2E (AGNT-01): POST /prompt → result 非空 + status=done
#   2. 履歴シード (ターン1): 固有の数値を記憶させる
#   3. fresh 履歴隔離 (AGNT-02 + D-10): fresh:true で前ターンの情報が漏れないことを確認
#
# 段階 3 の方法論的注意（2026-06-12 ロールアウト調査により確立）:
#   Codex は対話型エージェント CLI であり、ワークスペース検索（rg / ctx_search 等）を
#   自律的に実行する能力を持つ。段階 2 の秘密数値 7331 は turns/ 配下のプロンプトファイル
#   に平文で保存されるため、「以前伝えた秘密の数値は何ですか？」という単純な質問を送ると
#   Codex がファイル検索で 7331 を発見し、会話履歴の漏洩と誤判定されてしまう。
#   このファイル検索による FALSE POSITIVE を防ぐため、段階 3 のプロンプトには
#   「ファイル読み取り・検索・シェルコマンド実行を一切せず、会話の記憶だけで答えよ」
#   という明示的な制約を付与する。この制約がなければテスト自体が無効となる。
#
# 前提条件:
#   - codex が PATH 上にあること（~/.local/bin/codex）
#   - codex login 実行済み（~/.codex/auth.json 存在 + ChatGPT Plus 認証）
#   - jq が PATH 上にあること（結果の JSON パース用）
#   - curl が PATH 上にあること
#   - agents/codex.toml が存在すること（Task 1 で作成）
#
# 使い方: bash scripts/e2e-codex.sh（プロジェクトルートから実行）
# CI には繋がない（実エージェント + 実課金が必要なため — D-08）

set -euo pipefail

# --- パス定数 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$SCRIPT_DIR/.."
# e2e-codex.sh は専用ポート 8081 を使用（smoke.sh の 8080 と分離 — D-07）
PORT="${PORT:-8081}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="/tmp/ht-webif-e2e-codex-$$.log"

# --- グローバル変数（cleanup で参照するため file scope で宣言）---
CARGO_PID=""

# --- ログヘルパー ---
log() {
    echo "[e2e-codex] $*" >&2
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
    # cargo run プロセスを停止する（kill_on_drop により ht-mcp と codex も連鎖終了）
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
require_tool "codex" \
    "codex CLI が見つかりません。" \
    "~/.local/bin/codex が PATH に含まれているか確認してください（codex login 実行済みが前提）。"

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

# --- サーバ起動 ---
cd "$WEBIF_DIR"
log "ビルド + 起動中... (AGENT=codex, PORT=${PORT}, ログ: $LOG_FILE)"
# WR-05: TURNS_DIR は意図的に "./turns"（プロジェクトルート相対）に固定する。
#   理由: Codex は lean-ctx MCP hooks によりプロジェクトルート外のファイル読み取りを拒否する
#   （agents/codex.toml:16-19）。/tmp 等の外部パスを使うと "path escapes project root" になる。
#   main.rs:37 の turns_base.join(&agent_name) が "./turns" を "./turns/codex" に展開する（D-16）。
#   この per-agent サフィックス付与は別箇所で行われる隠れた結合のため、ここでルート内に着地させる
#   "./turns" を明示的に強制する。これは .env の TURNS_DIR 設定を上書きする点に注意（下でログ出力）。
EFFECTIVE_TURNS_DIR="./turns"
log "E2E は TURNS_DIR=${EFFECTIVE_TURNS_DIR} を強制（D-16: codex は ./turns/codex に展開。.env の値は上書きされる）"
AGENT=codex PORT="$PORT" TURNS_DIR="$EFFECTIVE_TURNS_DIR" cargo run --release >"$LOG_FILE" 2>&1 &
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

# --- 段階 1: 基本 E2E（AGNT-01）---
log "=== 段階 1: 基本 E2E (AGNT-01) ==="
log "プロンプト送信: 2+2 は何？"
T1_START=$(date +%s)
response1=""
if ! response1=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"What is 2+2? Answer with the number only.","wait":true}'); then
    log "ERROR: curl 失敗（段階 1）"
    exit 1
fi
T1_END=$(date +%s)
T1_ELAPSED=$(( T1_END - T1_START ))

status1=$(echo "$response1" | jq -r '.status // "unknown"')
result1=$(echo "$response1" | jq -r '.result // ""')
turn_id1=$(echo "$response1" | jq -r '.turn_id // "unknown"')

log "段階 1 結果: turnId=${turn_id1}, status=${status1}, 所要時間=${T1_ELAPSED}s"
log "段階 1 result 先頭 100 文字: ${result1:0:100}"

if [[ "$status1" == "timeout" ]] || [[ "$status1" == "failed" ]]; then
    log "ERROR: 段階 1 失敗 (status=${status1}) — result: ${result1:0:200}"
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

# --- 段階 3: fresh 履歴隔離（AGNT-02 + D-10）---
log "=== 段階 3: fresh 履歴隔離 (AGNT-02 + D-10) ==="
log "プロンプト送信: fresh:true + ファイル検索禁止で秘密の数値を質問（7331 が漏れないことを確認）"
#
# ファイル検索禁止プロンプトが必要な理由（2026-06-12 ロールアウト調査）:
#   Codex v0.139.0 は /clear 後および respawn 後ともに会話履歴を完全にリセットする
#   ことが ~/.codex/sessions/ のロールアウトファイル直接検査で確認された。
#   しかし Codex はエージェントとしてワークスペース検索（rg / ctx_search 等）を
#   自律実行できるため、「以前伝えた秘密の数値は何ですか？」という単純な質問に対して
#   turns/ 配下のプロンプトファイルを検索して 7331 を発見してしまう。
#   これは会話履歴の漏洩ではなくファイルシステムアクセスによる FALSE POSITIVE である。
#   ファイル読み取り・検索を明示的に禁止することでテストの正しい意味論を保証する。
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
log "段階 3 result 先頭 100 文字: ${result3:0:100}"

if [[ "$status3" == "timeout" ]] || [[ "$status3" == "failed" ]]; then
    log "ERROR: 段階 3 失敗 (status=${status3}) — result: ${result3:0:200}"
    exit 1
fi

# WR-03: 段階 3 の隔離アサーションを e2e-opencode.sh と同等の厳密さにする。
# fresh_mode=command（/clear）の文脈リセットは result テキストからは観測できない
# （respawn のようにログで発火を証明できない）ため、result テキストのハードゲートが
# 利用可能な最強のシグナルとなる。空回答や 7331 を単に省いた回答での空洞 PASS を防ぐ。

# WR-03 ハードゲート 1: result が空なら隔離検証は成立しない
if [[ -z "$result3" ]]; then
    log "ERROR: 段階 3 失敗 — result が空（隔離検証は空回答では成立しない）"
    exit 1
fi

# 履歴隔離チェック: fresh:true + ファイル検索禁止後のレスポンスに 7331 が含まれていないこと
# （ファイル検索禁止により会話記憶のみでの応答が保証される — 上記 FALSE POSITIVE 対策参照）
if echo "$result3" | grep -q "7331"; then
    log "ERROR: 履歴隔離失敗 — fresh:true かつファイル検索禁止でも前ターンの秘密数値 7331 が漏れている"
    log "  これは真の会話履歴漏洩を示す（ファイル検索ではない）"
    log "  result3: ${result3:0:300}"
    exit 1
fi

# WR-03 ハードゲート 2: UNKNOWN を含まなければ回答の意味論が不明
# ファイル検索禁止制約下で会話記憶がなければ UNKNOWN を返すはず（INFO ではなく必須化）
if ! echo "$result3" | grep -qi "UNKNOWN"; then
    log "ERROR: 段階 3 失敗 — result に UNKNOWN が含まれない（回答の意味論が不明）"
    log "  result3: ${result3:0:300}"
    exit 1
fi

log "OK: 段階 3 通過 (fresh:true + ファイル検索禁止で 7331 非出現 + UNKNOWN 出現 — 履歴隔離成立)"

# --- 最終サマリー ---
log ""
log "=== E2E 検証サマリー ==="
log "段階 1 (AGNT-01): turnId=${turn_id1}, 所要時間=${T1_ELAPSED}s, status=${status1} — PASS"
log "段階 2 (履歴シード): turnId=${turn_id2}, 所要時間=${T2_ELAPSED}s, status=${status2} — PASS"
log "段階 3 (AGNT-02): turnId=${turn_id3}, 所要時間=${T3_ELAPSED}s, status=${status3} — PASS"
log ""
log "OK: Codex E2E 完了 — AGNT-01 (result/status ファイル) + AGNT-02 (fresh:true 履歴隔離) 検証済み"
exit 0
