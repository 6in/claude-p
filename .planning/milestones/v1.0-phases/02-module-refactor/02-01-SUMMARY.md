---
phase: 02-module-refactor
plan: 01
subsystem: build-config
tags: [refactor, cargo, modules, skeleton]
requires:
  - phase-01-repository-hygiene  # Cargo.toml metadata already in place
provides:
  - lib-bin-dual-target          # webif/ now exposes both [lib] ht_webif and [[bin]] ht-webif
  - empty-module-skeleton        # config/http/mcp/turn/worker placeholders ready for content
affects: []
tech_stack:
  added: []                       # no new deps; pure structural change
  patterns:
    - "lib + bin dual-target (RESEARCH.md Pattern 1) — same crate exposes a binary entry and a reusable library"
key_files:
  created:
    - webif/src/lib.rs
    - webif/src/config.rs
    - webif/src/mcp.rs
    - webif/src/worker.rs
    - webif/src/turn.rs
    - webif/src/http.rs
    - .planning/phases/02-module-refactor/deferred-items.md
  modified:
    - webif/Cargo.toml
decisions:
  - "Cargo [lib].name = ht_webif (underscore — Rust identifier rule), [[bin]].name = ht-webif (hyphen — preserve existing binary name)"
  - "Placeholder modules contain only file-level //! doc comments; zero code moved this plan (movement deferred to Plan 02-02/03/04)"
  - "Pre-existing clippy::trim_split_whitespace lint at main.rs:163 deferred to Plan 02-02 (will be fixed when McpClient relocates to mcp.rs) — fixing it now would violate the plan's hard constraint that main.rs stays byte-identical"
metrics:
  duration_min: 2.4
  duration_seconds: 143
  tasks: 3
  files_changed: 8
  commits: 3
  completed: 2026-05-25
---

# Phase 02 Plan 01: クレートスケルトン作成 Summary

## One-liner

`webif/` クレートに `[lib]` + `[[bin]]` 二重ターゲットを宣言し、`lib.rs` と 5 つの空モジュール（config/http/mcp/turn/worker）を追加。`main.rs` は 1 バイトも変更せず、`cargo build --release` は警告 0・エラー 0 で完走。

## What Was Built

`webif/Cargo.toml` の `[dependencies]` ブロックの後ろに 2 セクションを追記:

```toml
[lib]
name = "ht_webif"
path = "src/lib.rs"

[[bin]]
name = "ht-webif"
path = "src/main.rs"
```

加えて 6 ファイルを新規作成:

- `webif/src/lib.rs` — `pub mod {config, http, mcp, turn, worker};` の 5 モジュール宣言（アルファベット順）+ file-level `//!` doc コメント 1 行
- `webif/src/{config,mcp,worker,turn,http}.rs` — 各ファイルとも file-level `//!` doc コメントが 1 行だけ（中身は意図的に空）

これにより、Plan 02-02/03/04 でシンボルを物理移送するときに `cargo build` が常に通る増分作業にできる土台が完成した。`main.rs` 本体は依然として 561 行の単一ファイルのまま動き続ける（バイナリは旧来通り）。

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Cargo.toml に [lib] + [[bin]] セクションを追加 | `eda6535` | `webif/Cargo.toml` |
| 2 | webif/src/lib.rs と 5 つの空モジュールファイルを作成 | `2fb5aed` | `webif/src/{lib,config,mcp,worker,turn,http}.rs` |
| 3 | ビルド検証 — lib + bin が警告なしでビルド | `6d33957` | `.planning/phases/02-module-refactor/deferred-items.md` |

## Verification Results

### Primary build gate (PASS)

```
cargo build --release         → EXIT 0, 0 warnings, 0 errors（10.78s）
cargo build --release --lib   → EXIT 0
cargo build --release --bin ht-webif → EXIT 0
```

artifacts:
- `webif/target/release/ht-webif` — 実行可能バイナリ ✓
- `webif/target/release/libht_webif.rlib` — ライブラリクレート ✓

### Acceptance criteria

| Check | Result |
|-------|--------|
| `grep -c '^\[lib\]$' Cargo.toml` returns 1 | ✓ |
| `grep -c '^\[\[bin\]\]$' Cargo.toml` returns 1 | ✓ |
| `name = "ht_webif"` present | ✓ |
| `name = "ht-webif"` present (in `[[bin]]` and `[package]`) | ✓ |
| `path = "src/lib.rs"` present | ✓ |
| `path = "src/main.rs"` present | ✓ |
| `[package]` 既存行 (`edition = "2021"`) 不変 | ✓ |
| `[dependencies]` 既存行 (`tokio = ...`) 不変 | ✓ |
| 6 ファイル全て `test -f` で存在確認 | ✓ |
| `lib.rs` に `pub mod` が 5 行 | ✓ |
| `lib.rs` に 5 モジュール（config/http/mcp/turn/worker、アルファベット順） | ✓ |
| 各プレースホルダの先頭文字が `//!` | ✓ |
| 各プレースホルダが 10 行以下（実測: 全て 1 行） | ✓ |
| `use`/`struct`/`fn`/`impl` がプレースホルダに 0 件 | ✓ |
| `main.rs` 561 行のまま | ✓ |
| `main.rs` の `struct McpClient` 1 個のまま | ✓ |
| `git diff webif/src/main.rs` が空 | ✓ |

## Decisions Made

1. **`[lib].name = ht_webif`（アンダースコア）vs `[[bin]].name = ht-webif`（ハイフン）の二重命名** — Rust 識別子はハイフンを許さないため `[lib].name` はアンダースコア必須。`[[bin]].name` は外部から呼ばれる名前（`cargo run --bin ht-webif`、`target/release/ht-webif`）なので既存ハイフン名を維持。RESEARCH.md §"Cargo.toml Changes Required" の指針通り。

2. **プレースホルダはコード 0 行に統一** — 各モジュールに `//!` doc コメント 1 行だけ書き、`use` 文すら入れない。Plan 02-04 が「空モジュールに型と関数を流し込む」前提なので、ここでスタブ関数を書くと差分が読みにくくなる。

3. **`main.rs` 完全不変原則の死守** — `must_haves.truths` の "1バイトも変更しない" を最上位制約とした。clippy lint を見つけても触らず deferred-items.md に記録（下記参照）。

## Deviations from Plan

### Auto-fixed Issues

なし。Plan 02-01 はコード移送を含まないため、Rule 1/2/3 に該当するバグや欠落機能はなかった。

### Discoveries Deferred

**1. [Out-of-scope] `clippy::trim_split_whitespace` lint in `main.rs:163-164`**

- **Found during:** Task 3（`cargo clippy --all-targets --release -- -D warnings` 実行時）
- **Issue:** `.trim().split_whitespace()` の chain は redundant（`split_whitespace` 自体が空白除去するため `.trim()` 不要）
- **Origin:** Pre-existing — baseline commit `5439df5f`（Phase 2 開始前）から存在
- **Why not fixed now:** Plan 02-01 の `must_haves.truths` が `main.rs` を 1 バイトも変更しないことを要求する。スコープ境界に従い deferred-items.md に記録、Plan 02-02 で `McpClient` を `mcp.rs` に移送するときに同時に修正する（同じコードを編集中なので追加リスク 0）
- **Impact on Plan 02-01:** Primary gate（`cargo build --release`）は warnings 0・errors 0 で PASS。secondary gate（`cargo clippy ... -D warnings`）のみ失敗。ランタイム挙動には一切影響しない
- **Tracked in:** `.planning/phases/02-module-refactor/deferred-items.md` § D-02-01

### Spec note (informational, not a deviation)

Task 2 acceptance criteria に `grep -c '^fn main' webif/src/main.rs returns 1` とあるが、実コードは `#[tokio::main]` の下で `async fn main()` のため、正確な行頭文字列マッチは "0" になる。`main` 関数自体は `webif/src/main.rs:522` に存在（`grep -n 'fn main'` で確認済み）。`main.rs` は完全に未変更で 561 行のままなのでプランの本質的意図（「main.rs の構造が壊れていないこと」）は満たされている。

## Known Stubs

`webif/src/{config,mcp,worker,turn,http}.rs` は意図的なプレースホルダ。Plan 02-01 の目的そのもの（空モジュール器の用意）なので "stub" としては扱わない。後続プランで充填される:

- `config.rs` ← Plan 02-02（TURN_TIMEOUT / MCP_TIMEOUT / HT_MCP_PATH）
- `mcp.rs` ← Plan 02-02（McpClient）
- `worker.rs` ← Plan 02-03（Worker）
- `turn.rs` ← Plan 02-03（Job / worker_loop / process_job / build_prompt_body / read_turn）
- `http.rs` ← Plan 02-04（handlers / DTOs / router）

## Authentication Gates

なし（ht-mcp / claude の起動を伴わないビルド検証のみ）。

## Next Steps

- **Plan 02-02:** `config.rs` と `mcp.rs` に main.rs から `TURN_TIMEOUT` / `MCP_TIMEOUT` / `HT_MCP_PATH` 読み込み と `McpClient` を移送。同時に D-02-01 の clippy lint を修正。
- **Plan 02-03:** `worker.rs` と `turn.rs` に `Worker` と `Job` / `worker_loop` / `process_job` / `build_prompt_body` / `read_turn` を移送。
- **Plan 02-04:** `http.rs` に handlers / DTOs / router を移送、`main.rs` 本体は薄いエントリポイントだけに縮退。

## Self-Check: PASSED

Files created:
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/lib.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/config.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/mcp.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/worker.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/turn.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/webif/src/http.rs` — FOUND
- `/home/parallels/workspaces/ht-mcp-sample/.planning/phases/02-module-refactor/deferred-items.md` — FOUND

Files modified:
- `/home/parallels/workspaces/ht-mcp-sample/webif/Cargo.toml` — FOUND (8 lines added)

Commits:
- `eda6535` — FOUND
- `2fb5aed` — FOUND
- `6d33957` — FOUND
