---
phase: 260528-iav
plan: 01
subsystem: docs
tags: [documentation, claude-md, refactor]
key_files:
  created:
    - webif/docs/STACK.md
    - webif/docs/CONVENTIONS.md
    - webif/docs/ARCHITECTURE.md
  modified:
    - webif/CLAUDE.md
    - .planning/STATE.md
decisions:
  - "Module path refs updated from stale src/main.rs:NNN to post-Phase-02 module names (src/http.rs, src/turn.rs, src/worker.rs, src/mcp.rs)"
  - "Anti-Patterns in ARCHITECTURE.md fleshed out with one-sentence why-wrong gloss + right-pattern sentence; linked to HT-PROTOCOL.md §§3.2/6/11/12"
  - "Single-file Rust bullet updated to module-split Rust in Pattern Overview"
metrics:
  duration: "~8 minutes"
  completed: "2026-05-28"
---

# Phase 260528-iav Plan 01: CLAUDE.md TL;DR + docs/ Split Summary

CLAUDE.md compressed from 289 lines to 90 lines; verbose stack/conventions/architecture content moved to three new `webif/docs/` reference files totaling 344 lines.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Create webif/docs/STACK.md | e0ddf10 | webif/docs/STACK.md (68 lines) |
| 2 | Create webif/docs/CONVENTIONS.md | 75ab834 | webif/docs/CONVENTIONS.md (123 lines) |
| 3 | Create webif/docs/ARCHITECTURE.md | 2722a91 | webif/docs/ARCHITECTURE.md (153 lines) |
| 4 | Rewrite webif/CLAUDE.md | e6a56b0 | webif/CLAUDE.md (289 → 90 lines) |

## Line Counts

| File | Lines |
|------|-------|
| webif/CLAUDE.md (before) | 289 |
| webif/CLAUDE.md (after) | 90 |
| webif/docs/STACK.md | 68 |
| webif/docs/CONVENTIONS.md | 123 |
| webif/docs/ARCHITECTURE.md | 153 |

## Judgement Calls: src/main.rs:NNN → Module Paths

The original CLAUDE.md contained many stale `src/main.rs:NNN` line-number references. These were updated to module names based on the post-Phase-02 file layout visible in `webif/src/`:

| Component | Old reference | New module |
|-----------|---------------|-----------|
| HTTP handlers (prompt_handler etc.) | `src/main.rs:410` etc. | `src/http.rs` |
| worker_loop, process_job, build_prompt_body, read_turn | `src/main.rs:287-369`, `src/main.rs:314`, `src/main.rs:296`, `src/main.rs:384` | `src/turn.rs` |
| Worker struct and methods | `src/main.rs:202-285` | `src/worker.rs` |
| McpClient, MCP JSON-RPC | `src/main.rs:43-198` | `src/mcp.rs` |
| AppState | `src/main.rs:373` | `src/http.rs` |
| main() entry point | `src/main.rs:521` | `src/main.rs` (kept — it's still the bin shim) |
| MCP_TIMEOUT, TURN_TIMEOUT constants | `src/main.rs:39,41` | module-name only (src/mcp.rs / src/turn.rs) |

Exact line numbers within the new modules were not verified (would require reading ~700 lines of source). Module-name-only refs were used throughout the docs per plan instructions ("write the module name only without a line number rather than carry stale refs").

## Content Dropped (not relocated)

The following content from the original CLAUDE.md was dropped entirely and not carried into any docs/ file:

1. **`## System Overview` with empty ```text``` fence** (lines 154–156) — empty code block with no content.
2. **`## Language and Edition` bare header** (line 70) — no body content.
3. **`## Import Organization` bare header** (line 101) — no body content.
4. **`## Configuration` bare header in conventions block** (line 133) — duplicate/empty; real Configuration content is in docs/STACK.md.
5. **`## Module Design` bare header** (line 148) — no body content (now covered in docs/CONVENTIONS.md ## Module Design with actual content).
6. **`## Cross-Cutting Concerns` trailing bare header** (line 260) — no body content.
7. **`## Serde Patterns` with only `#[derive(Deserialize)]` fragment** (lines 131–132) — fleshed out to a full section in docs/CONVENTIONS.md.
8. **Orphan `### Data Flow` subheadings** (`### Primary Request Path`, `### Synchronous Path`, `### Polling Path`, `### Raw Command Path`, `### Restart Path`, lines 198–202) — replaced with prose descriptions in docs/ARCHITECTURE.md ## Data Flow.
9. **Misplaced bullets in Frameworks** (lines 36–37: "None. No tests/…" and "cargo + just") — relocated to docs/STACK.md ## Build & Test Tooling with updated content (Phase 03 added tests).
10. **`#[derive(Deserialize)]` code fragment** (line 132) — bare code fragment without context, replaced by a proper bullet in docs/CONVENTIONS.md.

## Deviations from Plan

None — plan executed exactly as written. All 7 GSD marker pairs preserved verbatim in original order. Project/Constraints/Skills/Workflow/Profile blocks byte-identical to originals. Each compressed block ends with `詳細: [docs/...]` link.

## Self-Check: PASSED

- webif/CLAUDE.md: 90 lines (within 70–130 target) ✓
- GSD marker pairs: 7 start + 7 end ✓
- webif/docs/STACK.md: 68 lines (≥40) ✓
- webif/docs/CONVENTIONS.md: 123 lines (≥60) ✓
- webif/docs/ARCHITECTURE.md: 153 lines (≥80) ✓
- All links (docs/ ← CLAUDE.md, ../CLAUDE.md ← docs/) verified ✓
- Dead headers absent from CLAUDE.md ✓
- Core Value line verbatim ✓
- 4 commits created: e0ddf10, 75ab834, 2722a91, e6a56b0 ✓
