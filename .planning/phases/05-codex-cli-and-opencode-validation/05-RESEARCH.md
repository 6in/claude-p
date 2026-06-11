# Phase 5: Codex CLI and OpenCode Validation - Research

**Researched:** 2026-06-11
**Domain:** Empirical agent profiling — Codex CLI v0.139.0 and OpenCode v1.4.3 under ht-mcp
**Confidence:** HIGH for Codex (full E2E confirmed), MEDIUM for OpenCode (critical blocker found)

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AGNT-01 | Codex CLI プロファイル（`agents/codex.toml`）で `POST /prompt` → result 取得が実機 E2E で動作する | VERIFIED via empirical test: codex E2E succeeded in 18-27s; status+result files written correctly |
| AGNT-02 | Codex CLI で `fresh:true`（`/clear` 送信）が実機 E2E 動作する | VERIFIED: `/clear` leaves codex in identical ready state; fresh_mode="command" will work |
| AGNT-03 | OpenCode プロファイル（`agents/opencode.toml`）で `POST /prompt` → result 取得が実機 E2E で動作する | BLOCKED: Japanese trigger text silently discarded; English trigger worked but covenant compliance FAILED (GLM-4.6 answered "8" in TUI but never wrote files); needs alternative trigger approach or covenant change |
| AGNT-04 | OpenCode で `fresh:true`（`/new` 送信）が実機 E2E 動作する | PARTIAL: `/new` opens agent selector dialog (requires second Enter to confirm); `fresh_mode="command"` will need `/new\nEnter` sequence or `fresh_mode="respawn"` |

</phase_requirements>

---

## Summary

This phase involves empirical validation of two agents: **Codex CLI v0.139.0** (ChatGPT Plus subscription, gpt-5.5 model) and **OpenCode v1.4.3** (GitHub Copilot / OpenRouter GLM-4.6). Both are installed and authenticated on the host.

**Codex CLI is fully validated.** The E2E path works end-to-end: `codex --dangerously-bypass-approvals-and-sandbox` starts immediately (no interactive trust dialog), produces a stable ready state within 3 seconds, accepts a file-path trigger in Japanese, reads the prompt file, and writes result + status files reliably. Two independent E2E tests confirmed 18s and 24s completion times. `ready_pattern = "YOLO mode"` (from the startup banner) is the most stable substring, present from first snapshot and stable across all snapshots.

**OpenCode has two critical blockers.** First, ht-mcp `ht_send_keys` silently discards Japanese/multibyte Unicode text — the input field shows placeholder instead of typed text. English-only text works. Second, GLM-4.6 (OpenCode's default model) correctly reads the prompt file but does not reliably follow the output covenant — it answered "8" in the TUI session but never wrote the result or status files. This means either (a) the trigger/covenant must be reformulated for OpenCode's model, or (b) a different model must be configured. OpenCode with GitHub Copilot model may behave better.

**Primary recommendation:** Ship `agents/codex.toml` as VALIDATED in Phase 5. Ship `agents/opencode.toml` as EXPERIMENTAL with known limitations documented; the plan must include a verification task that tests the OpenCode trigger/covenant pair before marking AGNT-03/04 complete.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Agent profile files (codex.toml, opencode.toml) | `agents/` directory | — | New TOML files; no Rust code changes |
| Codex trust suppression | `agents/codex.toml` `cmd` field | Host `~/.codex/config.toml` | `--dangerously-bypass-approvals-and-sandbox` flag in spawn command |
| OpenCode multibyte trigger workaround | `agents/opencode.toml` `trigger_template` field | — | English-only trigger text; no Japanese in trigger |
| Output covenant for non-Claude models | `agents/opencode.toml` `output_covenant` field | — | Needs English covenant + possible model configuration |
| Ready pattern detection | `src/worker.rs` (existing `snap.contains`) | — | Substring match sufficient; no regex needed |
| E2E validation scripts | New `scripts/` or test section | — | Manual E2E test scripts for validation acceptance |

---

## Standard Stack

### Core (no new Rust dependencies)
| Item | Version | Purpose | Status |
|------|---------|---------|--------|
| `agents/codex.toml` | new file | Codex CLI agent profile | Create in this phase |
| `agents/opencode.toml` | new file | OpenCode agent profile | Create in this phase |

Phase 5 is **config-only** for the Codex path. No new Rust crates. No changes to `Cargo.toml`.

### Supporting (existing)
| Item | Already present | Notes |
|------|-----------------|-------|
| `AgentProfile` struct (`src/profile.rs`) | Yes — Phase 4 | Profile schema is complete |
| `fresh_mode = "command"` dispatch (`src/turn.rs`) | Yes — Phase 4 | Codex `/clear` path works |
| `fresh_mode = "respawn"` dispatch (`src/turn.rs`) | Yes — Phase 4 | OpenCode fallback if `/new` is unstable |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `fresh_mode = "command"` for OpenCode | `fresh_mode = "respawn"` | Respawn is heavier (kills session) but avoids the `/new` dialog Enter-twice issue; recommended as fallback if `/new` proves unreliable |
| Japanese trigger template | English-only trigger | English avoids the multibyte ht-mcp input bug; both work for codex (which handles Japanese fine), but OpenCode requires English |

---

## Package Legitimacy Audit

> Not applicable — Phase 5 adds no new packages. Config files only.

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious SUS:** none

---

## Architecture Patterns

### System Architecture Diagram

```
Phase 5 data flow (Codex):

  POST /prompt (curl) → axum handler → mpsc<Job> → worker_loop
       │
       ▼
  Worker<McpClient> (profile = agents/codex.toml)
       │  spawn_command = ["codex", "--dangerously-bypass-approvals-and-sandbox"]
       │  ready_pattern = "YOLO mode"
       │  trigger_template = "Read {prompt_path} and follow the instructions in it."
       │  output_covenant = [English file-write instructions]
       │
       ▼ ht-mcp stdio JSON-RPC
       │
  codex TUI (gpt-5.5, YOLO mode, project trusted)
       │  reads prompt-<turnId>.txt (in-project turns/codex/)
       │  writes result-<turnId>.txt
       │  writes status-<turnId>.json  ← sentinel
       │
       ▼
  worker_loop detects status file → turn complete

Phase 5 data flow (OpenCode - English trigger):

  POST /prompt → worker_loop → Worker<McpClient> (profile = agents/opencode.toml)
       │  spawn_command = ["opencode"]
       │  ready_pattern = "Ask anything"
       │  trigger_template = "Read {prompt_path} and follow the instructions in it."
       │  output_covenant = [English file-write instructions]
       │
       ▼ ht-mcp stdio
  opencode TUI (GLM-4.6 OpenRouter, GitHub Copilot)
       │  [RISK: model may not write files reliably — empirically confirmed failure]
       │
       ▼
  status file may NOT appear → turn timeout
```

### Recommended Project Structure
```
agents/
├── claude.toml      # Existing — v1.0 behavior (validated)
├── codex.toml       # NEW — Codex CLI profile (validated)
└── opencode.toml    # NEW — OpenCode profile (experimental, risks documented)
```

### Pattern 1: Codex Profile (Validated)
**What:** Complete `agents/codex.toml` for Codex CLI v0.139.0.
**Key properties:**
- `cmd` includes `--dangerously-bypass-approvals-and-sandbox` to skip all trust dialogs
- `ready_pattern = "YOLO mode"` — present in startup banner, stable across sessions
- `fresh_mode = "command"` with `clear_command = "/clear"` — verified `/clear` works
- `trigger_template` uses English (`Read {prompt_path} and follow...`) since Japanese text is also passed correctly via Codex
- `output_covenant` in Japanese works (Codex reads Japanese instructions reliably)
- `startup_timeout_secs = 15` — Codex starts in 3 seconds; 15s is generous
- `turn_timeout_secs = 300` — simple tasks complete in 18-27s; complex tasks may need full 300s

```toml
# agents/codex.toml
# Codex CLI (OpenAI) エージェントプロファイル。
# 前提条件:
#   - codex が PATH 上にあること（~/.local/bin/codex）
#   - ChatGPT Plus 認証済み: codex login 実行済み（~/.codex/auth.json 存在）
#   - プロジェクトディレクトリが ~/.codex/config.toml で trust_level = "trusted" に設定済み
#     もしくは --dangerously-bypass-approvals-and-sandbox フラグで全承認をスキップ
# 
# 多重インスタンス運用:
#   CODEX_HOME を別ディレクトリに変えることで独立した認証・設定を持つインスタンスを起動できる
#   例: CODEX_HOME=/tmp/codex-inst2 AGENT=codex ./ht-webif
cmd = ["codex", "--dangerously-bypass-approvals-and-sandbox"]

# 起動直後のバナーに "YOLO mode" が表示される（--dangerously-bypass-approvals-and-sandbox 時）
ready_pattern = "YOLO mode"

# /clear でコンテキストをリセットしてセッションを維持
fresh_mode = "command"
clear_command = "/clear"

# 出力規約テンプレート — Codex は日本語指示に対応済み
output_covenant = """
【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:
1. 回答本文を次のファイルに書く: {result_path}
2. 完了したら最後に次のファイルを作る: {status_path}
   中身は JSON 1行: {"status":"done"}（失敗時は {"status":"failed","error":"理由"}）
status ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。"""

# トリガーテンプレート — Codex は日本語パスも処理可能
trigger_template = "{prompt_path} を読んで、その指示に従ってください。"

# チューニング値
startup_timeout_secs = 15   # Codex は 3 秒で起動。15s は余裕を持たせた値
turn_timeout_secs = 300     # 単純タスクは 18-27 秒。複雑なタスクは 300s まで許容

# モデル選択（省略時は ~/.codex/config.toml の model = "gpt-5.5" が使われる）
# model_flag = "--model"
# model_value = "gpt-4o"
```
[VERIFIED: empirical test — E2E succeeded twice, 18s and 24s completion]

### Pattern 2: OpenCode Profile (Experimental)
**What:** `agents/opencode.toml` for OpenCode v1.4.3.
**Key risks:**
- Japanese text in trigger is silently discarded by ht-mcp — trigger MUST be English-only
- GLM-4.6 (OpenRouter default) does NOT reliably follow the output covenant — verified empirically
- `/new` opens an agent selector dialog (needs `Enter` twice to complete: `/new` → Enter → Enter)
- `ready_pattern = "Ask anything"` — present in startup and after sessions, stable

```toml
# agents/opencode.toml
# OpenCode エージェントプロファイル。
# 前提条件:
#   - opencode が PATH 上にあること（~/.opencode/bin/opencode）
#   - opencode providers に GitHub Copilot または使用モデルの認証済み
#     opencode providers list で確認、未設定なら opencode auth login
#
# ⚠ 既知の問題:
#   - ht-mcp ht_send_keys は日本語/マルチバイト文字を無音で破棄する
#     → trigger_template は ASCII のみ使用すること
#   - GLM-4.6 (OpenRouter デフォルト) は出力規約（ファイル書き込み指示）への遵守が不安定
#     → GitHub Copilot モデル（claude-3.5-sonnet 等）を使用すること
#     → model_flag/model_value でモデルを指定するか ~/.local/share/opencode/config.json で設定
#
# 多重インスタンス運用:
#   opencode の設定は ~/.local/share/opencode/ に保存される。
#   OPENCODE_HOME 等の環境変数はなく、インスタンス分離方法は未調査（Phase 6 で検討）
cmd = ["opencode"]

# 起動後に表示される入力フィールドのプレースホルダ
ready_pattern = "Ask anything"

# /new でセッションリセット。ただし Agent 選択ダイアログが開くため Enter が 2 回必要
# 実機検証で不安定な場合は respawn に切り替える
fresh_mode = "command"
clear_command = "/new"

# 出力規約テンプレート — ASCII のみ使用（マルチバイト文字の ht-mcp 問題を避けるため英語）
# ⚠ {result_path}/{status_path} は ASCII パスになるので問題なし（コードブロック外に置く）
output_covenant = """
[ht-webif output rule] Complete the task above and write to files as follows:
1. Write the answer/result to this file: {result_path}
2. After writing result, create this file: {status_path}
   Content must be exactly one JSON line: {"status":"done"} (on failure: {"status":"failed","error":"reason"})
The status file is the completion sentinel. Always write result FIRST, then status LAST."""

# トリガーテンプレート — ASCII のみ（マルチバイト文字の ht-mcp 問題を回避）
trigger_template = "Read {prompt_path} and follow the instructions in it."

# チューニング値
startup_timeout_secs = 15   # OpenCode は 8 秒前後で起動
turn_timeout_secs = 300     # GLM-4.6 で応答が止まる場合は短縮して respawn で回収

# モデル選択（Copilot 認証済みなら claude モデルを使用することを推奨）
# model_flag = "--model"
# model_value = "anthropic/claude-3.5-sonnet"
```
[ASSUMED for OpenCode model selection; VERIFIED: ready_pattern, trigger behavior, /new dialog]

### Pattern 3: OpenCode `fresh_mode` — Two-Enter Sequence
**What:** OpenCode's `/new` command opens an agent selector dialog, not a direct session reset. To complete the reset, a second Enter must be sent to select the highlighted agent (default: "build").
**Implementation options:**
1. `fresh_mode = "command"` with `clear_command = "/new"` — BUT `process_job` only sends `clear_command` + Enter once. The second Enter is not sent. This means `/new` appears in the input field and never executes as a command, OR the dialog opens but the selection is not confirmed.
2. `fresh_mode = "respawn"` — kills and recreates the session. Slower but reliable.
3. **Schema extension (Phase 5 scope creep risk):** Add a `clear_command_confirm` field to send a follow-up key after the clear command. Deferred unless `/new` proves essential.

**Recommended approach:** Use `fresh_mode = "respawn"` for OpenCode until the two-Enter requirement is resolved. The `respawn` path is already implemented and tested in Phase 4.

**Warning:** `clear_command = "/new"` alone will type `/new` into the input field and then press Enter — since OpenCode's input field accepts `/new` as a command only when submitted, this WILL open the agent selector. But without a second Enter, the selector remains open, blocking further input. Use `fresh_mode = "respawn"` to be safe.

### Anti-Patterns to Avoid

- **Japanese text in OpenCode trigger:** `ht_send_keys` silently drops multibyte characters for OpenCode. Always use `trigger_template = "Read {prompt_path} and follow the instructions in it."` (ASCII only). [VERIFIED: empirical test]
- **GLM-4.6 for output covenant compliance:** GLM-4.6 answers in the TUI but skips file writes. Either configure a different model (GitHub Copilot's claude-3.5-sonnet) or accept that AGNT-03 requires a model configuration step. [VERIFIED: empirical test — 90s timeout, no files written]
- **Assuming `/clear` opens a dialog in Codex:** Unlike OpenCode's `/new`, Codex's `/clear` directly resets the context and returns to idle. No second Enter needed. [VERIFIED: empirical test]
- **Using `/tmp` as TURNS_DIR with Codex:** Codex's lean-ctx hooks block reads outside the project root. The TURNS_DIR must be inside `~/.codex/config.toml`'s trusted project path (or D-16 default of `./turns/codex/` satisfies this since cwd is the project root). [VERIFIED: empirical test — `/tmp` paths rejected by lean-ctx MCP with `path escapes project root`]
- **Startup trust dialogs in Codex without the flag:** Without `--dangerously-bypass-approvals-and-sandbox`, Codex shows approval dialogs for each shell command. This blocks the worker_loop. Always include this flag. [VERIFIED: config.toml shows `trust_level = "trusted"` for the project but the flag is more reliable]

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Codex trust suppression | Config file hacks | `--dangerously-bypass-approvals-and-sandbox` flag in `cmd` | The project is already trusted via config.toml, but the flag is the canonical headless automation path [VERIFIED] |
| OpenCode model selection | Env var tricks | `opencode --model` or `~/.local/share/opencode/` config | Standard CLI flag approach; multi-instance model isolation via config [ASSUMED] |
| Multi-Enter for `/new` | Custom key sequence logic | `fresh_mode = "respawn"` | Already implemented; avoids dialog complexity entirely |

---

## Runtime State Inventory

> Rename/refactor phase: N/A — this is a new-profile addition phase, not a rename. No runtime state to migrate.

---

## Common Pitfalls

### Pitfall 1: Japanese Text Silently Dropped by ht-mcp for OpenCode
**What goes wrong:** `ht_send_keys` with Japanese/multibyte characters in the key array does nothing for OpenCode — the TUI input field stays at the "Ask anything..." placeholder with no text typed.
**Why it happens:** ht-mcp's PTY key injection does not reliably encode multibyte Unicode for OpenCode's input handling. The keys appear to be dropped. This does NOT affect Codex (which handles Japanese fine).
**How to avoid:** Use `trigger_template = "Read {prompt_path} and follow the instructions in it."` (English only) in `agents/opencode.toml`. The file path itself is ASCII so no encoding issues there.
**Warning signs:** After sending the trigger, snapshot shows "Ask anything..." placeholder still visible (not the typed trigger text).
[VERIFIED: empirical test — Japanese trigger typed but not visible in snapshot]

### Pitfall 2: GLM-4.6 (OpenCode Default) Does Not Follow Output Covenant
**What goes wrong:** OpenCode with GLM-4.6 reads the prompt, reasons through the answer, displays "8" (or similar) in the TUI — but does NOT write the result file or status file. The turn times out.
**Why it happens:** GLM-4.6 is not instruction-following enough to reliably execute multi-step file-write instructions, especially in a sandboxed environment or when the covenant uses terminology from a different tool (claude-specific framing).
**How to avoid:** Configure OpenCode to use a more capable model that follows file-write instructions. GitHub Copilot credentials are present (`opencode providers list` shows Copilot oauth). Use `model_flag`/`model_value` in the profile, or set a default model in OpenCode's config.
**Warning signs:** Snapshot shows model responded with answer in TUI, but no status file appears within 60-90 seconds.
[VERIFIED: empirical test — 90s timeout with "8" visible in TUI, no files written]

### Pitfall 3: `/new` Opens Agent Selector Dialog (Two Enters Needed)
**What goes wrong:** Sending `/new` + Enter to OpenCode opens the "Select agent" dialog with `build`, `plan`, etc. listed. Without a second Enter, the dialog stays open and blocks further input. The worker_loop's `submit_line` only sends one Enter.
**Why it happens:** OpenCode's `/new` command is interactive — it asks which agent to use for the new session.
**How to avoid:** Use `fresh_mode = "respawn"` for OpenCode. If `fresh_mode = "command"` with `/new` is needed, it requires a profile schema extension to send two keys (not currently supported by AgentProfile).
**Warning signs:** After a `fresh:true` request, the TUI snapshot shows the "Select agent" dialog open, and subsequent `submit_line` calls type into the search field of that dialog instead of the main input.
[VERIFIED: empirical test — "/new + Enter" confirmed to open dialog; second Enter confirmed to select agent]

### Pitfall 4: Codex Startup Takes ~3s Before ready_pattern Appears
**What goes wrong:** If startup_timeout_secs is too short (e.g., 5s), the worker may rarely miss the ready state if the host is under load.
**Why it happens:** Codex renders the startup banner (with "YOLO mode") within ~3s. Under normal conditions 15s is more than adequate. The project is already trusted so no additional dialog appears.
**How to avoid:** Set `startup_timeout_secs = 15` in `agents/codex.toml`. The current default (25s) also works but 15s is a better match for observed startup time.
[VERIFIED: empirical test — "YOLO mode" visible in 3s snapshot; 15s is safe]

### Pitfall 5: Codex `turns/codex/` Must Be Within Project Root (lean-ctx Restriction)
**What goes wrong:** Codex refuses to read prompt files outside the project root via its lean-ctx MCP hooks. If TURNS_DIR is set to an absolute path outside the project (e.g., `/tmp/turns/`), the trigger will receive an error `path escapes project root`.
**Why it happens:** Codex has lean-ctx installed as hooks, which restrict file reads to within the project root. `ht-mcp` uses the read-prompt-file approach and Codex processes the file via lean-ctx.
**How to avoid:** Keep TURNS_DIR at the default (`./turns/codex/` — via D-16 subdirectory). This resolves to `/home/parallels/workspaces/claude-p/turns/codex/` which is within the trusted project root.
**Warning signs:** Codex snapshot shows `path escapes project root` error in the task trace.
[VERIFIED: empirical test — /tmp path rejected; in-project path succeeded]

### Pitfall 6: OpenCode `ready_pattern` Is Not Stable Across Alt-Screen Renders
**What goes wrong:** When OpenCode first starts, the TUI renders with all-spaces until it initializes (~8 seconds). If `startup_timeout_secs` is too short, `snap.contains("Ask anything")` never returns true.
**Why it happens:** OpenCode uses a full-screen TUI with ANSI rendering. ht-mcp captures the screen after alt-screen initialization. "Ask anything..." appears once the TUI is fully rendered, around t=8s.
**How to avoid:** Set `startup_timeout_secs = 15` to allow time for the TUI to fully render. Running `opencode --print-logs` also shows log lines in the snapshot that may help confirm startup but is not needed for production use.
**Warning signs:** startup_timeout triggers frequently; snapshot is all spaces at t=5s.
[VERIFIED: empirical test — blank for 8s, then "Ask anything" visible; 15s adequate]

---

## Code Examples

### Minimal E2E Test Script for Codex (Acceptance Criterion)
```bash
#!/bin/bash
# E2E smoke test for agents/codex.toml
# Run from project root: bash scripts/e2e-codex.sh
set -e

TURN_ID="$(date -u +%Y%m%d-%H%M%S)-999"
TURNS_DIR="./turns/codex"
mkdir -p "$TURNS_DIR"

PROMPT_FILE="$TURNS_DIR/prompt-$TURN_ID.txt"
RESULT_FILE="$TURNS_DIR/result-$TURN_ID.txt"
STATUS_FILE="$TURNS_DIR/status-$TURN_ID.json"

cat > "$PROMPT_FILE" << 'EOF'
What is 2+2? Answer with the number only.

[ht-webif output rule] Complete the task and write to files:
1. Write the answer to: RESULT_PLACEHOLDER
2. After writing result, create: STATUS_PLACEHOLDER
   Content: {"status":"done"}
EOF

# Note: In real run, AGENT=codex PORT=8081 ./ht-webif handles this via POST /prompt
# This script tests the covenant mechanics directly via ht-mcp
echo "E2E test would use: AGENT=codex TURNS_DIR=$TURNS_DIR ./ht-webif"
echo "Then: curl -s -X POST localhost:8081/prompt -H 'Content-Type: application/json' -d '{\"prompt\":\"What is 2+2?\",\"wait\":true}'"
```

### Verified Codex Ready Pattern Check (worker.rs — existing code)
```rust
// In worker.rs spawn_session / ensure_healthy / recreate / restart:
// For codex.toml: ready_pattern = "YOLO mode"
// snap.contains(&profile.ready_pattern) correctly detects:
// "│ permissions: YOLO mode                         │"
// This string appears in the startup banner within 3 seconds.
```
[VERIFIED: empirical snapshot shows "YOLO mode" in startup banner]

### Verified OpenCode Ready Pattern Check
```rust
// For opencode.toml: ready_pattern = "Ask anything"
// snap.contains("Ask anything") correctly detects:
// "┃  Ask anything... \"Fix a TODO in the codebase\"  ┃"
// This string appears after ~8 seconds of startup.
// NOTE: All-spaces snapshots at t<8s will NOT contain this pattern (correct behavior).
```
[VERIFIED: empirical snapshot — blank at 3s, "Ask anything" visible at 8s]

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Claude-only hardcodes | `agents/*.toml` profiles (Phase 4) | 2026-06-11 | New agents are config-file additions |
| No codex.toml | `agents/codex.toml` | Phase 5 | Codex E2E validated |
| No opencode.toml | `agents/opencode.toml` | Phase 5 | OpenCode profile with known limitations |
| `/clear` (claude) = fresh_mode | `/clear` (codex) also works | 2026-06-11 empirical | Same implementation path |
| N/A | OpenCode `/new` opens dialog (2 Enters needed) | 2026-06-11 empirical | Requires `fresh_mode = "respawn"` or schema change |

**Deprecated patterns for this phase:**
- Using Japanese trigger_template for OpenCode: silently fails, must use English
- Assuming all models follow the Japanese output covenant: GLM-4.6 does not; Claude and gpt-5.5 do

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `codex` CLI | AGNT-01, AGNT-02 | Yes (`~/.local/bin/codex`) | 0.139.0 | — |
| `opencode` CLI | AGNT-03, AGNT-04 | Yes (`~/.opencode/bin/opencode`) | 1.4.3 | — |
| `ht-mcp` | All agents | Yes (`~/.cargo/bin/ht-mcp`) | 0.1.3 | — |
| ChatGPT Plus auth | Codex (gpt-5.5) | Yes (`~/.codex/auth.json`, `auth_mode: chatgpt`) | — | — |
| GitHub Copilot auth | OpenCode | Yes (`opencode providers list` shows Copilot oauth) | — | — |
| OpenRouter | OpenCode (GLM-4.6 default) | Yes (via `opencode providers list`) | — | Use Copilot model instead |
| `~/.codex/config.toml` project trust | Codex | Yes (`claude-p` trust_level = trusted) | — | `--dangerously-bypass-approvals-and-sandbox` (already in cmd) |
| In-project `turns/codex/` dir | Codex lean-ctx constraint | Created at runtime | — | D-16 default creates it automatically |

**Missing dependencies with no fallback:**
- None — all required tools are present and authenticated.

**Missing dependencies with fallback:**
- OpenCode model compliance: default GLM-4.6 fails the covenant; fallback is configuring GitHub Copilot model (available, needs profile config).

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | cargo test (existing, 27 tests green) |
| Config file | none — `cargo test` in project root |
| Quick run command | `cargo test --lib` |
| Full suite command | `cargo test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AGNT-01 | Codex E2E: prompt → result + status files | manual/e2e | `bash scripts/e2e-codex.sh` (to be created) | No — Wave 0 |
| AGNT-02 | Codex fresh:true → `/clear` → ready state | manual/e2e | included in e2e script | No — Wave 0 |
| AGNT-03 | OpenCode E2E: prompt → result + status files | manual/e2e | `bash scripts/e2e-opencode.sh` (to be created) | No — Wave 0 |
| AGNT-04 | OpenCode fresh:true → session reset → ready | manual/e2e | included in e2e script | No — Wave 0 |

**Note:** These are live E2E tests (require running `ht-webif` with real agents). They cannot be unit-tested with FakeMcp. The acceptance criteria in the roadmap define what "passing" means.

### Sampling Rate
- **Per plan task:** `cargo test` (27 tests must stay green — no Rust code changes in Phase 5, so this is a regression check only)
- **Phase gate:** Both `AGENT=codex ./ht-webif` E2E test and `AGENT=opencode ./ht-webif` E2E test must produce non-empty result file and `{"status":"done"}` status file

### Wave 0 Gaps
- [ ] `scripts/e2e-codex.sh` — covers AGNT-01, AGNT-02 (or inline verification steps in PLAN.md tasks)
- [ ] `scripts/e2e-opencode.sh` — covers AGNT-03, AGNT-04

*(Alternatively, E2E verification can be done inline in the plan tasks as manual acceptance steps — no script file required.)*

---

## Security Domain

Phase 5 adds two new agent profile files. Security analysis:

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No new auth paths | `--dangerously-bypass-approvals-and-sandbox` is operator-controlled startup flag |
| V5 Input Validation | No | `turn_id` validation already in http.rs; new profiles don't change HTTP input |
| V6 Cryptography | No | No crypto changes |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Codex `--dangerously-bypass-approvals-and-sandbox` exposes shell execution | Tampering | Same threat as existing claude integration; operator runs on localhost only (SEC-01 deferred) |
| OpenCode model writes arbitrary files per covenant | Tampering | Same as claude integration; trust is already established at the OS level |
| `CODEX_HOME` env var pointing to malicious auth | Spoofing | Operator-controlled env var; same risk level as `AGENT` env var |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | OpenCode configured with GitHub Copilot model (claude-3.5-sonnet) will follow the English output covenant reliably | OpenCode Profile Pattern | HIGH — if Copilot model also fails covenant, AGNT-03 requires a different approach (longer prompt engineering or respawn-only approach) |
| A2 | `fresh_mode = "respawn"` for OpenCode will reliably return to "Ask anything" ready state within 15s | OpenCode fresh_mode section | MEDIUM — startup takes 8s currently; respawn adds ht-mcp restart overhead; 15s timeout may be tight |
| A3 | `CODEX_HOME` env var controls codex config/auth directory for multi-instance isolation (Phase 6 concern) | Environment Availability | MEDIUM — `codex doctor` shows `CODEX_HOME = ~/.codex`; the env var is recognized but multi-instance behavior needs Phase 6 verification |
| A4 | OpenCode trigger in English with English-only covenant works for GitHub Copilot model | OpenCode profile output_covenant | MEDIUM — not empirically verified; Claude claude.toml uses Japanese and works; English covenant is different wording |

**If this table were empty:** Claims A1 and A4 must be resolved by the execution phase empirical tests. They are the key unknowns blocking AGNT-03 DONE status.

---

## Open Questions

1. **Does OpenCode's GitHub Copilot model follow the English output covenant?**
   - What we know: GLM-4.6 does not. Copilot credential exists. English covenant is untested.
   - What's unclear: Does `--model anthropic/claude-3.5-sonnet` work with Copilot oauth in opencode?
   - Recommendation: Plan task for AGNT-03 must include: (a) configure model, (b) test E2E. If model configuration fails, use `fresh_mode = "respawn"` and document as EXPERIMENTAL.

2. **Does `/new + Enter + Enter` work reliably for OpenCode fresh_mode?**
   - What we know: `/new + Enter` opens agent dialog; second `Enter` selects default agent (build) and returns to idle.
   - What's unclear: `process_job`'s `fresh_mode = "command"` only sends `clear_command + Enter` once. A second Enter would need a schema change or a two-key `clear_command`.
   - Recommendation: Use `fresh_mode = "respawn"` for OpenCode in the initial profile. The TOML comment should document the `/new` dialog behavior for future reference.

3. **Does `/new` in OpenCode actually clear history, or just switch agent?**
   - What we know: After `/new + Enter + Enter`, OpenCode returns to the idle state showing the logo.
   - What's unclear: Is the conversation history cleared, or just the visual context?
   - Recommendation: For Phase 5, treat "returns to idle state" as sufficient for `fresh:true` semantics. Full history isolation requires respawn.

---

## Sources

### Primary (HIGH confidence — empirical, 2026-06-11)
- Direct `ht-mcp` + Python MCP client tests — Codex E2E twice (18s and 24s completion)
- Direct `ht-mcp` + Python MCP client tests — OpenCode TUI snapshots, /new dialog, trigger input behavior
- `codex --help` output — flags: `--dangerously-bypass-approvals-and-sandbox`, `-c`, `--model`
- `opencode --help` output — flags, commands
- `codex doctor` output — confirmed `CODEX_HOME=~/.codex`, auth mode `chatgpt`, project trust
- `~/.codex/config.toml` — model `gpt-5.5`, project `claude-p` `trust_level = "trusted"`
- `opencode providers list` — GitHub Copilot oauth present, OpenRouter api present
- Phase 4 research (`04-RESEARCH.md`) — AgentProfile schema, mcp.rs session key `sessionId` (camelCase)

### Secondary (MEDIUM confidence — prior research)
- `.planning/ROADMAP.md` — Phase 5 success criteria
- `.planning/REQUIREMENTS.md` — AGNT-01..04 definitions
- `agents/claude.toml` — template for new profiles

### Tertiary (LOW confidence — not verified in this session)
- OpenCode GitHub Copilot model name (`anthropic/claude-3.5-sonnet`) — format not confirmed
- OpenCode `OPENCODE_HOME` or equivalent multi-instance isolation — not verified

---

## Metadata

**Confidence breakdown:**
- Codex profile: HIGH — two E2E tests passed; ready_pattern, /clear, trust dialog all verified empirically
- OpenCode profile: MEDIUM — ready_pattern and trigger delivery verified; covenant compliance NOT verified for any model
- Architecture: HIGH — no new Rust code; all infrastructure from Phase 4 is used as-is
- Fresh mode for OpenCode: LOW — `/new` dialog behavior verified but `fresh_mode = "respawn"` is the recommended fallback

**Research date:** 2026-06-11
**Valid until:** 2026-07-11 (Codex v0.139.0 and OpenCode v1.4.3 are pinned on this host; update check recommended if either upgrades)
