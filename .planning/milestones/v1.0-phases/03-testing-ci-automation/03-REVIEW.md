---
phase: 03-testing-ci-automation
reviewed: 2026-05-25T14:09:08Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - .github/workflows/ci.yml
  - justfile
  - webif/Cargo.toml
  - webif/Cargo.lock
  - webif/src/http.rs
  - webif/src/main.rs
  - webif/src/mcp.rs
  - webif/src/turn.rs
  - webif/src/worker.rs
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-05-25T14:09:08Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Phase 3 introduces a clean test scaffold: a `trait Mcp` + `trait Restartable` separation, generic `Worker<M>` / `AppState<M>` / `build_router<M>`, an in-memory `McpClient::from_streams` constructor, a `FakeMcp` scripted test double, and 11 unit / integration tests that all pass under `cargo test --release` (verified locally). `cargo fmt --check`, `cargo clippy --all-targets --release -- -D warnings`, and `cargo clippy --all-targets -- -D warnings` (debug) are all clean. The two `#[allow(dead_code)]` annotations (`McpClient.child`, `FakeMcp` struct/ctor) are justified — `child` is held only for `Drop`/`kill_on_drop` semantics, and `FakeMcp` fields are populated by tests that don't all exist yet but are intentionally pre-built for the scripted-reply pattern.

Test-time visibility is well contained: `from_streams` and `from_parts` are `#[cfg(test)] pub(crate)`; `tests` modules are `#[cfg(test)] pub(crate)` only where cross-module reuse is needed (mcp::tests::FakeMcp by http::tests). No production-visible API was widened beyond what the trait extraction itself required.

That said, the worker refactor introduced a substantive logic re-arrangement (Restartable::respawn replaces an inlined kill/spawn) and inlined a 25-second "wait for auto mode" polling loop in three places. The polling duplication, a latent state-corruption window in `Worker::restart`, and several CI / justfile portability gaps warrant fixes before this scaffold is locked in for downstream phases.

No security regressions found. Path-traversal guard is unchanged in behavior and now has regression coverage. No new injection sinks. No hardcoded credentials.

---

## Warnings

### WR-01: `Worker::restart()` partial-failure window leaves `session_id` pointing at a dead ht-mcp process

**File:** `webif/src/worker.rs:137-158`
**Issue:** If `self.client.respawn(&self.ht_mcp_path).await?` succeeds (old ht-mcp is killed, new one is spawned + handshaked) but the next line `self.client.create_claude_session().await?` fails, control returns `Err` from `restart()` while `self.session_id` still holds the *old* session id. That id refers to a session in the ht-mcp process that was just killed by `respawn()`. Any subsequent call against this Worker (e.g. `submit_line`, `snapshot`) will be issued against the new ht-mcp using the stale session id and will fail in a confusing way (the session does not exist in the fresh ht-mcp). The pre-Phase-3 `restart` had the same flaw (it built a fresh `(client, session_id)` via `boot` and only then assigned; if `boot` failed before returning the tuple, state was preserved — but if `boot` returned `Err` *after* the old `ht-mcp` was killed, state was corrupted in the same way). The refactor preserves the flaw and makes it slightly more reachable because `respawn` now commits the transport swap (`*self = new`) before `create_claude_session` runs.
**Fix:** Either (a) clear `self.session_id` to an empty `String` immediately after a successful `respawn` so callers can detect the unhealthy state via `ensure_healthy`, or (b) defer commit of `self.session_id` to the very end and have `ensure_healthy` not trust `session_id` after a failed restart. Concrete (a):
```rust
pub async fn restart(&mut self) -> Result<()> {
    self.client.respawn(&self.ht_mcp_path).await?;
    // ht-mcp は再生成済み。旧 session_id は失効しているので一旦クリア。
    self.session_id.clear();
    let new_id = self.client.create_claude_session().await?;
    // ... ready 待ち ...
    self.session_id = new_id;
    Ok(())
}
```
This way, if `create_claude_session` errors, the empty `session_id` will fail `ensure_healthy`'s snapshot check on the next request and trigger `recreate`.

---

### WR-02: `justfile` `set working-directory := 'webif'` requires `just` >= 1.33 with no version guard

**File:** `justfile:5`
**Issue:** The `set working-directory := '...'` directive was added in `just` v1.33.0 (released 2024-06). On older versions, `just` errors out with `error: Unknown setting 'working-directory'`. The justfile has no `set unstable` line, no version-required comment, and no `.justfile` companion that documents this requirement. A developer on Ubuntu 22.04 (`just` 0.10) or Debian stable (`just` 1.5) will see an opaque error. Worse, the project's CI does not run `just`, so the regression would only surface in developer machines.
**Fix:** Add a version-required comment at the top and consider a fallback recipe header that fails fast with a helpful message:
```just
# justfile — ht-webif 開発ショートカット
# 要 just >= 1.33（`set working-directory` 使用のため）
# CI からは justfile を呼ばない（cargo 直接呼び出し、D-23）

set working-directory := 'webif'
```
Optionally, add a `_check-just-version` helper that runs `just --version` and fails loudly if too old.

---

### WR-03: CI workflow does not pin action SHAs and could be vulnerable to upstream tag re-pointing

**File:** `.github/workflows/ci.yml:20, 23, 29`
**Issue:** All three third-party actions are pinned to major-version tags (`actions/checkout@v4`, `actions-rust-lang/setup-rust-toolchain@v1`, `Swatinem/rust-cache@v2`). Maintainers can re-point these tags to new commits at any time, and a compromise of those repos would silently execute arbitrary code with `GITHUB_TOKEN` write scope inside this CI. For a small OSS project this is a common accepted risk, but the project security posture (`HT-PROTOCOL` paths, Max-billed Claude credentials on the same host as ht-webif) makes tag-pinning weaker than ideal.
**Fix:** Pin to full commit SHAs and add a renovation comment, e.g.:
```yaml
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
- uses: actions-rust-lang/setup-rust-toolchain@9399c7bb15d4c7d47b27263d024f0a4978346ba4  # v1.10.0
- uses: Swatinem/rust-cache@23bce251a8cd2ffc3c1075eaa2d8fe07b8b6f1d3   # v2.7.3
```
If pinning to SHA is not acceptable, at minimum constrain `permissions:` at the workflow level (currently inherited as `contents: read` from defaults, which is fine, but make it explicit).

---

### WR-04: CI `cargo test --release` skips `debug_assert!` macros and disables overflow checks

**File:** `.github/workflows/ci.yml:40`, `justfile:17`
**Issue:** `cargo test --release` runs tests under the release profile, which by default sets `debug-assertions = false` and `overflow-checks = false`. The codebase does not currently use `debug_assert!` or rely on overflow panics, so no immediate bug, but this is a CI policy that will silently mask future correctness invariants expressed via `debug_assert!`. It also means tests cannot exercise overflow-panic branches. The justfile comment ("CI と揃える") shows this is intentional, but the trade-off is not documented anywhere reviewers can see (no `03-PATTERNS.md` rationale at the time of review beyond "match CI", which is circular).
**Fix:** Either add `[profile.release] debug-assertions = true overflow-checks = true` to `webif/Cargo.toml` so the release profile retains debug semantics for testing, or split CI into two steps (`cargo test` for correctness, `cargo test --release` for "release path also compiles"). Minimum acceptable: a comment in CI and/or PATTERNS explaining the explicit choice.

---

### WR-05: `prompt_handler` writes the prompt file before enqueuing the job — failure-mode produces an orphan that GET reports as `running` forever

**File:** `webif/src/http.rs:56-66`
**Issue:** The handler writes `prompt-<turn_id>.txt` (line 56) *before* `state.job_tx.send(...)` (line 59-66). If `job_tx.send` fails (channel closed), the handler returns 500 to the caller, but the prompt file is already on disk. `turn_handler` (line 102) returns `{"status":"running"}` whenever `prompt_path.exists() && !status_path.exists()`. With no worker to ever produce a status file, `GET /turns/{id}` will permanently report `running` for an orphaned turn. This is pre-existing behavior (not introduced by Phase 3), but Phase 3's HTTP tests now exercise `turn_handler` extensively and would have been the natural place to add a regression check.
**Fix:** Either (a) swap the order — enqueue first, then write prompt file inside `worker_loop` before the trigger is sent (this changes the contract: GET would briefly return 404 between enqueue and prompt write); or (b) clean up the orphan prompt file on send failure:
```rust
state.job_tx.send(Job { turn_id: turn_id.clone(), fresh: req.fresh })
    .await
    .map_err(|_| {
        // ベストエフォートで prompt ファイルを掃除
        let _ = std::fs::remove_file(&prompt_path);
        ise("ジョブキューが閉じています")
    })?;
```
Option (b) is the minimum acceptable fix.

---

## Info

### IN-01: 25-second "wait for `auto mode`" polling loop is duplicated in three places

**File:** `webif/src/worker.rs:42-53, 103-114, 141-151`
**Issue:** The same `loop { snapshot; if "auto mode" return; if deadline break; sleep 700ms }` pattern appears in `spawn_session`, `recreate`, and `restart`. The Phase 3 refactor noted this in the "設計メモ" comment at line 127 but did not extract a helper. Three copies means three places to update if the readiness probe ever changes (e.g. claude TUI renames the marker, or the polling cadence needs tuning).
**Fix:** Extract a private helper such as `async fn wait_until_ready<M: Mcp>(client: &mut M, session_id: &str) -> Result<()>` that contains the loop. Call it from all three sites. Suggested location: free function in `worker.rs` so all impl blocks can call it.

---

### IN-02: Magic string `"auto mode"` appears in four call sites with no constant

**File:** `webif/src/worker.rs:45, 87, 107, 144`
**Issue:** The `claude` TUI readiness sentinel is the substring `"auto mode"`. It appears in `spawn_session`, `ensure_healthy`, `recreate`, and `restart`. If the upstream claude TUI changes its banner text, this codebase will silently report sessions as unhealthy and trigger infinite recreation. There is no test of `ensure_healthy`'s readiness logic against the sentinel.
**Fix:** Extract a `const CLAUDE_READY_MARKER: &str = "auto mode";` in `webif/src/worker.rs` (or `config.rs`) and reference it from all four sites. Optionally add a unit test that exercises `FakeMcp` returning snapshots with and without the marker through `Worker::ensure_healthy`.

---

### IN-03: Public `AppState<M: Mcp + Send + 'static = McpClient>` exposes generic to API consumers

**File:** `webif/src/http.rs:22`
**Issue:** `AppState` is `pub` with a default type parameter. This is the documented design (D-03 in the phase plan), but the default-parameter form is non-obvious to consumers and shows up in rustdoc as a generic struct rather than a simple type. The library has no `pub` re-export aliasing it to a non-generic form. For consumers writing `Arc::new(AppState { ... })` outside this crate, type inference will pick `McpClient` from context, but anyone wanting a concrete name has to write `AppState<McpClient>`.
**Fix:** Add a `pub type AppStateDefault = AppState<McpClient>;` alias next to the struct definition, or add a doc-comment explaining the generic parameter and default. Low priority — the consumer surface is currently just `main.rs`.

---

### IN-04: CI workflow does not run a documentation/`rustdoc` lint pass

**File:** `.github/workflows/ci.yml`
**Issue:** Phase 3 added several `pub trait`s with `///` doc comments referencing other items (`Mcp`, `Restartable`, `Worker<M>`, etc.). Broken intra-doc links (e.g. `[Mcp::handshake]` if a name is renamed) won't be caught by `cargo clippy` or `cargo test`. `RUSTDOCFLAGS="-D warnings" cargo doc --no-deps` would catch them. Per phase-context, this is out of scope (the phase explicitly lists only fmt/clippy/test), but worth a future ticket.
**Fix:** Optionally add a fourth CI step:
```yaml
- name: cargo doc (lint)
  env:
    RUSTDOCFLAGS: "-D warnings"
  run: cargo doc --no-deps --document-private-items
```

---

_Reviewed: 2026-05-25T14:09:08Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
