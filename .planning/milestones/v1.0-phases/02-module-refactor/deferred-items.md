# Deferred Items — Phase 02 (Module Refactor)

Discoveries during phase execution that are out of scope for the current plan and deferred for follow-up.

## From Plan 02-01 execution (2026-05-25)

### D-02-01: `clippy::trim_split_whitespace` lint in `main.rs:163-164`

- **Found in:** `webif/src/main.rs:160-166` (function reading session ID from MCP response)
- **Lint:** `clippy::trim_split_whitespace` (rust-clippy 1.95.0+) — `str::trim` before `str::split_whitespace` is redundant because `split_whitespace` already trims leading/trailing whitespace
- **Code:**
  ```rust
  Ok(after
      .trim()
      .split_whitespace()
      .next()
      ...
  ```
- **Suggested fix:** Remove `.trim()` — `split_whitespace` handles it. The behaviour is identical.
- **Status:** Pre-existing (introduced in baseline commit `5439df5f` before Phase 2). NOT caused by Plan 02-01 (which only added `[lib]`/`[[bin]]` declarations and 6 placeholder files; `main.rs` is byte-identical, verified via `git diff`).
- **Why deferred:** Plan 02-01's `must_haves.truths` explicitly require `main.rs` to be "1バイトも変更しない". The clippy lint can be fixed in Plan 02-02 when `McpClient` is moved to `webif/src/mcp.rs` — at that point the code being relocated is already being edited, so the fix is in-scope and incurs zero extra risk.
- **Impact:** `cargo build --release` is clean (0 warnings / 0 errors — primary gate passes). Only `cargo clippy --all-targets --release -- -D warnings` fails. Runtime behaviour is unaffected.
- **Owner:** Plan 02-02 (Cargo.toml の修正と McpClient 移送) — when moving the MCP client to `mcp.rs`, drop `.trim()` from the chain at the same time.
