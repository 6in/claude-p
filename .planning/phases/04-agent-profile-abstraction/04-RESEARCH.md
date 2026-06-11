# Phase 4: Agent Profile Abstraction - Research

**Researched:** 2026-06-11
**Domain:** Rust config abstraction — TOML-driven agent profile for ht-webif
**Confidence:** HIGH (all findings grounded in direct codebase analysis and prior v2.0 research)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01:** Profile search path: CWD-relative `./agents/<name>.toml` by default; `AGENTS_DIR` env var overrides. Same "env > CWD-relative default" pattern as `TURNS_DIR`.

**D-02:** Missing `agents/claude.toml` (or any unknown agent) causes immediate error exit. No built-in fallback. TOML file is the single source of truth.

**D-03:** Profile-not-found error message includes the search path AND a list of available profiles (scan `agents/` directory; fall back to path-only if scan fails).

**D-04:** `agents/test.toml` is NOT committed to repo. It is generated in a `tempdir` inside tests (hermetic). Repo `agents/` contains only `claude.toml`.

**D-05:** `ready_pattern` uses substring match (`contains()`), same semantics as current hardcode. No `regex` crate added. Phase 5 may add regex if ANSI fragmentation is observed empirically.

**D-06:** Required fields: `command`, `ready_pattern`, `fresh_mode`, `clear_command`, `output_covenant`, `trigger_template`. Optional fields (with current defaults): `startup_timeout_secs` (default 25), `turn_timeout_secs` (default 300).

**D-07:** `serde(deny_unknown_fields)` — unknown TOML keys are rejected at startup (typo detection).

**D-08:** Schema defines only Phase 4 fields. `wedge_pattern` / `prerequisite_check` are Phase 5 additions.

**D-09:** Template placeholders: `{result_path}`, `{status_path}`, `{prompt_path}`. Implementation: `str::replace` only. TOML uses `"""..."""` basic multiline strings.

**D-10:** Trigger message (`src/turn.rs:47-50`) is extracted as `trigger_template` — a required field.

**D-11:** Startup validates placeholder existence: `output_covenant` must contain `{result_path}` and `{status_path}`; `trigger_template` must contain `{prompt_path}`. Missing placeholder → immediate `anyhow` error exit.

**D-12:** Golden test: assert `build_prompt_body` output (via `agents/claude.toml`) matches v1.0 `format!` output byte-for-byte.

**D-13:** Model selection: optional fields `model_flag` / `model_value`. If present, appended to spawn command. `agents/claude.toml` includes commented-out example.

**D-14:** `MCP_TIMEOUT` (30s) stays as a global constant — not per-profile.

**D-15:** No env var override for TOML values. Two-layer model: env = infra, TOML = agent behaviour.

**D-16:** `TURNS_DIR` always receives `<agent-name>` subdirectory appended, even when explicitly set. Default: `./turns/<agent-name>/`. **Breaking change from v1.0 explicit TURNS_DIR usage** — README must document this.

### Claude's Discretion

- `AgentProfile` struct field order, doc comments, internal layout of `src/profile.rs`
- Golden test placement (`profile.rs` or `turn.rs` `#[cfg(test)]`)
- Error message exact wording (Japanese, `anyhow` context — follow existing conventions)
- `fresh_mode = "respawn"` implementation details (kill+recreate path; FakeMcp test strategy)
- Available-profiles scan implementation (`std::fs::read_dir` sufficient)

### Deferred Ideas (OUT OF SCOPE)

- `wedge_pattern` / `prerequisite_check` fields — Phase 5
- `ready_pattern` regex + ANSI strip — Phase 5 if empirically needed
- `mcp_timeout_secs` profile field — Phase 5 if needed
- Timeout env var overrides (3-layer) — future
- `GET /info` endpoint — Phase 6
- Result file existence check (covenant silent failure detection) — Phase 5
- Profile hot-reload — FUT-02

</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROF-01 | 運用者は `agents/<name>.toml` でエージェントの spawn コマンド・引数・環境変数・ready_pattern・clear 手順を定義できる | `AgentProfile` struct + TOML loader in `src/profile.rs`; schema defined in §Standard Stack and §Code Examples |
| PROF-02 | 起動時に `AGENT=<name>` 環境変数でプロファイルを選択できる（未指定時は `claude` で後方互換） | `load_agent_name()` in `config.rs` follows existing `load_port()` pattern; §Architecture Patterns §Pattern 1 |
| PROF-03 | `agents/claude.toml` が現行ハードコード挙動を再現し、既存 4 エンドポイントの挙動が変わらない | Golden test (D-12) verifies byte-identical output; §Code Examples §Golden Test Pattern |
| PROF-04 | `fresh:true` がプロファイルの `fresh_mode` に従って動作する（`command` = clear コマンド / `respawn` = kill+再生成） | §Architecture Patterns §Pattern 3 fresh_mode dispatch; FakeMcp test strategy in §Code Examples |
| PROF-05 | `startup_timeout_secs`・`turn_timeout_secs`・model 選択をプロファイルで上書きできる（未指定時は現行デフォルト） | Optional serde fields with defaults; §Standard Stack TOML schema |
| PROF-06 | 新エージェント追加が TOML ファイル追加のみで完結する（Rust コード変更・リビルド不要） | D-04 hermetic test with tempdir-generated TOML verifies this; §Architecture Patterns §Pattern 4 |

</phase_requirements>

---

## Summary

Phase 4 is a pure refactor. All Claude-specific hardcodes are extracted into `agents/claude.toml` and driven through a new `AgentProfile` struct. No observable behaviour changes for existing users of the four HTTP endpoints. The only new dependency is `toml = "1"`.

The scope is exactly five hardcoded sites (confirmed by direct source analysis): (1) spawn command `["claude"]` in `mcp.rs:create_claude_session`, (2) ready pattern `"auto mode"` + 25s deadline in `worker.rs` at four sites (`spawn_session`, `recreate`, `restart`, `ensure_healthy`), (3) output covenant footer in `turn.rs:build_prompt_body`, (4) `/clear` fresh command in `turn.rs:process_job`, and (5) trigger message template in `turn.rs:process_job`. The `trait Mcp` method `create_claude_session` must be renamed to `create_session(cmd: &[String])` — this is the most structurally impactful change because both `McpClient` and `FakeMcp` implement it.

The most critical correctness constraint is D-12 (golden test): the output of `build_prompt_body` called with `agents/claude.toml`'s `output_covenant` must be byte-identical to the v1.0 `format!` output. Copy the literal string from `src/turn.rs:23-35` before editing that file. D-16 is a breaking change for users with explicit `TURNS_DIR` — the planner must include a README update task.

**Primary recommendation:** Implement in this order: `profile.rs` (struct + loader) → `config.rs` (add `load_agent_name` / `load_agents_dir`) → `agents/claude.toml` (extract all five hardcodes) → `mcp.rs` (rename trait method) → `worker.rs` (add `profile` field, replace 4 ready-pattern sites) → `turn.rs` (parametrize `build_prompt_body` and `process_job`) → `main.rs` (wire profile into startup) → tests (update broken tests + add golden test + add profile-not-found test).

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Profile schema definition | `src/profile.rs` (new) | — | New module; pure data type |
| Profile loading / validation | `src/profile.rs` (new) | `src/main.rs` | Load once at startup; validate placeholders; exit on failure |
| Agent name env resolution | `src/config.rs` | — | Follows existing `load_*` pattern |
| Agents dir env resolution | `src/config.rs` | — | Follows existing `load_*` pattern |
| Session spawn (profile-driven) | `src/mcp.rs` | `src/worker.rs` | `create_session(cmd)` accepts vec from profile |
| Ready-pattern polling | `src/worker.rs` | — | Four sites; all become `profile.ready_pattern` |
| Output covenant assembly | `src/turn.rs` | — | `build_prompt_body` gains `covenant_template` param |
| Trigger message assembly | `src/turn.rs` | — | `process_job` uses `profile.trigger_template` |
| fresh_mode dispatch | `src/turn.rs` | `src/worker.rs` | `fresh_mode = "command"` sends `clear_command`; `"respawn"` calls `worker.recreate()` |
| TURNS_DIR subdirectory namespacing | `src/main.rs` | `src/config.rs` | Append `<agent_name>` to turns base; D-16 |
| Startup banner | `src/main.rs` | — | Log agent name + actual turns path |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `toml` | `"1"` (1.1.2) | Parse `agents/*.toml` into `AgentProfile` via serde | Only new dependency; already a transitive dep of Cargo; integrates with existing `serde = "1"` zero-config [VERIFIED: cargo search + package-legitimacy OK] |

### Supporting (existing — no new additions)
| Library | Version | Purpose | Note |
|---------|---------|---------|------|
| `serde` | `"1"` | `#[derive(Deserialize)]` on `AgentProfile` | Already in Cargo.toml |
| `anyhow` | `"1"` | Profile load errors with Japanese context | Already in Cargo.toml |
| `std::fs::read_to_string` | stdlib | Read TOML file synchronously at startup | No async needed — profiles are small, read once |
| `std::fs::read_dir` | stdlib | Scan `agents/` for available-profiles error message (D-03) | No additional dep |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `toml = "1"` | `figment` | figment is excellent for layered runtime config but adds ~15MB transitive weight and a new abstraction layer — overkill for static per-agent files [ASSUMED based on prior research] |
| `toml = "1"` | `config` crate | Designed for application runtime config, not schema-defined profile files [ASSUMED] |
| `str::replace` for template substitution | `tera` / `handlebars` | Templates have only 2–3 placeholders; a template engine adds a dependency and a new mental model for no gain [ASSUMED] |

**Installation:**
```toml
# Cargo.toml [dependencies]
toml = "1"
```

**Version verification:**
```
toml = "1.1.2+spec-1.1.0"   # cargo search output 2026-06-11
```

---

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| `toml` | crates.io | ~11 yrs (2014-11-11) | 11.7M/wk | github.com/toml-rs/toml | OK | Approved |

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious SUS:** none

---

## Architecture Patterns

### System Architecture Diagram

```
Startup path:
  env: AGENT / AGENTS_DIR
       │
       ▼
  config::load_agent_name()   →  "claude" (default)
  config::load_agents_dir()   →  ./agents/
       │
       ▼
  profile::load_agent_profile("claude", agents_dir)
       │  reads agents/claude.toml
       │  serde::Deserialize → AgentProfile
       │  validates placeholders (D-11)
       │  fail → eprintln! + process::exit(1)
       │
       ▼
  Worker::new(ht_mcp_path, profile)
       │  client.create_session(&profile.command)
       │  polls: snap.contains(&profile.ready_pattern)
       │  deadline: profile.startup_timeout_secs
       │
       ▼
  worker_loop (Arc<Mutex<Worker>>)

Turn dispatch path:
  process_job(worker, turns_dir, job, profile)
       │
       ├─ job.fresh == true
       │     ├─ fresh_mode = "command" → worker.submit_line(&profile.clear_command)
       │     └─ fresh_mode = "respawn" → worker.recreate()
       │
       ├─ build_prompt_body(task, result_path, status_path, &profile.output_covenant)
       │     → str::replace {result_path}, {status_path}
       │     → writes to prompt-<turnId>.txt
       │
       └─ trigger = profile.trigger_template.replace("{prompt_path}", ...)
              worker.submit_line(&trigger)
```

### Recommended Project Structure
```
src/
├── profile.rs       # AgentProfile struct + load_agent_profile() (NEW)
├── config.rs        # + load_agent_name(), load_agents_dir() (MODIFY)
├── mcp.rs           # rename create_claude_session → create_session(cmd) (MODIFY)
├── worker.rs        # add profile field; replace 4 ready-pattern sites (MODIFY)
├── turn.rs          # parametrize build_prompt_body + process_job (MODIFY)
├── main.rs          # wire profile; apply TURNS_DIR/agent-name (MODIFY)
├── http.rs          # unchanged
└── lib.rs           # add: pub mod profile; (MODIFY)

agents/
└── claude.toml      # extracted hardcodes (NEW — committed to repo)
```

### Pattern 1: AgentProfile as a Plain Value Type
**What:** `AgentProfile` is a `#[derive(Debug, Clone, serde::Deserialize)]` struct stored as a field on `Worker<M>`. No trait, no dyn dispatch — one profile per process, loaded once.
**When to use:** When there is exactly one agent per process and no runtime switching.
**Example:**
```rust
// src/profile.rs
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentProfile {
    /// エージェントに渡す spawn コマンド（例: ["claude"]）
    pub command: Vec<String>,
    /// TUI ready 状態の部分文字列（例: "auto mode"）
    pub ready_pattern: String,
    /// fresh_mode: "command" = clear_command 送信 / "respawn" = セッション kill+再生成
    pub fresh_mode: String,
    /// fresh_mode = "command" 時に送るクリアコマンド（例: "/clear"）
    pub clear_command: String,
    /// 出力規約テンプレート — {result_path} / {status_path} を含む必須
    pub output_covenant: String,
    /// トリガーメッセージテンプレート — {prompt_path} を含む必須
    pub trigger_template: String,
    /// セッション起動タイムアウト秒（デフォルト 25）
    #[serde(default = "default_startup_timeout")]
    pub startup_timeout_secs: u64,
    /// 1 ターンのタイムアウト秒（デフォルト 300）
    #[serde(default = "default_turn_timeout")]
    pub turn_timeout_secs: u64,
    /// モデル選択フラグ（例: "--model"）。未指定なら spawn コマンドに追加しない
    pub model_flag: Option<String>,
    /// モデル選択値（例: "opus"）。model_flag とセットで指定
    pub model_value: Option<String>,
}

fn default_startup_timeout() -> u64 { 25 }
fn default_turn_timeout() -> u64 { 300 }
```
[Source: direct analysis of src/worker.rs, src/turn.rs, 04-CONTEXT.md decisions D-06/D-13]

### Pattern 2: load_agent_profile — Error-First, Path-Diagnostic
**What:** Profile loader follows the existing `load_*` pattern in `config.rs`. On failure it provides the search path and a list of available profiles.
**Example:**
```rust
// src/profile.rs
pub fn load_agent_profile(name: &str, agents_dir: &Path) -> anyhow::Result<AgentProfile> {
    let path = agents_dir.join(format!("{name}.toml"));
    let content = std::fs::read_to_string(&path).map_err(|_| {
        let available = list_available_profiles(agents_dir);
        anyhow::anyhow!(
            "agents/{name}.toml が見つかりません（探索: {}）。利用可能: {}",
            agents_dir.display(),
            if available.is_empty() { "なし".to_string() } else { available.join(", ") }
        )
    })?;
    let profile: AgentProfile = toml::from_str(&content)
        .with_context(|| format!("agents/{name}.toml のパースに失敗"))?;
    validate_profile(&profile, name)?;
    Ok(profile)
}

fn validate_profile(p: &AgentProfile, name: &str) -> anyhow::Result<()> {
    if !p.output_covenant.contains("{result_path}") || !p.output_covenant.contains("{status_path}") {
        anyhow::bail!("agents/{name}.toml: output_covenant に {{result_path}} と {{status_path}} が必要");
    }
    if !p.trigger_template.contains("{prompt_path}") {
        anyhow::bail!("agents/{name}.toml: trigger_template に {{prompt_path}} が必要");
    }
    Ok(())
}
```
[Source: 04-CONTEXT.md D-03, D-11; config.rs load_* patterns]

### Pattern 3: trait Mcp Signature Change
**What:** `create_claude_session()` becomes `create_session(cmd: &[String])`. Both `McpClient` and `FakeMcp` must be updated. The `FakeMcp` ignores the `cmd` parameter and pops from its scripted-reply queue as before.
**Example:**
```rust
// trait Mcp (src/mcp.rs)
async fn create_session(&mut self, cmd: &[String]) -> Result<String>;

// McpClient impl
async fn create_session(&mut self, cmd: &[String]) -> Result<String> {
    let text = self
        .call_tool("ht_create_session", json!({ "command": cmd }))
        .await?;
    // ... existing Session ID parsing unchanged
}

// FakeMcp impl (test module)
async fn create_session(&mut self, _cmd: &[String]) -> Result<String> {
    self.create_session_replies
        .pop_front()
        .unwrap_or_else(|| Err(anyhow!("create_session scripted reply 切れ")))
}
```
[Source: direct analysis src/mcp.rs:192-205; ARCHITECTURE.md §trait Mcp Change]

### Pattern 4: fresh_mode Dispatch in process_job
**What:** The hardcoded `worker.submit_line("/clear")` becomes a branch on `profile.fresh_mode`.
**When to use:** Any `fresh:true` job.
**Example:**
```rust
// src/turn.rs process_job
if job.fresh {
    match profile.fresh_mode.as_str() {
        "command" => {
            worker.submit_line(&profile.clear_command).await?;
        }
        "respawn" => {
            worker.recreate().await?;
        }
        other => {
            anyhow::bail!("未知の fresh_mode: {other}");
        }
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
}
```
[Source: 04-CONTEXT.md Claude's Discretion; REQUIREMENTS.md PROF-04]

### Pattern 5: TURNS_DIR with Agent-Name Subdirectory (D-16)
**What:** `main.rs` appends `<agent_name>` to the turns base path regardless of whether `TURNS_DIR` is explicitly set.
**Example:**
```rust
// src/main.rs (startup sequence)
let agent_name = load_agent_name();      // "claude" default
let agents_dir = load_agents_dir()?;
let profile = load_agent_profile(&agent_name, &agents_dir)?;

let turns_base = load_turns_dir()?;                    // ./turns or $TURNS_DIR
let turns_dir = turns_base.join(&agent_name);          // ./turns/claude/
tokio::fs::create_dir_all(&turns_dir).await?;
eprintln!("[profile] エージェント: {agent_name} / ターンディレクトリ: {}", turns_dir.display());
```
[Source: 04-CONTEXT.md D-16]

### Anti-Patterns to Avoid

- **Agent logic in trait Mcp:** Do not add `ready_pattern()` or `clear_command()` to `trait Mcp`. The transport trait knows nothing about TUI behaviour. Agent behaviour lives in `AgentProfile`. [CITED: ARCHITECTURE.md §Anti-Pattern 1]
- **Built-in fallback for missing TOML:** Do not use `include_str!` or any embedded default profile. TOML file is the single source of truth (D-02). A missing file is always an operator error that must be surfaced immediately.
- **`create_claude_session` left in place:** Do not keep the old method name as an alias. The trait rename is the point — `FakeMcp` must also be updated or existing tests referencing `create_claude_session` will fail to compile.
- **Async profile load:** Do not use `tokio::fs::read_to_string` for the TOML. Profile loading happens before `Worker::new` and before the `#[tokio::main]` async context is warm. Use synchronous `std::fs::read_to_string` (startup, small file). [ASSUMED based on Rust stdlib idioms]
- **Editing golden test expectations without a comment:** When updating `build_prompt_body_includes_task_and_paths`, add a comment linking to the TOML field so future editors know where the expected string comes from.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TOML parsing | Custom parser | `toml = "1"` + serde | Full TOML 1.1 spec, multiline strings, proper error messages [VERIFIED: cargo search] |
| Template substitution with 2-3 placeholders | Template engine (tera/handlebars) | `str::replace` | Three placeholders, no conditionals, no loops — a template engine is 100x more than needed [ASSUMED] |
| Profile validation error messages | Custom error type | `anyhow::bail!` / `.with_context()` | Existing convention across the codebase; Japanese context messages fit established pattern |
| Available-profile listing | Recursive search | `std::fs::read_dir` + filter `*.toml` | Flat single-level directory; no recursion needed |

**Key insight:** This is a pure extraction refactor. The code logic does not change — only the source of strings (Rust literals → TOML fields) changes. Resist any temptation to introduce new abstractions beyond `AgentProfile`.

---

## Common Pitfalls

### Pitfall 1: Editing turn.rs Before Capturing the Golden-Test String
**What goes wrong:** The v1.0 `build_prompt_body` format string in `src/turn.rs:23-35` is the ground truth for the golden test. If you modify `turn.rs` before copying that string into the test, you lose the exact bytes you need to assert against.
**Why it happens:** Developers edit the code and then try to write the test — but the "expected" string is now gone.
**How to avoid:** Step 1 of the turn.rs task must be: copy the literal output of the current `format!` call into a `const EXPECTED_BODY` string in the test. Then, and only then, modify `build_prompt_body`.
**Warning signs:** The golden test passes trivially (e.g., asserts `!= ""`) rather than asserting exact bytes.

### Pitfall 2: Four ready-pattern Sites in worker.rs — Missing One
**What goes wrong:** The pattern `snap.contains("auto mode")` appears in four separate places: `spawn_session`, `recreate`, `restart`, and `ensure_healthy`. Updating three out of four leaves a hidden Claude-specific hardcode.
**Why it happens:** `spawn_session` is in `impl Worker<McpClient>` (concrete impl); the other three are in `impl<M: Mcp + Send> Worker<M>` (generic impl). Different impl blocks, easy to overlook one.
**How to avoid:** After the change, `grep -n '"auto mode"' src/worker.rs` must return zero results.
**Warning signs:** `cargo test` stays green but a new `agents/test.toml` with a different `ready_pattern` would cause `spawn_session` to never detect readiness.

### Pitfall 3: FakeMcp Still Has create_claude_session After Rename
**What goes wrong:** The trait rename `create_claude_session` → `create_session(cmd: &[String])` must be reflected in both `McpClient` and `FakeMcp`. Since `FakeMcp` is in a `#[cfg(test)]` module, the compiler error only appears when running tests, not during a plain `cargo check`.
**Why it happens:** `FakeMcp` is in `mcp.rs::tests` which is conditionally compiled. Changing the trait and the production impl but forgetting `FakeMcp` compiles cleanly in release mode.
**How to avoid:** Always run `cargo test` (not just `cargo build`) before marking the mcp.rs task done. The `create_session_replies` field name stays unchanged — only the method signature changes.
**Warning signs:** `cargo build --release` succeeds but `cargo test` fails with "method not found" or "not all trait items implemented".

### Pitfall 4: D-16 TURNS_DIR Change Breaking Existing Test Setups
**What goes wrong:** Tests in `http.rs` and `turn.rs` that create a `tempdir` and pass it directly as `turns_dir` may be affected if `turns_dir` construction is moved out of `load_turns_dir()` into `main.rs` (where the `/<agent-name>` suffix is appended). Tests that bypass `main.rs` remain unaffected, but integration tests that go through the full `build_test_state` path may see unexpected subdirectory creation.
**Why it happens:** D-16 appends `/<agent-name>` in `main.rs`, not in `load_turns_dir()`. The config function returns the base path; the suffix is applied at startup. Tests that construct their own `turns_dir` are fine.
**How to avoid:** Keep `load_turns_dir()` returning the base path unchanged. Apply the suffix only in `main.rs`. Document this in comments.

### Pitfall 5: Multiline TOML String Trailing Newlines
**What goes wrong:** TOML `"""..."""` basic multiline strings include any newline immediately after the opening `"""` and before the closing `"""`. If `agents/claude.toml`'s `output_covenant` has a trailing `\n` that the v1.0 `format!` string does not, the golden test fails.
**Why it happens:** The v1.0 `format!` string has no trailing newline in `build_prompt_body`. TOML multiline strings often include a final newline.
**How to avoid:** Use the `\` line-ending escape to control whitespace in the TOML, or use `trim()` when reading. Alternatively, structure the TOML multiline string to exactly match the v1.0 output — use a single-quoted raw string test to verify.
**Warning signs:** Golden test fails with a diff showing one extra `\n` at the end.

---

## Code Examples

### agents/claude.toml (extracted from current hardcodes)
```toml
# agents/claude.toml
# Claude Code (claude CLI) エージェントプロファイル。
# 新プロファイル作成時のテンプレートとして使用してください。

command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"

# output_covenant: {result_path} と {status_path} の両プレースホルダが必須
output_covenant = """
【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:
1. 回答本文を次のファイルに書く: {result_path}
2. 完了したら最後に次のファイルを作る: {status_path}
   中身は JSON 1行: {"status":"done"}（失敗時は {"status":"failed","error":"理由"}）
status ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。"""

# trigger_template: {prompt_path} プレースホルダが必須
trigger_template = "{prompt_path} を読んで、その指示に従ってください。"

# チューニング値（未指定なら以下のデフォルト）
# startup_timeout_secs = 25
# turn_timeout_secs = 300

# モデル選択（コメントアウト例）
# model_flag = "--model"
# model_value = "opus"
```
[Source: direct analysis src/turn.rs:23-35 and :47-50; CONTEXT.md D-09/D-10]

**CRITICAL NOTE FOR IMPLEMENTATION:** The `output_covenant` value in the TOML must produce bytes **identical** to the v1.0 `format!` output. The v1.0 format string in `turn.rs:23-35` uses:
```
\n\n【ht-webif 出力規約】...
```
(two newlines before the header). The TOML multiline value must replicate this exactly. Verify with the golden test.

### Golden Test Pattern (D-12)
```rust
// In src/turn.rs #[cfg(test)] or src/profile.rs #[cfg(test)]
#[test]
fn build_prompt_body_covenant_matches_v1_output() {
    // v1.0 期待値: build_prompt_body が format! で生成していた文字列をそのまま固定
    let expected = "やってほしいこと\n\n\
【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:\n\
1. 回答本文を次のファイルに書く: /tmp/result-X.txt\n\
2. 完了したら最後に次のファイルを作る: /tmp/status-X.json\n\
   中身は JSON 1行: {\"status\":\"done\"}（失敗時は {\"status\":\"failed\",\"error\":\"理由\"}）\n\
status ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。";

    // agents/claude.toml のプロファイルをロードして同じ出力が得られることを確認
    let profile = load_agent_profile("claude", Path::new("agents")).unwrap();
    let body = build_prompt_body(
        "やってほしいこと",
        Path::new("/tmp/result-X.txt"),
        Path::new("/tmp/status-X.json"),
        &profile.output_covenant,
    );
    assert_eq!(body, expected, "agents/claude.toml の出力規約が v1.0 と一致しない");
}
```
[Source: CONTEXT.md D-12; current turn.rs:23-35 literal values]

### config.rs Additions (load_agent_name / load_agents_dir)
```rust
// src/config.rs — add after load_turns_dir

/// AGENT 環境変数を読む。未設定なら "claude"（後方互換）。
pub fn load_agent_name() -> String {
    std::env::var("AGENT").unwrap_or_else(|_| "claude".to_string())
}

/// AGENTS_DIR 環境変数を読む。未設定なら CWD/agents。
pub fn load_agents_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("AGENTS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("agents")),
    }
}
```
[Source: CONTEXT.md D-01; config.rs existing load_turns_dir pattern]

### Profile-Not-Found Test (D-04)
```rust
// Tests that verify PROF-06 (new agent = only new TOML file needed)
// and D-03 (error message includes available profiles)
#[test]
fn load_agent_profile_errors_on_missing_toml() {
    let dir = tempfile::tempdir().unwrap();
    // agents/claude.toml を動的作成
    let claude_toml = dir.path().join("claude.toml");
    std::fs::write(&claude_toml, r#"
        command = ["claude"]
        ready_pattern = "auto mode"
        fresh_mode = "command"
        clear_command = "/clear"
        output_covenant = "x {result_path} {status_path}"
        trigger_template = "{prompt_path}"
    "#).unwrap();

    let err = load_agent_profile("unknown_agent", dir.path()).unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("unknown_agent"), "エラーにエージェント名が含まれない");
    assert!(msg.contains("agents/"), "エラーに探索パスが含まれない");
    // 利用可能一覧に "claude" が含まれる
    assert!(msg.contains("claude"), "エラーに利用可能プロファイル一覧が含まれない");
}
```
[Source: CONTEXT.md D-03/D-04]

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hardcoded `["claude"]` in `create_claude_session()` | `create_session(cmd: &[String])` accepting profile command | Phase 4 | trait method rename; both McpClient and FakeMcp must update |
| `snap.contains("auto mode")` hardcoded in 4 sites | `snap.contains(&profile.ready_pattern)` | Phase 4 | All 4 sites in worker.rs |
| Covenant and trigger as `format!` Rust literals | `str::replace` on TOML-sourced templates | Phase 4 | `build_prompt_body` gains `covenant_template` param |
| `TURNS_DIR` defaults to `./turns/` | Defaults to `./turns/<agent-name>/` | Phase 4 | Breaking change — README required |
| Worker stores only client + session_id + ht_mcp_path | Adds `profile: AgentProfile` field | Phase 4 | Constructor signature changes |

**Deprecated patterns after Phase 4:**
- `create_claude_session()` method name: removed entirely from trait and impls
- Hardcoded `"auto mode"` string: must not appear in `src/worker.rs` after this phase
- Hardcoded `"/clear"` in `process_job`: must not appear in `src/turn.rs` after this phase

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `async` profile loading is unnecessary; `std::fs::read_to_string` at startup is sufficient | Architecture Patterns §Pattern 5 | Low — startup is synchronous anyway; worst case: minor refactor |
| A2 | `figment` adds ~15MB transitive weight | Standard Stack §Alternatives Considered | Low — only affects the "why not figment" rationale; conclusion (use `toml`) is correct regardless |
| A3 | TOML multiline strings with `"""` can reproduce exact v1.0 whitespace without additional Rust-side trimming | Code Examples §agents/claude.toml | MEDIUM — if trailing newline mismatch exists, golden test will catch it at implementation time; fix is in TOML formatting, not in architecture |

**If this table were empty:** All claims in this research were verified or cited. Table A3 is the only item requiring attention at implementation time — the golden test (D-12) is specifically designed to catch it.

---

## Open Questions

1. **`process_job` receives `profile` — via parameter or via `Worker` getter?**
   - What we know: `Worker` stores `profile: AgentProfile` (D-06 says field on Worker). `process_job` currently takes `worker: &mut Worker<M>`.
   - What's unclear: Should `process_job` call `worker.profile()` to access the profile, or should `TURN_TIMEOUT` stay in `config.rs` as a constant while the per-profile `turn_timeout_secs` overrides it in `process_job`?
   - Recommendation: Add `pub fn profile(&self) -> &AgentProfile` getter on `Worker<M>`. `process_job` calls `worker.profile()` for covenant, trigger, fresh_mode, clear_command, and turn_timeout. `TURN_TIMEOUT` constant in `config.rs` becomes the fallback default only (can be removed once profile.turn_timeout_secs is always set via serde default). This is Claude's Discretion territory.

2. **`spawn_session` is in `impl Worker<McpClient>` — how does it access profile?**
   - What we know: `spawn_session` is a `pub(crate)` associated function on `impl Worker<McpClient>`, taking `client: &mut McpClient`. It currently has no profile parameter.
   - Recommendation: Change signature to `spawn_session(client: &mut McpClient, profile: &AgentProfile)`. Since it is only called from `boot`, change `boot` to accept `profile` as well, and pass it from `Worker::new(ht_mcp_path, profile)`.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `cargo` / Rust toolchain | Build | Assumed present (CI target) | — | — |
| `ht-mcp` binary | Integration tests (none in Phase 4) | Assumed present at runtime | — | FakeMcp used in all unit tests |
| `claude` binary | Runtime (not needed for Phase 4 unit tests) | Assumed present at runtime | — | FakeMcp used in all unit tests |
| `agents/claude.toml` | Runtime + golden test | Created in this phase | New file | — |

Phase 4 adds no external tool dependencies beyond the already-required Rust toolchain.

---

## Security Domain

Phase 4 introduces one new input vector: reading a TOML file from disk. The file path is derived from `AGENTS_DIR` (env) + `AGENT` (env) + `.toml` suffix. No path traversal is possible because:
- `AGENTS_DIR` is an operator-controlled env var (not user input)
- `AGENT` is an operator-controlled env var (not user input)
- The resulting path is used only with `std::fs::read_to_string` (read-only)

No ASVS categories are newly applicable. The existing v1.0 security posture (localhost-only, no auth) is unchanged by this phase.

---

## Sources

### Primary (HIGH confidence — direct codebase analysis)
- `src/turn.rs` (full read, 2026-06-11) — exact hardcoded strings at lines 22-35, 47-58
- `src/worker.rs` (full read, 2026-06-11) — four `"auto mode"` sites confirmed; `spawn_session` in concrete impl block
- `src/mcp.rs` (full read, 2026-06-11) — `create_claude_session` signature; `FakeMcp` structure
- `src/config.rs` (full read, 2026-06-11) — `load_*` patterns to follow
- `src/main.rs` (full read, 2026-06-11) — startup sequence; banner output
- `Cargo.toml` (full read, 2026-06-11) — existing deps; no `toml` crate yet

### Primary (HIGH confidence — prior phase research)
- `.planning/research/ARCHITECTURE.md` — file/line change map, struct definitions, data flow
- `.planning/research/STACK.md` — `toml = "1"` rationale; alternatives rejected
- `.planning/research/PITFALLS.md` — Pitfall 7 (session clear differences), Pitfall 5 (TURNS_DIR collision)
- `.planning/phases/04-agent-profile-abstraction/04-CONTEXT.md` — all locked decisions D-01 through D-16

### Secondary (MEDIUM confidence)
- `cargo search toml` output (2026-06-11) — version 1.1.2 confirmed current
- `gsd-tools query package-legitimacy check --ecosystem crates toml` — verdict OK, 11.7M downloads/wk, 11yr old

### Tertiary (LOW confidence)
- figment crate weight estimate (~15MB) — [ASSUMED], not verified this session

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — `toml = "1"` confirmed via cargo search + legitimacy check; it is already a transitive dep of Cargo
- Architecture: HIGH — grounded in direct source analysis of all five modified files + prior ARCHITECTURE.md research
- Pitfalls: HIGH — derived from direct code reading (exact line numbers verified) + prior PITFALLS.md research
- TOML whitespace matching: MEDIUM — multiline TOML vs format! alignment needs verification at implementation time (golden test catches it)

**Research date:** 2026-06-11
**Valid until:** 2026-07-11 (stable domain; Rust codebase is v1.0 frozen)
