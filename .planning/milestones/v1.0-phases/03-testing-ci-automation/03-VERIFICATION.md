---
phase: 03-testing-ci-automation
verified: 2026-05-25T00:00:00Z
status: human_needed
score: 4/4 ROADMAP Success Criteria verified (28/28 must-haves verified across 6 plans)
overrides_applied: 0
---

# Phase 3: Testing & CI Automation — Verification Report

**Phase Goal:** モジュール分割後のコードに最小限のテストを載せ、`justfile` と GitHub Actions で `fmt`・`clippy`・`test` を自動化する。以後の変更で回帰が検知できる状態を作る
**Verified:** 2026-05-25
**Status:** human_needed (all automated checks pass; CI red/green behavior on push/PR requires GitHub-side verification)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | `cargo test` で純粋関数 + MCP JSON-RPC 単体テストが green | VERIFIED | Live probe `cargo test --release` from `webif/`: `11 passed; 0 failed`. Breakdown: `turn::tests::*` 5 (build_prompt_body, turn_id_formatter, read_turn_done/garbled/missing-result), `mcp::tests::*` 3 (next_id, request_envelope, result_extract). Matches plan claim 5+3=8 pure/MCP tests. |
| SC-2 | HTTP 統合テストで `/turns/{id}` パストラバーサル拒否 (`../` 形式 + 不正文字) と happy path を検証 | VERIFIED | Live probe shows 3 http::tests pass: `turn_handler_rejects_path_traversal_via_percent_encoded_slash` (covers `../` via `..%2F`), `turn_handler_rejects_ascii_letters_in_turn_id` (covers 不正文字), `turn_handler_returns_done_when_status_file_exists` (happy path). Code at `webif/src/http.rs:220-315`. FakeMcp stub used; no real `ht-mcp`. |
| SC-3 | リポジトリ直下に `justfile` + 6 サブコマンド (`build`/`run`/`test`/`fmt`/`clippy`/`clean`) | VERIFIED | `justfile` exists at repo root. `grep -E "^[a-z]+:"` returns exactly 6 recipes matching spec. `set working-directory := 'webif'` scopes each cargo call to `webif/`. |
| SC-4 | `.github/workflows/ci.yml` が push/PR トリガで `fmt --check` / `clippy -D warnings` / `test` を実行し、失敗で CI 赤 | VERIFIED (artifact) / human_needed (red/green behavior on GitHub) | `.github/workflows/ci.yml` exists. Triggers `push:branches:[main]` + `pull_request:branches:[main]`. Single `check` job on `ubuntu-latest` with `defaults.run.working-directory: webif`. Steps execute in order: `cargo fmt --all -- --check` → `cargo clippy --all-targets --release -- -D warnings` → `cargo test --release`. Uses `actions-rust-lang/setup-rust-toolchain@v1` (stable, rustfmt+clippy components) and `Swatinem/rust-cache@v2` (workspaces: `webif -> webif/target`). No `just` invocation (single `justfile` reference is in a comment line 3). |

### Cross-cutting Constraint

| Check | Status | Evidence |
|-------|--------|----------|
| `cargo build --release` warning 0 / error 0 | VERIFIED | Live probe: `Finished release profile [optimized] target(s) in 2.43s`. No warnings emitted. |
| `cargo clippy --all-targets --release -- -D warnings` warning 0 / error 0 | VERIFIED | Live probe: `Finished release profile` with exit 0. No warnings emitted. |
| `cargo fmt --all -- --check` (pre-CI sanity) | VERIFIED | Live probe exit 0 (housekeeping commit `7afa0ed` resolved drift from 03-01..03-04). |

**Score:** 4/4 ROADMAP Success Criteria fully verified in code + automated probes. SC-4 has a residual human-verification component (does CI actually go red on GitHub when a step fails?) — see Human Verification section below.

### Required Artifacts (across 6 plans)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `webif/Cargo.toml` | async-trait dep + [dev-dependencies] (tower util, tempfile) | VERIFIED | `async-trait = "0.1"` (line 21), `tower = { version = "0.5", features = ["util"] }` (line 25), `tempfile = "3"` (line 27). |
| `webif/src/mcp.rs` | trait Mcp + McpClient impl + #[cfg(test)] from_streams + FakeMcp + 3 MCP tests | VERIFIED | `pub trait Mcp` (line 20), `impl Mcp for McpClient` (line 176), `pub fn from_streams` under `#[cfg(test)]` (line 86, initial `next_id: 0` line 95). `pub(crate) struct FakeMcp` (line 264) with `impl Mcp` (line 295) and `impl Restartable` (line 342). 3 hermetic tests at lines 373-520. |
| `webif/src/worker.rs` | Worker<M: Mcp = McpClient> generic + Restartable-bound restart | VERIFIED | `pub struct Worker<M: Mcp = McpClient>` (line 12). Generic `impl<M: Mcp + Send> Worker<M>` (line 57). `#[cfg(test)] pub(crate) fn from_parts` (line 63). `impl<M: Mcp + Restartable + Send> Worker<M>::restart` (line 134-158). |
| `webif/src/turn.rs` | 5 pure-function tests in co-located #[cfg(test)] mod tests | VERIFIED | `mod tests` at line 117-208. 5 tests: `build_prompt_body_includes_task_and_paths`, `turn_id_formatter_matches_expected_shape`, `read_turn_returns_done_when_status_complete`, `read_turn_marks_unknown_when_status_garbled`, `read_turn_returns_empty_result_when_result_file_missing`. All green in live probe. |
| `webif/src/http.rs` | AppState<M> + ジェネリック化された 4 handlers + build_router<M> + 3 integration tests | VERIFIED | `pub struct AppState<M: Mcp + Send + 'static = McpClient>` (line 22). `pub fn build_router<M: Mcp + Restartable + Send + 'static>` (line 170). Tests at lines 180-316 use `tower::ServiceExt::oneshot`, `FakeMcp`, `tempdir`. |
| `webif/src/main.rs` | wiring-only (defaults to Worker<McpClient> via type inference) | VERIFIED | 52 lines, calls `Worker::new(ht_mcp_path)` (line 19) — type inferred as `Worker<McpClient>` from default. |
| `webif/src/lib.rs` | pub mod for all submodules | VERIFIED | `pub mod config; pub mod http; pub mod mcp; pub mod turn; pub mod worker;` (lines 19-23). |
| `justfile` | 6 recipes scoped to webif/ | VERIFIED | Exactly 6 recipes (build, run, test, fmt, clippy, clean); `set working-directory := 'webif'` on line 5. |
| `.github/workflows/ci.yml` | push+PR triggered single check job | VERIFIED | Single `check` job on `ubuntu-latest` with all required actions + steps. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `webif/src/worker.rs` | `webif/src/mcp.rs` | `use crate::mcp::{Mcp, McpClient, Restartable}` | WIRED | Line 7. |
| `webif/src/http.rs` | `webif/src/worker.rs` | `Worker<M>` in `AppState<M>` | WIRED | Line 23: `pub worker: Arc<Mutex<Worker<M>>>`. |
| `webif/src/main.rs` | `webif/src/worker.rs` | `Worker::new` default-typed | WIRED | Line 19: `let worker = Worker::new(ht_mcp_path).await?;` returns `Worker<McpClient>` via default type. |
| `webif/src/turn.rs` (mod tests) | `build_prompt_body`, `read_turn` | `use super::*` | WIRED | Line 119. |
| `webif/src/mcp.rs` (mod tests) | `McpClient::request`, `from_streams`, `Mcp`, `Restartable` | `use super::*` + `tokio::io::duplex` | WIRED | Line 253-255. `tokio::io::duplex(1024)` used in `make_client_and_harness` line 365-367. |
| `webif/src/http.rs` (mod tests) | `build_router`, `AppState`, `crate::mcp::tests::FakeMcp` | `use tower::ServiceExt; use crate::mcp::tests::FakeMcp` | WIRED | Lines 182-188. `app.oneshot(Request::builder()...)` used in all 3 tests. |
| `justfile` | `webif/Cargo.toml` | `set working-directory := 'webif'` | WIRED | Line 5; each recipe invokes `cargo <subcmd>` against `webif/`. |
| `.github/workflows/ci.yml` | `webif/` (cargo project root) | `defaults.run.working-directory: webif` | WIRED | Line 18. No `cd webif` needed in each step. |

### Behavioral Spot-Checks (live probes)

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Pure-function + MCP + HTTP tests pass under release profile | `cd webif && cargo test --release` | `11 passed; 0 failed; 0 ignored` | PASS |
| Clippy clean on all targets, release profile | `cd webif && cargo clippy --all-targets --release -- -D warnings` | exit 0, no warnings | PASS |
| Release build produces no warnings | `cd webif && cargo build --release` | `Finished release profile in 2.43s`, no warnings | PASS |
| fmt-check clean (matches CI fmt step) | `cd webif && cargo fmt --all -- --check` | exit 0 | PASS |
| Justfile has exactly 6 recipes | `grep -E "^[a-z]+:" justfile \| wc -l` | 6 | PASS |
| CI does not invoke `just` | `grep -n "just" .github/workflows/ci.yml` | Only 1 match — comment line 3 | PASS |

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|----------------|-------------|--------|----------|
| TEST-01 | 03-01, 03-02 | 純粋関数の単体テスト | SATISFIED | 5 tests in `webif/src/turn.rs` cover build_prompt_body, turn_id formatter, read_turn (3 branches). All green in live probe. |
| TEST-02 | 03-01, 03-03 | MCP クライアントの JSON-RPC 単体テスト | SATISFIED | 3 hermetic tests in `webif/src/mcp.rs` using `tokio::io::duplex` + `from_streams`: envelope, next_id, result extraction. All green. |
| TEST-03 | 03-01, 03-04 | HTTP ハンドラ統合テスト (FakeMcp stub) | SATISFIED | 3 tests in `webif/src/http.rs` cover percent-encoded `../`, ASCII-letter rejection, happy path. Uses `tower::ServiceExt::oneshot` + `FakeMcp` + `tempdir`. All green. |
| TOOL-01 | 03-05 | `justfile` で開発コマンド集約 | SATISFIED | 6 recipes (build/run/test/fmt/clippy/clean) at repo root, scoped to webif/. |
| TOOL-02 | 03-06 | GitHub Actions で fmt/clippy/test 自動化 | SATISFIED | `.github/workflows/ci.yml` defines single `check` job with all 3 steps in the documented order. |

All 5 requirement IDs declared in plan frontmatter are covered. No orphaned requirements: REQUIREMENTS.md maps exactly TEST-01/02/03 + TOOL-01/02 to Phase 3, and every ID appears in at least one plan.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | — | TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER scan across modified files | — | Clean — no debt markers introduced by Phase 3. |
| `webif/src/mcp.rs` | 46 | `#[allow(dead_code)]` on `McpClient::child` | INFO | Pre-existing (Phase 2). Justified by Drop/kill_on_drop semantics — field held only for ownership; review report WR-noted as acceptable. |
| `webif/src/mcp.rs` | 263, 281 | `#[allow(dead_code)]` on FakeMcp struct/ctor | INFO | Intentional. Some FakeMcp fields are pre-built for the scripted-reply pattern but not all tests use them yet. Review report confirms acceptable. |

The standalone code review (`03-REVIEW.md`) found 0 critical, 5 warning (W1-W5: latent restart partial-failure window, justfile version requirement, `recreate` polling-loop dup, etc.), 4 info. None of the warnings block this phase's goal — they are advisory improvement items for future maintenance.

### Probe Execution

No project-specific `scripts/*/tests/probe-*.sh` exist. The probe-equivalent for this Rust phase is `cargo test --release` + `cargo clippy --all-targets --release -- -D warnings` + `cargo fmt --all -- --check`, all of which passed live (see Behavioral Spot-Checks).

### Human Verification Required

The only outstanding item is whether CI actually surfaces red on GitHub when one of the three steps fails. This cannot be verified locally without pushing intentionally-broken code to a GitHub branch.

#### 1. CI red/green behavior on GitHub

**Test:** After this phase merges to `main`, push a branch with a deliberately mis-formatted file (or a clippy violation, or a failing test) and open a PR.
**Expected:** The `check` job on the PR turns red, blocking merge. After reverting the change, the job turns green.
**Why human:** Requires GitHub Actions runtime; cannot simulate from local probes. The workflow file structure has been verified to be correct, but actual runner behavior depends on GitHub-side execution.

### Gaps Summary

No gaps. Every must-have across all 6 plans is implemented and verified by live probes. The phase goal — "テストとオートメーションで以後の変更の回帰を検知できる状態" — is achieved:

- 11 tests green under release profile (matches CI `cargo test --release` step).
- Clippy clean with `-D warnings` (matches CI clippy step).
- Build clean with no warnings (cross-cutting constraint).
- fmt-check clean (matches CI fmt step, after housekeeping commit `7afa0ed`).
- `justfile` provides local 1:1 mirrors of the cargo commands CI uses.
- CI workflow file structurally matches the success criterion #4 contract.

The remaining `human_needed` flag is purely to confirm GitHub Actions runtime behavior on push/PR — a runtime-only check that cannot be executed from the verifier process.

---

_Verified: 2026-05-25_
_Verifier: Claude (gsd-verifier)_
