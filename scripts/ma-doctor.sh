#!/usr/bin/env bash
# ma-doctor.sh — マルチエージェント動作環境の report-only フル診断ツール。
#
# flutter doctor 的に 8 セクションを [OK]/[WARN]/[FAIL] で表示し、
# FAIL 行に修正ヒントを添え、末尾に件数サマリを出す。
#
# 設計原則:
#   - report-only: ~/.claude.json / PATH / 設定ファイルへの書き込みは一切しない。
#   - FAIL が 1 つでもあれば exit 1、無ければ（WARN のみ含む）exit 0。
#   - 各チェックは個別失敗で abort しない（set -e 下でも続行）。
#
# 使い方:
#   ma-doctor.sh           # 診断実行
#   ma-doctor.sh --help    # usage 表示
#   ma-doctor.sh -h        # usage 表示
#
# 詳細: README-MULTI-AGENT.md §動作環境の診断

set -euo pipefail

# --- カウンタ変数（失敗集計方式: launch-agents.sh の WR-04 を踏襲） ---
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# --- TTY 判定・カラー設定 ---
if [[ -t 1 ]]; then
    COLOR_OK="\033[32m"    # 緑
    COLOR_WARN="\033[33m"  # 黄
    COLOR_FAIL="\033[31m"  # 赤
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
else
    COLOR_OK=""
    COLOR_WARN=""
    COLOR_FAIL=""
    COLOR_RESET=""
    COLOR_BOLD=""
fi

# --- 出力ヘルパー ---
ok() {
    local msg="$1"
    OK_COUNT=$((OK_COUNT + 1))
    echo -e "${COLOR_OK}[OK]${COLOR_RESET} ${msg}"
}

warn() {
    local msg="$1"
    local hint="${2:-}"
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} ${msg}"
    if [[ -n "$hint" ]]; then
        echo "  ヒント: ${hint}"
    fi
}

fail() {
    local msg="$1"
    local hint="${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${COLOR_FAIL}[FAIL]${COLOR_RESET} ${msg}"
    if [[ -n "$hint" ]]; then
        echo "  ヒント: ${hint}"
    fi
}

# --- usage ---
usage() {
    echo "使い方: $(basename "$0") [--help|-h]"
    echo ""
    echo "マルチエージェント動作環境（ht-webif + launch-agents.sh + ma-client.sh + 各エージェント CLI"
    echo "+ 認証 + instances.conf + 稼働インスタンス）の report-only フル診断ツール。"
    echo ""
    echo "  $(basename "$0")         # 診断実行（8 セクション）"
    echo "  $(basename "$0") --help  # このヘルプを表示"
    echo ""
    echo "特徴:"
    echo "  - report-only: ~/.claude.json / PATH / 設定ファイルへの書き込みは一切しない"
    echo "  - 各チェックを [OK]/[WARN]/[FAIL] で表示し、FAIL 行に修正ヒントを付加"
    echo "  - FAIL が 1 つでもあれば exit 1、無ければ（WARN のみは）exit 0"
    echo "  - 末尾に OK/WARN/FAIL の件数サマリを表示"
    echo ""
    echo "チェック内容（8 セクション）:"
    echo "  1. インストール/PATH    ht-webif / launch-agents.sh / ma-client.sh の存在確認"
    echo "  2. 依存コマンド         ht-mcp / curl / jq or python3"
    echo "  3. agents プロファイル  AGENTS_DIR > cwd/agents > XDG global の探索"
    echo "  4. エージェントバイナリ  各プロファイルの command[0] の存在確認"
    echo "  5. 認証/セットアップ    claude 認証 / codex 認証 / opencode 前提ファイル"
    echo "  6. claude フォルダ信頼  ~/.claude.json の hasTrustDialogAccepted 確認"
    echo "  7. instances.conf      書式・重複ポート・エージェント解決確認"
    echo "  8. 稼働インスタンス     /info 応答確認"
}

# --- 引数 dispatch ---
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        # 引数なし = 診断実行（続行）
        ;;
    *)
        echo "エラー: 不明な引数: $1" >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
esac

# --- JSON エンコーダ検出（launch-agents.sh の JSON_ENCODER 方式を踏襲） ---
JSON_ENCODER=""
if command -v jq >/dev/null 2>&1; then
    JSON_ENCODER="jq"
elif command -v python3 >/dev/null 2>&1; then
    JSON_ENCODER="python3"
fi

# --- JSON フィールド取得ヘルパー（launch-agents.sh:50-61 と同形） ---
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
        *)
            echo ""
            ;;
    esac
}

# ============================================================
echo -e "${COLOR_BOLD}ma-doctor — マルチエージェント動作環境 診断${COLOR_RESET}"
echo "診断日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ============================================================
# セクション 1: インストール/PATH
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 1: インストール/PATH ===${COLOR_RESET}"

for cmd in ht-webif launch-agents.sh ma-client.sh; do
    if cmd_path="$(command -v "$cmd" 2>/dev/null)"; then
        ok "${cmd} が見つかりました: ${cmd_path}"
    else
        fail "${cmd} が PATH にありません" "just install を実行してください"
    fi
done

# ~/.local/bin が PATH に含まれるか確認
case ":$PATH:" in
    *":$HOME/.local/bin:"*)
        ok "\$HOME/.local/bin が PATH に含まれています"
        ;;
    *)
        warn "\$HOME/.local/bin が PATH に含まれていません" \
            "export PATH=\"\$HOME/.local/bin:\$PATH\" を ~/.bashrc 等に追加してください"
        ;;
esac

echo ""

# ============================================================
# セクション 2: 依存コマンド
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 2: 依存コマンド ===${COLOR_RESET}"

# ht-mcp
if command -v ht-mcp >/dev/null 2>&1; then
    ok "ht-mcp が見つかりました: $(command -v ht-mcp)"
else
    fail "ht-mcp が PATH にありません" "ht-mcp をインストールして PATH に配置してください"
fi

# curl
if command -v curl >/dev/null 2>&1; then
    ok "curl が見つかりました: $(command -v curl)"
else
    fail "curl が PATH にありません" "curl をインストールしてください（例: apt install curl）"
fi

# jq または python3（JSON エンコーダ）
if [[ -n "$JSON_ENCODER" ]]; then
    ok "JSON エンコーダ: ${JSON_ENCODER}（採用）"
else
    fail "jq か python3 のいずれかが必要です" \
        "jq または python3 をインストールしてください（例: apt install jq）"
fi

echo ""

# ============================================================
# セクション 3: agents プロファイル解決
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 3: agents プロファイル解決 ===${COLOR_RESET}"

# src/config.rs load_agents_dir の 3 段 precedence を再現（key_link）
AGENTS_DIR_RESOLVED=""
AGENTS_DIR_REASON=""

# 1) AGENTS_DIR env（非空なら最優先・存在チェックなし）
if [[ -n "${AGENTS_DIR:-}" ]]; then
    AGENTS_DIR_RESOLVED="$AGENTS_DIR"
    AGENTS_DIR_REASON="AGENTS_DIR 環境変数"
# 2) cwd/agents が dir なら採用
elif [[ -d "$(pwd)/agents" ]]; then
    AGENTS_DIR_RESOLVED="$(pwd)/agents"
    AGENTS_DIR_REASON="cwd/agents"
# 3) XDG グローバル（XDG_CONFIG_HOME が空文字なら未設定扱い）
else
    XDG_BASE="${XDG_CONFIG_HOME:-}"
    if [[ -z "$XDG_BASE" ]]; then
        XDG_BASE="${HOME}/.config"
    fi
    XDG_AGENTS="${XDG_BASE}/claude-p/agents"
    if [[ -d "$XDG_AGENTS" ]]; then
        AGENTS_DIR_RESOLVED="$XDG_AGENTS"
        AGENTS_DIR_REASON="XDG グローバル（${XDG_BASE}/claude-p/agents）"
    fi
fi

# 保持する（プロファイル名 → command[0]）の連想配列
declare -A PROFILE_COMMANDS
FOUND_PROFILE_NAMES=()

if [[ -z "$AGENTS_DIR_RESOLVED" ]]; then
    fail "agents ディレクトリが見つかりません" \
        "AGENTS_DIR を設定するか、./agents を配置するか、just install で XDG グローバルに配置してください"
else
    ok "agents ディレクトリ: ${AGENTS_DIR_RESOLVED}（根拠: ${AGENTS_DIR_REASON}）"

    # TOML ファイル列挙
    toml_files=()
    while IFS= read -r f; do
        toml_files+=("$f")
    done < <(ls "${AGENTS_DIR_RESOLVED}"/*.toml 2>/dev/null || true)

    if [[ ${#toml_files[@]} -eq 0 ]]; then
        warn "agents ディレクトリに *.toml が見つかりません" \
            "agents/*.toml を配置するか、just install を実行してください"
    else
        for toml_file in "${toml_files[@]}"; do
            profile_name="$(basename "$toml_file" .toml)"

            # command[0] 抽出: python3 tomllib 優先 → grep フォールバック
            cmd0=""
            if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
                cmd0="$(python3 -c '
import tomllib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = tomllib.load(f)
    a = d.get("command") or d.get("cmd") or []
    print(a[0] if a else "")
except Exception:
    print("")
' "$toml_file" 2>/dev/null)" || cmd0=""
            else
                # 簡易 grep: command = [...] または cmd = [...] の最初のクォート文字列
                cmd0="$(grep -E '^(command|cmd)[[:space:]]*=' "$toml_file" 2>/dev/null \
                    | head -1 \
                    | grep -oE '"[^"]*"' \
                    | head -1 \
                    | tr -d '"')" || cmd0=""
            fi

            if [[ -n "$cmd0" ]]; then
                ok "プロファイル: ${profile_name} → command[0]=${cmd0}"
                PROFILE_COMMANDS["$profile_name"]="$cmd0"
                FOUND_PROFILE_NAMES+=("$profile_name")
            else
                warn "プロファイル: ${profile_name} — command/cmd の抽出に失敗しました" \
                    "${toml_file} の command 配列を確認してください"
                FOUND_PROFILE_NAMES+=("$profile_name")
            fi
        done
    fi
fi

echo ""

# ============================================================
# セクション 4: エージェントバイナリ
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 4: エージェントバイナリ ===${COLOR_RESET}"

if [[ ${#FOUND_PROFILE_NAMES[@]} -eq 0 ]]; then
    warn "プロファイルが未解決のためエージェントバイナリを確認できません"
else
    for profile_name in "${FOUND_PROFILE_NAMES[@]}"; do
        cmd0="${PROFILE_COMMANDS[$profile_name]:-}"
        if [[ -z "$cmd0" ]]; then
            warn "${profile_name}: command[0] が未抽出のためスキップ"
            continue
        fi

        # bash ラッパーケース（例: opencode の ["bash", "scripts/opencode-runner.sh"]）
        if [[ "$cmd0" == "bash" ]]; then
            if command -v bash >/dev/null 2>&1; then
                # command[1]（ラッパースクリプトパス）を TOML から抽出
                wrapper_path=""
                if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
                    toml_file="${AGENTS_DIR_RESOLVED}/${profile_name}.toml"
                    wrapper_path="$(python3 -c '
import tomllib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = tomllib.load(f)
    a = d.get("command") or d.get("cmd") or []
    print(a[1] if len(a) > 1 else "")
except Exception:
    print("")
' "$toml_file" 2>/dev/null)" || wrapper_path=""
                else
                    # grep で 2 番目の文字列を抽出
                    toml_file="${AGENTS_DIR_RESOLVED}/${profile_name}.toml"
                    wrapper_path="$(grep -E '^(command|cmd)[[:space:]]*=' "$toml_file" 2>/dev/null \
                        | head -1 \
                        | grep -oE '"[^"]*"' \
                        | sed -n '2p' \
                        | tr -d '"')" || wrapper_path=""
                fi

                if [[ -n "$wrapper_path" ]]; then
                    # cwd 基準で解決
                    if [[ -f "$(pwd)/${wrapper_path}" ]] || [[ -f "${wrapper_path}" ]]; then
                        ok "${profile_name}: bash + ラッパースクリプト（${wrapper_path}）が見つかりました"
                    else
                        warn "${profile_name}: bash は OK だがラッパースクリプトが見つかりません: ${wrapper_path}" \
                            "該当ディレクトリで実行しているか、setup 済みか確認してください"
                    fi
                else
                    ok "${profile_name}: bash が見つかりました（ラッパーパス抽出不可）"
                fi
            else
                fail "${profile_name}: bash が PATH にありません"
            fi
        else
            if command -v "$cmd0" >/dev/null 2>&1; then
                ok "${profile_name}: ${cmd0} が見つかりました: $(command -v "$cmd0")"
            else
                warn "${profile_name}: ${cmd0} が PATH にありません" \
                    "${cmd0} CLI を PATH に配置してください"
            fi
        fi
    done
fi

echo ""

# ============================================================
# セクション 5: 認証/セットアップ
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 5: 認証/セットアップ ===${COLOR_RESET}"

if [[ ${#FOUND_PROFILE_NAMES[@]} -eq 0 ]]; then
    warn "プロファイルが未解決のため認証状態を確認できません"
else
    for profile_name in "${FOUND_PROFILE_NAMES[@]}"; do
        case "$profile_name" in
            claude)
                creds="${HOME}/.claude/.credentials.json"
                if [[ -f "$creds" ]]; then
                    ok "claude: 認証ファイルが見つかりました: ${creds}"
                else
                    fail "claude: 認証ファイルが見つかりません: ${creds}" \
                        "claude に Max サブスクリプションでログインしてください（claude auth login）"
                fi
                ;;
            codex)
                codex_home="${CODEX_HOME:-${HOME}/.codex}"
                codex_auth="${codex_home}/auth.json"
                if [[ -f "$codex_auth" ]]; then
                    ok "codex: 認証ファイルが見つかりました: ${codex_auth}（CODEX_HOME=${codex_home}）"
                else
                    warn "codex: 認証ファイルが見つかりません: ${codex_auth}（CODEX_HOME=${codex_home}）" \
                        "codex login を実行してください"
                fi
                ;;
            opencode)
                xdg_cfg="${XDG_CONFIG_HOME:-}"
                if [[ -z "$xdg_cfg" ]]; then
                    xdg_cfg="${HOME}/.config"
                fi
                turn_md="${xdg_cfg}/opencode/commands/turn.md"
                opencode_json="${xdg_cfg}/opencode/opencode.json"
                if [[ -f "$turn_md" ]] && [[ -f "$opencode_json" ]]; then
                    ok "opencode: 前提ファイルが見つかりました（turn.md / opencode.json）"
                else
                    missing_files=""
                    [[ ! -f "$turn_md" ]] && missing_files="${missing_files} turn.md"
                    [[ ! -f "$opencode_json" ]] && missing_files="${missing_files} opencode.json"
                    warn "opencode: 前提ファイルが不足しています:${missing_files}" \
                        "bash scripts/setup-opencode.sh を実行してください"
                fi
                ;;
        esac
    done
fi

echo ""

# ============================================================
# セクション 6: claude フォルダ信頼
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 6: claude フォルダ信頼 ===${COLOR_RESET}"

CLAUDE_JSON="${HOME}/.claude.json"
CWD="$(pwd)"

if [[ ! -f "$CLAUDE_JSON" ]]; then
    warn "~/.claude.json が見つかりません（確認不可）" \
        "claude を一度起動して信頼ダイアログを承認してください"
elif [[ -z "$JSON_ENCODER" ]]; then
    warn "JSON エンコーダが利用不可のため ~/.claude.json を確認できません（確認不可）" \
        "jq または python3 をインストールしてください"
else
    trusted=""
    case "$JSON_ENCODER" in
        python3)
            trusted="$(python3 -c "
import json, sys
try:
    with open('${CLAUDE_JSON}', 'r') as f:
        d = json.load(f)
    projects = d.get('projects', {})
    entry = projects.get('${CWD}', {})
    val = entry.get('hasTrustDialogAccepted', None)
    print('true' if val is True else 'false' if val is False else 'missing')
except Exception as e:
    print('error: ' + str(e))
" 2>/dev/null)" || trusted="error"
            ;;
        jq)
            trusted="$(jq -r --arg cwd "${CWD}" \
                '.projects[$cwd].hasTrustDialogAccepted // "missing"' \
                "${CLAUDE_JSON}" 2>/dev/null)" || trusted="error"
            # jq returns true/false as bare boolean strings
            ;;
    esac

    case "$trusted" in
        true)
            ok "claude フォルダ信頼: ${CWD} は信頼済み（hasTrustDialogAccepted=true）"
            ;;
        false)
            warn "claude フォルダ信頼: ${CWD} の hasTrustDialogAccepted が false" \
                "claude を該当ディレクトリで起動して信頼ダイアログを承認してください"
            ;;
        missing)
            warn "claude フォルダ信頼: ${CWD} が ~/.claude.json に未登録" \
                "新規ディレクトリでは claude を起動して信頼ダイアログを承認してください"
            ;;
        error*)
            warn "claude フォルダ信頼: ~/.claude.json のパースに失敗しました（確認不可）: ${trusted}"
            ;;
        *)
            warn "claude フォルダ信頼: 確認不可（値: ${trusted}）"
            ;;
    esac
fi

echo ""

# ============================================================
# セクション 7: instances.conf（cwd）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 7: instances.conf（cwd）===${COLOR_RESET}"

INSTANCES_CONF="$(pwd)/instances.conf"
# セクション 8 用に (agent, port) ペアを保持
declare -a INSTANCE_AGENTS=()
declare -a INSTANCE_PORTS=()
HAS_INSTANCES_CONF=false

if [[ ! -f "$INSTANCES_CONF" ]]; then
    warn "instances.conf が見つかりません: ${INSTANCES_CONF}" \
        "多重起動する場合は instances.conf を配置してください（単一インスタンスなら不要）"
else
    HAS_INSTANCES_CONF=true
    ok "instances.conf が見つかりました: ${INSTANCES_CONF}"

    # ポート重複チェック用
    declare -A SEEN_PORTS

    while IFS= read -r line || [[ -n "$line" ]]; do
        # コメント行と空行をスキップ（launch-agents.sh と同じ規則）
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local_fields=()
        read -ra local_fields <<< "$line"
        row_agent="${local_fields[0]:-}"
        row_port="${local_fields[1]:-}"

        if [[ -z "$row_agent" ]] || [[ -z "$row_port" ]]; then
            warn "instances.conf の不完全な行をスキップ: '${line}'"
            continue
        fi

        # ポート番号形式チェック
        if ! [[ "$row_port" =~ ^[0-9]+$ ]]; then
            fail "instances.conf: ポート番号が不正: ${row_port}（agent: ${row_agent}）" \
                "ポートは数字のみ（例: 8080）にしてください"
            continue
        fi

        # ポート重複チェック
        if [[ -n "${SEEN_PORTS[$row_port]:-}" ]]; then
            fail "instances.conf: ポート重複: ${row_port}（agent: ${row_agent} と ${SEEN_PORTS[$row_port]}）" \
                "各インスタンスに別のポートを割り当ててください"
            continue
        fi
        SEEN_PORTS["$row_port"]="$row_agent"

        # エージェントプロファイル解決可能か確認
        if [[ -n "$AGENTS_DIR_RESOLVED" ]]; then
            if [[ -f "${AGENTS_DIR_RESOLVED}/${row_agent}.toml" ]]; then
                ok "instances.conf: agent=${row_agent} port=${row_port} — プロファイル解決 OK"
            else
                warn "instances.conf: agent=${row_agent} port=${row_port} — プロファイルが見つかりません" \
                    "${AGENTS_DIR_RESOLVED}/${row_agent}.toml を作成してください"
            fi
        else
            ok "instances.conf: agent=${row_agent} port=${row_port}（agents ディレクトリ未解決のためプロファイル確認スキップ）"
        fi

        INSTANCE_AGENTS+=("$row_agent")
        INSTANCE_PORTS+=("$row_port")

    done < "$INSTANCES_CONF"
fi

echo ""

# ============================================================
# セクション 8: 稼働インスタンス（instances.conf がある場合のみ）
# ============================================================
echo -e "${COLOR_BOLD}=== セクション 8: 稼働インスタンス ===${COLOR_RESET}"

if [[ "$HAS_INSTANCES_CONF" == false ]]; then
    echo "  instances.conf が無いためスキップします"
elif [[ ${#INSTANCE_AGENTS[@]} -eq 0 ]]; then
    echo "  instances.conf にエントリが見つかりません（スキップ）"
else
    for i in "${!INSTANCE_AGENTS[@]}"; do
        inst_agent="${INSTANCE_AGENTS[$i]}"
        inst_port="${INSTANCE_PORTS[$i]}"

        info_resp=""
        if info_resp="$(curl -s --max-time 3 "http://127.0.0.1:${inst_port}/info" 2>/dev/null)" \
            && [[ -n "$info_resp" ]]; then
            # 応答あり
            actual_agent="$(json_get_field "$info_resp" "agent")"
            actual_status="$(json_get_field "$info_resp" "status")"
            uptime_secs="$(json_get_field "$info_resp" "uptime_secs")"
            turns_processed="$(json_get_field "$info_resp" "turns_processed")"

            if [[ -n "$actual_agent" ]] && [[ "$actual_agent" != "$inst_agent" ]]; then
                warn "instances.conf: agent=${inst_agent} port=${inst_port} — 応答エージェントが不一致: ${actual_agent}" \
                    "ポート衝突の可能性。別エージェントが同 port を使用中かもしれません"
            else
                ok "instances.conf: agent=${inst_agent} port=${inst_port} — 応答あり（status=${actual_status} uptime=${uptime_secs}s turns=${turns_processed}）"
            fi
        else
            # 未応答: カウンタは増やさない（起動前は正常）
            echo "  [INFO] agent=${inst_agent} port=${inst_port} — DOWN（未応答）起動前であれば正常"
        fi
    done
fi

echo ""

# ============================================================
# 末尾サマリ（D-3）
# ============================================================
echo "------------------------------------------------------------"
echo -e "診断結果: ${COLOR_OK}OK=${OK_COUNT}${COLOR_RESET} ${COLOR_WARN}WARN=${WARN_COUNT}${COLOR_RESET} ${COLOR_FAIL}FAIL=${FAIL_COUNT}${COLOR_RESET}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "FAIL が ${FAIL_COUNT} 件あります。上記のヒントを参照して修正してください。"
    exit 1
fi

exit 0
