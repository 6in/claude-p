---
phase: 260527-lb8-add-cors-support
plan: "01"
subsystem: http
tags: [cors, tower-http, axum, security]
dependency_graph:
  requires: []
  provides: [CORS-01]
  affects: [webif/src/http.rs, webif/src/config.rs, webif/src/main.rs]
tech_stack:
  added: [tower-http 0.6 (cors feature)]
  patterns: [CorsLayer on axum Router via .layer(), env-driven origin whitelist]
key_files:
  created: []
  modified:
    - webif/Cargo.toml
    - webif/Cargo.lock
    - webif/src/config.rs
    - webif/src/http.rs
    - webif/src/main.rs
    - webif/.env.example
    - webif/README.md
decisions:
  - build_router takes cors_origins as second argument rather than storing in AppState (startup-time config, not per-request state)
  - allow_credentials intentionally omitted (no cookies/auth, and "*" + credentials is disallowed by CORS spec)
  - tower-http 0.6 added to [dependencies] only, not [dev-dependencies]
metrics:
  duration: ~8 minutes
  completed: 2026-05-27
  tasks_completed: 2
  tasks_total: 2
---

# Phase 260527-lb8 Plan 01: Add CORS Support Summary

**One-liner:** CORS support via tower-http CorsLayer with `CORS_ORIGINS` env var override; default full-permissive `*`.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | tower-http 導入 + load_cors_origins + CorsLayer 配線 + 新規テスト | c59b41b | Cargo.toml, Cargo.lock, src/config.rs, src/http.rs, src/main.rs |
| 2 | .env.example と README.md に CORS 設定の使い方を追記 | e5095fd | .env.example, README.md |

## What Was Built

- `tower-http = { version = "0.6", features = ["cors"] }` added to `[dependencies]` in `Cargo.toml`
- `load_cors_origins() -> Vec<String>` added to `src/config.rs`: reads `CORS_ORIGINS` env var (comma-split, trim, filter-empty), falls back to `vec!["*"]`
- `build_router` signature extended to `build_router(state, cors_origins: Vec<String>) -> Router`: builds `CorsLayer` with `Any` wildcard when `*` present, explicit `HeaderValue` list otherwise; layers before `.with_state(state)`
- `src/main.rs` updated: imports `load_cors_origins`, logs `CORS 許可オリジン: [...]`, passes result to `build_router`
- 2 new inline CORS tests added:
  - `cors_preflight_allows_any_origin_under_default_config`: OPTIONS preflight returns 2xx + `access-control-allow-origin`
  - `cors_actual_request_includes_allow_origin_header`: GET with Origin header on 400 path still gets CORS header
- `.env.example` updated with commented `CORS_ORIGINS` entry (opt-in tightening style)
- `README.md` updated: `CORS_ORIGINS` row in env table, new `## CORS` section before `## API`

## Test Results

```
running 13 tests
test http::tests::cors_preflight_allows_any_origin_under_default_config ... ok
test http::tests::cors_actual_request_includes_allow_origin_header ... ok
test http::tests::turn_handler_rejects_ascii_letters_in_turn_id ... ok
test http::tests::turn_handler_rejects_path_traversal_via_percent_encoded_slash ... ok
test http::tests::turn_handler_returns_done_when_status_file_exists ... ok
test mcp::tests::* ... ok (5 tests)
test turn::tests::* ... ok (5 tests)

test result: ok. 13 passed; 0 failed
```

## Decisions Made

1. **build_router second-argument approach**: CORS origins passed as `cors_origins: Vec<String>` rather than stored in `AppState`. Rationale: CORS is startup-time config baked into the Router once, not per-request runtime state; AppState is for request-scoped shared state. Avoids touching all 11 existing test helpers.

2. **`allow_credentials` intentionally absent**: The API has no cookies or auth headers. CORS spec prohibits `allow_origin(Any)` + `allow_credentials(true)` simultaneously (browsers reject it). Documented in both code and README.

3. **tower-http in `[dependencies]` only**: The `CorsLayer` is used in production `build_router`, not test-only code, so `[dev-dependencies]` placement would be incorrect.

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None.

## Threat Flags

None — CORS is a browser-side mechanism that relaxes the same-origin policy. The API already binds to `127.0.0.1:8080` (loopback only), so adding `CorsLayer` does not expose new network surface to non-browser clients. No new endpoints, auth paths, or schema changes introduced.

## Self-Check: PASSED

- `webif/src/http.rs` contains `use tower_http::cors::{Any, CorsLayer};` (line 17) and `.layer(cors)` (line 199)
- `webif/src/config.rs` contains `pub fn load_cors_origins` (line 45)
- `webif/src/main.rs` calls `build_router(state, cors_origins)` (line 40)
- Commit `c59b41b` verified via `git log -1 --oneline`
- Commit `e5095fd` verified via `git log -1 --oneline`
- All 13 tests green (11 existing + 2 new)
- `cargo build --release` produces `target/release/ht-webif`
