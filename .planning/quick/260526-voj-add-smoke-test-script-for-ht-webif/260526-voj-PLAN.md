---
phase: 260526-voj
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - webif/scripts/smoke.sh
  - webif/README.md
autonomous: true
requirements: [SMOKE-01]
---

<objective>
Create `webif/scripts/smoke.sh`, a single self-contained shell script that
proves the ht-webif HTTP surface works end-to-end against a real `ht-mcp`
+ `claude` TUI installation: build & launch the server in the background,
wait for it to come up, fire one `POST /prompt` with `wait:true` via curl,
print the result, and clean up the spawned processes — all driven by `set
-euo pipefail` with Japanese-language status messages matching the
existing `[restart]` / `[worker]` log style.

Purpose: Give the developer a one-command smoke check
(`./webif/scripts/smoke.sh`) confirming the Core Value of the project —
"curl 1発で Claude にタスクを送って結果を受け取れる" — still works after
a code change. This is the minimal regression net for a binary whose
core behaviour cannot be exercised by `cargo test` (because it requires
a logged-in `claude` CLI + `ht-mcp` subprocess + a real Max
subscription).

Output: A new executable file at `webif/scripts/smoke.sh` (mode 0755),
plus a short pointer in `webif/README.md` so the script is discoverable
without `ls scripts/`.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@webif/CLAUDE.md
@webif/README.md
@webif/.env.example
@webif/justfile

<!-- Key constants and HTTP surface the script must match. -->
<interfaces>

From `webif/src/main.rs` (binds + timeouts the script must respect):
- Bind address: `127.0.0.1:8080` (hard-coded — script targets this exact URL).
- `POST /prompt` body: `{"prompt": string, "wait"?: bool, "fresh"?: bool}`.
  - With `"wait": true` the server blocks up to ~700 s and returns
    `{"turn_id": "...", "status": "completed"|"timeout"|"failed", "result"?: string, "error"?: string}`.
- `GET /turns/{turn_id}` — readiness probe: ID whitelist is `^[0-9-]+$`,
  so `/turns/0` returns 404 (not 400). Any HTTP response — even 4xx —
  proves the server is listening; only `curl` exit code != 0 with no
  HTTP status means "not up yet".
- Child-process model: the `ht-webif` binary uses `kill_on_drop(true)`
  on its `ht-mcp` subprocess, so killing the parent `ht-webif` process
  is sufficient — `ht-mcp` (and the `claude` TUI it spawned) will be
  reaped automatically. Do **not** broadly `pkill ht-mcp`, which could
  hit unrelated developer processes.

From `webif/CLAUDE.md`:
- Logging convention: bracketed source tag prefix
  (`[restart]`, `[worker]`, `[shared-fate]`). The smoke script uses
  `[smoke]` for consistency.
- Comment / user-facing message language: Japanese for echo text,
  English for identifiers.
- Dependencies the script must verify before starting:
  - `ht-mcp` on PATH **or** `HT_MCP_PATH` env points at an existing file.
  - `claude` CLI on PATH (the Rust binary itself does not check this;
    failure surfaces only when `ht-mcp` spawns it).
- The `cargo run` invocation must happen from `webif/` so `dotenvy`
  picks up `webif/.env`.

From `webif/.env.example`:
- Only one env var: `HT_MCP_PATH` (default `ht-mcp`).

From `webif/justfile`:
- Existing tooling-check pattern (Japanese error + install hint + non-zero exit):
  ```
  @command -v docker >/dev/null 2>&1 || { \
      echo "ERROR: docker が見つかりません。"; \
      echo "  Docker のインストール手順: https://docs.docker.com/get-docker/"; \
      exit 1; \
  }
  ```
  The smoke script mirrors this idiom for its `ht-mcp` / `claude`
  pre-flight checks.
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create webif/scripts/smoke.sh end-to-end smoke test</name>
  <files>webif/scripts/smoke.sh</files>
  <action>
Create a new executable file at `webif/scripts/smoke.sh` implementing a
single end-to-end smoke test for ht-webif. Use the Write tool then mark
the file executable with `chmod +x webif/scripts/smoke.sh`.

Required structure (top to bottom):

1. **Shebang + strict mode.** First line `#!/usr/bin/env bash`, then
   `set -euo pipefail`. Add a brief Japanese header comment block
   describing the script's purpose (one curl で動作確認).

2. **Path anchoring.** Set
   `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` and
   `WEBIF_DIR="$SCRIPT_DIR/.."`. The script must work from any CWD.
   Define `BASE_URL="http://127.0.0.1:8080"` and
   `LOG_FILE` as `/tmp/ht-webif-smoke-$$.log` (uses the script's own
   PID so concurrent invocations don't collide).

3. **Logging helper.** Define a `log()` function that prints
   `[smoke] $*` to stderr. Use it for every user-facing status message.
   All status text must be Japanese (e.g. 「ビルド + 起動中...」,
   「サーバ起動待機中 (Ns/60s)...」, 「プロンプト送信: 2 + 2 は何？」,
   「結果:」, 「OK: 動作確認完了」). Error messages also Japanese.

4. **Pre-flight dependency check.** Mirror the justfile's
   `command -v ... || { echo "ERROR: ..."; exit 1; }` idiom:
   - Check `claude` is on PATH; if missing, print
     「ERROR: claude CLI が見つかりません。」 + install hint pointing
     at the README's 前提依存 section, exit 1.
   - Check ht-mcp: if `HT_MCP_PATH` env is set and non-empty, require
     `[[ -x "$HT_MCP_PATH" ]]`; otherwise require `command -v ht-mcp`.
     Failure message: 「ERROR: ht-mcp が見つかりません。」 + hint
     「PATH に追加するか HT_MCP_PATH を設定してください。」.

5. **Cleanup trap (declared before backgrounding the server).**
   Declare `CARGO_PID=""` and `EXIT_CODE=0` at file scope. Define a
   `cleanup()` function and install it with
   `trap cleanup EXIT INT TERM`. The function must:
   - Capture the current exit code (`local rc=$?`).
   - If `CARGO_PID` is non-empty AND `kill -0 "$CARGO_PID" 2>/dev/null`
     succeeds: send `SIGTERM`, then `wait` with a 5-second budget
     (loop: `for i in 1..5; do kill -0 ... || break; sleep 1; done`),
     then `SIGKILL` if still alive. Rely on Rust's `kill_on_drop` to
     reap the `ht-mcp` child — do NOT pkill `ht-mcp` globally.
   - If `rc != 0` AND log file exists: print
     「[smoke] 失敗ログ (末尾 40 行):」 to stderr, then
     `tail -n 40 "$LOG_FILE" >&2`.
   - If `rc == 0` AND log file exists: `rm -f "$LOG_FILE"`.
   - `return $rc` (or `exit $rc`) — preserve the original failure code.

6. **Launch the server.** `cd "$WEBIF_DIR"`. Log
   「ビルド + 起動中... (ログ: $LOG_FILE)」. Run
   `cargo run --release >"$LOG_FILE" 2>&1 &` and capture
   `CARGO_PID=$!`.

7. **Readiness wait (60 s budget).** Loop up to 60 iterations,
   sleeping 1 s between each. On every iteration:
   - First check the cargo process is still alive:
     `if ! kill -0 "$CARGO_PID" 2>/dev/null` → log
     「ERROR: cargo run プロセスが終了しました (ビルド失敗かポート競合の可能性)」
     and `exit 1` (the trap will dump the log tail).
   - Probe with
     `code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/turns/0" || echo "000")`.
     If `code != "000"` → break (any HTTP status proves the server is
     listening — `/turns/0` will normally return 404).
   - Log 「サーバ起動待機中 (${i}s/60s)...」 every ~5 s (gate on
     `i % 5 == 0`) to avoid log spam.
   - On loop exhaustion: log
     「ERROR: 60 秒待ってもサーバが応答しませんでした」 and `exit 1`.

8. **Submit the prompt.** Log 「プロンプト送信: 2 + 2 は何？」. Run:
   ```
   response=$(curl -s --max-time 720 -X POST "$BASE_URL/prompt" \
       -H 'Content-Type: application/json' \
       -d '{"prompt": "2 + 2 は何？", "wait": true}')
   ```
   If `curl` itself fails (non-zero exit), log
   「ERROR: curl 失敗」 and `exit 1`.

9. **Inspect & display result.** Log 「結果:」. Then:
   - If `command -v jq >/dev/null 2>&1`: echo
     `"$response" | jq .` to stdout. Extract status with
     `status=$(echo "$response" | jq -r '.status // "unknown"')` and
     result text with `result=$(echo "$response" | jq -r '.result // empty')`.
   - Else (no jq): echo `"$response"` raw. Parse `status` with a
     simple grep/sed fallback:
     `status=$(echo "$response" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)`.
   - If `status` is `"timeout"` or `"failed"`: log
     「ERROR: ターン失敗 (status=$status)」 and `exit 1`.
   - If `status` is `"completed"` AND `jq` was used AND `result` is
     non-empty: log 「Claude の回答:」 followed by
     `printf '%s\n' "$result"` so the bare answer is easy to eyeball.

10. **Success exit.** Log 「OK: 動作確認完了」. `exit 0` — the trap
    handles process & log cleanup.

Style requirements:
- Quote every variable expansion (`"$VAR"`, `"$@"`).
- Use `$(...)` not backticks.
- Use `[[ ]]` for tests (bash-only is fine — the shebang is
  `/usr/bin/env bash`).
- The script must pass `shellcheck` cleanly. If a `# shellcheck`
  directive is needed (e.g. for the deliberate global `CARGO_PID`),
  add it with a one-line reason comment in Japanese.
- Keep total length under ~140 lines. Favor a few helper functions
  (`log`, `require_tool`, `cleanup`, `wait_for_server`) over one big
  linear body.

After writing the file, run `chmod +x webif/scripts/smoke.sh` from the
repo root.
  </action>
  <verify>
    <automated>bash -n webif/scripts/smoke.sh && [ -x webif/scripts/smoke.sh ] && shellcheck webif/scripts/smoke.sh 2>/dev/null || shellcheck -S warning webif/scripts/smoke.sh 2>/dev/null || echo "shellcheck not installed — bash -n syntax-check passed"</automated>
  </verify>
  <done>
- `webif/scripts/smoke.sh` exists and is mode 0755 (executable bit set).
- `bash -n webif/scripts/smoke.sh` exits 0 (syntactically valid).
- If `shellcheck` is installed, it reports no errors (warnings ok).
- The script contains all required elements: shebang line with
  `#!/usr/bin/env bash`, `set -euo pipefail`, `trap` on EXIT/INT/TERM,
  pre-flight checks for both `claude` and `ht-mcp`/`HT_MCP_PATH`, a
  60-second readiness loop that also checks `kill -0 "$CARGO_PID"`,
  one `curl -X POST .../prompt` with `wait:true`, and a final
  「OK: 動作確認完了」 success message.
- All user-facing echo strings are Japanese and prefixed with
  `[smoke]` (via the `log` helper).
  </done>
</task>

<task type="auto">
  <name>Task 2: Add smoke-test pointer to README.md</name>
  <files>webif/README.md</files>
  <action>
Add a short "動作確認 (smoke test)" subsection to `webif/README.md` so
the new script is discoverable. Place it between the existing 「## 起動」
section (ends around line 69) and 「## API」 (starts at line 71).

The subsection MUST be ≤5 content lines (excluding the heading and
trailing blank line) per the planning constraints. Use this exact
shape:

```
## 動作確認

依存 (`ht-mcp` / `claude` CLI) が揃っているかと、curl で 1 ターン回せるかを
スモークテストで一括確認できる:

```bash
./scripts/smoke.sh
```

サーバ起動 → `POST /prompt` (wait:true) → 結果表示 → 後片付けまでを 1
コマンドで実行する。失敗時はビルドログの末尾 40 行を stderr に出力する。
```

Use the `Edit` tool with a precise anchor (the last line of the
「## 起動」 section, currently:
「外部から接続したい場合は SSH トンネルやリバースプロキシを使用すること。」)
to avoid touching the surrounding API documentation. Insert exactly
one blank line before the new `## 動作確認` heading and one blank line
after the new section, matching the existing heading spacing in the
file.

Do not modify any other content in README.md.
  </action>
  <verify>
    <automated>grep -q "^## 動作確認$" webif/README.md && grep -q "scripts/smoke.sh" webif/README.md && grep -c "^## " webif/README.md</automated>
  </verify>
  <done>
- `webif/README.md` contains a new `## 動作確認` heading.
- The new section references `./scripts/smoke.sh`.
- The section sits between 「## 起動」 and 「## API」 (verify by
  reading the file and confirming heading order).
- The diff for this task touches only the inserted lines — no other
  README content changed.
  </done>
</task>

</tasks>

<verification>
End-to-end the plan is verified by:

1. `bash -n webif/scripts/smoke.sh` — syntactic validity.
2. `[ -x webif/scripts/smoke.sh ]` — exec bit set.
3. `grep -q "^## 動作確認$" webif/README.md` — README pointer added.
4. (Optional, requires logged-in `claude` + `ht-mcp` on PATH)
   `./webif/scripts/smoke.sh` — full live run prints
   「OK: 動作確認完了」 and exits 0.

Step 4 is not part of the automated verify gate because it requires
the developer's Max-subscription `claude` credentials and a real
`ht-mcp` install — but step 4 IS the artefact's reason to exist, and
the developer should run it manually once after the plan is executed.
</verification>

<success_criteria>
- A developer with `cargo`, `ht-mcp`, and a Max-logged-in `claude` CLI
  can run `./webif/scripts/smoke.sh` from any CWD and observe:
  1. Japanese `[smoke]` status messages tracing build → readiness →
     prompt submission → result.
  2. A non-empty Claude answer to「2 + 2 は何？」.
  3. Exit code 0, with both the `ht-webif` cargo process and the
     `ht-mcp` subprocess fully reaped (no orphaned listeners on
     `127.0.0.1:8080`).
- If `claude` or `ht-mcp` is missing, the script fails fast with a
  Japanese error message before attempting to build.
- If `cargo run` fails to bind (port in use) or fails to compile, the
  script detects this within ~1 second of the failure and dumps the
  last 40 log lines.
- Ctrl-C during any phase triggers the cleanup trap and leaves no
  orphaned processes.
- `webif/README.md` mentions `scripts/smoke.sh` in the 動作確認
  section, so the script is discoverable without `ls scripts/`.
</success_criteria>

<output>
After completion, create
`.planning/quick/260526-voj-add-smoke-test-script-for-ht-webif/260526-voj-SUMMARY.md`
summarising:
- The two artefacts produced (`webif/scripts/smoke.sh`, the README
  insertion).
- Any deviations from the action text (e.g. shellcheck warnings that
  required `# shellcheck disable=...` directives, with reason).
- A one-line "how to run" for the developer:
  `./webif/scripts/smoke.sh` (requires logged-in `claude` + `ht-mcp`).
</output>
