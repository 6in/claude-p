# Project Research Summary

**Project:** ht-webif v2.0 — マルチエージェント対応
**Domain:** Multi-agent HTTP WebIF driver — profile-driven TUI orchestration
**Researched:** 2026-06-11
**Confidence:** HIGH (stack + architecture based on direct source analysis); MEDIUM (Codex/OpenCode TUI internals)

## Executive Summary

ht-webif v2.0 extends the existing single-agent (Claude Code) HTTP WebIF to support multiple AI agent TUIs — Codex CLI and OpenCode — via a profile-based abstraction. The fundamental insight driving the design is that ht-mcp already spawns arbitrary commands via PTY (it defaults to `bash`, not `claude`); the entire existing MCP transport layer is therefore already agent-agnostic. Only four sites in the codebase hardcode Claude-specific behavior: the `ht_create_session` spawn command, three instances of the `"auto mode"` ready-detection string, the `/clear` session-reset keystroke, and the Japanese output covenant appended to every prompt. Replacing these four sites with values read from a per-process `agents/<name>.toml` profile file is the entire implementation of multi-agent support.

The recommended approach is to introduce a single new type — `AgentProfile` — loaded once at startup from `agents/${AGENT}.toml` (defaulting to `claude`), stored as a plain `Clone`-able struct on `Worker<M>`, and threaded through the four claude-specific sites. No new architectural patterns, no runtime dispatch, no per-request agent switching. The only new direct dependency is `toml = "1"` for TOML deserialization. Multi-instance parallel operation requires no new WebIF code — the existing `PORT` + `TURNS_DIR` isolation is already complete; the `AGENT` env var is the only addition needed.

The main risks are not in the Rust implementation but in the empirical unknowns about Codex CLI and OpenCode TUI behavior: ready-detection patterns for non-Claude agents must be discovered by running the actual binaries under ht-mcp, the output covenant (the natural-language instruction to write result/status files) must be tested per model family, and authentication/trust-dialog prerequisites are different for each agent. These risks are contained by a phased approach: implement the profile abstraction first (with Claude as the only profile, behavior unchanged), then add each new agent after empirical testing.

## Key Findings

### Recommended Stack

The existing stack requires one addition: `toml = "1"` for parsing `agents/*.toml` profile files. This crate is already a transitive dependency of Cargo itself and integrates directly with the existing `serde` + `#[derive(Deserialize)]` pattern. All other stack additions (figment, config crate, rmcp, agent-router crates) are rejected as overkill. See `.planning/research/STACK.md` for the full alternatives evaluation.

**Core technologies (new):**
- `toml = "1"`: Parse `agents/*.toml` profile files — only new direct dependency; serde integration is default in 1.x
- `ht-mcp` arbitrary PTY: Already accepts `command: Vec<String>`; passes `["codex"]` or `["opencode"]` with zero transport changes
- `std::env::var("AGENT")`: Instance-level agent selection — same dotenvy pattern already used for `PORT`/`TURNS_DIR`

### Expected Features

See `.planning/research/FEATURES.md` for the full feature table with complexity ratings.

**Must have (v2.0 launch — all P1):**
- Agent profile TOML schema: `command`, `ready_pattern`, `clear_command`, `output_covenant`, `fresh_mode`, `turn_timeout_secs`, `session_startup_timeout_secs`, `wedge_pattern` fields
- `AGENT=<name>` env var selecting profile at startup
- `ready_pattern` replaces hardcoded `"auto mode"` check in `worker::spawn_session` (four sites)
- `clear_command` + `fresh_mode` replace hardcoded `/clear` in the `fresh:true` path
- `output_covenant` template replaces hardcoded Japanese footer in `turn.rs`
- Built-in profiles: `agents/claude.toml`, `agents/codex.toml`, `agents/opencode.toml`
- `GET /info` endpoint: `{ "agent": "<name>", "port": <n>, "status": "healthy" }`
- Launcher script `scripts/launch-agents.sh` for parallel instance startup
- `extra_args` / permission-bypass field in profile (`--dangerously-skip-permissions`, `--yolo`)

**Schema decision — `fresh_mode` field (CORRECTED 2026-06-11):** Codex CLI DOES support in-session `/clear`/`/new` (user-confirmed + official docs; see STACK.md, which had this right — the original "no in-session clear" claim from FEATURES.md was wrong). All three launch agents default to `fresh_mode = "command"`. The field is retained as schema generality for future agents that lack an in-session clear, and as a fallback if `/clear` proves unreliable under PTY automation during empirical validation.

**Should have (v2.x after validation):**
- `model_flag` + `model_value` profile fields for per-instance model override
- Extended `/info` with uptime and turn count
- `prerequisite_check` shell command run at startup to verify auth readiness

**Defer (v3+):**
- Gemini CLI profile (TUI behavior not yet stable)
- Per-request agent switching (explicitly out of scope: "1 process = 1 agent")

### Architecture Approach

The change is purely additive at the data layer: one new file (`src/profile.rs`) defines `AgentProfile`, and four existing files receive targeted parameter changes. The HTTP layer (`http.rs`) and MCP transport layer interface are unchanged. The `trait Mcp` gains one signature change: `create_claude_session()` becomes `create_session(command: &[String])`. `Worker<M>` gains a `profile: AgentProfile` field. `AgentProfile` is a plain value type (not a trait) — one profile per process, no runtime dispatch needed.

See `.planning/research/ARCHITECTURE.md` for the complete component boundary table, data-flow diagrams, and exact per-file change descriptions.

**Major components:**
1. `src/profile.rs` (NEW): `AgentProfile` struct + `load_agent_profile(name: &str)` — TOML deserialization, no async I/O
2. `src/worker.rs` (MODIFY): Stores `profile: AgentProfile`; replaces 4 hardcoded strings; exposes `profile()` getter
3. `src/turn.rs` (MODIFY): `build_prompt_body` gains `covenant_template` param; `process_job` uses `profile.clear_command` / `profile.fresh_mode`
4. `src/mcp.rs` (MODIFY): `create_session(command: &[String])` replaces `create_claude_session()`; `FakeMcp` updated
5. `src/config.rs` (MODIFY): Adds `load_agent_name()` — reads `AGENT` env var, defaults to `"claude"`
6. `agents/*.toml` (NEW): Per-agent profile files checked into repo

### Critical Pitfalls

See `.planning/research/PITFALLS.md` for all 8 pitfalls with recovery strategies and phase-to-pitfall mapping.

1. **Ready-detection regex is agent-specific and brittle** — Codex CLI's Ratatui TUI embeds ANSI escape codes that can split expected substrings across version bumps (GitHub issues #23031, #23740). Strip ANSI before regex matching. Log raw snapshot when pattern fails. Do not ship a new agent profile without an integration smoke test against a real binary.

2. **Output covenant is not portable across model families** — Claude Code follows the file-write instruction reliably; Codex CLI (GPT-4o/o3) and OpenCode with local models may ignore it silently. Add `result-<turnId>.txt` existence check to `turn.rs` in Phase 1 so silent failures surface before any non-Claude agent is wired in.

3. **First-run trust dialogs and auth prerequisites block startup** — Codex CLI shows a directory-trust dialog not always suppressed by `--yolo` (GitHub issues #14345, #9695); OpenCode requires `opencode auth login` before TUI launch. Add `prerequisite_check` field to profiles; fail fast with a clear error rather than timing out.

4. **`fresh:true` / session clear divergence** — the clear command is agent-specific (Claude `/clear`, OpenCode `/new`, Codex `/clear`/`/new` — CORRECTED 2026-06-11: Codex does have in-session clear). OpenCode's `/new` creates a new session ID requiring re-running ready-detection. Per-profile `clear_command` is P1; `fresh_mode` retained as generality/fallback.

5. **`turns/` directory collision in multi-instance operation** — Default `TURNS_DIR = ./turns/` causes silent namespace collisions. Change default to `./turns/<agent-name>/` in Phase 1 so `AGENT=claude` and `AGENT=codex` are automatically isolated.

## Implications for Roadmap

### Phase 1: Agent Profile Abstraction (claude-only, behavior-preserving)

**Rationale:** The profile schema is the foundation for everything downstream. Introducing it with Claude as the only profile — extracting existing hardcodes into `agents/claude.toml` with no behavior change — lets the Rust refactor be code-reviewed in isolation from the empirical unknowns about non-Claude agents. Forces the full schema (including `fresh_mode`, `wedge_pattern`, `turn_timeout_secs`) to be defined before agent-specific values are needed.

**Delivers:**
- `src/profile.rs` with `AgentProfile` struct and TOML loader
- `AGENT` env var support in `config.rs`
- `create_session(command: &[String])` trait method replacing `create_claude_session()`
- Full schema: `ready_pattern`, `clear_command`, `fresh_mode`, `output_covenant`, `turn_timeout_secs`, `wedge_pattern` fields
- `agents/claude.toml` (re-expresses all current hardcodes)
- `turn.rs` result-file existence check (catches silent covenant failures before non-Claude agents are added)
- `GET /info` endpoint
- Default `TURNS_DIR` changed to `./turns/<agent-name>/`

**Avoids:** Ready-detection hardcode debt; covenant portability failures surfacing late; `turns/` collision pitfall baked in from day one.

**Exit criterion:** `AGENT=claude ./ht-webif` is functionally identical to v1.0; `cargo test` green.

**Research flag:** Standard patterns — no phase-level research needed. Architecture is fully specified to exact line numbers in ARCHITECTURE.md.

### Phase 2: Codex CLI and OpenCode Profile Validation

**Rationale:** This phase is research-heavy and implementation-light. The Rust code from Phase 1 requires only new TOML files; the work is empirical: run each agent under ht-mcp, capture snapshots, determine `ready_pattern` values, test `output_covenant` text, validate `/clear` behavior for Codex (falling back to `fresh_mode = "respawn"` only if `/clear` proves unreliable under PTY automation), and confirm permission-bypass flags suppress all interactive prompts. The implementation delta is small (two new TOML files plus any schema tweaks), but the empirical testing is the actual time investment and the source of all blocking unknowns.

**Delivers:**
- `agents/codex.toml`: verified `ready_pattern`, `clear_command = "/clear"` + `fresh_mode = "command"` (respawn fallback only if `/clear` unreliable), `turn_timeout_secs >= 600`, covenant tested against GPT-4o/o3
- `agents/opencode.toml`: verified `ready_pattern`, `clear_command = "/new"`, `fresh_mode = "command"`, covenant tested against configured provider
- Prerequisite documentation in each profile (auth setup, directory trust steps)
- Integration smoke tests gated behind feature flag for CI without binaries
- `CODEX_HOME` isolation guidance in operational notes

**Avoids:** Covenant portability failures (Pitfall 2); first-run dialog wedge (Pitfall 3); wrong `fresh_mode` for Codex (Pitfall 4/7); wrong timeout calibration (Pitfall 8).

**Exit criterion:** `AGENT=codex ./ht-webif` and `AGENT=opencode ./ht-webif` each accept `POST /prompt` and produce non-empty `result-<turnId>.txt` and `status-<turnId>.json`. `fresh:true` works for both.

**Research flag:** NEEDS EMPIRICAL RESEARCH — `ready_pattern` values, `output_covenant` wording, and trust-dialog suppression must be determined by running real binaries under ht-mcp before writing TOML. Do not write profile files by assumption.

### Phase 3: Multi-Instance Parallel Foundation

**Rationale:** Once both agents are validated individually, the multi-instance story is documentation and tooling, not code. The existing `PORT` + `TURNS_DIR` + `AGENT` env-var isolation is already complete after Phases 1 and 2. This phase adds the launcher script and operational documentation that makes parallel operation trivially correct.

**Delivers:**
- `scripts/launch-agents.sh` — spawns N instances on a port range, polls `/info` to confirm readiness
- `justfile` recipes: `just up-claude`, `just up-codex`, `just up-all`
- `README.md` multi-instance section with `CODEX_HOME` isolation instructions
- Validation that `TURNS_DIR` defaults prevent cross-instance collisions over 100 turns

**Avoids:** Credential file races for concurrent Codex instances (Pitfall 6).

**Exit criterion:** `just up-all` starts all three agent instances; `curl` to each `/info` returns the correct agent name; 100 concurrent turns across instances produce zero file-name collisions.

**Research flag:** Standard patterns — shell scripting and documentation; no phase-level research needed.

### Phase Ordering Rationale

- Phase 1 before Phase 2: The profile schema must be finalized and proved out with Claude before empirical testing of other agents can inform schema tweaks. Schema changes are cheap when in a TOML file; they are expensive when encoded as Rust constants.
- Phase 2 before Phase 3: The launcher script polls `/info` and routes to agents by port; it can only be validated end-to-end once both agents work individually.
- Empirical testing is the critical path for Phase 2: The Rust implementation work is ~30 minutes (write two TOML files); the empirical testing work (snapshot capture, covenant tuning) is the actual time investment.

### Research Flags

Phases needing deeper research during planning/execution:
- **Phase 2:** Requires running Codex CLI and OpenCode under ht-mcp to capture real PTY snapshots. `ready_pattern` values, covenant text per model family, and trust-dialog suppression behavior are all empirical unknowns. Use `/gsd-plan-phase --research-phase 2` before executing.

Phases with standard patterns (skip research-phase):
- **Phase 1:** Architecture fully specified in ARCHITECTURE.md with exact file/line references. Mechanical refactor.
- **Phase 3:** Shell scripting and README work. No novel patterns.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | `toml = "1"` verified against crates.io; ht-mcp arbitrary-command support confirmed from source code |
| Features | HIGH | Profile schema fields derived from direct codebase analysis; TUI behaviors confirmed from official docs |
| Architecture | HIGH | Direct source analysis of v1.0 with exact file/line references; component boundaries precisely specified |
| Pitfalls | HIGH | 8 pitfalls with specific GitHub issue numbers; all grounded in real failure modes with recovery steps |

**Overall confidence:** HIGH for Phase 1 (everything specified to line of code). MEDIUM for Phase 2 (Codex CLI `ready_pattern` and covenant text require empirical discovery).

### Gaps to Address

- **Codex CLI `ready_pattern`:** Likely `">"` or `"codex>"` but must be confirmed by capturing a real `ht_take_snapshot` output. Do not ship the profile without this.
- **Codex CLI output covenant compliance:** Whether GPT-4o/o3 reliably follows the file-write instruction is untested. May need a differently-worded or more explicit covenant than the Claude version.
- **OpenCode `ready_pattern`:** Same gap — TUI layout differs from Claude Code; must be captured empirically.
- **OpenCode `--dangerously-skip-permissions` stability:** Undocumented flag; community issues suggest it works but may not suppress all prompts. Treat as MEDIUM confidence; test before shipping the profile.
- **Codex `fresh_mode = "respawn"` session lifecycle:** How ht-mcp handles killing and recreating a Codex session needs a smoke test to confirm no orphan processes or PTY leaks.

## Sources

### Primary (HIGH confidence)
- Direct source analysis: `src/mcp.rs`, `src/worker.rs`, `src/turn.rs`, `src/config.rs`, `src/main.rs` (v1.0, 2026-06-11)
- [github.com/memextech/ht-mcp](https://github.com/memextech/ht-mcp) — arbitrary PTY command confirmed from `session_manager.rs`
- [developers.openai.com/codex/cli/](https://developers.openai.com/codex/cli/) — slash commands, flags, auth
- [opencode.ai/docs/](https://opencode.ai/docs/) — TUI commands, CLI flags, provider auth
- [crates.io/crates/toml](https://crates.io/crates/toml) — version 1.1.2 latest; serde integration default
- HT-PROTOCOL.md v1.1 (project internal)

### Secondary (MEDIUM confidence)
- OpenCode `--dangerously-skip-permissions` — GitHub issues anomalyco/opencode #8463, #9070, #21065
- Codex CLI ANSI escape leakage in TUI output — GitHub issues #23031, #23740
- Codex directory trust not bypassed by `--yolo` in some versions — GitHub issues #14345, #9695

### Tertiary (LOW confidence — requires empirical validation)
- Codex CLI `ready_pattern` value — inference from Ratatui TUI design; must be confirmed by snapshot capture
- OpenCode `ready_pattern` value — inference from TUI layout description; must be confirmed
- Codex CLI output covenant compliance with GPT-4o/o3 — must be tested against real responses

---
*Research completed: 2026-06-11*
*Ready for roadmap: yes*
