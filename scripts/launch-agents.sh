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
#   TURNS:    $(pwd)/turns-${PORT}/${AGENT}/
#             （WR-01: サーバは TURNS_DIR=turns-${PORT} に D-16 の <agent>/ を付与して
#              turns-${PORT}/${AGENT}/ に書き込む。ポート分離は launcher が注入する
#              turns-${PORT} の差で成立し、<agent>/ は D-16 が付ける実効サブディレクトリ。）
#
# D-03: instances.conf は $(pwd)/instances.conf のみから読む。
# PATH から ht-webif を発見する（D-04）。`just install` でインストール済みであること。

set -euo pipefail

# --- パス定数（D-03: cwd 基準） ---
INSTANCES_CONF="$(pwd)/instances.conf"

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
# 戻り値（WR-06）:
#   0 = /info が応答し agent が一致（ready）
#   1 = /info が未応答 or agent フィールド取得不可（まだ起動中）
#   2 = /info が応答したが agent が別名（ポート衝突: 別エージェントが使用中）
# 呼び出し側は 2 を「未応答」ではなく即時ハード失敗として扱うこと。
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
    if [[ -z "$actual" ]]; then
        return 1
    fi
    if [[ "$actual" != "$expected_agent" ]]; then
        # /info は応答しているが期待エージェントと異なる = ポート衝突
        return 2
    fi
    return 0
}

# --- up サブコマンド（D-07/D-08: 設定ファイル駆動の一括起動 + readiness 確認） ---
cmd_up() {
    log "instances.conf からインスタンスを起動します: ${INSTANCES_CONF}"

    # D-04: PATH から ht-webif を発見する（cargo build は不要）。
    # `just install` で ~/.local/bin に配置済みであること。
    local server_bin
    server_bin="$(command -v ht-webif)" || {
        log "ERROR: ht-webif が PATH にありません。just install を実行してください"
        exit 1
    }
    log "ht-webif を発見: ${server_bin}"

    # WR-04: インスタンス単位の失敗を集計し、ループは中断せず最後にまとめて非ゼロ終了する。
    # これで「起動できるインスタンスは起動し、失敗したものだけ報告する」挙動になる。
    local failures=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # <agent> <port> [KEY=VALUE ...] をパース
        # WR-02: 一度だけ配列としてパースし、KEY=VALUE トークンの境界を保持する。
        # 旧実装は awk で再結合 → tr で空白再分割していたため、値に空白を含む
        # トークン（例 CODEX_HOME=/home/user/My Configs/.codex）が壊れて
        # 末尾が捨てられていた。配列スライスでトークン単位を維持する。
        local agent port
        local fields=()
        read -ra fields <<< "$line"
        agent="${fields[0]:-}"
        port="${fields[1]:-}"
        # extra_kvs: 3列目以降の KEY=VALUE トークン列（列区切りは空白）
        # bash 3.2 (macOS /bin/bash) は set -u 下で空配列の "${arr[@]}" 展開を
        # unbound variable 扱いする（bash 4.4 で修正）。3列目が無い行では空スライスに
        # なるため、長さガードで空配列を明示的に作って後段の展開を安全にする。
        local extra_kvs=()
        [ "${#fields[@]}" -gt 2 ] && extra_kvs=("${fields[@]:2}")

        if [[ -z "$agent" ]] || [[ -z "$port" ]]; then
            log "WARN: 不正な行をスキップします: ${line}"
            continue
        fi

        local pid_file="/tmp/ht-webif-${port}.pid"
        local log_file="/tmp/ht-webif-${port}.log"
        # WR-01: サーバは TURNS_DIR(=turns-${port}) に D-16 の <agent>/ を付与する。
        # 表示・報告には実効パス turns-${port}/${agent} を使う（cwd 基準）。
        local turns_dir="$(pwd)/turns-${port}/${agent}"

        log "起動中: agent=${agent} port=${port} turns_dir=${turns_dir}"

        # 既存 PID ファイル確認
        if [[ -f "$pid_file" ]]; then
            local existing_pid
            existing_pid=$(cat "$pid_file" 2>/dev/null || true)
            # WR-05: PID ファイルの内容が数値であることを検証する。空・非数値（部分書き込みや
            # クラッシュで壊れたファイル）なら破棄して新規起動に進む。
            if ! [[ "$existing_pid" =~ ^[0-9]+$ ]]; then
                log "  WARN: 不正な PID ファイルを削除します: ${pid_file} (内容: ${existing_pid:-<empty>})"
                rm -f "$pid_file"
            elif kill -0 "$existing_pid" 2>/dev/null; then
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
        # D-03: ユーザの cwd を維持する（cd しない）。TURNS_DIR は絶対パスで明示する。
        (
            # extra_kvs の各 KEY=VALUE を export する（eval なし、トークン境界保持）
            # ${arr[@]+"${arr[@]}"} は bash 3.2 でも空配列を安全に展開する（set -u 対応）。
            for kv in ${extra_kvs[@]+"${extra_kvs[@]}"}; do
                [[ -z "$kv" ]] && continue
                # KEY=VALUE の形式のみ受け付ける（安全ガード）
                if [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                    export "$kv"
                else
                    log "WARN: 不正な env トークンをスキップします: ${kv}"
                fi
            done
            # ht-webif は driven な claude TUI を spawn する。親が Claude Code セッション
            # （例: gsd-moonlighting を Claude から起動）だと CLAUDECODE / CLAUDE_CODE_* /
            # CLAUDE_CODE_SESSION_ID / CLAUDE_CODE_CHILD_SESSION が漏れ継承され、driven claude が
            # 「ネストした子セッション」と誤認して通常の対話ターンを開始しない（プロンプト未処理）。
            # spawn 前に親の Claude Code セッション系 env をスクラブする（auth 用 CLAUDE_CONFIG_DIR
            # 等は CLAUDE_CODE_ プレフィックスに含まれないため温存される）。
            while IFS='=' read -r _k _; do unset "$_k"; done \
                < <(env | grep -E '^(CLAUDECODE=|CLAUDE_CODE_|CLAUDE_EFFORT=|AI_AGENT=|CLAUDE_PLUGIN_DATA=)')

            # D-04: PATH から発見したバイナリを直接 spawn する（cargo run ラッパーを挟まない）。
            # $! は ht-webif 本体の PID になり、down-all の SIGTERM/SIGKILL が確実に届く。
            # TURNS_DIR を cwd 基準の絶対パスで注入（D-16: ポート別 turns ディレクトリ分離）。
            # CLAUDE_CODE_NO_FLICKER=1: 上のスクラブで CLAUDE_CODE_* を全消去した後、driven claude
            # 用にこれだけ再注入する。Claude Code v2.1.193+ は未設定だと初回に「Try the new
            # fullscreen renderer?」オンボーディング選択を表示し、TUI が ready に到達せず ht-webif の
            # readiness がタイムアウト → 起動失敗する（trust ダイアログと同類の footgun）。事前選択で抑止。
            nohup env PORT="${port}" TURNS_DIR="$(pwd)/turns-${port}" AGENT="${agent}" \
                CLAUDE_CODE_NO_FLICKER="1" \
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
            log "ERROR: PID ファイルが作成されませんでした: ${pid_file} (agent=${agent} port=${port})"
            failures=$((failures + 1))
            continue
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
                # WR-04: このインスタンスを失敗としてカウントし、for を抜けて次のインスタンスへ
                # （continue 2 で while ループの次イテレーションへ）。
                failures=$((failures + 1))
                continue 2
            fi

            # WR-06: 戻り値を捕捉し、別エージェント衝突（2）は即時ハード失敗にする。
            local check_rc=0
            check_info_agent "$port" "$agent" || check_rc=$?
            if [[ $check_rc -eq 0 ]]; then
                log "  起動完了: agent=${agent} port=${port} pid=${pid} turns_dir=${turns_dir}"
                break
            elif [[ $check_rc -eq 2 ]]; then
                log "ERROR: port ${port} は別エージェントが使用中です（期待: ${agent}）。ポート衝突のため起動を中止します。"
                # 起動した可能性のある自プロセスは別ポート衝突なので触らない（衝突相手は別インスタンス）。
                # 自分が spawn した pid のみ後始末する。
                kill -TERM "$pid" 2>/dev/null || true
                rm -f "$pid_file"
                failures=$((failures + 1))
                continue 2
            fi

            if (( i % 10 == 0 )); then
                log "  待機中 (${i}s/60s)... agent=${agent} port=${port}"
            fi
            sleep 1
        done

        # 最終確認（タイムアウト判定）。WR-06: ここでも 2 を衝突として区別する。
        local final_rc=0
        check_info_agent "$port" "$agent" || final_rc=$?
        if [[ $final_rc -ne 0 ]]; then
            if [[ $final_rc -eq 2 ]]; then
                log "ERROR: port ${port} は別エージェントが使用中です（期待: ${agent}）。ポート衝突。"
            else
                log "ERROR: 60 秒待ってもインスタンスが応答しませんでした (agent=${agent} port=${port})"
            fi
            if [[ -f "$log_file" ]]; then
                log "ログ末尾 20 行:"
                tail -n 20 "$log_file" >&2
            fi
            # WR-04: 失敗としてカウントして次のインスタンスへ。
            failures=$((failures + 1))
            continue
        fi

    done < "$INSTANCES_CONF"

    # WR-04: 1件でも失敗があれば最後に非ゼロ終了する（成功分は起動済み）。
    if [[ $failures -gt 0 ]]; then
        log "ERROR: ${failures} 件のインスタンスが起動に失敗しました"
        exit 1
    fi

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
        pid=$(cat "$pid_file" 2>/dev/null || true)

        # WR-05: 不正な PID（空・非数値）なら kill に渡さず、ファイルだけ破棄する。
        # 空 PID を「停止済み」と誤認して生存サーバを放置するのを防ぐ。
        if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
            log "  WARN: 不正な PID ファイル: ${pid_file} (内容: ${pid:-<empty>}) — 削除します"
            rm -f "$pid_file"
            continue
        fi

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
        # WR-01: サーバの実効書き込み先は turns-${port}/${agent}（D-16）。cwd 基準で表示。
        local turns_dir="$(pwd)/turns-${port}/${agent}"

        echo "=== agent=${agent} port=${port} ==="
        echo "  TURNS_DIR: ${turns_dir}"
        echo "  PID_FILE:  ${pid_file}"
        echo "  LOG_FILE:  ${log_file}"

        # PID 情報
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file" 2>/dev/null || true)
            # WR-05: 非数値 PID は kill -0 に渡さず明示表示する。
            if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
                echo "  PID:       (不正な PID ファイル: ${pid:-<empty>})"
            else
                echo "  PID:       ${pid}"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "  PROCESS:   生存"
                else
                    echo "  PROCESS:   死亡（PID ファイルが残存）"
                fi
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
