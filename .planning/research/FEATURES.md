# Feature Research

**Domain:** Multi-agent HTTP WebIF driver — agent profile / multi-backend TUI orchestration
**Researched:** 2026-06-11
**Confidence:** HIGH (core agent behaviors from official docs); MEDIUM (ready-detection patterns from source observation)

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist when adopting a profile-based multi-backend driver. Missing these = product feels incomplete or requires code changes to add new agents.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Agent profile TOML/JSON with `command`, `args`, `env` fields | Standard pattern for any pluggable backend system (cf. Codex CLI config.toml agent roles, OpenCode opencode.json) — users expect zero-code extensibility | LOW | Flat struct in `agents/*.toml`; loaded at startup via `AGENT=<name>` |
| `ready_pattern` field (regex matched against terminal snapshot) | Every TUI has a distinct startup state; without a configurable pattern the driver is hard-coded to Claude's "auto mode" text — breaks immediately for Codex/OpenCode | MEDIUM | Currently hard-coded as `snap.contains("auto mode")` in `worker.rs:45`; must become a profile field |
| `clear_command` field (e.g. `/clear` vs `/new`) | Claude Code uses `/clear`, OpenCode uses `/new` (alias `/clear` in TUI, keyboard `ctrl+x n`), Codex always starts a fresh session — the `fresh:true` path is currently hard-coded | LOW | Single string field sent as a TUI keystroke line; existing `fresh:true` plumbing reuses this |
| `AGENT` env var selecting which profile to load at startup | Users expect instance-level selection without recompiling; matches the existing `PORT`/`TURNS_DIR` env-var config pattern already in the codebase | LOW | `config.rs` already has the env-loading pattern; add `load_agent_profile()` |
| `/info` or `/health` endpoint exposing active agent name and port | When running N instances on different ports, callers need a machine-readable way to know which agent a port serves before routing work to it | LOW | Add a `GET /info` JSON response: `{ "agent": "codex", "port": 8081, "status": "healthy" }` |
| Permission/trust bypass args in profile (`extra_args`) | Claude Code: `--dangerously-skip-permissions`; Codex CLI: `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`) or `CODEX_NON_INTERACTIVE=1`; OpenCode: `--dangerously-skip-permissions` flag or `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` env var — automation dies on interactive permission prompts | LOW | An `extra_args` array in the profile covers all three; profile author chooses the right flag per agent |
| Working directory field (`cwd`) | Codex CLI: `--cd`/`-C` flag; OpenCode: positional `[project]` arg or `--dir`; Claude Code: cwd inherited from spawn — profile must capture this per-agent convention | LOW | Passed as spawn arg or env; `ht_create_session` in ht-mcp can accept a `command` string containing `--cd` |

### Differentiators (Competitive Advantage)

Features that make ht-webif's multi-agent story meaningfully better than manually managing multiple TUI invocations.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Launcher script (e.g. `scripts/launch-agents.sh`) generating N instances on port range | Eliminates the manual `PORT=8081 AGENT=codex ./ht-webif &` boilerplate for parallel orchestration; direct answer to "parallel drive foundation" goal | LOW | Shell script only; no Rust code change; reads `agents/*.toml` names and a port-base arg |
| Model selection field in profile (`model_arg`) | Each backend spells model selection differently: Claude Code `--model claude-opus-4-8`, Codex `--model gpt-5.4`, OpenCode `--model anthropic/claude-sonnet-4-5` — profile captures the correct arg name and value pair | LOW | Profile fields `model_flag` (e.g. `--model`) + `model_value`; or just flatten into `args` array |
| `prompt_submit_key` field (default `\n`, but some TUIs may differ) | Abstracts keystroke submission; currently ht-mcp `submit_line` appends `\n` — field becomes documentation + future override point | LOW | For all three surveyed agents, Enter (`\n`) submits prompts; field value is mostly documentation now but enables future specialisation |
| `startup_timeout_secs` field | Claude Code reaches ready in ~5 s locally, but Codex CLI with model downloading could be 30 s+; configurable timeout prevents false "agent failed to start" errors | LOW | Replaces hard-coded `Duration::from_secs(25)` in `worker.rs:42` |
| `/info` response includes `profile_name`, `version`, uptime, turn count | Gives orchestrator scripts richer observability without a full metrics stack | LOW | Extend the `/info` JSON; no external dependency |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Per-request agent switching (`POST /prompt {"agent":"codex"}`) | Callers want one endpoint to fan out to multiple agents | Breaks "1 process = 1 agent" invariant; requires worker pool management inside WebIF; adds lock contention and session state complexity | Keep 1 process = 1 agent; caller routes to different ports. This was explicitly decided Out of Scope in PROJECT.md. |
| Built-in orchestration / fan-out inside WebIF | Seems convenient for multi-agent pipelines | Crosses the boundary into orchestrator territory; the WebIF's value is being a thin, reliable bridge — not a scheduler | Callers compose via shell scripts, Go/Python orchestrators, or a dedicated routing layer |
| Dynamic profile hot-reload (add agent without restart) | Operators want zero-downtime agent changes | Profile state is baked into Worker at boot time; hot-reload requires a state machine for "draining" the current worker, adds error surfaces | Restart the instance (`POST /restart` already exists); launch new instance on new port |
| Embedded agent registry / service discovery inside WebIF | Would let callers query "what agents are available?" | Centralised registry is a separate service concern; WebIF instances are stateless peers | Each instance exposes `/info`; callers maintain their own port→agent map (a text file or env vars) |
| Agent profile schema validation with JSON Schema / serde error messages | Nice UX | Profile is read once at startup; a clear panic with field name is sufficient for the operator audience | `anyhow` context messages in `config.rs` pattern; no external schema library needed |

---

## Feature Dependencies

```
AGENT env var selection
    └──requires──> Agent profile loader (agents/*.toml)
                       └──requires──> Profile fields: command, args, env, ready_pattern,
                                      clear_command, startup_timeout_secs, extra_args, cwd

Agent profile loader
    └──enables──> Worker::spawn_session (replaces hard-coded "auto mode" + 25s timeout)
    └──enables──> fresh:true / clear path (replaces hard-coded "/clear")
    └──enables──> /info endpoint (reads loaded profile name)

/info endpoint
    └──enhances──> Launcher script (script polls /info to confirm instance is up)

Launcher script
    └──requires──> /info or /health endpoint (to health-check each spawned instance)
```

### Dependency Notes

- **Agent profile loader requires profile fields**: The entire multi-agent feature chain starts here. Without a well-specified TOML schema, every downstream feature is undefined.
- **Worker::spawn_session requires ready_pattern**: The existing hard-coded `snap.contains("auto mode")` in `worker.rs` must be replaced with a profile-driven check before Codex or OpenCode instances can start reliably.
- **fresh:true clear path requires clear_command field**: OpenCode's `/new` vs Claude's `/clear` divergence means the existing `fresh:true` path silently does the wrong thing without this field.
- **Launcher script enhances /info**: The launcher can `curl /info` to confirm a port is serving the expected agent before declaring it ready — prevents sending work to a half-started instance.

---

## MVP Definition

### Launch With (v2.0)

Minimum viable set to achieve "Codex CLI and OpenCode supported, multiple instances parallel-driveable":

- [x] Agent profile TOML schema with `command`, `args`, `env`, `ready_pattern`, `clear_command`, `startup_timeout_secs` fields
- [x] `AGENT=<name>` env var selecting profile at startup
- [x] `ready_pattern` replaces hard-coded `"auto mode"` check in `worker::spawn_session`
- [x] `clear_command` replaces hard-coded `"/clear"` in the `fresh:true` path
- [x] Claude profile defined as `agents/claude.toml` (re-expresses current hard-coded behavior)
- [x] Codex profile defined as `agents/codex.toml` (command, bypass flag, ready pattern)
- [x] OpenCode profile defined as `agents/opencode.toml` (command, `/new` clear, ready pattern)
- [x] `GET /info` returns `{ "agent": "<name>", "port": <n>, "status": "healthy" }`
- [x] Launcher script `scripts/launch-agents.sh` for parallel instances

### Add After Validation (v2.x)

- [ ] `model_flag` + `model_value` profile fields for model selection — add when users report needing per-instance model override without editing `args`
- [ ] `startup_timeout_secs` as a profile field — add when Codex startup time proves variable in practice
- [ ] `/info` extended with uptime and turn count — add when operators ask for observability

### Future Consideration (v3+)

- [ ] Gemini CLI profile — defer until Gemini CLI TUI behavior is stable and documented
- [ ] Profile validation with friendly error messages — defer; `anyhow` context is sufficient for v2.0's operator audience

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Agent profile TOML + AGENT env var | HIGH | LOW | P1 |
| `ready_pattern` field (replaces hard-coded "auto mode") | HIGH | LOW | P1 |
| `clear_command` field (replaces hard-coded "/clear") | HIGH | LOW | P1 |
| Claude / Codex / OpenCode built-in profiles | HIGH | LOW | P1 |
| `GET /info` endpoint | MEDIUM | LOW | P1 |
| Launcher script | MEDIUM | LOW | P1 |
| `extra_args` / permission bypass in profile | HIGH | LOW | P1 |
| `model_flag`+`model_value` profile fields | MEDIUM | LOW | P2 |
| `startup_timeout_secs` field | LOW | LOW | P2 |
| Extended `/info` (uptime, turn count) | LOW | LOW | P3 |

**Priority key:** P1 = must have for v2.0 launch; P2 = add after core validated; P3 = nice to have

---

## TUI Behavior Reference (per Agent)

This section is the canonical source for profile field values — the output of comparing the three target agents.

### Claude Code (`claude`)

| Behavior | Value | Notes |
|----------|-------|-------|
| Spawn command | `claude` | No subcommand needed for interactive TUI |
| Model flag | `--model <id-or-alias>` | Aliases: `sonnet`, `opus`, `haiku`, `fable`; e.g. `--model claude-opus-4-8` |
| Permission bypass flag | `--dangerously-skip-permissions` | Equivalent to `--permission-mode bypassPermissions` |
| Ready signal (terminal snapshot) | `"auto mode"` (current hard-code) | Appears in status bar when interactive session is open; confirmed working in existing codebase |
| Clear / new session command | `/clear` | No `/new` command; `/clear` resets context within same session |
| Prompt submission | `\n` (Enter) via `submit_line` | Standard; ht-mcp `submit_line` appends newline |
| First-run trust prompts | Yes — tool permission prompts on first file/bash use | Mitigated by `--dangerously-skip-permissions` or pre-configuring `settings.json` `allowedTools` |
| Working directory | Inherited from spawn cwd (no flag needed) | `--add-dir` flag for additional dirs |
| Context in ht-mcp | `ht_create_session` `command` = `claude` | Current `create_claude_session` in mcp.rs calls this |

### Codex CLI (`codex`)

| Behavior | Value | Notes |
|----------|-------|-------|
| Spawn command | `codex` | Interactive TUI by default with no subcommand |
| Model flag | `--model <id>` or `-m <id>` | e.g. `--model gpt-5.4` |
| Permission bypass flag | `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`) | Also `CODEX_NON_INTERACTIVE=1` for unattended installer; for runtime bypass `--yolo` is the correct flag |
| Ready signal (terminal snapshot) | Unknown — requires empirical observation | Likely a prompt marker or status line; must be determined by running `codex` under ht-mcp and capturing snapshot. `ready_pattern` in profile should be set after testing. Best guess: presence of a `>` or `codex>` prompt marker |
| Clear / new session command | Fresh `codex` session (no in-session clear command) | `codex resume` resumes; `codex fork` branches. For WebIF "fresh" semantics, the profile `clear_command` should be empty and fresh:true should kill+respawn the session instead |
| Prompt submission | `\n` (Enter) | Standard |
| First-run trust prompts | Yes — approval prompts before shell execution | `--yolo` bypasses; authenticate via `OPENAI_API_KEY` env var |
| Working directory | `--cd <path>` or `-C <path>` flag | Must be in `args` array in profile |
| Context in ht-mcp | `ht_create_session` `command` = `codex [--yolo] [--model ...]` | Full command string including flags |

### OpenCode (`opencode`)

| Behavior | Value | Notes |
|----------|-------|-------|
| Spawn command | `opencode` | TUI launches with no subcommand |
| Model flag | `--model <provider/model>` or `-m <provider/model>` | e.g. `--model anthropic/claude-sonnet-4-5` |
| Permission bypass flag | `--dangerously-skip-permissions` (undocumented) or `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` | Can also be set via `"permission": "allow"` in `opencode.json`; env var is preferable for WebIF use |
| Ready signal (terminal snapshot) | Unknown — requires empirical observation | OpenCode starts a TUI with a sidebar and message input; snapshot likely shows the project path or a prompt input indicator. `ready_pattern` must be set after testing |
| Clear / new session command | `/new` (alias `/clear`; keyboard `ctrl+x n`) | Send `/new\n` via `submit_line` for fresh session semantics |
| Prompt submission | `\n` (Enter) | Standard |
| First-run trust prompts | Yes — permission prompts for file/shell tool calls | `--dangerously-skip-permissions` or `OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true` mitigates |
| Working directory | Positional `[project]` arg or `--dir` flag | `opencode /path/to/project` or `opencode --dir /path/to/project` |
| Context in ht-mcp | `ht_create_session` `command` = `opencode [--dir ...] [--model ...]` | |
| Config file | `opencode.json` in project root or `~/.config/opencode/opencode.json` globally | Provider API keys, permission defaults, model defaults |

---

## Critical Implementation Note: Codex "fresh" Semantics

Codex CLI does not have an in-session `/clear` equivalent. Each `codex` invocation always starts a fresh session (`codex resume` explicitly opts into continuation). For the `fresh:true` path in WebIF, the profile should express this as:

```
fresh_mode = "respawn"   # kill and respawn the session (vs "command" for Claude/OpenCode)
```

This means the profile schema needs a `fresh_mode` field with values `"command"` (send `clear_command` text) or `"respawn"` (kill+recreate session). This is a P1 schema decision — failing to capture it means Codex `fresh:true` silently sends `/clear` which is a no-op or error.

---

## Sources

- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) — official, HIGH confidence
- [OpenCode CLI docs](https://opencode.ai/docs/cli/) — official, HIGH confidence
- [OpenCode TUI docs](https://opencode.ai/docs/tui/) — official, HIGH confidence
- [Codex CLI reference](https://developers.openai.com/codex/cli/reference) — official, HIGH confidence
- [Codex CLI features](https://developers.openai.com/codex/cli/features) — official, HIGH confidence
- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) — official, HIGH confidence
- [ht-mcp GitHub](https://github.com/memextech/ht-mcp) — official, HIGH confidence
- OpenCode `--dangerously-skip-permissions` GitHub issues (anomalyco/opencode #8463, #9070, #21065) — community, MEDIUM confidence
- Existing codebase: `src/worker.rs` ready detection pattern and `src/mcp.rs` spawn logic — source, HIGH confidence

---

*Feature research for: ht-webif v2.0 multi-agent support*
*Researched: 2026-06-11*
