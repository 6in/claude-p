# Phase 3 — Deferred Items

Out-of-scope discoveries logged during Phase 3 execution. Not fixed in their discovery plan; tracked here for future cleanup.

## From 03-06 (CI workflow)

### `cargo fmt --all -- --check` fails on existing source

**Discovered:** 2026-05-25 during 03-06 execution.

**Symptom:** Running `cargo fmt --all -- --check` from `webif/` returns exit code 1 with diffs in:
- `webif/src/http.rs` (lines 58, 99, 131, 182, 193)
- `webif/src/main.rs` (lines 30, 37)
- `webif/src/mcp.rs` (lines 62, 150, 375, 398, 410, 444, 460, 488, 497)
- `webif/src/turn.rs` (line 90)
- `webif/src/worker.rs` (lines 20, 57, 142)

**Scope:** Out of scope for 03-06. 03-06 only creates `.github/workflows/ci.yml`; pre-existing formatting drift in source files is from plans 03-01 / 03-02 / 03-03 / 03-04 (test-additions / generic-ization). All diffs are mechanical rustfmt rewraps (function arg wrapping, struct-init expansion, multi-line string call refactoring) — no semantic changes.

**Impact on CI green-state:** On first push to `main` after this plan lands, the `cargo fmt --check` step will fail RED. This is technically Phase 3 Success Criterion #4 working as designed (CI catches non-compliant code), but the desired state is "all four success criteria met simultaneously". A follow-up fix is needed:

```bash
cd webif && cargo fmt --all
git add webif/src/{http,main,mcp,turn,worker}.rs
git commit -m "style(webif): apply rustfmt to satisfy CI fmt --check"
```

**Recommendation:** Apply the above fix in a separate housekeeping commit (single-file scope: rustfmt-only) before merging Phase 3 to main, OR as part of the human-verify checkpoint follow-up when CI shows red on first push.

**Status:** Resolved 2026-05-25 in commit `7afa0ed` (`style(03): apply rustfmt across webif/src to satisfy CI fmt --check`) by the execute-phase orchestrator immediately after 03-06 completed. Post-fix: `cargo fmt --check` clean, `cargo clippy --all-targets --release -- -D warnings` 0 warnings, `cargo test --release` 11 passed.
