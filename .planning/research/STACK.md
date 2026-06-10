# Stack Research

**Domain:** Multi-agent support additions to ht-webif (Rust + axum HTTP WebIF)
**Researched:** 2026-06-11
**Confidence:** HIGH for TOML crate selection and ht-mcp arbitrariness; MEDIUM for Codex/OpenCode TUI interaction details (verified via official docs and source)

---

## Scope

This file covers only **new additions** required for the v2.0 マルチエージェント対応 milestone. The existing stack (tokio, axum 0.8, serde, serde_json, anyhow, chrono, dotenvy, tower-http, async-trait) is already validated and is NOT re-evaluated here.

---

## New Dependency: TOML Parsing

### Recommendation: `toml = "1"` (default features)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `toml` | 1.1.2 (latest as of 2026-04-01) | Parse `agents/*.toml` profile files into typed Rust structs | Already a transitive dependency of Cargo itself; integrates directly with existing `serde` + `#[derive(Deserialize)]`. Zero new conceptual surface area for maintainers. |

**Cargo.toml addition:**
```toml
toml = "1"
```
No extra features needed — the default build includes serde deserialization support when `serde` is already a dependency. The `serde` feature is enabled by default in toml 1.x.

### Alternatives Rejected

| Crate | Version | Why Not |
|-------|---------|---------|
| `figment` | 0.10.19 | Excellent for layered runtime config (env > file > defaults) but adds 15 MB transitive weight and a new abstraction layer. The project already uses dotenvy + `std::env` for runtime config; agent profiles are static per-instance files, not layered config. No benefit over plain `toml` deserialization. |
| `config` | 0.14.x | 58M+ downloads but designed for application runtime config, not schema-defined profile files. Adds unnecessary complexity — profiles are read once at startup and are structurally fixed. |
| `toml_edit` | 0.22.x | Format-preserving TOML rewriter. Only needed when writing TOML back to disk (e.g., a config editor). ht-webif reads profiles; it does not write them. |
| `basic-toml` | 0.1.x | Minimal subset — lacks some TOML 1.0 features. No advantage over the standard `toml` crate for this use case. |

**Rationale for `toml = "1"` over `toml = "0.8"`:** Version 1.x (released 2026-03) implements the finalized TOML 1.1 spec and is now stable. The 0.8 series is in maintenance mode. New code should target 1.x.

---

## ht-mcp: Arbitrary TUI Support Confirmed

**Finding:** ht-mcp is **not Claude-specific**. It spawns any arbitrary command via PTY.

The `ht_create_session` tool accepts a `command: Vec<String>` parameter (optional). When omitted, it defaults to `["bash"]`. The spawning code is:

```rust
let command = args.command.unwrap_or_else(|| vec!["bash".to_string()]);
// passed to pty::spawn() as-is — no allowlist, no validation
```

This means the existing `mcp.rs` / `worker.rs` infrastructure that currently passes `["claude"]` to `ht_create_session` can pass `["codex"]`, `["opencode"]`, or any other binary simply by changing the command vector. **No changes to the MCP client transport layer are required.**

The six MCP tools exposed by ht-mcp (`ht_create_session`, `ht_send_keys`, `ht_take_snapshot`, `ht_execute_command`, `ht_list_sessions`, `ht_close_session`) are all generic terminal operations.

**Implication for agent profiles:** The `command` field in `agents/*.toml` maps directly to the `command` argument of `ht_create_session`. The only code that needs to change is the session initialization path in `worker.rs` — it currently hardcodes `"claude"` and needs to read from the loaded agent profile instead.

---

## Target Agents: Codex CLI and OpenCode

### Codex CLI

| Property | Value |
|----------|-------|
| Binary name | `codex` |
| Install (npm) | `npm install -g @openai/codex` |
| Install (Homebrew) | `brew install --cask codex` |
| Install (binary) | GitHub Releases — `codex-x86_64-unknown-linux-musl.tar.gz` (Linux) |
| Current version | 0.139.0 (as of 2026-06-09) — Rust codebase (96% Rust) |
| Authentication | Requires `OPENAI_API_KEY` env var (API billing, not subscription-based) |
| Interactive TUI | Full-screen TUI launched by running `codex` with no args |

**TUI session management slash commands (relevant for `clear_command` profile field):**
- `/clear` — wipes transcript and starts a fresh chat (confirmed by official docs)
- `/new` — same effect as `/clear`, initiates a fresh conversation
- `/compact` — summarizes earlier turns to free tokens (not a full reset)
- `/quit`, `/exit` — exits the CLI

**Non-interactive / headless mode (relevant for ht-mcp driving strategy):**
Codex has a `codex exec "<prompt>"` subcommand designed for CI/scripted runs. However, ht-webif drives Codex the same way it drives Claude: by spawning the interactive TUI via ht-mcp and sending keystrokes. The `exec` subcommand is **not** used because ht-mcp drives the interactive TUI session.

**Prompt submission in interactive TUI:** Type prompt text + Enter to submit. Same pattern as Claude.

**Known caveat:** Codex requires `OPENAI_API_KEY` — it uses OpenAI API billing, not a subscription. This is architecturally different from Claude (Max subscription OAuth). The agent profile should document this constraint. The webif itself does not manage API keys; they must be set in the environment before spawning.

### OpenCode

| Property | Value |
|----------|-------|
| Binary name | `opencode` |
| Install (script) | `curl -fsSL https://opencode.ai/install \| bash` |
| Install (npm) | `npm i -g opencode-ai@latest` |
| Install (Homebrew) | `brew install opencode` |
| Current version | Active development (Go-based, maintained at opencode-ai/opencode) |
| Authentication | Provider-specific API keys via `opencode auth login` → `~/.local/share/opencode/auth.json` |
| Interactive TUI | Full-screen TUI launched by running `opencode` |

**TUI session management (relevant for `clear_command` profile field):**
- `/clear` — starts a new session (confirmed, with alias `/new`)
- `Ctrl+X n` — keyboard shortcut for new session (leader key `Ctrl+X`, then `n`)
- `Ctrl+P` — opens command panel
- `/undo`, `/redo` — available
- Tab — switches between "build" and "plan" modes

**Prompt submission in interactive TUI:** Type prompt text + Enter to submit. Same as Claude.

**Non-interactive mode:** OpenCode supports `opencode run "<prompt>"` and `opencode -p "<prompt>"` for scripted use. Like Codex, ht-webif drives it through the interactive TUI via ht-mcp, not via these non-interactive flags.

**Known caveat:** OpenCode supports multiple LLM providers (OpenAI, Anthropic, etc.) configured via `opencode auth login`. The provider and model used depend on what the user has configured before spawning. The agent profile should note which provider/model is expected but cannot enforce it.

---

## Agent Profile File Format: Recommended Schema

Based on the above research, the `agents/*.toml` profile format needed is minimal. Recommended fields:

```toml
# agents/claude.toml (example)
[agent]
name = "claude"
command = ["claude"]         # passed to ht_create_session as command vec
ready_pattern = ">"          # regex/string to detect TUI ready state in snapshot
clear_command = "/clear\n"   # keystrokes to send for session reset (fresh:true)
```

```toml
# agents/codex.toml (example)
[agent]
name = "codex"
command = ["codex"]
ready_pattern = ">"
clear_command = "/clear\n"
```

```toml
# agents/opencode.toml (example)
[agent]
name = "opencode"
command = ["opencode"]
ready_pattern = ">"
clear_command = "/clear\n"
```

The corresponding Rust struct:

```rust
#[derive(Debug, Deserialize)]
pub struct AgentProfile {
    pub agent: AgentConfig,
}

#[derive(Debug, Deserialize)]
pub struct AgentConfig {
    pub name: String,
    pub command: Vec<String>,
    pub ready_pattern: String,
    pub clear_command: String,
}
```

Deserialized with:
```rust
let content = std::fs::read_to_string(path)?;
let profile: AgentProfile = toml::from_str(&content)?;
```

No async I/O needed — profiles are small files read once at startup.

---

## Recommended Stack Additions

| Technology | Version | Purpose | Add to Cargo.toml |
|------------|---------|---------|-------------------|
| `toml` | `"1"` | Parse `agents/*.toml` profile files | `toml = "1"` |

That is the only new direct dependency. No other crates are needed.

**No new crates for:**
- Agent selection — `std::env::var("AGENT")` via existing dotenvy pattern, handled in `config.rs`
- Multi-instance support — already works via `PORT`/`TURNS_DIR` env vars; no code change needed
- ht-mcp transport — existing `mcp.rs` is generic; only the `command` arg to `ht_create_session` changes
- Profile loading path — `std::fs::read_to_string` + `toml::from_str` is sufficient

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| TOML parsing | `toml = "1"` | `figment` | figment is for layered runtime config, not static typed files; overkill |
| TOML parsing | `toml = "1"` | `config` crate | Same problem as figment; wrong abstraction |
| TOML parsing | `toml = "1"` | `toml = "0.8"` | 0.8 is maintenance-only; 1.x is stable with TOML 1.1 spec |
| Profile format | TOML | JSON | TOML is more human-editable for config files; consistent with Cargo ecosystem |
| Profile format | TOML | YAML | YAML has parsing pitfalls (indentation, type coercion); TOML is safer for simple configs |

---

## What NOT to Add

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `figment` | Heavy for this use case — profiles are read-once static files, not layered runtime config | `toml = "1"` + `#[derive(Deserialize)]` |
| `config` crate | Same — designed for application configuration hierarchy, not agent profile schemas | `toml = "1"` |
| `rmcp` | Already rejected in v1.0 (stdio JSON-RPC is sufficient, no need for the rmcp framework) | Hand-rolled MCP client in `mcp.rs` |
| `codex exec` / `opencode run` wrappers | ht-webif drives interactive TUIs via ht-mcp, not via non-interactive subcommands | ht-mcp `ht_create_session` + `ht_send_keys` |
| Any "agent router" crate | Routing between agents is caller's responsibility (out of scope per PROJECT.md) | Shell scripts / external orchestrators |

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| `toml = "1"` | `serde = "1"` (already in Cargo.toml) | toml 1.x uses serde 1.x; no conflict |
| `toml = "1"` | `tokio = "1"` | No tokio dependency in toml — pure sync parsing, fine to use in async context at startup |
| `codex` binary | `ht-mcp` (arbitrary PTY) | Confirmed: ht-mcp spawns any command, no claude-specific code |
| `opencode` binary | `ht-mcp` (arbitrary PTY) | Same as above |

---

## Sources

- [crates.io/crates/toml](https://crates.io/crates/toml) — version 1.1.2 confirmed latest (2026-04-01)
- [docs.rs/crate/toml/latest](https://docs.rs/crate/toml/latest) — serde integration confirmed default
- [github.com/memextech/ht-mcp session_manager.rs](https://github.com/memextech/ht-mcp) — `command` parameter confirmed arbitrary (`Vec<String>`, defaults to `["bash"]`)
- [developers.openai.com/codex/cli/slash-commands](https://developers.openai.com/codex/cli/slash-commands) — `/clear`, `/new`, `/compact` confirmed; confidence HIGH
- [developers.openai.com/codex/cli/reference](https://developers.openai.com/codex/cli/reference) — `codex exec` non-interactive mode, flags confirmed
- [github.com/openai/codex](https://github.com/openai/codex) — binary name `codex`, version 0.139.0, Rust codebase, install methods
- [opencode.ai/docs/cli/](https://opencode.ai/docs/cli/) — binary name `opencode`, `run` subcommand, session management
- [opencode.ai/docs/tui/](https://opencode.ai/docs/) + community sources — `/clear` (alias `/new`), `Ctrl+X n` shortcut; confidence MEDIUM (TUI internals less formally documented)
- [crates.io/crates/figment](https://crates.io/crates/figment) — version 0.10.19, evaluated and rejected
- [lib.rs/config](https://lib.rs/config) — `config` crate evaluated and rejected

---

*Stack research for: ht-webif v2.0 マルチエージェント対応*
*Researched: 2026-06-11*
