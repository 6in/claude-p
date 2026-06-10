# Architecture Research: Multi-Agent Support

**Domain:** Multi-agent abstraction layer over interactive TUI agents
**Researched:** 2026-06-11
**Confidence:** HIGH (based on direct source analysis of the existing codebase)

---

## Context: What Is Claude-Specific Today

Before describing the target architecture, it is essential to identify exactly which code is claude-specific in the current v1.0 codebase. Everything else is already agent-agnostic.

### Claude-specific sites (all four must be generalized)

| Location | Line(s) | What is hardcoded |
|---|---|---|
| `src/mcp.rs` — `create_claude_session()` | ~192-205 | Spawn command `["claude"]` sent to `ht_create_session`; parses `"Session ID:"` from ht-mcp response |
| `src/worker.rs` — `spawn_session()`, `recreate()`, `restart()` | ~41-53, 100-122, 137-158 | Ready-detection string `"auto mode"` (hardcoded in three places) |
| `src/turn.rs` — `build_prompt_body()` | ~22-36 | Prompt footer covenant (Japanese; instructs claude to write result/status files using specific paths) |
| `src/turn.rs` — `process_job()` | ~54-56 | Fresh-session clear command `/clear` (hardcoded) |

Everything else — the MCP transport layer (`McpClient`, `trait Mcp`, `trait Restartable`), the HTTP layer, the job queue, the turn-file state machine, and the filesystem sentinel — is already agent-agnostic.

---

## Target Architecture

The goal is to introduce one new abstraction — the `AgentProfile` — that captures all agent-specific behaviour, and thread it through the four claude-specific sites above without changing the overall system shape.

### System Overview (v2.0)

```
┌───────────────────────────────────────────────────────────────────────┐
│  Startup (main.rs)                                                    │
│   AGENT env → load AgentProfile from agents/<name>.toml              │
│   pass profile into Worker::new(ht_mcp_path, profile)                │
└────────────────────────────┬──────────────────────────────────────────┘
                             │ AgentProfile
                             ▼
┌───────────────────────────────────────────────────────────────────────┐
│  Worker<M>  (src/worker.rs)                                           │
│   stores: client: M, session_id, ht_mcp_path, profile: AgentProfile  │
│   spawn_session():  profile.spawn_command → create_session()          │
│                     profile.ready_pattern → snapshot polling          │
│   recreate():       same ready_pattern                                │
│   restart():        same ready_pattern                                │
│   ensure_healthy(): profile.ready_pattern for health check            │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
                             ▼ trait Mcp (unchanged)
┌───────────────────────────────────────────────────────────────────────┐
│  McpClient (src/mcp.rs)                                               │
│   create_session(command: &[String]) — accepts spawn_command          │
│   (was: hardcoded ["claude"])                                         │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
                             ▼ ht-mcp child
┌───────────────────────────────────────────────────────────────────────┐
│  Agent TUI  (claude / codex / opencode / ...)                        │
│   reads prompt file, writes result + status files                     │
│   (behaviour governed by prompt footer from AgentProfile)             │
└───────────────────────────────────────────────────────────────────────┘
```

### Component Boundaries

| Component | Responsibility | What Changes |
|---|---|---|
| `src/profile.rs` (NEW) | Define `AgentProfile` struct; load from TOML file; expose `load_agent_profile()` | New file |
| `src/config.rs` | Add `load_agent_name()` to read `AGENT` env var | Add ~5 lines |
| `src/mcp.rs` — `trait Mcp` | `create_session(command: &[String])` replaces `create_claude_session()` | One method rename + signature change |
| `src/mcp.rs` — `McpClient` | `create_session()` accepts `command` parameter instead of hardcoding `["claude"]` | Parametrize one call |
| `src/worker.rs` | Hold `profile: AgentProfile`; use `profile.spawn_command`, `profile.ready_pattern`, `profile.clear_command` | Add field; replace 4 hardcoded strings |
| `src/turn.rs` — `build_prompt_body()` | Accept `covenant_template: &str` from profile; substitute `{result}` / `{status}` | Parametrize the footer |
| `src/turn.rs` — `process_job()` | Use `profile.clear_command` instead of `"/clear"` | One string substitution |
| `src/http.rs` | No changes required | Unchanged |
| `agents/*.toml` (NEW) | Per-agent profile files checked into repo | New directory + files |

---

## The AgentProfile Struct

This is the core new type. All agent-specific knowledge lives here.

```rust
/// エージェントプロファイル。設定ファイル（agents/<name>.toml）から読み込む。
#[derive(Debug, Clone, serde::Deserialize)]
pub struct AgentProfile {
    /// エージェント識別子（ログ・エラーメッセージ用）
    pub name: String,

    /// ht_create_session に渡す spawn コマンド（例: ["claude"] / ["codex"] / ["opencode"]）
    pub spawn_command: Vec<String>,

    /// TUI が ready 状態であることを示すスナップショット内の文字列
    /// （例: "auto mode" for claude, ">" for codex shell prompt）
    pub ready_pattern: String,

    /// fresh:true 時に送るクリアコマンド（例: "/clear" for claude, "/new" for opencode）
    /// None の場合は新規セッション生成で代替
    pub clear_command: Option<String>,

    /// prompt ファイルに付加する出力規約テンプレート
    /// プレースホルダ: {result} = result ファイルパス, {status} = status ファイルパス
    pub output_covenant: String,
}
```

### Profile File Format

`agents/claude.toml`:
```toml
name = "claude"
spawn_command = ["claude"]
ready_pattern = "auto mode"
clear_command = "/clear"
output_covenant = """

────────────────────────────────
【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:
1. 回答本文を次のファイルに書く: {result}
2. 完了したら最後に次のファイルを作る: {status}
   中身は JSON 1行: {"status":"done"}（失敗時は {"status":"failed","error":"理由"}）
status ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。
"""
```

`agents/codex.toml`:
```toml
name = "codex"
spawn_command = ["codex"]
ready_pattern = ">"          # adjust after empirical testing
clear_command = "/new"       # TBD — needs verification against codex CLI
output_covenant = """

---
[ht-webif output instructions]
Execute the task above. When finished:
1. Write your complete answer to: {result}
2. Write exactly this JSON to: {status}
   {"status":"done"} on success, {"status":"failed","error":"reason"} on failure
Write the result file first. Write the status file last — its appearance signals completion.
"""
```

### Notes on output_covenant

The output covenant is the most fragile per-agent element. It is natural-language instruction appended to every prompt, and the agent must follow it reliably. Key considerations:

- Claude Code (auto mode) has strong instruction-following; the existing covenant text is proven.
- Codex CLI and OpenCode are less battle-tested in this usage mode. Their covenant text must be discovered empirically, not assumed.
- The template substitution uses `{result}` and `{status}` as placeholders, replaced with absolute filesystem paths at turn dispatch time.
- HT-PROTOCOL §9 describes the Worker procedure that the covenant implements. The protocol itself does not change; only the natural-language wording is per-agent.

---

## Data Flow Changes

### Startup (main.rs changes)

Before:
```
load_ht_mcp_path() → Worker::new(ht_mcp_path)
```

After:
```
load_ht_mcp_path() + load_agent_name() → load_agent_profile(agent_name) → Worker::new(ht_mcp_path, profile)
```

The profile propagates from `main.rs` → `Worker` → used at `spawn_session`, `recreate`, `restart`, `ensure_healthy`, and `process_job`.

### process_job (turn.rs changes)

The function signature gains a `profile: &AgentProfile` parameter (or the profile is stored on `Worker` and accessed via a getter). The fresh-session clear becomes:

```rust
if job.fresh {
    match &worker.profile().clear_command {
        Some(cmd) => { worker.submit_line(cmd).await?; }
        None      => { worker.recreate().await?; }
    }
    tokio::time::sleep(Duration::from_millis(1000)).await;
}
```

### build_prompt_body (turn.rs changes)

```rust
pub fn build_prompt_body(
    task: &str,
    result_path: &Path,
    status_path: &Path,
    covenant_template: &str,
) -> String {
    let covenant = covenant_template
        .replace("{result}", &result_path.display().to_string())
        .replace("{status}", &status_path.display().to_string());
    format!("{task}{covenant}")
}
```

The existing test `build_prompt_body_includes_task_and_paths` must be updated to pass the covenant template, but the logic under test is unchanged.

---

## trait Mcp Change: create_session Signature

The single method rename is the most structurally impactful change. The existing `create_claude_session()` with no parameters becomes `create_session(command: &[String])`:

```rust
#[async_trait]
pub trait Mcp: Send {
    async fn handshake(&mut self) -> Result<()>;
    async fn create_session(&mut self, command: &[String]) -> Result<String>;
    async fn close_session(&mut self, session_id: &str) -> Result<()>;
    async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()>;
    async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()>;
    async fn snapshot(&mut self, session_id: &str) -> Result<String>;
}
```

`FakeMcp` in the test module must also implement `create_session(command: &[String])` — the `create_session_replies` queue still serves scripted replies; the `command` parameter is ignored in the fake.

---

## Ready-Detection Generalization

Current code in `spawn_session`, `recreate`, `restart`, and `ensure_healthy` all check `snap.contains("auto mode")`. All four sites become `snap.contains(&profile.ready_pattern)`.

The 25-second boot deadline and 700ms poll interval are not per-agent (they are operational constants). They stay in `config.rs` or as constants in `worker.rs`. If future agents need different timeouts, add optional `boot_timeout_secs` to `AgentProfile` with a default fallback.

---

## Multi-Instance Parallel Foundation

No new WebIF code is required. The existing `PORT` + `TURNS_DIR` isolation is already complete. The only addition is the `AGENT` env var that selects the profile at startup.

To run two agents in parallel:

```bash
# Instance 1 — claude on port 8080
AGENT=claude PORT=8080 TURNS_DIR=/tmp/turns-claude ./ht-webif &

# Instance 2 — codex on port 8081
AGENT=codex PORT=8081 TURNS_DIR=/tmp/turns-codex ./ht-webif &
```

Turn-file namespacing: each instance uses its own `TURNS_DIR`, so there is no filename collision. The `turnId` format (`YYYYMMDD-HHMMSS-mmm`) remains unchanged; HT-PROTOCOL §3 already documents the `-w<workerId>` suffix for future parallel-worker disambiguation, but that suffix is not needed for the multi-instance model (each instance is its own process).

---

## Patterns to Follow

### Pattern 1: Profile as a Plain Value Type

Store `AgentProfile` as a plain `Clone`-able struct (not behind a trait). There is exactly one profile per process. Making it a trait would add complexity with no benefit — no runtime dispatch needed, no mock needed (profiles are data, not behaviour).

Store it as a field on `Worker<M>`:
```rust
pub struct Worker<M: Mcp = McpClient> {
    client: M,
    pub session_id: String,
    ht_mcp_path: String,
    profile: AgentProfile,   // NEW
}
```

Expose it via a `pub fn profile(&self) -> &AgentProfile` getter for use by `process_job`.

### Pattern 2: Profile Loading at Startup, Not Per-Turn

Load `AgentProfile` once in `main.rs` and pass it into `Worker::new`. Do not reload per turn. Profile changes require a process restart — this is correct (1 process = 1 agent by design).

### Pattern 3: Profiles Directory Checked Into Repo

Ship `agents/claude.toml` in the repository. The `AGENT` env var defaults to `"claude"` if unset (backward compatibility). Profile files are discovered at a path relative to the binary's working directory, or via an `AGENTS_DIR` env var. Start with the simpler CWD-relative convention.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Encoding Agent Logic in the Trait

Do not add `ready_pattern()` or `clear_command()` to `trait Mcp`. The `Mcp` trait abstracts the MCP transport layer (ht-mcp JSON-RPC operations). It knows nothing about which TUI is running or how to detect its readiness. Agent behaviour belongs in `AgentProfile`, not in the transport.

### Anti-Pattern 2: Runtime Agent Switching

Do not add an `agent` field to `PromptReq` or `Job`. The design decision (from PROJECT.md) is "1 process = 1 agent." Per-request agent selection would require either a second worker (defeating the serial model) or session teardown + rebuild on every switch (expensive and error-prone).

### Anti-Pattern 3: Discover ready_pattern Empirically at Startup

Do not implement logic to auto-detect the ready state by trying multiple patterns. The profile declares the ready pattern explicitly. If a new agent needs empirical discovery, that is offline research, not runtime logic.

### Anti-Pattern 4: Covenant as Code

Do not encode the output covenant as Rust string literals in profile structs defined in code. It must be in the TOML profile file. The covenant is the instruction given to a natural-language model; it will need iteration and per-agent tuning that must not require recompilation.

---

## Build Order (Phase Recommendations)

This ordering respects dependencies and de-risks the most uncertain parts first.

### Phase 1 — Profile Abstraction (claude remains the only profile)

**Goal:** Introduce `AgentProfile` and thread it through all four claude-specific sites. No behaviour change. All existing tests stay green.

1. Add `src/profile.rs` — `AgentProfile` struct + `load_agent_profile(name: &str) -> Result<AgentProfile>`.
2. Add `agents/claude.toml` with the existing claude hardcodes extracted.
3. Modify `src/config.rs` — add `load_agent_name()` (reads `AGENT` env, defaults to `"claude"`).
4. Modify `src/mcp.rs` — rename `create_claude_session` to `create_session(command: &[String])` in both trait and impl; update `FakeMcp`.
5. Modify `src/worker.rs` — add `profile` field; replace four `"auto mode"` sites and the `create_claude_session()` call.
6. Modify `src/turn.rs` — `build_prompt_body` gains `covenant_template` parameter; `process_job` uses `profile.clear_command`.
7. Modify `src/main.rs` — load profile and pass to `Worker::new`.
8. Update tests broken by the `create_session` signature change and the `build_prompt_body` parameter change.

**Exit criterion:** `cargo test` green; `AGENT=claude ./ht-webif` behaves identically to v1.0.

### Phase 2 — Second Agent Profile (Codex CLI or OpenCode)

**Goal:** Add a second `agents/<name>.toml` and verify end-to-end via manual smoke test. This phase is research-heavy; the implementation delta is small (just a new TOML file) but the ready-detection and covenant text require empirical verification against the actual TUI.

**Flags for deeper research:**
- What does a codex TUI snapshot look like when idle/ready? (`ready_pattern`)
- Does codex honor file-write instructions in a prompt footer reliably?
- Does opencode have a `/clear`-equivalent or `/new`-equivalent?
- Both agents: what happens when they cannot find the output files? Do they error, or silently succeed?

**Recommended approach:** Run the agent manually in an ht-mcp session, take snapshots at various states, and capture the ready pattern before writing the TOML.

**Exit criterion:** `AGENT=codex ./ht-webif` accepts a `POST /prompt` and the result/status files appear in `TURNS_DIR`.

### Phase 3 — Multi-Instance Tooling and Documentation

**Goal:** Make it trivially easy to launch two instances with different agents.

1. Add a sample `docker-compose.yml` or `justfile` recipe demonstrating two-instance startup.
2. Update `README.md` with the multi-instance usage pattern.
3. Validate that `TURNS_DIR` isolation prevents cross-instance turn-file collisions.

**Exit criterion:** `just up-claude` and `just up-codex` start both instances; `curl` to each returns responses from the correct agent.

---

## Files Modified vs New (summary)

| File | Status | Change |
|---|---|---|
| `src/profile.rs` | NEW | `AgentProfile` struct + TOML loader |
| `src/config.rs` | MODIFY | Add `load_agent_name()` |
| `src/mcp.rs` | MODIFY | Rename + parametrize `create_session`; update `FakeMcp` |
| `src/worker.rs` | MODIFY | Add `profile` field; replace 4 hardcoded strings |
| `src/turn.rs` | MODIFY | `build_prompt_body` covenant parameter; `clear_command` from profile |
| `src/main.rs` | MODIFY | Load profile; pass to `Worker::new` |
| `agents/claude.toml` | NEW | Claude profile (extracted from existing hardcodes) |
| `agents/codex.toml` | NEW (Phase 2) | Codex CLI profile |
| `agents/opencode.toml` | NEW (Phase 2) | OpenCode profile |

`src/http.rs` and `src/lib.rs` require no changes.

---

## Sources

- Direct source analysis of `src/mcp.rs`, `src/worker.rs`, `src/turn.rs`, `src/config.rs`, `src/main.rs` (v1.0, 2026-06-11)
- `.planning/codebase/ARCHITECTURE.md` (architecture map, 2026-05-26)
- `HT-PROTOCOL.md` v1.1
- `.planning/PROJECT.md` (v2.0 milestone requirements)
