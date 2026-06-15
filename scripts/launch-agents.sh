#!/usr/bin/env bash
# launch-agents.sh — instances.conf 駆動の多重インスタンス起動/停止/状態確認オーケストレータ。
#
# 使い方:
#   launch-agents.sh up          instances.conf の全インスタンスを起動し readiness を確認する
#   launch-agents.sh down-all    instances.conf の全インスタンスを停止する（SIGTERM → SIGKILL）
#   launch-agents.sh status      各インスタンスの /info を叩いて状態を表示する
#
# per-instance 規約（claude-p 準拠）:
#   PID:      /tmp/ht-webif-${PORT}.pid
#   LOG:      /tmp/ht-webif-${PORT}.log
#   TURNS:    ${WEBIF_DIR}/turns-${PORT}/${AGENT}/
#             （WR-01: サーバは TURNS_DIR=turns-${PORT} に D-16 の <agent>/ を付与して
#              turns-${PORT}/${AGENT}/ に書き込む。ポート分離は launcher が注入する
#              turns-${PORT} の差で成立し、<agent>/ は D-16 が付ける実効サブディレクトリ。）

set -euo pipefail

# --- パス定数 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_CONF="${WEBIF_DIR}/instances.conf"

# --- ログヘルパー ---
log() {
    echo "[launch-agents] $*" >&2
}

# --- 設定ファイル存在確認 ---
if [[ ! -f "$INSTANCES_CONF" ]]; then
    log "ERROR: 設定ファイルが見つかりません: ${INSTANCES_CONF}"
    exit 1
fi

# --- ツール検出（JSON エンコーダ） ---
# jq 優先、なければ python3（claude-p の JSON_ENCODER 検出と同じ規約）
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

# --- JSON フィールド取得ヘルパー ---
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

# --- Readiness ヘルパー（D-09: /info の agent 名一致ポーリング） ---
# check_info_agent port expected_agent
# /info を叩いて agent フィールドが expected_agent と一致すれば return 0。
check_info_agent() {
    local port="$1"
    local expected_agent="$2"
    local resp
    resp=$(curl -s --max-time 2 "http://127.0.0.1:${port}/info" 2>/dev/null) || return 1
    if [[ -z "$resp" ]]; then
        return 1
    fi
    local actual
    actual=$(json_get_field "$resp" "agent") || return 1
    [[ "$actual" == "$expected_agent" ]]
}

# --- up サブコマンド（D-07/D-08: 設定ファイル駆動の一括起動 + readiness 確認） ---
cmd_up() {
    log "instances.conf からインスタンスを起動します: ${INSTANCES_CONF}"

    # CR-01: cargo run ラッパーではなくビルド済みバイナリを直接起動するため、
    # ループ前に一度だけリリースビルドする。これにより $! が実サーバの PID になり、
    # down-all の SIGTERM が cargo ラッパーではなく ht-webif 本体に届く。
    local server_bin="${WEBIF_DIR}/target/release/ht-webif"
    log "リリースビルド中: ${server_bin}"
    if ! (cd "$WEBIF_DIR" && cargo build --release) >&2; then
        log "ERROR: cargo build --release に失敗しました"
        exit 1
    fi
    if [[ ! -x "$server_bin" ]]; then
        log "ERROR: ビルド済みバイナリが見つかりません: ${server_bin}"
        exit 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # <agent> <port> [KEY=VALUE ...] をパース
        local agent port
        read -r agent port <<< "$line"
        # extra_env_tokens: KEY=VALUE トークン列（3列目以降）
        local extra_tokens
        extra_tokens=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i}' | sed 's/ $//')

        if [[ -z "$agent" ]] || [[ -z "$port" ]]; then
            log "WARN: 不正な行をスキップします: ${line}"
            continue
        fi

        local pid_file="/tmp/ht-webif-${port}.pid"
        local log_file="/tmp/ht-webif-${port}.log"
        # WR-01: サーバは TURNS_DIR(=turns-${port}) に D-16 の <agent>/ を付与する。
        # 表示・報告には実効パス turns-${port}/${agent} を使う。
        local turns_dir="${WEBIF_DIR}/turns-${port}/${agent}"

        log "起動中: agent=${agent} port=${port} turns_dir=${turns_dir}"

        # 既存 PID ファイル確認
        if [[ -f "$pid_file" ]]; then
            local existing_pid
            existing_pid=$(cat "$pid_file")
            if kill -0 "$existing_pid" 2>/dev/null; then
                log "  既に起動済み (pid=${existing_pid})。スキップします。"
                continue
            else
                log "  古い PID ファイルを削除します (旧 pid=${existing_pid})"
                rm -f "$pid_file"
            fi
        fi

        # WR-01: turns ディレクトリの事前作成は不要（サーバが起動時に create_dir_all で
        # turns-${port}/${agent} を作る）。launcher 側で turns-${port} だけ作っても
        # サーバの実効パス turns-${port}/${agent} とずれるため、ここでは作らない。

        # extra_env を export した上でデーモン spawn（T-06-03: eval 不使用、export で逐次適用）
        (
            cd "$WEBIF_DIR"
            # extra_env_tokens の各 KEY=VALUE を export する（eval なし）
            if [[ -n "$extra_tokens" ]]; then
                while IFS= read -r kv; do
                    [[ -z "$kv" ]] && continue
                    # KEY=VALUE の形式のみ受け付ける（安全ガード）
                    if [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                        export "$kv"
                    else
                        log "WARN: 不正な env トークンをスキップします: ${kv}"
                    fi
                done <<< "$(echo "$extra_tokens" | tr ' ' '\n')"
            fi
            # CR-01: ビルド済みバイナリを直接 spawn する（cargo run ラッパーを挟まない）。
            # $! は ht-webif 本体の PID になり、down-all の SIGTERM/SIGKILL が確実に届く。
            # TURNS_DIR を turns-${port} として spawn（D-16: ポート別 turns ディレクトリ分離）。
            nohup env PORT="${port}" TURNS_DIR="${WEBIF_DIR}/turns-${port}" AGENT="${agent}" \
                "$server_bin" >"${log_file}" 2>&1 &
            local pid=$!
            echo "$pid" > "${pid_file}"
            disown "$pid"
        )

        # PID ファイルが書かれるまで待つ（最大 5 秒）
        local pid=""
        local wait_pid=0
        while [[ $wait_pid -lt 5 ]]; do
            if [[ -f "$pid_file" ]]; then
                pid=$(cat "$pid_file")
                break
            fi
            sleep 1
            (( wait_pid++ )) || true
        done

        if [[ -z "$pid" ]]; then
            log "ERROR: PID ファイルが作成されませんでした: ${pid_file}"
            exit 1
        fi

        log "  PID: ${pid} — readiness 待機中（最大 60s）..."

        # Readiness ポーリング（D-09: /info の agent 名一致まで待つ）
        local i
        for i in $(seq 1 60); do
            # 早期死亡検知
            if ! kill -0 "$pid" 2>/dev/null; then
                log "ERROR: プロセスが終了しました (agent=${agent} port=${port})"
                if [[ -f "$log_file" ]]; then
                    log "ログ末尾 20 行:"
                    tail -n 20 "$log_file" >&2
                fi
                rm -f "$pid_file"
                exit 1
            fi

            if check_info_agent "$port" "$agent"; then
                log "  起動完了: agent=${agent} port=${port} pid=${pid} turns_dir=${turns_dir}"
                break
            fi

            if (( i % 10 == 0 )); then
                log "  待機中 (${i}s/60s)... agent=${agent} port=${port}"
            fi
            sleep 1
        done

        if ! check_info_agent "$port" "$agent"; then
            log "ERROR: 60 秒待ってもインスタンスが応答しませんでした (agent=${agent} port=${port})"
            if [[ -f "$log_file" ]]; then
                log "ログ末尾 20 行:"
                tail -n 20 "$log_file" >&2
            fi
            exit 1
        fi

    done < "$INSTANCES_CONF"

    log "全インスタンス起動完了"
}

# --- down-all サブコマンド（D-08: 全 PID に SIGTERM → SIGKILL） ---
cmd_down_all() {
    log "全インスタンスを停止します..."

    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local agent port
        read -r agent port <<< "$line"

        if [[ -z "$agent" ]] || [[ -z "$port" ]]; then
            continue
        fi

        local pid_file="/tmp/ht-webif-${port}.pid"

        if [[ ! -f "$pid_file" ]]; then
            log "  PID ファイルなし: agent=${agent} port=${port} — スキップ"
            continue
        fi

        local pid
        pid=$(cat "$pid_file")

        if ! kill -0 "$pid" 2>/dev/null; then
            log "  プロセスは既に停止: agent=${agent} port=${port} pid=${pid}"
            rm -f "$pid_file"
            continue
        fi

        log "  停止中: agent=${agent} port=${port} pid=${pid}"
        kill -TERM "$pid" 2>/dev/null || true

        # 最大 5 秒待つ（claude-p の stop ロジック踏襲）
        local i
        for i in 1 2 3 4 5; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done

        # まだ生きていれば強制終了
        if kill -0 "$pid" 2>/dev/null; then
            log "  SIGKILL 送信: agent=${agent} port=${port} pid=${pid}"
            kill -KILL "$pid" 2>/dev/null || true
        fi

        rm -f "$pid_file"
        log "  停止完了: agent=${agent} port=${port}"

    done < "$INSTANCES_CONF"

    log "全インスタンス停止完了"
}

# --- status サブコマンド（D-08: 各インスタンスの /info を叩いて状態表示） ---
cmd_status() {
    log "インスタンス状態を確認します..."
    echo ""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local agent port
        read -r agent port <<< "$line"

        if [[ -z "$agent" ]] || [[ -z "$port" ]]; then
            continue
        fi

        local pid_file="/tmp/ht-webif-${port}.pid"
        local log_file="/tmp/ht-webif-${port}.log"
        # WR-01: サーバの実効書き込み先は turns-${port}/${agent}（D-16）。
        local turns_dir="${WEBIF_DIR}/turns-${port}/${agent}"

        echo "=== agent=${agent} port=${port} ==="
        echo "  TURNS_DIR: ${turns_dir}"
        echo "  PID_FILE:  ${pid_file}"
        echo "  LOG_FILE:  ${log_file}"

        # PID 情報
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            echo "  PID:       ${pid}"
            if kill -0 "$pid" 2>/dev/null; then
                echo "  PROCESS:   生存"
            else
                echo "  PROCESS:   死亡（PID ファイルが残存）"
            fi
        else
            echo "  PID:       (PID ファイルなし)"
        fi

        # /info を叩いて JSON レスポンスを表示
        local info_resp
        if info_resp=$(curl -s --max-time 3 "http://127.0.0.1:${port}/info" 2>/dev/null) && [[ -n "$info_resp" ]]; then
            local actual_agent actual_status uptime_secs turns_processed
            actual_agent=$(json_get_field "$info_resp" "agent")
            actual_status=$(json_get_field "$info_resp" "status")
            uptime_secs=$(json_get_field "$info_resp" "uptime_secs")
            turns_processed=$(json_get_field "$info_resp" "turns_processed")
            echo "  /info:"
            echo "    agent:           ${actual_agent}"
            echo "    status:          ${actual_status}"
            echo "    uptime_secs:     ${uptime_secs}"
            echo "    turns_processed: ${turns_processed}"
        else
            echo "  /info:     応答なし (DOWN)"
        fi
        echo ""

    done < "$INSTANCES_CONF"
}

# --- サブコマンド dispatch ---
usage() {
    echo "[launch-agents] 使い方:" >&2
    echo "  $(basename "$0") up          全インスタンスを起動する" >&2
    echo "  $(basename "$0") down-all    全インスタンスを停止する" >&2
    echo "  $(basename "$0") status      各インスタンスの状態を表示する" >&2
    exit 1
}

case "${1:-}" in
    up)        cmd_up ;;
    down-all)  cmd_down_all ;;
    status)    cmd_status ;;
    *)         usage ;;
esac
