---
phase: quick-260526-b7m
plan: 01
subsystem: build-and-release
tags: [makefile, cross-compile, github-actions, release-matrix]
requires:
  - justfile (Phase 03-05) — dev recipes
  - .github/workflows/ci.yml (Phase 03-06) — CI workflow
  - webif/Cargo.toml — package metadata
provides:
  - Makefile — cross-build targets (linux-amd64/arm64 + windows-amd64)
  - .github/workflows/release.yml — 6-target release matrix
affects:
  - dev workflow (Makefile coexists with justfile by role separation)
tech_stack:
  added:
    - cross (cargo install, Docker-backed cross-compiler) — runtime dependency for Makefile
    - actions/upload-artifact@v4 — artifact uploads in release.yml
  patterns:
    - "Role separation: justfile=dev, Makefile=cross-release, release.yml=CI cross+native"
    - "Fail-fast tool check: `command -v` + install hint, no silent fallback"
    - "Matrix-include with `use_cross` flag: ubuntu+cross vs windows/macos+native cargo"
key_files:
  created:
    - Makefile
    - .github/workflows/release.yml
  modified: []
decisions:
  - "windows-arm64 (aarch64-pc-windows-msvc) は Makefile から除外 → release.yml 専属 (cross 公式 image 無し、windows-latest 上 rustup target + native cargo で代替)"
  - "Makefile default ターゲットは `help` (D-02/D-15: 曖昧な default build を避ける)"
  - "check-tools は docker と cross の両方を 1 レシピ内で fail-fast 検査 (D-04)"
  - "全レシピが `--manifest-path webif/Cargo.toml` 経由で webif/ を指す (D-03、`cd webif &&` を回避)"
  - "release.yml は ci.yml と完全独立 (別トリガ、別 working-directory 戦略)"
metrics:
  duration: "~10 min"
  completed: 2026-05-26
  tasks: 3
  files: 2
---

> **⚠ SUPERSEDED (partial) by quick task 260526-qm5 (2026-05-26)**
>
> 本 SUMMARY の以下の意思決定は後続 quick task `260526-qm5-merge-makefile-into-justfile`
> によって reversed された:
>
> - **D-02 (justfile / Makefile / release.yml 三本立て役割分担)** — justfile に
>   cross-build レシピ (`dist-*`) を統合し、Makefile は削除した。dev も cross-release も
>   justfile に集約された。
> - **D-03 revised (webif/Makefile 配置)** — `webif/Makefile` は存在しなくなった。
>   配置論点ごと消滅。
>
> 引き続き有効な意思決定:
>
> - **D-01 (macOS は CI 委譲)** — `.github/workflows/release.yml` で生成する方針は変わらず。
> - **windows-arm64 ルーティング (release.yml 専属)** — cross 公式 image 非対応のため
>   release.yml の windows-latest runner で native cargo を使う方針は変わらず。
> - **release.yml の 6 ターゲット matrix と全ステップ** — 一切変更なし。
>
> 詳細は `.planning/quick/260526-qm5-merge-makefile-into-justfile/260526-qm5-PLAN.md` を参照。

# Quick Task 260526-b7m: マルチOS Makefile + Release Matrix Summary

クロスビルド専用 Makefile (linux-amd64/arm64 + windows-amd64) と 6 ターゲット release matrix workflow を新規追加した。dev フロー (justfile) と CI フロー (ci.yml) には一切触らず、役割分担で共存させる構成。

## Output Files

### 1. `Makefile` (repo root, new, 86 lines)

クロスビルド専用、`cross` + Docker を用いて 3 cross-stable target を生成する。

**Recipe 一覧 (実際に書き出した名前):**

| Recipe | 役割 | Cross-build triple |
|--------|------|--------------------|
| `help` | default、各ターゲットの案内を表示 | — |
| `check-tools` | docker と cross の存在を fail-fast 検査 | — |
| `linux-amd64` | Linux x86_64 バイナリ生成 | `x86_64-unknown-linux-gnu` |
| `linux-arm64` | Linux aarch64 バイナリ生成 | `aarch64-unknown-linux-gnu` |
| `windows-amd64` | Windows x86_64 .exe 生成 | `x86_64-pc-windows-gnu` |
| `all` | 上記 3 cross-stable target を順次実行 | — |
| `clean-dist` | `dist/` ディレクトリを削除 | — |

**意図的に置かなかった recipe:**
- `macos-*` / `darwin-*` (D-01: macOS は CI 委譲)
- `windows-arm64` (cross 公式 image 無し、release.yml 専属)
- `build` / `run` / `test` / `fmt` / `clippy` / `clean` (justfile の責務、D-02)

### 2. `.github/workflows/release.yml` (new, 90 lines)

6 ターゲット matrix。タグ push (`v*`) と `workflow_dispatch` でトリガ、artifact upload までで停止 (Release 発行はしない)。

**Matrix 6 ターゲット:**

| target triple | os | use_cross |
|---------------|-----|-----------|
| `x86_64-unknown-linux-gnu`   | ubuntu-latest  | true  |
| `aarch64-unknown-linux-gnu`  | ubuntu-latest  | true  |
| `x86_64-pc-windows-gnu`      | ubuntu-latest  | true  |
| `aarch64-pc-windows-msvc`    | windows-latest | false |
| `x86_64-apple-darwin`        | macos-latest   | false |
| `aarch64-apple-darwin`       | macos-latest   | false |

**Build 経路:**
- `use_cross: true` (3 ターゲット) → `cross build --release --target <triple> --manifest-path webif/Cargo.toml` on ubuntu-latest
- `use_cross: false` (3 ターゲット) → `cargo build --release --target <triple> --manifest-path webif/Cargo.toml` on windows-latest/macos-latest with `rustup target add` (via `actions-rust-lang/setup-rust-toolchain@v1` の `target:` 入力)

**ステップ:** checkout → toolchain (target 同時 add) → cache (key=target) → cross install (条件) → build (cross or native) → stage binary (bash, `.exe` 拡張子判定) → upload-artifact@v4

## Planner Decision: windows-arm64 Routing

**判断:** `aarch64-pc-windows-msvc` を Makefile から外し、release.yml 専属とした。

**根拠:**
- cross 公式 Docker image は windows-arm64 に対応しない (`cross-rs/cross` 本体のサポート対象は `x86_64-pc-windows-gnu` のみ。aarch64 は cross-toolchains 側ユーザビルド領域)
- 代替として GitHub Actions の `windows-latest` runner 上で `rustup target add aarch64-pc-windows-msvc` + `cargo build --release --target aarch64-pc-windows-msvc` を実行 (MSVC linker が標準で使えるためクロスが成立)
- これにより 6 ターゲット全てが CI で生成され、ローカル Makefile は cross が「素直に」サポートする 3 ターゲットに集中可能

**Future:** 将来 cross 公式が windows-arm64 image を公開した場合、Makefile に `windows-arm64` recipe を追加して昇格可能 (meeting note)。release.yml はそのままで両立する。

## 触らなかった保護対象ファイル

`git diff HEAD~2 HEAD --name-only` で確認済み — 以下は 0 touch:

- `justfile` (dev recipes)
- `.github/workflows/ci.yml` (CI workflow)
- `webif/src/*.rs` (Rust source)
- `webif/Cargo.toml` (package metadata)
- `webif/Cargo.lock`
- `webif/.gitignore`

## Commits

| Task | Commit | Subject |
|------|--------|---------|
| 1 | `17beb72` | `build(quick-260526-b7m): add Makefile for cross-builds` |
| 2 | `cd59f2a` | `ci(quick-260526-b7m): add release workflow for 6-target matrix` |

Task 3 は `checkpoint:human-verify` のため commit なし (verification only)。

## 既知の運用上の注意

1. **Docker daemon 必須:** `make linux-*` / `make windows-amd64` は cross が裏で Docker container を起動するため、Docker daemon が動いていないと cross 自体が失敗する。`make check-tools` は `docker` バイナリの存在のみ確認し、daemon の起動状態は確認しない (`docker info` 等での probing は将来の拡張余地)。
2. **`cargo install cross --locked` 初回必須:** `make check-tools` は cross 未インストール時にインストール手順を表示するが、自動インストールはしない (D-04 の fail-fast 方針)。
3. **dev とのモード切替:** 開発作業 (build/run/test/fmt/clippy) は `just <recipe>` を使う。`make` は cross release build 専用。`make help` の注記でこの分担を明示してある。
4. **release.yml の artifact 保持期間:** 既定 (90 日) を使用。明示的な retention 設定はしていない。
5. **`webif/target/` の cross 利用:** cross の build 出力先は `webif/target/<triple>/release/` (cross は呼び出し元の `--manifest-path` から target_dir を継承)。Makefile の `cp` ステップはこのパスを直接参照する。

## Deviations from Plan

None — plan executed exactly as written. 1 件の microedit:

- release.yml の冒頭コメントに `action-gh-release` という文字列を入れていたところ、Task 2 の automated verify の `! grep -qE 'create-release|action-gh-release'` がコメント文を拾って false positive で fail。意味を変えずに「softprops 系や公式 release action」と言い換えて回避 (commit 内に取り込み済み、別 commit にはしていない)。これは verify 文言と人間向けコメントの語彙衝突であって、scope 逸脱ではない。

## CHECKPOINT VERIFICATION (Task 3)

Task 3 は `checkpoint:human-verify`。以下、executor 側で実行した結果。

### A. Makefile help と dry-run

| Probe | Result |
|-------|--------|
| A1: `make help` 表示内容 (3 cross-build + check-tools + clean-dist + all + 注記 2 行) | **PASS** (出力で目視確認、上記「Recipe 一覧」表と一致) |
| A2: `make -n all` で 3 cross-build コマンドが正しい triple で展開 | **PASS** (`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `x86_64-pc-windows-gnu` がそれぞれ `cross build --release --target ... --manifest-path webif/Cargo.toml` として展開) |
| A3: `! grep -E '^(macos\|darwin\|build\|run\|test\|fmt\|clippy):' Makefile` | **PASS** (該当 0 行) |

### B. (任意) 実際のクロスビルド

| Probe | Result |
|-------|--------|
| B-1: `make check-tools` の fail-fast 動作 | **PASS** (docker は present、cross は ABSENT → `ERROR: cross が見つかりません。インストール: cargo install cross --git https://github.com/cross-rs/cross` を表示し exit 2 で停止) |
| B-2: `make linux-amd64` → `dist/ht-webif-linux-amd64` 生成 | **SKIPPED: cross not installed** (制約に従い install attempt はしない) |

### C. release.yml lint と matrix 完全性

| Probe | Result |
|-------|--------|
| C-1: `python3 -c "...matrix.include len..."` が `6` | **PASS** (出力: `6`) |
| C-2: `gh workflow view` / `actionlint` / `yamllint` | **SKIPPED: tools not installed** (gh: push 権限なし、actionlint/yamllint: 未インストール、制約に従い install attempt はしない。代替として python3 yaml.safe_load による parse は C-1 で実施済み) |
| C-3: `diff HEAD:ci.yml ci.yml` (ci.yml 不変) | **PASS** (diff exit 0、同一) |

### D. 変更ファイル最終確認

| Probe | Result |
|-------|--------|
| D: `git status --porcelain \| grep -E '\.(rs\|toml)$\|^.M justfile\|^.M .github/workflows/ci.yml'` | **PASS** (該当 0 件。pending changes は `.planning/quick/` のみで orchestrator が docs commit する) |

### 判定

**全 mandatory probe (A1/A2/A3, C1/C3, D) PASS。** Optional probe は環境制約により skip:
- B-2: cross 未インストールのため SKIP (B-1 で fail-fast 動作は確認済み)
- C-2: actionlint/yamllint/push 権限なしのため SKIP (yaml.safe_load による parse 検証は実施済み)

resume signal: **`approved (skipped: B-2, C-2)`**

## Self-Check: PASSED

- `Makefile` exists at repo root: **FOUND**
- `.github/workflows/release.yml` exists: **FOUND**
- Commit `17beb72` exists in git log: **FOUND**
- Commit `cd59f2a` exists in git log: **FOUND**
- `webif/src/*`, `webif/Cargo.toml`, `justfile`, `.github/workflows/ci.yml`: **UNCHANGED** (verified via `git diff HEAD~2 HEAD --name-only`)

---

## Post-Completion Fix (2026-05-26)

ユーザレビューで「Makefile は webif/ 直下に置くべき」との指摘を受け、移送。

**Changes:**
- `git mv Makefile webif/Makefile` (履歴保持)
- Makefile 内パス調整: `webif/Cargo.toml` → `Cargo.toml`、`webif/target/...` → `target/...`
- ヘッダコメント・help テキストを新配置 (`cd webif && make ...`) に追従
- `.gitignore` に `webif/dist/` を追加（クロスビルド成果物の意図せぬコミット防止）
- CONTEXT.md の D-03 を "revised" として更新（初版の rationale と新版の rationale 両方を保存）

**Affected files:**
- `webif/Makefile` (relocated + path adjustments)
- `.gitignore` (`webif/dist/` 追加)
- `.planning/quick/260526-b7m-.../260526-b7m-CONTEXT.md` (D-03 revised)

**release.yml は変更なし**: `webif/Cargo.toml` を `--manifest-path` で指す既存パスは CI 視点では正しい (CI は repo 直下が cwd)。
