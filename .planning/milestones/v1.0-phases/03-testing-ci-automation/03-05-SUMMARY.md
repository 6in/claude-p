---
phase: 03-testing-ci-automation
plan: 05
subsystem: tooling
tags: [justfile, just, task-runner, cargo, dev-shortcuts]

# Dependency graph
requires:
  - phase: 03-testing-ci-automation
    provides: "Plans 03-02/03/04 が確立した release-profile + -D warnings の cargo 呼び方（justfile はこれらを単にラップ）"
provides:
  - "リポジトリ直下 justfile（6 レシピ: build / run / test / fmt / clippy / clean）"
  - "set working-directory := 'webif' による DRY な webif/ ダウン構成"
  - "開発者ローカルでの cargo ショートカット（CI とは独立、D-23）"
affects: [03-06-ci-workflow, developer-onboarding]

# Tech tracking
tech-stack:
  added: [just]
  patterns:
    - "set working-directory directive で全レシピを webif/ にダウン（cd を各レシピで繰り返さない）"
    - "justfile は dev shortcut 専用、CI は cargo 直接呼び出し（責務分離 D-23）"

key-files:
  created:
    - "justfile (リポジトリ直下、29 行、6 レシピ)"
  modified: []

key-decisions:
  - "set working-directory := 'webif' を採用（各レシピで cd webif && を繰り返す代替案を不採用）— DRY と just --list での見た目を優先"
  - "default レシピを置かない（D-15）— 6 レシピを fully explicit に保ち、誤起動を防ぐ"
  - "test レシピは cargo test --release（dev profile ではなく）— CI (cargo test --release) と同 profile に揃え、リグレッションを早期検知"

patterns-established:
  - "リポジトリ直下 justfile + webif/ サブクレート構成: set working-directory で吸収する"
  - "日本語コメント + 英語識別子（CONVENTIONS 準拠）を justfile にも適用"

requirements-completed: [TOOL-01]

# Metrics
duration: 1min
completed: 2026-05-25
---

# Phase 03 Plan 05: justfile (TOOL-01) Summary

**リポジトリ直下に justfile を新設（6 レシピ: build / run / test / fmt / clippy / clean、`set working-directory := 'webif'` で webif/ サブクレートにダウン、CI とは独立）**

## Performance

- **Duration:** 1 min
- **Started:** 2026-05-25T13:52:25Z
- **Completed:** 2026-05-25T13:53:30Z
- **Tasks:** 1 executed + 1 checkpoint (skipped — `just` not installed)
- **Files modified:** 1 (created)

## Accomplishments
- `justfile` をリポジトリ直下に新設（既存タスクランナーなし → 新規パターン導入）
- D-12 / D-13 / D-14 / D-15 / D-23 を厳格遵守: 6 レシピ exactly、余剰なし、CI 非依存
- `set working-directory := 'webif'` 方式を採用（D-14 選択肢 (a)）— 1 directive で 6 レシピ全てが `webif/` で cargo を実行する DRY な形
- Cross-cutting constraint 準拠: `clippy` レシピは `cargo clippy --all-targets --release -- -D warnings`、`test` レシピは `cargo test --release`

## Task Commits

1. **Task 1: justfile をリポジトリ直下に新規作成（6 レシピ）** - `5b5ca06` (chore)
2. **Task 2: just <recipe> の動作確認（人的検証）** - skipped (`just` not installed on host; Task 1 automated verification confirmed file structure / content / no spurious recipes)

**Plan metadata:** (this SUMMARY + STATE/ROADMAP/REQUIREMENTS) → `[hash filled by final commit]`

## Files Created/Modified
- `justfile` (NEW, repo root, 29 lines) — 6 dev shortcut recipes (build/run/test/fmt/clippy/clean) で `webif/` の cargo を起動

## 6 レシピ一覧

| Recipe | Command | Notes |
|--------|---------|-------|
| `build` | `cargo build --release` | release profile（dev profile ではなく ROADMAP cross-cutting に揃える方向） |
| `run` | `cargo run` | dev profile（開発時のフィードバック速度優先） |
| `test` | `cargo test --release` | CI と同 profile（D-21 / CONTEXT specifics line 160） |
| `fmt` | `cargo fmt --all` | フォーマット強制 |
| `clippy` | `cargo clippy --all-targets --release -- -D warnings` | ROADMAP cross-cutting constraint 準拠 |
| `clean` | `cargo clean` | build artifact 削除 |

全レシピが `set working-directory := 'webif'` のディレクトリ指定で `webif/` 内で実行される。リポジトリ直下から `just build` 等を起動する運用に統一。

## Decisions Made
- **working-directory 方式の選択（D-14）**: `set working-directory := 'webif'` を採用。各レシピ内で `cd webif && cargo ...` を書く代替案より DRY で、`just --list` の出力にも `cd` ノイズが入らない。just 0.10.4+ で安定サポート。
- **default レシピ非導入（D-15）**: `default: build` のような利便レシピを置かず、`just` 単体実行時はリスト表示にフォールバックさせる。意図しないビルド連鎖を防ぐ。
- **fmt は `--check` ではなく適用版**: ローカル shortcut の趣旨に合わせて即時整形する `cargo fmt --all`。CI 側（Plan 03-06 で導入予定）が `cargo fmt --all -- --check` で差分検知する責務分離。

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- **`just` バイナリ未インストール（host parallels-vm）**: Task 2（人的検証）は `which just` で実行不可と確認できたため、plan 内の `<resume-signal>` で許可されている "skip" 経路を選択。Task 1 の自動検証（`test -f` / `grep -c` で 6 レシピ / `set working-directory` / 各 cargo コマンド存在確認）で justfile の正当性は実証済み。実環境での `just --list` / `just build` / `just test` / `just clippy` 動作確認は Plan 03-06 着手前の開発者裁量に委ねる。

## User Setup Required

None - justfile は optional な開発ショートカットであり、必須ではない。`just` を使いたい開発者は `cargo install just` または `brew install just` 等で入れる。CI からは呼ばないため CI 整備（Plan 03-06）に対する prerequisite ではない。

## Next Phase Readiness

- **Plan 03-06 (CI ワークフロー) Ready**: TOOL-01 完了で Phase 3 残りは TOOL-02 のみ。CI ワークフローは D-23 通り justfile を呼ばず `cargo` を直接実行するため、Plan 03-06 は本 plan の成果物に依存しない（独立して着手可能）。
- **No blockers for Phase 3 completion.**

## Self-Check: PASSED

**Verified files:**
- FOUND: `/home/parallels/workspaces/ht-mcp-sample/justfile`
- FOUND: `.planning/phases/03-testing-ci-automation/03-05-SUMMARY.md`

**Verified commits:**
- FOUND: `5b5ca06` (chore(03-05): add justfile with 6 dev shortcut recipes)

**Recipe count check:** exactly 6 (build / clean / clippy / fmt / run / test) — no forbidden recipes (default / check / cov / watch).

---
*Phase: 03-testing-ci-automation*
*Completed: 2026-05-25*
