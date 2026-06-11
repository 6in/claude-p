# Pitfalls Research

**Domain:** Multi-agent CLI TUI driving system (generalizing ht-webif from Claude Code to Codex CLI / OpenCode)
**Researched:** 2026-06-11
**Confidence:** HIGH

---

## Critical Pitfalls

### Pitfall 1: Ready-Detection String Is Agent-Specific and Brittle

**What goes wrong:**
The current `worker.rs` ready-detection uses `snap.contains("auto mode")` — a string present in Claude Code's welcome screen. When a new agent is added via a profile, the profile author forgets to test the ready-regex against a real headless terminal snapshot, uses a string that appears only transiently, or uses a substring present in the agent's *error* output as well as its idle state. The worker loop either loops indefinitely (false negative) or dispatches a turn before the agent is actually interactive (false positive), producing corrupted output or a wedged session.

**Why it happens:**
The generalisation feels obvious — just replace one hardcoded string with a configurable regex — but the test path for the regex is often omitted. Different agents render their idle states differently: Claude Code shows `auto mode` in a status bar, Codex CLI shows a Ratatui-rendered prompt area, OpenCode shows a completely different layout with no equivalent phrase. ANSI escape codes embedded in a raw terminal snapshot can split or interleave the expected substring, making a regex that works on a clean screenshot fail on a real PTY snapshot. Worse, Codex CLI has had several releases where raw ANSI sequences leaked into TUI output on startup (GitHub issue #23031 / #23740), so the same regex silently breaks after a version bump.

**How to avoid:**
- The agent profile TOML must store a `ready_pattern` field as a regex string, not a fixed substring.
- At profile load time, validate that the regex compiles.
- Add an integration-style smoke test for each profile that spawns the real binary, takes a snapshot, and asserts the pattern matches. Make this test gated behind a feature flag or Cargo feature so CI can skip it when the binary is unavailable.
- Log the raw snapshot text (trimmed) when `ready_pattern` fails to match within the deadline, so the operator sees exactly what the TUI is showing.
- Strip ANSI escape codes from snapshots before applying the regex, using a crate like `strip-ansi-escapes`, unless the profile explicitly opts into raw matching.

**Warning signs:**
- Session startup timeout fires regularly (`claude TUI が起動しない`) after switching to a new agent.
- Turns complete instantly with empty result files (agent received the dispatch trigger before finishing startup).
- ANSI strip: snapshot logs contain `\x1b[` sequences mixed with the expected text.

**Phase to address:** Agent Profile Mechanism phase (the phase that introduces `agents/*.toml` and profile-driven spawning). Test coverage must be established for each new profile before it is considered shipped.

---

### Pitfall 2: Per-Agent File-Write Convention Is Not Reliable for All Agents

**What goes wrong:**
HT-PROTOCOL relies on the worker (the LLM) following an explicit instruction: read `prompt-<turnId>.txt`, then write the result to `result-<turnId>.txt` via `.tmp`→rename, then write `status-<turnId>.json`. This works for Claude Code because its system prompt and CLAUDE.md conventions are well-established and the model has been trained on precise file-operation instructions. Codex CLI and OpenCode run different underlying models (GPT-4o / o3 variants, or whatever the user configures in OpenCode). These models:
1. May not reliably follow the atomic rename convention, writing directly to `result-<turnId>.txt` without the `.tmp` intermediate.
2. May write the status file *before* the result file, violating the ordering guarantee the Orchestrator relies on.
3. In complex tasks, may decide to write partial output and return control before the task is done (a `waiting_input` or ambiguous completion).
4. OpenCode with a local/weak model (via LM Studio integration) may silently ignore the file-writing instruction entirely and just print the answer to the TUI screen.

**Why it happens:**
The HT-PROTOCOL worker instructions assume a model that is both capable of following multi-step filesystem instructions and that has already been primed with a bootstrap message. Each new agent requires its own bootstrap prompt tuned for its model family. A generic "write to these files" instruction that works for Claude 3.7 may produce a different failure mode on o3-mini (token budget constraints) or a local Llama variant (instruction following gap).

**How to avoid:**
- The agent profile must include a `bootstrap_prompt` field — the exact text to send to the agent on first launch to prime it for HT-PROTOCOL compliance.
- Do not assume the bootstrap from Claude can be reused verbatim. Each model family needs empirical testing.
- Add a validation step in `turn.rs`: after the status sentinel appears, verify that `result-<turnId>.txt` also exists (when `status == "done"`). If the result file is missing, treat the turn as `failed` and log the raw snapshot so the operator can diagnose whether the model ignored the instruction.
- Document explicitly in the profile spec that models that cannot reliably follow file-write instructions are unsupported. Do not attempt to work around non-compliant models by screen-scraping the TUI output as a fallback — this reintroduces the exact length-limitation problem that HT-PROTOCOL was designed to eliminate.
- For Codex CLI specifically: it has a `codex exec` headless mode that outputs structured JSONL. This could be used as a separate (non-TUI) execution path for Codex, bypassing the file-write convention entirely. The agent profile TOML could include an `execution_mode` field (`tui` vs `exec`) to indicate which path to use.

**Warning signs:**
- `status-<turnId>.json` appears with `status: "done"` but `result-<turnId>.txt` is absent or empty.
- `status` file contains valid JSON but result content is "I have completed the task" with no actual output (the model wrote a summary to the status instead of writing to the result file).
- Turn latency is suspiciously short (under 2 seconds) for a non-trivial task — the model skipped the file write.

**Phase to address:** Codex CLI support phase and OpenCode support phase each need empirical bootstrap-prompt testing before merge. The `turn.rs` validation (result file existence check) should be added in the Agent Profile Mechanism phase, before any non-Claude agent is wired in.

---

### Pitfall 3: First-Run Onboarding and Trust Dialogs Block Automation

**What goes wrong:**
Codex CLI shows a full-screen Ratatui trust dialog on first launch in a new directory: "Do you trust the contents of this directory?" This is not suppressed by `--dangerously-bypass-approvals-and-sandbox` (`--yolo`) in all versions (GitHub issues #14345, #9695). Until this dialog is dismissed, the agent is not in its idle state, so the ready-pattern does not match, and the session startup times out. On a fresh host or a new `$HOME`, this happens on every first launch per directory.

OpenCode similarly asks for provider authentication if `~/.local/share/opencode/auth.json` does not exist or has expired. The authentication flow opens a browser (not viable headlessly) or requires `opencode auth login` to be run manually beforehand.

**Why it happens:**
These CLI tools are designed for interactive developer use. Their onboarding flows are reasonable UX for humans but are fundamentally incompatible with unattended headless automation. The existing Claude Code path avoids this because `~/.claude/.credentials.json` is assumed to exist (the constraint is documented: "auth context: the host's claude binary must already be logged in to Max"). Naively carrying the same assumption to other agents misses that each agent has its own credential path and its own first-run ceremony.

**How to avoid:**
- For Codex CLI: the agent profile should document the prerequisite: `codex login` (or setting `OPENAI_API_KEY` / `CODEX_ACCESS_TOKEN`) must be completed before launching ht-webif. The startup healthcheck should detect the "sign in" screen string and return an error immediately rather than timing out after 25 seconds.
- For Codex CLI directory trust: pre-trust the working directory by running `codex` once interactively, or configure `~/.codex/config.toml` with the directory in the trusted list. The profile README must state this requirement.
- For OpenCode: `opencode auth login` must complete for the chosen provider before starting ht-webif. The ready-pattern check should detect auth-prompt text and fail fast.
- Add a `prerequisite_check` field to the agent profile — a shell command that exits 0 only when auth is ready (e.g., `test -f ~/.codex/auth.json`). Run this check at webif startup before spawning the agent; emit a clear error if it fails.

**Warning signs:**
- Session startup timeout with a snapshot containing "sign in" or "Trust this directory?" text.
- Log shows `claude TUI が起動しない` within 5 seconds of launch (too fast for a real timeout, meaning the snapshot matched nothing useful).
- Runs succeed on the developer's machine but fail in CI or on a freshly provisioned host.

**Phase to address:** Each agent support phase (Codex CLI phase, OpenCode phase). The prerequisite-check mechanism belongs in the Agent Profile Mechanism phase.

---

### Pitfall 4: Mid-Turn Permission and Approval Dialogs Silently Wedge Turns

**What goes wrong:**
Codex CLI (in its default approval mode) shows a full-screen approval dialog mid-turn when the agent wants to execute a shell command, apply a file edit, or access the network. The orchestrator is polling `status-<turnId>.json`, which will never appear because the agent is paused waiting for human input. The turn hits `TURN_TIMEOUT` (300s), the retry logic fires, and the session is recreated — but the recreated session starts fresh, losing all progress. This can repeat indefinitely if every turn triggers the same approval.

The HT-PROTOCOL §10 already identifies "permission dialog" as a known error case for Claude Code, but the detection approach (snapshot + TUI scraping) is Claude-specific. Codex CLI's approval overlay looks entirely different from Claude Code's, and the snapshot text will not match any existing heuristic.

**Why it happens:**
The naive assumption is "just set `--yolo`/`--dangerously-bypass-approvals-and-sandbox`". But as noted in pitfall 3, `--yolo` does not fully suppress all prompts in all Codex CLI versions. Even when it does work, `--yolo` removes sandboxing, which changes the security posture of the deployment. The profile author must explicitly decide on an approval policy and document the tradeoff.

**How to avoid:**
- The agent profile TOML must include an `approval_mode` field. For Codex CLI, valid values map to its actual flags: `suggest` (default, will wedge), `auto-edit` (edits without approval), `full-auto` (commands without approval), `dangerously-bypass-approvals-and-sandbox`.
- For automation use cases, the recommended profile setting for Codex CLI is `full-auto`. Document this and its security implications in the profile file.
- The worker's approval-dialog detection logic must be agent-specific. Add a `wedge_pattern` regex field to the profile — if this pattern is found in a snapshot taken during the turn polling loop, treat it as a `waiting_input` state rather than silently waiting for the status file to appear.
- For OpenCode: it does not have an equivalent mid-turn approval system in the same way, but it does have tool permission prompts depending on provider and model. Investigate this empirically during the OpenCode phase.

**Warning signs:**
- Turns consistently time out at exactly 300s with no status file written.
- Snapshot taken at timeout shows a dialog or menu overlay rather than the normal editor/composer view.
- The same prompt that worked with `fresh:true` fails without it (suggests context accumulation triggers an approval).

**Phase to address:** Codex CLI support phase. The `wedge_pattern` mechanism should be designed in the Agent Profile Mechanism phase as a first-class field so it is available for all agents.

---

### Pitfall 5: Shared `turns/` Directory Collisions in Multi-Instance Operation

**What goes wrong:**
The current design allows multiple ht-webif instances to run in parallel by setting different `PORT` and `TURNS_DIR` env vars. If two instances are started with the same `TURNS_DIR` (e.g., both defaulting to `./turns/`), their turn files will share a namespace. The `turnId` format (`YYYYMMDD-HHMMSS-mmm`) provides millisecond precision but not instance identity. Two instances starting a turn in the same millisecond produce identically named files, and one will silently overwrite the other's `prompt-<turnId>.txt`. The status-file atomic rename means the second writer wins, but the first instance's orchestrator is polling for its turn's status file and will see the second instance's completion (or never see it if the second instance wrote to a different path).

**Why it happens:**
The env-var isolation story (`PORT` + `TURNS_DIR`) is clear in the documentation, but `TURNS_DIR` defaults to `./turns/` relative to the working directory. If an operator starts two instances from the same directory (common when testing multi-agent setups), they share the same `turns/` directory without realising it. The collision is rare in practice at low concurrency but becomes significant as the number of instances and turn rate increases.

**How to avoid:**
- Change the default `TURNS_DIR` to `./turns/<agent-name>/` so that even without explicit configuration, different agents (running from the same directory with `AGENT=claude`, `AGENT=codex`) get separate subdirectories.
- Add a startup check: if `TURNS_DIR` is the same as another running instance's turns directory (detectable via a lockfile or a PID file at `$TURNS_DIR/.webif.lock`), log a warning and optionally fail fast.
- In the HT-PROTOCOL §3.2, the parallel-worker extension (`-w<workerId>`) is designed for same-instance parallelism. For cross-instance parallelism, use `TURNS_DIR` isolation as the primary mechanism, not worker-ID suffixes. Document this explicitly.
- The orchestrator (caller) is responsible for knowing which `TURNS_DIR` corresponds to which instance. Do not attempt to unify turn namespaces across instances at the WebIF level.

**Warning signs:**
- `GET /turns/{turn_id}` returns a status file with a different agent's content (wrong `summary` field).
- Turns reported as completed contain results that do not match the prompt that was sent.
- `turns/` directory contains status files whose `turn_id` field does not match the filename.

**Phase to address:** Multi-instance parallel foundation phase. The default `TURNS_DIR` change should be included in the Agent Profile Mechanism phase if agent-name is available at startup.

---

### Pitfall 6: Agent Config and Credential File Races with Concurrent Instances

**What goes wrong:**
Codex CLI stores OAuth/session tokens in `~/.codex/auth.json` and rewrites this file when it refreshes tokens. If two Codex CLI instances run simultaneously (two ht-webif instances both using `AGENT=codex`), one instance's token refresh can overwrite the tokens just written by the other. Codex's own documentation explicitly warns: "do not share the same file across concurrent jobs." After the overwrite, one instance holds a stale/invalidated token and begins failing with authentication errors mid-session.

OpenCode stores credentials in `~/.local/share/opencode/auth.json` and has the same exposure when multiple instances run with the same provider credentials.

**Why it happens:**
Single-instance deployment makes this invisible during development. The problem only surfaces when an operator follows the "parallel instances for parallel agents" pattern without reading the per-agent credential-isolation requirements.

**How to avoid:**
- For Codex CLI: use the OS keyring credential store (`cli_auth_credentials_store: "keyring"` in `~/.codex/config.toml`) rather than the file-based store. The OS keyring handles concurrent access correctly.
- Alternatively: set `CODEX_HOME` to a per-instance directory (e.g., `~/.codex-instance-1/`, `~/.codex-instance-2/`). The agent profile can document this as a required env var when running multiple Codex instances.
- For OpenCode: investigate whether `XDG_DATA_HOME` isolation provides per-instance credential separation. Document the recommended isolation strategy in the OpenCode profile.
- Add a "parallel deployment" section to the project README that lists per-agent credential isolation requirements.

**Warning signs:**
- Authentication errors appear only when two Codex instances are running simultaneously, not when running one at a time.
- `~/.codex/auth.json` mtime updates more frequently than the token refresh interval for a single session.
- One instance begins returning 401/403 errors from OpenAI while the other continues working.

**Phase to address:** Multi-instance parallel foundation phase. Each agent support phase should document the credential-isolation requirement as part of the profile's operational notes.

---

### Pitfall 7: Session Clear/Reset Command Differences Break `fresh:true`

**What goes wrong:**
The current `fresh:true` implementation sends `/clear` to the Claude Code TUI before dispatching a prompt. This is hardcoded in the worker logic. (CORRECTED 2026-06-11: this section originally claimed Codex CLI lacks `/clear` — that was wrong; Codex CLI does support `/clear`/`/new` in-session, per user confirmation and official docs. The general pitfall stands for agents whose clear vocabulary differs.) OpenCode uses `/new` (with `/clear` as an alias as of the current version, but this has varied across releases), and a future agent may have no clear command at all — sending an unrecognized slash command as a literal prompt confuses the agent or corrupts the session instead of clearing it.

**Why it happens:**
The clear command is treated as a stable primitive, but it is actually agent-specific. Claude Code's `/clear` is one of its most-used commands and well-documented, but other agents have different vocabulary. The profile abstraction makes this seem solved by a `clear_command` field, but the subtlety is that some agents do not clear in-place — OpenCode's `/new` starts a *new session* (new session ID), which means the agent's internal session state changes and any context the worker holds about the session may be invalidated.

**How to avoid:**
- The agent profile TOML must include a `clear_command` field (e.g., `"/clear"` for Claude Code and Codex CLI, `"/new"` for OpenCode).
- For agents where "clear" creates a new session rather than clearing in the current one, the worker must re-run the ready-detection after issuing the clear command, because the session context changed. Model this as a mini-restart rather than a simple command dispatch.
- For agents that have no clear command (or where clearing is unsafe in headless mode), set `clear_command = ""` in the profile and document that `fresh:true` is unsupported for that agent.
- Test `fresh:true` explicitly in each agent's integration test.

**Warning signs:**
- With `fresh:true` and a non-Claude agent, the agent responds to `/clear` as if it were a prompt ("I don't know what /clear means").
- Session health check (`ensure_healthy`) fires unexpectedly after a `fresh:true` dispatch (session state changed due to `/new` creating a new session).
- Result files contain session-confusion artifacts (agent references prior turns that should have been cleared).

**Phase to address:** Agent Profile Mechanism phase (the `clear_command` field must be defined in the schema from the start). Each agent support phase must include an explicit `fresh:true` test.

---

### Pitfall 8: Timeout Values Calibrated for Claude Code Are Wrong for Other Agents

**What goes wrong:**
The current system has three timeout constants calibrated for Claude Code: `MCP_TIMEOUT = 30s` (per MCP call), `TURN_TIMEOUT = 300s` (per turn), and a 25-second session startup deadline. Codex CLI can legitimately run shell commands and multi-step agentic loops that take much longer than 300 seconds — the documentation notes it can stay on a task for "up to seven hours." If the profile does not override the turn timeout, Codex turns that involve non-trivial coding tasks will time out and retry (wasting a session recreate and a retry slot) when they were actually making progress.

Conversely, OpenCode with a slow local model (LM Studio + Llama) may be unable to complete any turn within 300 seconds for even simple prompts due to inference latency. Keeping the same timeout means long waits on failed turns for local-model users, but a shorter timeout means premature cancellation of turns that would have succeeded.

**Why it happens:**
Timeouts are typically set once for the "known good" agent and never revisited. The profile abstraction needs to carry timeout overrides, but it is easy to omit this from the schema and only discover the need during integration testing.

**How to avoid:**
- The agent profile TOML must include `turn_timeout_secs` and `session_startup_timeout_secs` fields with agent-specific defaults.
- Claude Code profile: `turn_timeout_secs = 300`, `session_startup_timeout_secs = 25` (preserving existing behaviour).
- Codex CLI profile: `turn_timeout_secs = 600` minimum; document that complex agentic tasks may require higher values and that callers can override via a future per-request timeout parameter.
- OpenCode profile: leave as empirical — document that the correct value depends on the configured provider and model.
- The `MCP_TIMEOUT` (30s per MCP call) is a transport-level constant, not a per-turn concern. It should remain global and not be per-profile, but document why it is intentionally separate.

**Warning signs:**
- Codex CLI turns time out at exactly 300s with a snapshot showing active tool execution in progress (the agent was working, not wedged).
- OpenCode turns with local models never complete within 300s even for trivial prompts.
- Retry-after-timeout creates a second session while the first was still running, resulting in two concurrent Codex CLI processes writing to overlapping files.

**Phase to address:** Agent Profile Mechanism phase (add timeout fields to the schema). Codex CLI support phase and OpenCode support phase (set and validate empirically correct defaults).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcode ready-detection string per agent in Rust code instead of profile TOML | Faster initial implementation | Every new agent requires a Rust change + recompile; defeats the "add agent without code change" goal | Never — this is the anti-goal of the milestone |
| Use `--yolo` unconditionally for Codex CLI without documenting security implications | Avoids the mid-turn approval dialog pitfall immediately | Operators assume no sandbox is always safe; becomes a security incident when WebIF is exposed beyond localhost | Only acceptable if the WebIF remains localhost-only AND the profile README documents this explicitly |
| Reuse Claude Code's bootstrap prompt for Codex CLI without empirical testing | Saves time writing a new prompt | Model instruction-following differences cause silent file-write failures; turns complete with empty results | Never — bootstrap prompts must be empirically validated per model family |
| Default `TURNS_DIR = ./turns/` for all agents | Zero configuration for single-agent use | Silent collisions when two instances share a directory; very hard to diagnose | Acceptable for single-agent single-instance; must be overridden for multi-agent parallel operation |
| Skip `turn.rs` result-file existence check after status sentinel | Simpler code | Missing result files return 200 OK with empty content; caller has no way to distinguish success from silent failure | Never — this check is required for protocol correctness |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Codex CLI authentication | Assuming `~/.codex/auth.json` exists because the developer ran Codex once | Add a prerequisite check (`codex whoami` or `test -f ~/.codex/auth.json`) to the profile and run it at webif startup |
| Codex CLI directory trust | Launching ht-webif from a new directory and hitting the trust dialog | Pre-trust the working directory by running `codex` once interactively, or document the trust-bypass config setting in the profile |
| OpenCode provider auth | Launching with `AGENT=opencode` before running `opencode auth login` | The profile README must list `opencode auth login <provider>` as a mandatory setup step |
| Codex CLI concurrent credentials | Running two Codex instances against the same `~/.codex/auth.json` | Use `CODEX_HOME` isolation per instance, or switch to the OS keyring credential store |
| OpenCode `/new` vs `/clear` | Using the OpenCode profile to send `/clear` (from the Claude profile) on `fresh:true` | Define `clear_command = "/new"` in the OpenCode profile; treat `/new` as a session-restart, re-run ready-detection after |
| Codex CLI `codex exec` vs TUI mode | Driving the interactive TUI when `codex exec` provides a cleaner headless interface | For Codex, consider whether `exec` mode (structured JSONL output) is a better match than the TUI path; add `execution_mode` to the profile schema |
| ht-mcp session count | Creating one ht-mcp session per agent instance and assuming all agents work the same | Each agent's session creation may have side effects (Codex directory trust, OpenCode session DB initialisation); test session lifecycle per agent |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Using snapshot polling to detect ready state for Codex CLI's Ratatui TUI | High CPU on the ht-mcp process; ready detection is flaky near version boundaries | Use a regex that matches a stable rendered text element, not a layout-dependent string; strip ANSI before matching | After any Codex CLI version bump that changes TUI layout |
| Polling `status-<turnId>.json` at 700ms intervals for agents with very long turn times | Unnecessary inotify/stat pressure when Codex CLI turns run for 10+ minutes | Increase poll interval proportionally to the expected turn duration; consider profile-configurable `poll_interval_ms` | Not a hard failure, but degrades to unnecessary noise on systems running many instances |
| Re-running full ready-detection after every `fresh:true` clear command | Adds 1–25 seconds of latency to every `fresh:true` call | Claude Code's `/clear` stays in the same session, so re-detection is unnecessary. Only re-detect for agents where clear creates a new session | Becomes a problem when `fresh:true` is used in high-frequency automation loops |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Using `--yolo` (disable sandbox + approvals) for Codex CLI in a profile without documenting the implications | An operator exposes the WebIF endpoint beyond localhost, believing the approval dialogs provide protection | Make `approval_mode` explicit in the profile; add a comment warning that `dangerously-bypass-approvals-and-sandbox` removes sandboxing; log a startup warning if this mode is active |
| Sharing `CODEX_HOME` (and therefore `auth.json`) across multiple instances | Token theft via TOCTOU: one instance reads a stale token after the other refreshed it | Use per-instance `CODEX_HOME` or OS keyring; document in operational notes |
| Storing `OPENAI_API_KEY` in the ht-webif `.env` file when the Codex profile uses API-key auth | Key exposure if `.env` is accidentally committed or if the WebIF process is compromised | `.env` is in `.gitignore` (already done); add a note that API keys for Codex should be in the OS environment or a separate secrets manager, not in the project `.env` |

---

## "Looks Done But Isn't" Checklist

- [ ] **Agent profile ready-pattern:** Profile has a `ready_pattern` field with a tested regex — verify by running `cargo test -- agent_profile` and checking the integration smoke test passes against a real binary snapshot.
- [ ] **Bootstrap prompt tested:** The profile's `bootstrap_prompt` has been sent to the real agent and the agent's response confirms it understood the HT-PROTOCOL file-write convention. Do not mark a profile as "supported" without this verification.
- [ ] **`fresh:true` works end-to-end:** A test turn with `fresh:true` completes successfully and a subsequent turn does not see context from the pre-clear session. Verify for each new agent profile.
- [ ] **`turns/` isolation:** When running two instances of ht-webif with different `AGENT` values, their turn files are in separate directories and do not collide. Verify by checking `TURNS_DIR` defaults include the agent name.
- [ ] **Credential prerequisites documented:** The profile README explicitly lists what must be done before launching ht-webif (e.g., `codex login`, `opencode auth login <provider>`). Verify by following the README on a freshly provisioned machine.
- [ ] **Timeout values empirically set:** The profile's `turn_timeout_secs` was determined by running a representative task (not just a trivial "hello world") and observing actual completion time. Not just copied from the Claude profile.
- [ ] **Mid-turn approval dialogs handled:** Either the profile's `approval_mode` prevents mid-turn dialogs, or `wedge_pattern` is defined and tested to detect them. Do not leave this as "untested assumption."

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Ready-detection regex never matches for new agent | MEDIUM | 1. Enable raw snapshot logging. 2. Run agent manually in a terminal and compare snapshot text. 3. Update `ready_pattern` in profile TOML. 4. Re-run smoke test. |
| Agent ignores file-write instruction (silent empty results) | HIGH | 1. Switch to `codex exec` mode for Codex CLI (bypasses TUI entirely). 2. For OpenCode: try a different model with stronger instruction following. 3. Revise `bootstrap_prompt` with explicit examples. |
| First-run trust dialog wedges startup | LOW | 1. Run agent interactively once in the working directory to dismiss the dialog. 2. For Codex CLI: check `~/.codex/config.toml` for a trusted directories setting. 3. Update prerequisite check in the profile. |
| `turns/` collision between instances | MEDIUM | 1. Stop both instances. 2. Delete or archive the shared `turns/` directory. 3. Set distinct `TURNS_DIR` values for each instance. 4. Restart. |
| Credential race / stale token mid-session | HIGH | 1. Stop all Codex instances. 2. Run `codex login` once to refresh the token. 3. Switch to `CODEX_HOME` isolation. 4. Restart instances one at a time. |
| Wrong timeout causes premature retry that spawns duplicate Codex processes | HIGH | 1. Run `ps aux | grep codex` to find and kill orphaned processes. 2. Increase `turn_timeout_secs` in the profile. 3. Add a pre-dispatch check that the previous session is not still running. |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Ready-detection regex is agent-specific and brittle | Agent Profile Mechanism | Integration smoke test per profile passes on CI with real binary; log shows ANSI-stripped snapshot on failure |
| File-write convention unreliable for non-Claude models | Agent Profile Mechanism (schema) + Codex/OpenCode phases (empirical) | Turn completes with non-empty `result-<turnId>.txt`; `turn.rs` existence check passes |
| First-run onboarding and trust dialogs | Codex CLI support phase + OpenCode support phase | Prerequisite check exits 0 on a fresh host; startup does not time out in a clean environment |
| Mid-turn approval dialogs wedge turns | Agent Profile Mechanism (wedge_pattern schema) + Codex CLI phase (value) | `fresh:true` + a file-edit turn completes without hitting TURN_TIMEOUT |
| Shared `turns/` directory collisions | Multi-instance parallel foundation phase | Two instances running simultaneously produce no file-name collisions over 100 turns |
| Credential file races | Multi-instance parallel foundation phase | Two Codex instances run for 30 minutes without authentication errors |
| Session clear command differences break `fresh:true` | Agent Profile Mechanism (clear_command schema) | `fresh:true` test passes per agent; second turn does not see context from first |
| Timeout values wrong for non-Claude agents | Agent Profile Mechanism (timeout fields schema) + per-agent phases | Codex CLI turn involving a 5-minute task completes without retry; OpenCode local-model turn completes within the configured timeout |

---

## Sources

- HT-PROTOCOL.md v1.1 (project internal)
- `.planning/PROJECT.md` (project internal — current milestone context)
- `src/worker.rs` (current ready-detection: `snap.contains("auto mode")`)
- [Codex CLI — Command line options](https://developers.openai.com/codex/cli/reference)
- [Codex CLI — Authentication](https://developers.openai.com/codex/auth)
- [Codex CLI — Maintain auth in CI/CD](https://developers.openai.com/codex/auth/ci-cd-auth)
- [Codex CLI — AGENTS.md custom instructions](https://developers.openai.com/codex/guides/agents-md)
- [Codex CLI — Non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [Codex CLI — Features](https://developers.openai.com/codex/cli/features)
- [Codex issue #14345: Directory trust not bypassed by --yolo](https://github.com/openai/codex/issues/14345)
- [Codex issue #9695: YOLO suppresses trust prompt but blocks .codex/skills](https://github.com/openai/codex/issues/9695)
- [Codex issue #23031: Raw ANSI sequences leak in TUI startup](https://github.com/openai/codex/issues/23031)
- [Codex issue #4775: Default timeout for shell commands](https://github.com/openai/codex/issues/4775)
- [Codex issue #2969: full-auto still prompts for approval](https://github.com/openai/codex/issues/2969)
- [OpenCode — TUI documentation](https://opencode.ai/docs/tui/)
- [OpenCode — Keybinds](https://opencode.ai/docs/keybinds/)
- [OpenCode — Providers](https://opencode.ai/docs/providers/)
- [OpenCode issue #19499: Add /clear slash command (similar to Claude Code)](https://github.com/anomalyco/opencode/issues/19499)
- [OpenCode issue #6119: TUI raw ANSI output and memory leak](https://github.com/sst/opencode/issues/6119)
- [OpenCode issue #5006: TUI renders truncated LLM response](https://github.com/anomalyco/opencode/issues/5006)
- [OpenCode keybinding issue #11983: input_newline shift+enter ignored](https://github.com/anomalyco/opencode/issues/11983)
- [tui-use: semantic ready-state detection for TUI apps](https://github.com/onesuper/tui-use)
- [GPT Frontier: preventing collisions with concurrent AI agents](https://www.gptfrontier.com/preventing-database-and-port-collisions-with-concurrent-ai-agents/)
- [Codex custom agent definitions TOML](https://codex.danielvaughan.com/2026/04/27/codex-cli-custom-agent-definitions-toml-specialised-subagents/)

---
*Pitfalls research for: ht-webif multi-agent TUI driving (Codex CLI / OpenCode)*
*Researched: 2026-06-11*
