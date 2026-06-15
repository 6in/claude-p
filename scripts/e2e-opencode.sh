#!/usr/bin/env bash
# e2e-opencode.sh — OpenCode エージェントの E2E 検証スクリプト。
#
# ht-webif を AGENT=opencode PORT=8082 で起動し、次の段階を検証する:
#   1. 基本 E2E (AGNT-03): POST /prompt → result 非空 + status=done
#   2. 履歴シード（ターン1）: 固有の数値を記憶させる
#   2.5. 正の対照実験: 非 fresh で秘密数値を質問 → UNKNOWN を期待（D-09 アーキテクチャ上の継続性なし）
#   3. fresh 履歴隔離 (AGNT-04 + D-10): fresh:true で Worker::recreate() が実際に発火したことを
#       サーバログ（[shared-fate] 再生成行）で証明する
#
# fresh_mode 確定結果（D-01/D-02 — 2026-06-12 実機試行）:
#   D-01: /new を試行 → 05-RESEARCH.md Pattern 3 が予測するとおり、/new はエージェント選択
#         ダイアログを開く（Enter が 2 回必要）。ht-webif の process_job は clear_command を
#         1 回だけ送信するためダイアログがスタックし、履歴隔離が成立しない。
#   D-02: respawn にフォールバック確定。respawn は Phase 4 で実装・テスト済みのパス。
#         agents/opencode.toml: fresh_mode = "respawn"（確定値）
#
# AGNT-04 falsifiability（05-03-PLAN.md — gap-closure）:
#   D-09 アーキテクチャ（opencode run --command turn ラッパー）では各ターンが独立した会話となる。
#   そのため、段階 2 でシードした 7331 は段階 3 前に必ず破棄される。
#   「7331 が漏れない」チェックは fresh_mode=respawn が壊れていても必ず PASS するため空洞。
#   代替検証: 段階 3 で fresh:true ターン前後の [shared-fate] 再生成行数を比較し、
#   Worker::recreate() が実際に発火したことを証明する（respawn 機構が壊れれば増分 0 で FAIL）。
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
    # 成功時はログファイルを削除する（recreate_after は成功時 cleanup 前に記録済み）
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
AGENT=opencode PORT="$PORT" TURNS_DIR="./turns" cargo run --release >"$LOG_FILE" 2>&1 &
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

# WR-01: status=done allowlist — status が done 以外はすべて失敗（unknown/timeout/failed を含む）
if [[ "$status1" != "done" ]]; then
    log "ERROR: 段階 1 失敗 (status=${status1}, 期待値 done) — result: $(echo "$result1" | head -c 200)"
    exit 1
fi
if [[ -z "$result1" ]]; then
    log "ERROR: 段階 1 失敗 — result が空"
    exit 1
fi
log "OK: 段階 1 通過 (result 非空 + status=done)"

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

# WR-01: status=done allowlist
if [[ "$status2" != "done" ]]; then
    log "ERROR: 段階 2 失敗 (status=${status2}, 期待値 done)"
    exit 1
fi
log "OK: 段階 2 通過 (履歴シード完了)"

# --- 段階 2.5: 正の対照実験（非 fresh — D-09 アーキテクチャの継続性欠如を実機で記録）---
log "=== 段階 2.5: 正の対照実験（非 fresh での会話継続性確認）==="
#
# 目的: D-09 ラッパー方式（opencode run --command turn）では各ターンが独立した会話となり、
# 非 fresh ターン間にも会話継続性が存在しないことを実機で確認・記録する。
# これにより「段階 2→3 単独では 7331 非出現は隔離の証拠にならない」理由を明示する。
# UNKNOWN が返ることが期待値。7331 が返れば会話継続性ではなくファイル検索由来の疑いがある。
#
STAGE25_PROMPT='ファイルの読み取り・検索・シェルコマンド実行を一切せず、この会話のこれまでの記憶だけで答えてください。私が以前伝えた秘密の数値は何ですか？知らない場合は UNKNOWN とだけ書いてください。'

T25_START=$(date +%s)
STAGE25_JSON=$(echo '{}' | jq --arg p "$STAGE25_PROMPT" '{prompt: $p, wait: true}')
response25=""
if ! response25=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d "$STAGE25_JSON"); then
    log "ERROR: curl 失敗（段階 2.5）"
    exit 1
fi
T25_END=$(date +%s)
T25_ELAPSED=$(( T25_END - T25_START ))

status25=$(echo "$response25" | jq -r '.status // "unknown"')
result25=$(echo "$response25" | jq -r '.result // ""')
turn_id25=$(echo "$response25" | jq -r '.turn_id // "unknown"')

log "段階 2.5 結果: turnId=${turn_id25}, status=${status25}, 所要時間=${T25_ELAPSED}s"
log "段階 2.5 result 先頭 100 文字: $(echo "$result25" | head -c 100)"

# WR-01: status=done allowlist
if [[ "$status25" != "done" ]]; then
    log "ERROR: 段階 2.5 失敗 (status=${status25}, 期待値 done)"
    exit 1
fi

# 段階 2.5 の意味論: 期待値は UNKNOWN（D-09 アーキテクチャ上の継続性欠如）
if echo "$result25" | grep -qi "UNKNOWN"; then
    log "INFO: 段階 2.5 — UNKNOWN を確認（期待値）。D-09 ラッパー方式では非 fresh でも前ターンの記憶がない。"
elif echo "$result25" | grep -q "7331"; then
    log "WARNING: 段階 2.5 — result に 7331 が含まれる。これは会話継続性ではなくファイル検索由来の可能性が高い。"
    log "  段階 2.5 はテスト失敗にしないが、ファイル検索禁止制約の有効性を確認すること。"
else
    log "INFO: 段階 2.5 — UNKNOWN でも 7331 でもないレスポンス（継続性なしとして記録）。"
fi

# D-09 アーキテクチャ上の重要な注記: このログ行が段階 2→3 の隔離証明の限界を明示する
log "注: OpenCode は D-09 アーキテクチャ上、非 fresh でも前ターンを記憶しない。"
log "    よって段階 2→3 の 7331 非出現は隔離の証拠にならず、段階 3 では respawn 機構の"
log "    発火そのものを [shared-fate] 再生成ログで検証する。"
log "OK: 段階 2.5 通過 (非 fresh での継続性欠如を実機記録)"

# --- 段階 3: fresh 履歴隔離（AGNT-04 + D-10）— respawn 発火ログ検証 ---
log "=== 段階 3: fresh 履歴隔離 (AGNT-04 + D-10) — respawn 発火ログ検証 ==="
#
# 合格条件変更（05-03-PLAN.md gap-closure）:
#   旧: 7331 が result に含まれないこと（空洞 — fresh_mode が壊れていても常に PASS）
#   新: fresh:true ターンで Worker::recreate() が実際に発火したこと
#       → LOG_FILE 内の [shared-fate] 再生成行数が fresh ターン前後で増加すること
#
# src/worker.rs recreate() 成功時のログ（worker.rs:152-155）:
#   eprintln!("[shared-fate] claude セッション再生成: {} （旧 {} を閉鎖）", new_id, old)
#
# CR-01: 計数は recreate() 成功行のみを対象とする。worker.rs には末尾が「再生成」で
# 終わる行が 2 つ存在し、両方とも 'shared-fate.*再生成' にマッチしてしまう:
#   - worker.rs:116 「[shared-fate] claude セッション不健全 → 再生成」（ensure_healthy の不健全パス）
#   - worker.rs:153 「[shared-fate] claude セッション再生成: …」（recreate 成功）
# ensure_healthy() は process_job の冒頭で毎ターン呼ばれる（turn.rs:50）ため、不健全行を
# 数えると respawn が壊れていてもゲートが PASS する空洞が再発する。コロン付き成功プレフィックス
# '[shared-fate] claude セッション再生成:'（116 行にはコロンがない）で固定文字列計数する。
#
STAGE3_PROMPT='ファイルの読み取り・検索・シェルコマンド実行を一切せず、この会話のこれまでの記憶だけで答えてください。私が以前伝えた秘密の数値は何ですか？知らない場合は UNKNOWN とだけ書いてください。'

# respawn 発火の baseline 取得（fresh:true curl 送信より前に実行すること）
# 再生成成功行のみを計数する（ensure_healthy の "不健全 → 再生成" 行を除外 — CR-01）
recreate_before=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
log "respawn baseline: LOG_FILE 内 [shared-fate] 再生成行数 = ${recreate_before}"

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

# WR-01: status=done allowlist
if [[ "$status3" != "done" ]]; then
    log "ERROR: 段階 3 失敗 (status=${status3}, 期待値 done) — result: $(echo "$result3" | head -c 200)"
    exit 1
fi

# WR-02 ハードゲート 1: result が空なら隔離検証は成立しない
if [[ -z "$result3" ]]; then
    log "ERROR: 段階 3 失敗 — result が空（隔離検証は空回答では成立しない）"
    exit 1
fi

# WR-02 ハードゲート 2: UNKNOWN を含まなければ回答の意味論が不明
# ファイル検索禁止制約下で会話記憶がなければ UNKNOWN を返すはず
if ! echo "$result3" | grep -qi "UNKNOWN"; then
    log "ERROR: 段階 3 失敗 — result に UNKNOWN が含まれない（回答の意味論が不明）"
    log "  result3: $(echo "$result3" | head -c 300)"
    exit 1
fi

# 補助確認: 7331 が含まれていれば respawn が機能していない（true isolation failure）
if echo "$result3" | grep -q "7331"; then
    log "ERROR: 段階 3 失敗 — fresh:true かつファイル検索禁止でも前ターンの秘密数値 7331 が漏れている"
    log "  これは respawn によるプロセス再起動が機能していない可能性を示す"
    log "  result3: $(echo "$result3" | head -c 300)"
    exit 1
fi

# メインゲート: fresh:true ターンで Worker::recreate() が発火したことを LOG_FILE で証明する
# wait:true が返った時点で処理完了 = recreate ログ出力済み（cleanup による LOG_FILE 削除前）
# 再生成成功行のみを計数する（ensure_healthy の "不健全 → 再生成" 行を除外 — CR-01）
recreate_after=$(grep -cF '[shared-fate] claude セッション再生成:' "$LOG_FILE" || true)
log "respawn 発火確認: LOG_FILE 内 [shared-fate] 再生成行数 = before=${recreate_before} / after=${recreate_after}"

if [[ "$recreate_after" -le "$recreate_before" ]]; then
    log "ERROR: 段階 3 失敗 — fresh:true ターンで Worker::recreate() が発火しなかった"
    log "  before=${recreate_before}, after=${recreate_after}（増分ゼロ）"
    log "  agents/opencode.toml の fresh_mode=respawn が有効に機能していないことを示す"
    log "  respawn 機構が壊れているか、fresh フラグが無視されている可能性がある"
    exit 1
fi

log "OK: 段階 3 通過 — fresh:true で Worker::recreate() が発火 (before=${recreate_before} → after=${recreate_after})"
log "    respawn 機構（AGNT-04）が実際に動作していることをサーバログで証明"

# --- 最終サマリー ---
log ""
log "=== E2E 検証サマリー ==="
log "段階 1 (AGNT-03): turnId=${turn_id1}, 所要時間=${T1_ELAPSED}s, status=${status1} — PASS"
log "段階 2 (履歴シード): turnId=${turn_id2}, 所要時間=${T2_ELAPSED}s, status=${status2} — PASS"
log "段階 2.5 (正の対照): turnId=${turn_id25}, 所要時間=${T25_ELAPSED}s, status=${status25} — PASS（継続性欠如を実機記録）"
log "段階 3 (AGNT-04): turnId=${turn_id3}, 所要時間=${T3_ELAPSED}s, status=${status3} — PASS"
log "  respawn 発火証明: [shared-fate] 再生成行 before=${recreate_before} → after=${recreate_after}（増分 $(( recreate_after - recreate_before ))）"
log ""
log "fresh_mode 確定値: respawn（/new はエージェント選択ダイアログのため不採用 — D-01/D-02）"
log "AGNT-04 検証方式: Worker::recreate() 発火ログ検証（respawn が壊れれば必ず FAIL — 05-03 gap-closure）"
log ""
log "OK: OpenCode E2E 完了 — AGNT-03 (result/status ファイル) + AGNT-04 (respawn 発火証明) 検証済み"
exit 0
