# Phase 5: Codex CLI and OpenCode Validation - Pattern Map

**Mapped:** 2026-06-12
**Files analyzed:** 5 (2 TOML configs, 3 bash scripts)
**Analogs found:** 5 / 5

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `agents/codex.toml` | config | request-response | `agents/claude.toml` | exact |
| `agents/opencode.toml` | config | request-response | `agents/claude.toml` | exact |
| `scripts/e2e-codex.sh` | utility/test | request-response | `scripts/smoke.sh` | role-match |
| `scripts/e2e-opencode.sh` | utility/test | request-response | `scripts/smoke.sh` | role-match |
| `scripts/setup-opencode.sh` | utility | file-I/O | `scripts/smoke.sh` (structure only) | partial |

---

## Pattern Assignments

### `agents/codex.toml` (config, request-response)

**Analog:** `agents/claude.toml` (lines 1–36)

**File header comment pattern** (lines 1–5 of claude.toml):
```toml
# agents/claude.toml
# Claude Code（claude CLI）エージェントプロファイル。
# 新プロファイル作成時のテンプレートとして使用してください。
# 各フィールドの説明を参考に agents/<name>.toml を追加するだけで新エージェントを登録できます。
```
For codex.toml, adapt to include prerequisite block (auth + trust setup) as multi-line comments.

**Field ordering and comment style** (all fields in claude.toml):
```toml
# spawn コマンド（例: ["claude"] / ["codex", "--yolo"] / ["opencode"]）
command = ["claude"]

# TUI が ready 状態になったと判定する部分文字列
ready_pattern = "auto mode"

# fresh リセット方式: "command" = clear_command 送信 / "respawn" = セッション kill+再生成
fresh_mode = "command"

# fresh リセット方式: "command" = clear_command 送信 / "respawn" = セッション kill+再生成
clear_command = "/clear"

# 出力規約テンプレート。{result_path} と {status_path} の両プレースホルダが必須。
output_covenant = """..."""

# トリガーメッセージテンプレート。{prompt_path} プレースホルダが必須。
trigger_template = "..."

# チューニング値（未指定なら以下のデフォルトが使われる）
# startup_timeout_secs = 25
# turn_timeout_secs = 300

# モデル選択（コメントアウト例 — 使用する場合は両方指定）
# model_flag = "--model"
# model_value = "opus"
```

**Codex-specific values** (from 05-RESEARCH.md Pattern 1, D-12):
- `command = ["codex", "--dangerously-bypass-approvals-and-sandbox"]`
- `ready_pattern = "YOLO mode"`
- `fresh_mode = "command"` + `clear_command = "/clear"`
- `trigger_template = "{prompt_path} を読んで、その指示に従ってください。"` (Japanese OK for Codex — VERIFIED)
- `output_covenant` — Japanese text OK (copy from claude.toml covenant, substitute ht-webif branding)
- `startup_timeout_secs = 15` (3s observed; 15s generous)
- `turn_timeout_secs = 300` (18-27s observed for simple tasks)
- Comment: actual measured times in TOML comments (Codex startup ~3s / E2E 18-27s)

**Field name note:** `agents/claude.toml` uses `command =` (line 7). `src/profile.rs` must be checked to confirm the canonical field name (`cmd` vs `command`). RESEARCH.md Pattern 1 uses `cmd =`. Use whichever `src/profile.rs` defines as the struct field name.

---

### `agents/opencode.toml` (config, request-response)

**Analog:** `agents/claude.toml` (lines 1–36)

Same field ordering and comment style as codex.toml above.

**OpenCode-specific values** (from 05-RESEARCH.md Pattern 2, D-13):
- `command = ["opencode"]`
- `ready_pattern = "Ask anything"`
- `fresh_mode = "respawn"` (D-01/D-02: try `/new` first; if dialog blocks, switch to respawn — RESEARCH recommends respawn as safe default)
- `clear_command = "/new"` (present but note the two-Enter dialog limitation in comments)
- `trigger_template = "/turn {prompt_path}"` (ASCII-only — CRITICAL, Japanese silently dropped — Pitfall 1)
- `output_covenant` — English only (multibyte constraint — Pitfall 1); copy from RESEARCH.md Pattern 2
- `startup_timeout_secs = 15` (4-8s observed; 15s adequate)
- `turn_timeout_secs = 300`

**Warning comment block** — copy ht-mcp multibyte warning, /new dialog warning, GLM-4.6 covenant warning from RESEARCH.md Pattern 2 (lines 211–226 of 05-RESEARCH.md).

**Prerequisite comment** (D-06): must reference `bash scripts/setup-opencode.sh` and `opencode auth login`.

---

### `scripts/e2e-codex.sh` (utility/test, request-response)

**Analog:** `scripts/smoke.sh` (lines 1–155)

**Shebang + strict mode pattern** (smoke.sh lines 1–8):
```bash
#!/usr/bin/env bash
# [description]
set -euo pipefail
```

**Path constant pattern** (smoke.sh lines 9–17):
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBIF_DIR="$SCRIPT_DIR/.."
PORT="${PORT:-8080}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="/tmp/ht-webif-smoke-$$.log"
```
For e2e-codex.sh: use `PORT="${PORT:-8081}"` (dedicated port per D-07), `AGENT=codex`, `TURNS_DIR="./turns/codex"`.

**PID tracking + global var pattern** (smoke.sh lines 19–23):
```bash
CARGO_PID=""
EXIT_CODE=0
```

**log() helper pattern** (smoke.sh lines 24–27):
```bash
log() {
    echo "[smoke] $*" >&2
}
```
For e2e scripts: use `[e2e-codex]` / `[e2e-opencode]` tag.

**cleanup + trap pattern** (smoke.sh lines 41–67):
```bash
cleanup() {
    local rc=$?
    if [[ -n "$CARGO_PID" ]] && kill -0 "$CARGO_PID" 2>/dev/null; then
        kill -TERM "$CARGO_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$CARGO_PID" 2>/dev/null || break
            sleep 1
        done
        kill -0 "$CARGO_PID" 2>/dev/null && kill -KILL "$CARGO_PID" 2>/dev/null || true
    fi
    ...
}
trap cleanup EXIT INT TERM
```

**require_tool() helper pattern** (smoke.sh lines 29–39):
```bash
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
```

**Server start pattern** (smoke.sh lines 87–91):
```bash
cd "$WEBIF_DIR"
log "ビルド + 起動中... (PORT=${PORT}, ログ: $LOG_FILE)"
cargo run --release >"$LOG_FILE" 2>&1 &
CARGO_PID=$!
```
For e2e scripts: use `AGENT=codex PORT=8081 TURNS_DIR=./turns/codex cargo run --release`.

**wait_for_server() polling pattern** (smoke.sh lines 93–116):
```bash
wait_for_server() {
    local i
    for i in $(seq 1 60); do
        if ! kill -0 "$CARGO_PID" 2>/dev/null; then
            log "ERROR: cargo run プロセスが終了しました"
            exit 1
        fi
        if curl -s -o /dev/null --max-time 2 "$BASE_URL/turns/0" 2>/dev/null; then
            return 0
        fi
        if (( i % 5 == 0 )); then
            log "サーバ起動待機中 (${i}s/60s)..."
        fi
        sleep 1
    done
    log "ERROR: 60 秒待ってもサーバが応答しませんでした"
    exit 1
}
```

**curl POST + response check pattern** (smoke.sh lines 121–151):
```bash
response=""
if ! response=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "...", "wait": true}'); then
    log "ERROR: curl 失敗"
    exit 1
fi
status=$(echo "$response" | jq -r '.status // "unknown"')
if [[ "$status" == "timeout" ]] || [[ "$status" == "failed" ]]; then
    log "ERROR: ターン失敗 (status=$status)"
    exit 1
fi
log "OK: 動作確認完了"
exit 0
```

**E2E-specific additions** (not in smoke.sh — new patterns per D-10/D-11):

Turn 1 (history seed):
```bash
response1=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "Remember this secret number: 7331", "wait": true}')
```

Fresh turn with history isolation check (D-10):
```bash
response2=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"prompt": "What secret number did I tell you?", "fresh": true, "wait": true}')
# Verify result does NOT contain "7331"
result2=$(echo "$response2" | jq -r '.result // ""')
if echo "$result2" | grep -q "7331"; then
    log "ERROR: 履歴隔離失敗 — fresh:true後も前ターンの情報が漏れている"
    exit 1
fi
```

---

### `scripts/e2e-opencode.sh` (utility/test, request-response)

**Analog:** `scripts/smoke.sh` + `scripts/e2e-codex.sh` (same structure)

Copy all patterns from e2e-codex.sh section above. OpenCode-specific differences:
- `PORT="${PORT:-8082}"` (different port from codex)
- `AGENT=opencode`
- `TURNS_DIR=./turns/opencode`
- `require_tool "opencode"` instead of `require_tool "codex"`
- Log tag: `[e2e-opencode]`
- `fresh_mode` test: tests `fresh:true` — if `fresh_mode=respawn` is the final decision, the reset is heavier but the history isolation check (D-11) remains identical

---

### `scripts/setup-opencode.sh` (utility, file-I/O)

**Analog:** `scripts/smoke.sh` (structure: shebang, strict mode, log helper, require_tool, idempotent check, exit 0)

**Shebang + strict mode:** same as smoke.sh lines 1, 7–8.

**log() helper:** same as smoke.sh lines 24–27, tag `[setup-opencode]`.

**Idempotent file creation pattern** (new — no exact analog, from D-05):
```bash
TURN_CMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands"
TURN_CMD_FILE="$TURN_CMD_DIR/turn.md"

if [[ -f "$TURN_CMD_FILE" ]]; then
    log "turn.md は既に存在します: $TURN_CMD_FILE (スキップ)"
    exit 0
fi

mkdir -p "$TURN_CMD_DIR"
cat > "$TURN_CMD_FILE" << 'HEREDOC'
---
description: Read a prompt file and follow the instructions in it
---
Read the file $ARGUMENTS and follow the instructions in it.
HEREDOC

log "OK: turn.md を作成しました: $TURN_CMD_FILE"
exit 0
```

**XDG_CONFIG_HOME handling:** `"${XDG_CONFIG_HOME:-$HOME/.config}"` — standard XDG base dir fallback, consistent with OpenCode's own config path convention.

---

## Shared Patterns

### Strict bash mode
**Source:** `scripts/smoke.sh` line 7
**Apply to:** All three new bash scripts
```bash
set -euo pipefail
```

### Cleanup + trap
**Source:** `scripts/smoke.sh` lines 41–67
**Apply to:** `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh`
Pattern: kill CARGO_PID on EXIT/INT/TERM; SIGKILL fallback after 5s; show log tail on failure.

### TOML field comment style
**Source:** `agents/claude.toml` lines 6–36
**Apply to:** `agents/codex.toml`, `agents/opencode.toml`
Pattern: each field preceded by a `# 説明` comment line; optional/commented-out fields use `# field = value` style.

### TOML prerequisite comment block
**Source:** `05-RESEARCH.md` Pattern 2 (lines 204–226 of RESEARCH.md)
**Apply to:** Both new TOML files
Pattern: multi-line `# 前提条件:` block at top of file before first field, listing auth steps and known issues.

### curl POST with wait:true + status check
**Source:** `scripts/smoke.sh` lines 121–151
**Apply to:** `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh`
Pattern: `curl -s --max-time 720 -X POST ... -d '{"prompt": "...", "wait": true}'` → jq extract status → fail on "timeout" or "failed".

---

## No Analog Found

All files have analogs. No entries.

---

## Notes for Planner

1. **Field name `cmd` vs `command`:** `agents/claude.toml` uses `command =` but `05-RESEARCH.md` Pattern 1/2 uses `cmd =`. Planner must check `src/profile.rs` struct field name before writing the TOML files. The profile schema uses `deny_unknown_fields` so the wrong key will fail silently or at load time.

2. **fresh_mode for opencode.toml:** D-01 says try `/new` first during implementation, then fall back to respawn if dialog blocks. The PLAN must include a verification step that runs the `/new` path and documents the result before committing the final `fresh_mode` value.

3. **PORT assignments for e2e scripts:** D-07 specifies dedicated PORTs. Codex and OpenCode scripts must use different ports (e.g., 8081/8082) to avoid conflicts during parallel validation runs.

4. **scripts/ directory already exists** at `/home/parallels/workspaces/claude-p/scripts/` — no mkdir needed.

5. **History isolation test (D-10/D-11):** Both e2e scripts must include the 2-turn test: seed a unique fact → fresh:true turn asking for that fact → verify it is absent from the result. This is the acceptance criterion per CONTEXT.md D-10.

---

## Metadata

**Analog search scope:** `agents/`, `scripts/`
**Files scanned:** 2 (`agents/claude.toml`, `scripts/smoke.sh`)
**Pattern extraction date:** 2026-06-12
```
