#!/usr/bin/env bash
# ma-client.sh — マルチエージェント curl ラッパー。
#
# launch-agents.sh で起動した各 ht-webif インスタンスに対し、ポート番号を意識せず
# エージェント名でプロンプトを送受信できる薄いシェルスクリプト。
#
# サブコマンド一覧（D-3）:
#   ma-client.sh <agent> [フラグ] [-p "プロンプト" | positional引数 | stdin]
#       エージェントにプロンプトを送信する（既定: 同期 = 完了まで待ちresultを表示）
#   ma-client.sh result <agent> <turn_id>
#       turn_id の状態と結果を GET /turns で取得・表示する
#   ma-client.sh status
#       instances.conf の全エージェントの /info 一覧を表示する
#
# フラグ（D-1〜D-6）:
#   -p <prompt>    プロンプトを直接指定（D-2: 後方互換 positional 引数でも可）
#   --async        wait なしで turn_id を即表示する（D-1）
#   --fresh        fresh:true をリクエストボディに付加する（D-6）
#   --port <N>     agent→port の自動解決を上書きする（D-5）
#
# 例:
#   ma-client.sh claude -p "Rust とは何か"      # 同期送信 → result 表示
#   ma-client.sh claude "Rust とは何か"          # positional 引数（後方互換）
#   echo "質問" | ma-client.sh claude            # stdin パイプ
#   ma-client.sh claude -p "..." --async         # 非同期 → turn_id 表示
#   ma-client.sh claude -p "..." --fresh         # 文脈リセット
#   ma-client.sh claude -p "..." --port 9090     # ポート上書き
#   ma-client.sh result claude 20260616-103045-123  # ターン結果取得
#   ma-client.sh status                          # 全インスタンス状態確認
#
# 接続先は常に 127.0.0.1 固定（D-6）。
# ポートは $(pwd)/instances.conf から自動解決する（D-3/D-5）。

set -euo pipefail

# --- パス定数（D-3: cwd 基準） ---
INSTANCES_CONF="$(pwd)/instances.conf"

# --- ログヘルパー ---
log() {
    echo "[ma-client] $*" >&2
}

# --- ツール検出（JSON エンコーダ）。launch-agents.sh の規約を踏襲。 ---
JSON_ENCODER=""
if command -v jq >/dev/null 2>&1; then
    JSON_ENCODER="jq"
elif command -v python3 >/dev/null 2>&1; then
    JSON_ENCODER="python3"
else
    log "ERROR: jq か python3 のどちらかが必要です。"
    log "  jq または python3 をインストールしてください。"
    exit 1
fi

# --- JSON フィールド取得ヘルパー（launch-agents.sh と同形） ---
json_get_field() {
    local json="$1"
    local field="$2"
    case "$JSON_ENCODER" in
        jq)
            echo "$json" | jq -r ".${field} // empty"
            ;;
        python3)
            echo "$json" | python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print(d.get('${field}', ''))"
            ;;
    esac
}

# --- 文字列を JSON 文字列リテラルにエンコードするヘルパー（T-fce-01 緩和） ---
# stdin からテキストを読み、JSON 文字列リテラル（ダブルクォート付き）を stdout に出力する。
# jq -Rs で引用符・改行・スラッシュを安全にエスケープする。シェル文字列連結は使わない。
json_encode_string() {
    case "$JSON_ENCODER" in
        jq)
            jq -Rs .
            ;;
        python3)
            python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))'
            ;;
    esac
}

# --- instances.conf からエージェント名をポートに解決するヘルパー（D-5） ---
# 使用法: resolve_port <agent>
# stdout にポート番号を出力。解決不可なら日本語エラーで exit 1。
resolve_port() {
    local agent="$1"
    if [[ ! -f "$INSTANCES_CONF" ]]; then
        log "ERROR: instances.conf が見つかりません: ${INSTANCES_CONF}"
        exit 1
    fi
    local found_port=""
    local all_agents=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ（launch-agents.sh と同じ規則）
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        local fields=()
        read -ra fields <<< "$line"
        local row_agent="${fields[0]:-}"
        local row_port="${fields[1]:-}"
        if [[ -z "$row_agent" ]] || [[ -z "$row_port" ]]; then
            continue
        fi
        all_agents+=("$row_agent")
        if [[ "$row_agent" == "$agent" ]] && [[ -z "$found_port" ]]; then
            found_port="$row_port"
        fi
    done < "$INSTANCES_CONF"
    if [[ -z "$found_port" ]]; then
        log "ERROR: エージェント '${agent}' が見つかりません。"
        log "       利用可能なエージェント: ${all_agents[*]:-（なし）}"
        exit 1
    fi
    echo "$found_port"
}

# --- usage 表示 ---
usage() {
    echo "使い方:" >&2
    echo "  send（既定）: $(basename "$0") <agent> [-p <prompt>] [--async] [--fresh] [--port <N>]" >&2
    echo "      エージェントにプロンプトを送信する（既定: 同期 = 完了まで待ち result を表示）" >&2
    echo "      -p <prompt>   プロンプトを直接指定（省略時は positional 引数 or stdin）" >&2
    echo "      --async       wait なしで turn_id を即表示（非同期）" >&2
    echo "      --fresh       fresh:true を付加（文脈リセット）" >&2
    echo "      --port <N>    agent→port の自動解決を上書き" >&2
    echo "" >&2
    echo "  result: $(basename "$0") result <agent> <turn_id>" >&2
    echo "      ターン結果を GET /turns で取得・表示する" >&2
    echo "" >&2
    echo "  status: $(basename "$0") status" >&2
    echo "      instances.conf の全エージェントの /info 一覧を表示する" >&2
    echo "" >&2
    echo "  $(basename "$0") --help | -h" >&2
    echo "      このヘルプを表示する" >&2
    exit 1
}

# --- send サブコマンド ---
cmd_send() {
    local agent="$1"
    shift

    # フラグ解析
    local opt_prompt=""
    local opt_async=false
    local opt_fresh=false
    local opt_port=""
    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p)
                shift
                if [[ $# -eq 0 ]]; then
                    log "ERROR: -p の後にプロンプト文字列が必要です"
                    usage
                fi
                opt_prompt="$1"
                shift
                ;;
            --async)
                opt_async=true
                shift
                ;;
            --fresh)
                opt_fresh=true
                shift
                ;;
            --port)
                shift
                if [[ $# -eq 0 ]]; then
                    log "ERROR: --port の後にポート番号が必要です"
                    usage
                fi
                opt_port="$1"
                shift
                ;;
            -*)
                log "ERROR: 不明なフラグ: $1"
                usage
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    # プロンプト決定（D-2: -p 指定 > positional 引数 > stdin パイプ）
    local prompt=""
    if [[ -n "$opt_prompt" ]]; then
        prompt="$opt_prompt"
    elif [[ ${#positional_args[@]} -gt 0 ]]; then
        prompt="${positional_args[*]}"
    elif [[ ! -t 0 ]]; then
        prompt="$(cat)"
    else
        log "ERROR: プロンプトが指定されていません。-p <prompt>、positional 引数、または stdin から入力してください"
        usage
    fi

    # ポート決定（D-5: --port 上書き or instances.conf 解決）
    local port=""
    if [[ -n "$opt_port" ]]; then
        port="$opt_port"
    else
        port="$(resolve_port "$agent")"
    fi

    # リクエストボディ構築（T-fce-01: json_encode_string で安全化、文字列連結回避）
    local encoded_prompt
    encoded_prompt="$(printf '%s' "$prompt" | json_encode_string)"

    local body=""
    case "$JSON_ENCODER" in
        jq)
            if [[ "$opt_async" == false ]]; then
                # 同期（wait:true）
                if [[ "$opt_fresh" == true ]]; then
                    body="$(jq -n --argjson p "$encoded_prompt" '{"prompt":$p,"wait":true,"fresh":true}')"
                else
                    body="$(jq -n --argjson p "$encoded_prompt" '{"prompt":$p,"wait":true}')"
                fi
            else
                # 非同期（wait なし）
                if [[ "$opt_fresh" == true ]]; then
                    body="$(jq -n --argjson p "$encoded_prompt" '{"prompt":$p,"fresh":true}')"
                else
                    body="$(jq -n --argjson p "$encoded_prompt" '{"prompt":$p}')"
                fi
            fi
            ;;
        python3)
            if [[ "$opt_async" == false ]]; then
                if [[ "$opt_fresh" == true ]]; then
                    body="$(printf '%s' "$prompt" | python3 -c 'import sys,json; p=sys.stdin.read(); print(json.dumps({"prompt":p,"wait":True,"fresh":True}))')"
                else
                    body="$(printf '%s' "$prompt" | python3 -c 'import sys,json; p=sys.stdin.read(); print(json.dumps({"prompt":p,"wait":True}))')"
                fi
            else
                if [[ "$opt_fresh" == true ]]; then
                    body="$(printf '%s' "$prompt" | python3 -c 'import sys,json; p=sys.stdin.read(); print(json.dumps({"prompt":p,"fresh":True}))')"
                else
                    body="$(printf '%s' "$prompt" | python3 -c 'import sys,json; p=sys.stdin.read(); print(json.dumps({"prompt":p}))')"
                fi
            fi
            ;;
    esac

    # 送信
    log "エージェント '${agent}' (port=${port}) にプロンプトを送信します..."
    local resp=""
    resp="$(curl -s -X POST "http://127.0.0.1:${port}/prompt" \
        -H 'Content-Type: application/json' \
        -d "$body" 2>/dev/null)" || true

    if [[ -z "$resp" ]]; then
        log "ERROR: port ${port} の ${agent} に接続できません。launch-agents.sh up で起動済みか確認してください"
        exit 1
    fi

    # 応答処理
    if [[ "$opt_async" == true ]]; then
        # 非同期: turn_id を表示
        local turn_id
        turn_id="$(json_get_field "$resp" "turn_id")"
        if [[ -z "$turn_id" ]]; then
            log "WARN: turn_id が取得できませんでした。サーバ応答: ${resp}"
        else
            echo "$turn_id"
        fi
    else
        # 同期: status が "done" なら result 本文を stdout に出力
        local status
        status="$(json_get_field "$resp" "status")"
        if [[ "$status" == "done" ]]; then
            json_get_field "$resp" "result"
        else
            log "WARN: ステータス=${status}"
            local result
            result="$(json_get_field "$resp" "result")"
            if [[ -n "$result" ]]; then
                echo "$result"
            fi
            echo "$resp" >&2
        fi
    fi
}

# --- result サブコマンド（D-3） ---
cmd_result() {
    local agent="${1:-}"
    local turn_id="${2:-}"

    if [[ -z "$agent" ]] || [[ -z "$turn_id" ]]; then
        log "ERROR: result サブコマンドには <agent> と <turn_id> の両方が必要です"
        usage
    fi

    local port
    port="$(resolve_port "$agent")"

    local resp=""
    resp="$(curl -s "http://127.0.0.1:${port}/turns/${turn_id}" 2>/dev/null)" || true

    if [[ -z "$resp" ]]; then
        log "ERROR: port ${port} の ${agent} に接続できません。launch-agents.sh up で起動済みか確認してください"
        exit 1
    fi

    local status
    status="$(json_get_field "$resp" "status")"

    if [[ -z "$status" ]]; then
        log "ターン ${turn_id} が見つかりません（応答: ${resp}）"
        exit 1
    fi

    log "status: ${status}"
    if [[ "$status" == "done" ]]; then
        json_get_field "$resp" "result"
    else
        echo "status: ${status}" >&2
        local result
        result="$(json_get_field "$resp" "result")"
        if [[ -n "$result" ]]; then
            echo "$result"
        fi
    fi
}

# --- status サブコマンド（D-3） ---
cmd_status() {
    if [[ ! -f "$INSTANCES_CONF" ]]; then
        log "ERROR: instances.conf が見つかりません: ${INSTANCES_CONF}"
        exit 1
    fi

    echo ""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local fields=()
        read -ra fields <<< "$line"
        local agent="${fields[0]:-}"
        local port="${fields[1]:-}"

        if [[ -z "$agent" ]] || [[ -z "$port" ]]; then
            continue
        fi

        echo "=== agent=${agent} port=${port} ==="
        local info_resp=""
        if info_resp="$(curl -s --max-time 3 "http://127.0.0.1:${port}/info" 2>/dev/null)" && [[ -n "$info_resp" ]]; then
            local actual_agent actual_status uptime_secs turns_processed
            actual_agent="$(json_get_field "$info_resp" "agent")"
            actual_status="$(json_get_field "$info_resp" "status")"
            uptime_secs="$(json_get_field "$info_resp" "uptime_secs")"
            turns_processed="$(json_get_field "$info_resp" "turns_processed")"
            echo "  agent:           ${actual_agent}"
            echo "  status:          ${actual_status}"
            echo "  uptime_secs:     ${uptime_secs}"
            echo "  turns_processed: ${turns_processed}"
        else
            echo "  応答なし (DOWN)"
        fi
        echo ""

    done < "$INSTANCES_CONF"
}

# --- サブコマンド dispatch（D-3） ---
case "${1:-}" in
    -h|--help)
        usage
        ;;
    "")
        usage
        ;;
    result)
        shift
        cmd_result "${1:-}" "${2:-}"
        ;;
    status)
        cmd_status
        ;;
    *)
        # 第1引数をエージェント名として cmd_send に委譲
        agent_name="$1"
        shift
        cmd_send "$agent_name" "$@"
        ;;
esac
