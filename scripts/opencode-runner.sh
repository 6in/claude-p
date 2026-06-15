#!/usr/bin/env bash
# opencode-runner.sh — opencode run ラッパー（ht-webif AGENT=opencode 用）
#
# ht-webif / ht-mcp は「長期起動のエージェントプロセス」を想定する設計だが、
# opencode TUI 経由のキーストローク注入は PTY 内で安定動作しない（Pitfall 9）。
# このラッパーは stdin から1行ずつトリガーを受け取り `opencode run --command turn <path>`
# を呼び出す。`opencode run` は非対話モードで動作し、ファイル書き込み後に終了する。
#
# ready_pattern: "OpenCodeRunner ready"
# trigger_template (opencode.toml): "opencode run --command turn {prompt_path}"
#
# 設計メモ（D-08: Pitfall 9 - opencode TUI keystroke injection failure）:
#   - opencode TUI を ht-mcp PTY 内で起動しても /turn コマンドが処理されない問題の回避策。
#   - opencode run はコマンドライン引数でプロンプトを受け取る非対話モード。
#   - このラッパーは stdin を監視し、受け取った行を eval で実行する。
#   - PTY 内での echo を抑制して安定動作させる。

set -u

# PTY の echo を抑制（入力文字が端末に反射されないようにする）
stty -echo 2>/dev/null || true

# 準備完了シグナル: ht-webif の ready_pattern がこの文字列を検出する
echo "OpenCodeRunner ready"

while true; do
    # 1行読み込む（タイムアウトなし — ht-webif が turn timeout 後に recreate を呼ぶため不要）
    if IFS= read -r trigger; then
        if [[ -n "$trigger" ]]; then
            # トリガーを実行（例: "opencode run --command turn ./turns/opencode/prompt-xxx.txt"）
            # eval は引数分割のために使用。パスにスペースを含む場合は問題になるが、
            # turnId 形式（YYYYMMDD-HHMMSS-mmm）はスペースを含まないため安全。
            # WR-02: opencode run 失敗（認証切れ・モデルエラー・非ゼロ終了）を握り潰さず
            # 終了コードを stderr にログする。stdout（PTY 画面 = ht-mcp が拾うスナップショット）
            # に混ぜないことで ready_pattern 誤検出やスナップショット汚染を避ける。
            # ループは継続する（次ターンの ready 再送出のため）。
            # rc は eval 直後に取得する。`if ! eval` の then 節内では $? が
            # 否定演算子の結果（0）になり eval の終了コードを取りこぼすため、
            # 一旦 rc に退避してから判定する。
            rc=0
            eval "$trigger" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                echo "[opencode-runner] WARN: trigger 失敗 (rc=${rc}): $trigger" >&2
            fi
        fi
        # 次のターン用に準備完了シグナルを再送出
        echo "OpenCodeRunner ready"
    else
        # stdin が閉じた（ht-mcp セッション終了）
        break
    fi
done
