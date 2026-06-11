---
phase: 04-agent-profile-abstraction
plan: 01
subsystem: config
tags: [rust, toml, serde, agent-profile, config-abstraction]

# Dependency graph
requires: []
provides:
  - "AgentProfile struct with serde::Deserialize + deny_unknown_fields (src/profile.rs)"
  - "load_agent_profile: TOML loader with placeholder validation and available-profile listing"
  - "agents/claude.toml: extracted hardcodes (command, ready_pattern, fresh_mode, clear_command, output_covenant, trigger_template)"
  - "load_agent_name + load_agents_dir in src/config.rs"
affects: [04-02-wire-profile, 05-agent-validation]

# Tech tracking
tech-stack:
  added: [toml = "1"]
  patterns:
    - "AgentProfile as plain value type: #[derive(Debug, Clone, serde::Deserialize)] + #[serde(deny_unknown_fields)]"
    - "Profile loader: error-first with search-path + available-list diagnostics"
    - "Startup validation: anyhow::bail! for missing placeholders at load time"
    - "Serde default functions: fn default_startup_timeout() -> u64 { 25 }"

key-files:
  created:
    - src/profile.rs
    - agents/claude.toml
  modified:
    - Cargo.toml
    - src/lib.rs
    - src/config.rs

key-decisions:
  - "D-07 enforced: serde deny_unknown_fields rejects unknown TOML keys at startup (typo detection)"
  - "D-11 enforced: validate_profile checks {result_path}/{status_path} in output_covenant and {prompt_path} in trigger_template"
  - "D-13 enforced: model_flag/model_value are Option<String> — absent from TOML is valid"
  - "D-15 enforced: no env override for TOML values — env=infra / TOML=agent-behaviour two-layer model maintained"
  - "D-04 enforced: agents/test.toml not committed; all tests use tempfile::tempdir for hermetic TOML"

patterns-established:
  - "Pattern: agents/<name>.toml as agent profile source of truth; load_agent_profile(name, agents_dir)"
  - "Pattern: load_agent_name() / load_agents_dir() follow existing load_* env-resolution pattern in config.rs"
  - "Pattern: [profile] tag for profile-related eprintln! log messages"

requirements-completed: [PROF-01, PROF-02, PROF-05, PROF-06]

# Metrics
duration: 5min
completed: 2026-06-11
---

# Phase 4 Plan 01: Agent Profile Abstraction — Foundation Summary

**AgentProfile struct + agents/claude.toml extraction + TOML loader with placeholder validation, establishing the contract layer for 04-02 wiring**

## Performance

- **Duration:** 5 min
- **Started:** 2026-06-11T07:57:45Z
- **Completed:** 2026-06-11T08:02:12Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- `src/profile.rs` created: `AgentProfile` struct, `load_agent_profile`, `validate_profile`, `list_available_profiles` with 10 co-located tests all green
- `agents/claude.toml` created: all 5 current hardcodes extracted (command, ready_pattern, fresh_mode, clear_command, output_covenant, trigger_template) with optional field comment examples
- `src/config.rs` extended: `load_agent_name` (AGENT env > "claude" default) and `load_agents_dir` (AGENTS_DIR env > CWD/agents default)
- All 23 tests green (10 new profile tests + 13 existing unchanged)

## Task Commits

Each task was committed atomically:

1. **Task 1: toml 依存追加 + profile モジュール宣言 + agents/claude.toml 抽出** - `8fa32bf` (feat)
2. **Task 2: AgentProfile struct + load_agent_profile + validate + scan + tests** - `8c43757` (feat)
3. **Task 3: config.rs — load_agent_name + load_agents_dir** - `0891f7f` (feat)

## Files Created/Modified
- `src/profile.rs` (new, 316 lines) — AgentProfile struct, loader, validator, scan, 10 tests
- `agents/claude.toml` (new) — Claude Code agent profile with 5 required fields + optional commented fields
- `Cargo.toml` — added `toml = "1"` dependency
- `src/lib.rs` — added `pub mod profile;`
- `src/config.rs` — added `load_agent_name` and `load_agents_dir`

## Decisions Made
- AgentProfile stores `command: Vec<String>` (not `Vec<str>`) to enable owned storage on Worker struct in 04-02
- `validate_profile` is non-pub: it's always called via `load_agent_profile`; callers never need to invoke it separately
- `list_available_profiles` is non-pub: error diagnostics helper only
- TOML output_covenant uses `"""..."""` multiline without leading `\n\n` — `build_prompt_body` in 04-02 will use `format!("{task}\n\n{body}")` to reproduce v1.0 output byte-identical (D-12 golden test to be added in 04-02 when turn.rs is parametrized)

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered
- `use std::path::{Path, PathBuf}` initially included unused `PathBuf` — caught by compiler warning, removed before commit (Rule 1 auto-fix, trivial)

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All contract types for 04-02 are now defined: `AgentProfile`, `load_agent_profile`, `load_agent_name`, `load_agents_dir`
- 04-02 can now wire profile into Worker, mcp.rs (trait rename), worker.rs (4 ready-pattern sites), turn.rs (build_prompt_body parametrization), and main.rs startup sequence
- Golden test (D-12) verifying byte-identical covenant output is deferred to 04-02 where `build_prompt_body` signature changes

---
*Phase: 04-agent-profile-abstraction*
*Completed: 2026-06-11*
