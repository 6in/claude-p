---
phase: 01-repository-hygiene
reviewed: 2026-05-24T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - .gitignore
  - LICENSE
  - README.md
  - webif/Cargo.toml
findings:
  critical: 0
  warning: 4
  info: 4
  total: 8
status: issues_found
---

# Phase 1: Code Review Report

**Reviewed:** 2026-05-24T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Phase 1 ("Repository Hygiene") introduces `.gitignore`, `LICENSE`, `README.md`, and extends `webif/Cargo.toml` with package metadata. Reviewed as a docs/config audit per phase scope; no Rust code was touched.

Strong points verified:
- `.env` is correctly ignored; `.env.example` is correctly tracked (`git check-ignore` confirms only `.env` and `.env.local` are excluded). No secret leakage risk in the four files reviewed.
- License/SPDX consistency: `LICENSE` is MIT (text body matches the canonical MIT template); `Cargo.toml` declares `license = "MIT"`. `cargo metadata` parses the manifest cleanly.
- Path-traversal claim in README (`turn_id` accepts only digits and hyphens) matches `webif/src/main.rs:457`.
- Timeout values quoted in README (MCP 30s / turn 300s / wait 700s) match the source constants (`main.rs:39, 41, 433`).

Issues found are primarily documentation accuracy drift and a few Cargo.toml metadata polish items. No blockers.

## Warnings

### WR-01: README claims atomic `.tmp`→`mv` rename for *all* turn files, but WebIF writes `prompt-<turnId>.txt` non-atomically

**File:** `README.md:197`
**Issue:** The "ターン成果物" section states:

> `status-<turnId>.json` の出現が完了シグナル（HT-PROTOCOL §6）。ファイルの書き込みはすべて `.tmp` → `mv` による atomic rename で行われる。

"すべて" (all) is incorrect. The WebIF-owned `prompt-<turnId>.txt` is written with a plain `tokio::fs::write(&prompt_path, body)` at `webif/src/main.rs:422` — there is no `.tmp` staging or rename anywhere in `main.rs` (verified: `grep -n -E "\.tmp|fs::rename" main.rs` returns zero matches). Only the claude-TUI-owned `result-*.txt` / `status-*.json` files are written atomically (and that's per HT-PROTOCOL §6, outside this crate's code).

This drift matters because the README is the contract surface; future readers (and reviewers of `prompt-<turnId>.txt` race conditions) will assume atomicity that does not exist. The race is currently benign because `turn_handler` checks `status_path.exists()` first and `prompt_path.exists()` second (`main.rs:462-466`), so a torn `prompt-*.txt` cannot be observed as `completed` — but the README should not promise behavior the WebIF does not implement.

**Fix:** Narrow the claim to the TUI-written files. Suggested rewrite:

```markdown
`status-<turnId>.json` の出現が完了シグナル（HT-PROTOCOL §6）。
claude TUI による `result-<turnId>.txt` / `status-<turnId>.json` の書き込みは
`.tmp` → `mv` による atomic rename で行われる（WebIF が書く `prompt-<turnId>.txt`
は使い回し前提のため非アトミック）。詳細は [HT-PROTOCOL.md](./HT-PROTOCOL.md) を参照。
```

### WR-02: README's `dotenvy` precedence statement is technically wrong (`.env` does NOT override pre-set environment variables)

**File:** `README.md:185`
**Issue:** The "環境変数" section says:

> 設定の優先順位: **実環境変数 > `.env` > 既定値**（`dotenvy` の標準動作）。

This is what the project intends, but it is the opposite of `dotenvy::dotenv()`'s actual default. The crate's standard `dotenv()` (used at `main.rs:524`) loads `.env` but **does not overwrite** existing process env vars — which happens to produce the documented "実環境変数 > `.env`" precedence. However the README phrases this as if it were a built-in feature, which can mislead a contributor who later switches to `dotenv_override()` / `from_path_override()` and silently inverts the precedence.

More importantly: the same statement appears verbatim in CLAUDE.md (project instructions) and is repeated in `.env.example:5`. None of these documents call out that switching to `*_override` variants would break the contract.

**Fix:** Either (a) keep the precedence sentence and add a one-line caveat, or (b) be explicit about the mechanism. Suggested:

```markdown
設定の優先順位: **実環境変数 > `.env` > 既定値**。
`dotenvy::dotenv()` は既存の環境変数を上書きしない仕様であり、
`dotenv_override()` 等の上書き系 API に切り替えると優先順位が逆転する点に注意。
```

### WR-03: README "前提依存" wording promises `.tmp`→本名 atomic rename as an OS prerequisite, but neither WebIF nor `.env.example` enforces this

**File:** `README.md:27`
**Issue:**

> **POSIX-like OS**: ファイルの atomic rename（`.tmp` → 本名）を前提とする

There is no Windows guard, no `cfg(unix)` check, and no startup probe. A user who runs `cargo run` on Windows will get a binary that compiles and starts, then silently relies on Windows' weaker rename semantics for files written by claude TUI. The README states a prerequisite but the binary does not refuse to start when it is violated. This is more of a "tighten the docs, or add a guard" item — given that the rename is done by claude TUI (out of WebIF's process), tightening the docs is the realistic fix.

**Fix:** Reword to clarify that this is a *required* runtime property of the host filesystem (not a sanity check WebIF performs), and that running on Windows is unsupported. e.g.:

```markdown
- **POSIX-like OS（必須）**: claude TUI が `result` / `status` ファイルを
  `.tmp` → 本名 の atomic rename で書き出すため、`rename(2)` の atomic 上書き
  セマンティクスが必要。Windows での動作は未検証・非サポート。
```

### WR-04: `webif/Cargo.toml` `authors` field is a placeholder ("ht-webif contributors") that will be embedded in published artefacts

**File:** `webif/Cargo.toml:8`
**Issue:** `authors = ["ht-webif contributors"]` is a non-attributable placeholder. The same placeholder appears in `LICENSE:3` (`Copyright (c) 2026 ht-webif contributors`). For a private/Max-sub-only repo this is fine, but the manifest also declares a public-looking `repository = "https://github.com/0hya6in/ht-mcp-sample"` and `categories = ["command-line-utilities"]` / `keywords = [...]` — i.e., it is shaped for `cargo publish`. If anyone runs `cargo publish` (intentionally or accidentally via CI later) the placeholder ships to crates.io and cannot be edited without yanking.

Either decide "not for publication" and add `publish = false`, or fill in real authors. The current state is ambiguous.

**Fix (recommended):** Add `publish = false` until publication is an explicit goal:

```toml
[package]
name = "ht-webif"
version = "0.1.0"
edition = "2021"
publish = false  # crates.io 公開予定なし。公開する場合は authors を実名/組織名に差し替えること
description = "..."
# ...
```

If publication IS the goal, replace the placeholder with attributable author identities (real names / handles / org email).

## Info

### IN-01: `.gitignore` Cargo.lock comment is at the top level but the lockfile lives at `webif/Cargo.lock`

**File:** `.gitignore:8`
**Issue:** The comment `# 注: Cargo.lock はバイナリクレートのためトラックする（ignore しない）` is informative and correct, but it sits next to the root `/target/` and `webif/target/` rules where a reader expects only target-related entries. The lockfile is at `webif/Cargo.lock` (not at repo root), and there is no `/Cargo.lock` rule above the comment — so the comment is reassuring rather than load-bearing. Also note that `webif/Cargo.lock` is currently **untracked** (per `git status`), despite the comment's promise. Either add it to the commit (recommended for binary crates) or the comment is aspirational.

**Fix:** Either (a) `git add webif/Cargo.lock` so the lockfile is actually tracked, satisfying the comment's intent; or (b) move the comment to a clearer location and stop promising what isn't done. Recommend (a).

### IN-02: `.gitignore` rule `/.env` is anchored to repo root, but the README does not warn users who create a per-subdir `.env`

**File:** `.gitignore:16`
**Issue:** `/.env` is a leading-slash anchored pattern matching *only* the repo-root `.env`. If a developer follows the README's "リポジトリルートで `.env` を用意する" path the file is correctly ignored. However, anyone who experiments with `cd webif && cp ../.env.example .env` (a natural thing to try given the "either-cwd" run instructions in the README at lines 47-56) would create `webif/.env` — which is NOT ignored. The unanchored `.env.local` rule on line 17 mismatches in style with the anchored `/.env` on line 16, increasing the chance of confusion.

**Fix:** Use a consistent unanchored pattern that catches `.env` anywhere in the tree (and keep tracking `.env.example` via the existing dotenvy/template suffix):

```gitignore
# 秘密情報（実設定ファイル — サンプルテンプレート .env.example はトラックする）
.env
.env.local
!.env.example
```

The explicit negation `!.env.example` documents intent and is robust against future `.env` rules that might glob more broadly.

### IN-03: README example timestamps use "20260523" but today is 2026-05-24; trivial drift

**File:** `README.md:87, 102, 118, 121, 128, 137`
**Issue:** All `turn_id` examples use `20260523-...`, presumably written on 2026-05-23. Today is 2026-05-24. Not a defect — examples are illustrative — but worth normalizing to e.g. `YYYYMMDD-HHMMSS-NNN` placeholder once, then drop date-specific samples to avoid future re-edits every time the README is touched. Optional polish.

**Fix:** Either leave as-is (it's just sample output) or use a placeholder convention:

```
{
  "turn_id": "<YYYYMMDD-HHMMSS-mmm>",
  "status": "accepted"
}
```

### IN-04: `LICENSE` copyright line uses placeholder "ht-webif contributors" — same concern as Cargo.toml authors

**File:** `LICENSE:3`
**Issue:** `Copyright (c) 2026 ht-webif contributors` — the same placeholder identity as `Cargo.toml:8`. MIT requires the copyright notice to be preserved in redistributions; once the project has any external contributor the line should name a copyright holder (individual or org). Currently fine for a solo/internal repo, but flagging so it's a conscious choice.

**Fix:** When ready, replace with either a real name/handle or an explicit collective ("Copyright (c) 2026 <Your Name>" or "(c) 2026 the ht-webif authors. See AUTHORS file."). No urgency for Phase 1.

---

_Reviewed: 2026-05-24T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
