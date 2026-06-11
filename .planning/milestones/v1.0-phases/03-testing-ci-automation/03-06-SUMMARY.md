---
phase: 03-testing-ci-automation
plan: 06
subsystem: ci
tags: [ci, github-actions, automation, tooling]
dependency_graph:
  requires:
    - .planning/phases/03-testing-ci-automation/03-CONTEXT.md (D-16..D-23)
    - .planning/phases/03-testing-ci-automation/03-PATTERNS.md (CI skeleton)
    - 03-02 / 03-03 / 03-04 (test additions — referenced by `cargo test` step)
    - webif/Cargo.toml (cargo project root referenced via working-directory: webif)
  provides:
    - .github/workflows/ci.yml (push/PR triggered single check job)
    - TOOL-02 requirement satisfied
    - ROADMAP Phase 3 Success Criterion #4 satisfied
  affects:
    - 以後 main への push / PR ごとに fmt-check + clippy + test が自動走行する
tech_stack:
  added:
    - GitHub Actions (CI runner; no local dependency)
    - actions/checkout@v4
    - actions-rust-lang/setup-rust-toolchain@v1
    - Swatinem/rust-cache@v2
  patterns: []
key_files:
  created:
    - .github/workflows/ci.yml
  modified: []
decisions:
  - "D-16..D-23 を YAML スケルトンとして 1 ファイル完結で実装（PATTERNS.md lines 490-528 に完全準拠）"
  - "Task 2 (human-verify) は resume-signal `skip` ルートを採用 — リモート push 前のため CI 実行確認を first-push に deferred"
  - "deferred-items.md に `cargo fmt --all -- --check` の pre-existing 違反を記録（scope boundary、03-06 のファイル責務外）"
metrics:
  duration_minutes: 2.3
  completed_date: "2026-05-25"
---

# Phase 03 Plan 06: GitHub Actions CI Workflow Summary

## One-liner

push / PR (main) で `cargo fmt --check` → `cargo clippy --all-targets --release -- -D warnings` → `cargo test --release` を ubuntu-latest 単一 OS / stable toolchain / Swatinem キャッシュ付き単一 `check` ジョブで直列実行する GitHub Actions ワークフロー (`.github/workflows/ci.yml`) を新規追加。

## What Was Built

### `.github/workflows/ci.yml` (40 行 / 新規)

**配置:** リポジトリ直下 `.github/workflows/ci.yml`（`.github/` 自体も新規）。

**構成要素:**

| 要素 | 値 | 決定 |
|------|----|------|
| `name` | `CI` | — |
| トリガ | `push: branches: [main]` + `pull_request: branches: [main]` | D-17（フォーク PR duplicate 抑制） |
| OS | `ubuntu-latest` 単一 | D-18（Linux 単一ホスト前提） |
| Toolchain | `stable` + `components: rustfmt, clippy` | D-19（`actions-rust-lang/setup-rust-toolchain@v1`） |
| キャッシュ | `Swatinem/rust-cache@v2` with `workspaces: webif -> webif/target` | D-20 |
| ジョブ構成 | 単一 `check` ジョブ / 直列 | D-21（並列化しない） |
| Working dir | `defaults.run.working-directory: webif` | D-22（各 step で `cd webif` 省略） |
| Justfile | 呼ばない（cargo 直接） | D-23 |

**Steps（順序固定）:**

1. `actions/checkout@v4`
2. `actions-rust-lang/setup-rust-toolchain@v1` (toolchain: stable, components: rustfmt, clippy)
3. `Swatinem/rust-cache@v2` (workspaces: webif -> webif/target)
4. `cargo fmt --all -- --check`
5. `cargo clippy --all-targets --release -- -D warnings`
6. `cargo test --release`

## 採用した actions のバージョン

| Action | バージョン | 根拠 |
|--------|-----------|------|
| `actions/checkout` | `v4` | GitHub 推奨最新メジャー |
| `actions-rust-lang/setup-rust-toolchain` | `v1` | D-19 明示指定 |
| `Swatinem/rust-cache` | `v2` | D-20 明示指定 |

## `defaults.run.working-directory: webif` の動作確認結果

**ローカル静的検証:** YAML 構造を `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` で parse 確認済み。`defaults.run.working-directory: webif` が `jobs.check.defaults.run.working-directory` の位置に正しく入っていることを検証。

**リモート動作確認:** `first push` 時に確認する（**deferred** — 後述）。

## 異常系（fmt 違反など）で CI が赤くなる確認

**結論:** ローカル検証では fmt step がリグレッション検知器として機能することを **既に実証** している（意図せず）。

`cargo fmt --all -- --check` を `webif/` で実行したところ、Plan 03-01 〜 03-04 で追加されたコードに pre-existing な rustfmt 違反が検出された（exit code 1、20 箇所の diff）。これは「fmt 違反があると `cargo fmt --check` step が fail する」ことを実証している（皮肉な形だが目的は達成）。

詳細は `.planning/phases/03-testing-ci-automation/deferred-items.md` に記録。03-06 のスコープ外（`.github/workflows/ci.yml` のみが本プランの責務）のため、別 housekeeping commit で fix する必要がある。

## 全 Phase 3 plans (01..06) 完了後の最終結果

すべて `webif/` ディレクトリで実行:

| コマンド | 結果 | 備考 |
|---------|------|------|
| `cargo build --release` | ✓ OK | `Finished release profile [optimized] target(s) in 2.01s` |
| `cargo clippy --all-targets --release -- -D warnings` | ✓ OK | warning 0 |
| `cargo test --release` | ✓ OK | `11 passed; 0 failed; 0 ignored` |
| `cargo fmt --all -- --check` | ✗ FAIL | pre-existing drift (deferred-items.md に記録、20 箇所の機械的 diff) |

11 tests の内訳（03-02 〜 03-04 で追加）:
- `turn.rs`: `build_prompt_body` / `read_turn` (done/garbled/missing-result) / `turn_id_formatter` — 計 5 本
- `mcp.rs`: `request` JSON-RPC エンベロープ / `next_id` increment / handshake — 計 3 本
- `http.rs`: `turn_handler` パストラバーサル 2 種 + happy path — 計 3 本

合計 11 本（CONTEXT.md `<specifics>` で見積もった 10 本前後と一致）。

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | `.github/workflows/` ディレクトリ作成 + `ci.yml` 新規作成 | `8606bba` | `.github/workflows/ci.yml` |
| 2 | GitHub Actions reachability 検証（human-verify） | — | — (skip per resume-signal) |

## Task 2 (human-verify) の扱い

**選択:** `skip` ルート — `resume-signal` の3つの選択肢のうち、「user wants to commit the workflow file without immediately verifying remote CI (verification deferred to first real push)」を選択。

**理由:**
1. 本実行コンテキストはリモート push を行う権限を持たない（user は明示的に push 指示していない）
2. プラン自身が skip を許可している（resume-signal 第 2 選択肢）
3. ローカル静的検証（YAML parse / grep による 11 件のシンボル確認 / step 順序確認）はすべて PASS
4. 期せずして fmt 違反検出（前述）により step ロジックの正しさは間接実証済み

**Deferred to first push:**
- Actions タブに `CI` ワークフローが表示されること
- push でも PR でもジョブが起動すること
- `defaults.run.working-directory: webif` がリモートで動作すること
- 緑になるかどうか（先に `cargo fmt --all` を webif/ で実行して deferred-items.md の違反を解消する必要あり、deferred-items.md に手順記載済み）

## Deviations from Plan

### Out-of-Scope Discoveries

**1. [Scope Boundary] Pre-existing `cargo fmt --check` violations in webif/src/**
- **Found during:** Task 1 verification (after `ci.yml` write, ran fmt check to confirm CI step would pass)
- **Issue:** 20 箇所の rustfmt diff in `webif/src/{http,main,mcp,turn,worker}.rs`（Plans 03-01 〜 03-04 由来の機械的 wrap drift）
- **Scope decision:** Out of scope — 03-06 は `.github/workflows/ci.yml` のみが files_modified。
- **Action:** `.planning/phases/03-testing-ci-automation/deferred-items.md` に記録 + fix 手順を添付。
- **Files modified:** 無（log のみ）

### Rules 1-3 Auto-fixes

None — 本プランは新規ファイル 1 件のみで、deviation 発生余地が極小。

## Self-Check: PASSED

**Created files (Task 1):**
- `[ FOUND ] .github/workflows/ci.yml` — `test -f` PASS

**Commit verification:**
- `[ FOUND ] 8606bba` — `git log --oneline | grep 8606bba` PASS

**YAML parse:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` → `YAML PARSE OK`

**Plan automated verify commands (11 件):** all PASS — file exists / name: CI / ubuntu-latest / setup-rust-toolchain@v1 / rust-cache@v2 / working-directory: webif / fmt-check / clippy / test / branches: [main] / no `just ` invocation.

**Required success criteria (8 件):** all PASS:
- ✓ `.github/workflows/ci.yml` exists at repo root
- ✓ Single `check` job
- ✓ ubuntu-latest
- ✓ stable
- ✓ Swatinem/rust-cache@v2
- ✓ defaults.run.working-directory: webif
- ✓ fmt-check → clippy → test serial
- ✓ Does NOT invoke `just`
