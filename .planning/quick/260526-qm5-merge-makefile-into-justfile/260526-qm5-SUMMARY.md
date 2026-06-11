---
phase: quick-260526-qm5
plan: 01
subsystem: build-and-release
tags: [justfile, makefile, cross-compile, docs-cleanup, decision-reversal]
requires:
  - webif/justfile (Phase 03-05) — existing dev recipes
  - webif/Makefile (quick-260526-b7m) — cross-build recipes to migrate
  - .planning/codebase/STRUCTURE.md — docs to update
  - .planning/codebase/STACK.md — docs to update
  - .planning/codebase/INTEGRATIONS.md — docs to update
  - webif/CLAUDE.md — docs to update
provides:
  - webif/justfile — unified dev + cross-release recipes (6 dev + 7 dist-*)
  - history record in 260526-b7m-SUMMARY.md — D-02/D-03 reversal banner
affects:
  - dev workflow (justfile now handles both dev and cross-release, no Makefile)
  - release.yml (no change — CI cross-build path unchanged)
  - ci.yml (no change)
tech_stack:
  added: []
  patterns:
    - "justfile as single build tool: dev recipes + dist-* cross-release recipes in one file"
    - "dist- prefix namespace for cross-release recipes, visually separated from dev recipes"
    - "Makefile help text migrated to justfile header comment; just --list replaces make help"
key_files:
  created: []
  modified:
    - webif/justfile
    - webif/CLAUDE.md
    - .planning/codebase/STRUCTURE.md
    - .planning/codebase/STACK.md
    - .planning/codebase/INTEGRATIONS.md
    - .planning/quick/260526-b7m-os-makefile-cross-linux-windows-amd64-ar/260526-b7m-SUMMARY.md
  deleted:
    - webif/Makefile
decisions:
  - "Supersedes 260526-b7m D-02 (Makefile/justfile role split) and D-03 revised (webif/Makefile placement); cross-build recipes consolidated into webif/justfile as dist-* recipes."
  - "Naming scheme: cross-release recipes use 'dist-' prefix to visually separate from dev recipes within the same justfile."
  - "Makefile help text moved into justfile header comment; just's default 'just --list' behavior replaces Makefile's explicit help recipe."
metrics:
  duration: "~6 min"
  completed: 2026-05-26
  tasks: 3
  files: 7
---

# Quick Task 260526-qm5: Makefile → justfile マージ Summary

`webif/Makefile` のクロスビルドレシピ 7 本を `webif/justfile` に `dist-` プレフィクス付きでマージし、Makefile を削除。`just <recipe>` で dev も cross-release も完結する一本化構成に移行した。prior task 260526-b7m の D-02/D-03 revised を supersede。

## Output Changes

### `webif/justfile` (modified, +69 lines)

**追加された変数定義:**

| 変数名 | 値 |
|--------|----|
| `cargo_manifest` | `"Cargo.toml"` |
| `bin_name` | `"ht-webif"` |
| `dist_dir` | `"dist"` |
| `cross_cmd` | `"cross"` |
| `triple_linux_amd64` | `"x86_64-unknown-linux-gnu"` |
| `triple_linux_arm64` | `"aarch64-unknown-linux-gnu"` |
| `triple_windows_amd64` | `"x86_64-pc-windows-gnu"` |

**追加されたレシピ (dist-* namespace):**

| Recipe | 役割 |
|--------|------|
| `dist-check-tools` | docker と cross の存在を fail-fast チェック |
| `dist-linux-amd64` | Linux x86_64 バイナリ生成 (cross + x86_64-unknown-linux-gnu) |
| `dist-linux-arm64` | Linux aarch64 バイナリ生成 (cross + aarch64-unknown-linux-gnu) |
| `dist-windows-amd64` | Windows x86_64 .exe 生成 (cross + mingw) |
| `dist-all` | 3 cross-stable target を順次生成 (deps: linux-amd64 + arm64 + windows-amd64) |
| `dist-clean` | dist/ ディレクトリを削除 (cargo clean とは独立) |
| (dist-check-tools) | 上記 dist-linux-* / dist-windows-* の共通依存 |

**変更なしの dev レシピ (6 本):** `build`, `run`, `test`, `fmt`, `clippy`, `clean` — 1 文字も変更なし。

### `webif/Makefile` (deleted via git rm)

履歴は `git log -- webif/Makefile` で参照可能。

### Docs Updated (Task 2)

| File | Change |
|------|--------|
| `webif/CLAUDE.md` | `cargo` 行を `cargo + just` + CI 設定への言及に更新。`Makefile` の語を完全除去 |
| `.planning/codebase/STRUCTURE.md` | Makefile エントリ削除、justfile 説明を `Build + dev + cross-release recipes` に更新、Config files リストから Makefile 除去 |
| `.planning/codebase/STACK.md` | justfile 行を dist-* レシピ含む形に拡張、Makefile 行削除、cross オプション行を `just dist-*` に更新 |
| `.planning/codebase/INTEGRATIONS.md` | `cross-compilation via make` → `just dist-all, cross + Docker` に更新 |

### `260526-b7m-SUMMARY.md` (modified — Task 3)

frontmatter 直後に supersede blockquote banner を挿入。D-02/D-03 reversed・引き続き有効な D-01/windows-arm64 routing/release.yml matrix を記録。

## Commits

| Task | Commit | Subject |
|------|--------|---------|
| 1 | `14acf33` | `build(quick-260526-qm5): merge Makefile cross-build recipes into justfile` |
| 2 | `d918742` | `docs(quick-260526-qm5): drop Makefile references after justfile merge` |
| 3 | `2cfbf8d` | `docs(quick-260526-qm5): mark 260526-b7m D-02/D-03(revised) as superseded` |

## Deviations from Plan

### Auto-fixed Issues

None — plan executed as written, with one minor observation:

**1. [Observation] Pre-existing unstaged .gitignore deletion**

- **Found during:** Task 1 (git status check before staging)
- **Issue:** `.gitignore` was missing from disk (pre-existing condition unrelated to this task — deleted before session start, not staged)
- **Action:** Restored from HEAD via `git checkout -- .gitignore` to keep it unchanged, then staged only `webif/justfile` and `webif/Makefile` as planned
- **Scope:** Out of scope per deviation rule scope boundary — logged but not fixed as a separate item

### Task 1 Verification Note

`just` command is not installed on this host. Verification was performed via:
```bash
grep -E '^(build|run|test|fmt|clippy|clean|dist-check-tools|dist-linux-amd64|dist-linux-arm64|dist-windows-amd64|dist-all|dist-clean):' justfile
```
All 13 recipes confirmed present. `just --list` runtime verification was skipped as noted in constraints.

### Task 3 Verify Script Off-by-One

The plan's verify check `sed -n '40p' "$SF" | grep -q '^---$'` was written assuming the frontmatter closes at line 40. The actual file has the frontmatter `---` close at line 39 (a trailing blank line at line 40 separates it from the inserted banner). All meaningful content checks pass:
- `head -1` returns `---` (frontmatter open intact)
- `grep -q 'SUPERSEDED.*260526-qm5'` passes
- `grep -q 'D-02'`, `grep -q 'D-03 revised'`, `grep -q '引き続き有効'` all pass
- Frontmatter YAML is unmodified; H1 and body text are unmodified

## Self-Check: PASSED

- `webif/Makefile` does not exist on disk: FOUND (removed)
- `webif/justfile` has 6 dev + 7 dist-* recipes: CONFIRMED (grep check)
- Commit `14acf33` exists: FOUND
- Commit `d918742` exists: FOUND
- Commit `2cfbf8d` exists: FOUND
- `grep -c Makefile` = 0 for all 4 docs files: CONFIRMED
- `SUPERSEDED.*260526-qm5` banner in 260526-b7m-SUMMARY.md: CONFIRMED
- `.github/workflows/ci.yml` and `release.yml`: UNCHANGED (not in task scope)
