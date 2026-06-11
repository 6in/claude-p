# Quick Task 260526-b7m: マルチOSビルド対応Makefile - Context

**Gathered:** 2026-05-26
**Status:** Ready for planning

<domain>
## Task Boundary

リポジトリ直下に `Makefile` を新規作成し、Linux / macOS / Windows × AMD64 / ARM64 の 6 ターゲットで `ht-webif` バイナリをビルドできるようにする。Phase 3 で既に入っている `justfile`（dev ショートカット）はそのまま残し、Makefile はクロスビルド専用とする。

スコープ外:
- 既存 `justfile` のレシピ書き換え・削除
- `webif/src/*.rs` の Windows/macOS 動作互換性対応（コードはこのまま、ビルドだけ通すのが目的）
- `ht-mcp` 外部バイナリの Windows/macOS 提供（WebIF 側はビルドできても実行時に ht-mcp が無ければ動かないのは既知）
- リリース成果物の自動発行（GitHub Releases へのアップロード）

</domain>

<decisions>
## Implementation Decisions

### D-01: クロスコンパイル方式 — cross (Docker) + macOS は CI 委譲

- **Linux × AMD64/ARM64、Windows × AMD64/ARM64 の 4 ターゲット**: [`cross`](https://github.com/cross-rs/cross) crate（Docker コンテナで `cargo build --target <triple>` を実行）を採用。Docker さえあれば dev box 1 台から全部ビルド可能。
- **macOS × AMD64/ARM64 の 2 ターゲット**: cross でも実用上困難（osxcross + Apple SDK が必要、ライセンス都合あり）なので、ローカル Makefile からは外す。代わりに `.github/workflows/` 配下に `macos-latest` runner を使った release matrix workflow を追加する。
- **Why:** dev box (Linux) からの cross-build が実用範囲で 4/6 カバーでき、macOS だけは GitHub Actions の macos-latest（無料 OSS 枠）に委ねるのが現代の標準パターン。osxcross を ht-webif のためだけにセットアップするコストは見合わない。
- **How to apply:** Makefile には `linux-amd64` / `linux-arm64` / `windows-amd64` / `windows-arm64` のレシピを置き、いずれも `cross build --release --target <triple>` を呼ぶ。macOS 2 ターゲットは GitHub Actions ワークフロー（タグ push or 手動 dispatch トリガ）で `cargo build --release --target <triple>` を実行する。

### D-02: 既存 justfile との関係 — 共存（役割分担）

- **justfile**: dev ショートカット維持。`just build / run / test / fmt / clippy / clean` は触らない。Phase 3 D-12 の決定（"dev は justfile" with `set working-directory := 'webif'`）を尊重する。
- **Makefile**: クロスビルド専用。`make linux-amd64` 等の release-target build と、それを束ねる `make all` / `make clean-dist`、Docker/cross の存在チェックなどに限定する。
- **Why:** Phase 3 D-12 を覆さない最小変更。dev フローと release-build フローを物理的に別ファイルに分けたほうが mental model が単純（"日常は just、リリース時は make"）。
- **How to apply:** Makefile は dev shortcut を一切提供しない。`make build` のような曖昧な default も置かない（誤って justfile と衝突しないよう）。`make help` で正しい使い方を案内する。

### D-03 (revised 2026-05-26): Makefile の配置場所 — `webif/` 直下

- 配置先: `/home/parallels/workspaces/ht-mcp-sample/webif/Makefile`（`Cargo.toml` と同階層）。
- **Why (revised):** Makefile は cargo プロジェクト固有のビルドインフラなので、`Cargo.toml` の隣に置くのが Rust の慣行。`webif/target/` を直接参照できる（`--manifest-path` 不要）、`webif/` を独立した crate として扱う場合に Makefile も付随する、という整合性。`cd webif && make ...` の UX 劣化は受け入れる — 日常 dev は repo 直下の `just`、release ビルドは `cd webif && make` という棲み分けが mental model としては明快。
- **How to apply:** Makefile 内では `CARGO_MANIFEST := Cargo.toml`、出力先は `dist/`（= `webif/dist/`、`.gitignore` 追加済み）。`webif/target/<triple>/release/...` から `target/<triple>/release/...` へ全パスを `webif/` プレフィックス無しに揃える。
- **History:** 初版 D-03 は「repo 直下 + `--manifest-path webif/Cargo.toml`」だったが、ユーザレビュー (2026-05-26) で「Makefile は webif/ に置くべき」と訂正されたため supersede。初版 Makefile は commit `17beb72` に存在、移送 commit でこの版に置き換えた。

### D-04: cross / docker が無いときの挙動 — fail-fast + ヘルプ

- ビルドターゲット呼び出し時、`cross` か `docker` が無ければ `make` は即エラー終了し、インストール手順を案内する。
- **Why:** サイレントに別の `cargo` にフォールバックすると、ユーザは「ビルドできた = クロスビルドできた」と誤認するリスクがある（実際にはホスト triple 向けのバイナリ）。
- **How to apply:** Makefile の頭で `command -v cross >/dev/null 2>&1 || (echo 'install: cargo install cross --git https://github.com/cross-rs/cross' && exit 1)` を実行するレシピを置き、各クロスビルドレシピの前提条件にする。

### D-05: GitHub Actions の release matrix workflow

- 配置先: `.github/workflows/release.yml`（Phase 3 で入った `ci.yml` とは別ファイル）。
- トリガ: `push: tags: ['v*']` + `workflow_dispatch`（手動）。
- マトリクス: 6 ターゲット（`ubuntu-latest` で linux 2 + windows 2 を `cross`、`macos-latest` で macos 2 を native cargo）。
- 成果物: 各ターゲットのバイナリを `actions/upload-artifact@v4` で artifact として残す（リリース発行までは行わない、ダウンロード可能な形式まで）。
- CI workflow との関係: `ci.yml`（push/PR トリガ）はそのまま。`release.yml` は別トリガ・別頻度。

### Claude's Discretion
- バイナリ命名規約（`ht-webif-linux-amd64` 等）
- アーカイブ形式（生バイナリ vs tar.gz）
- `dist/` ディレクトリの構成
- `make help` の文面
- README/README.md の更新可否（Makefile があることのアナウンス）

</decisions>

<specifics>
## Specific Ideas

- `cross` の README: https://github.com/cross-rs/cross
- 6 つの Rust target triple:
  - `x86_64-unknown-linux-gnu` (linux-amd64)
  - `aarch64-unknown-linux-gnu` (linux-arm64)
  - `x86_64-pc-windows-gnu` (windows-amd64) — gnu toolchain (mingw)
  - `aarch64-pc-windows-msvc` (windows-arm64) ※ cross の Windows ARM64 サポート状況は要確認、無理なら gnu/msvc どちらを選ぶか planner で決める
  - `x86_64-apple-darwin` (macos-amd64) — CI のみ
  - `aarch64-apple-darwin` (macos-arm64) — CI のみ
- 既存 `webif/Cargo.toml` の package name は `ht-webif`、bin 名も `ht-webif`（main.rs）

</specifics>

<canonical_refs>
## Canonical References

- `.planning/phases/03-testing-ci-automation/03-CONTEXT.md` § D-12, D-14, D-23（justfile の責務範囲を決定した文書）
- `.planning/PROJECT.md` § Constraints（"Single host" / "POSIX-like OS assumed" の前提）
- `webif/Cargo.toml`（package メタデータ）
- `.github/workflows/ci.yml`（既存 CI、ubuntu-latest 単一）
- `justfile`（dev 6 recipes、`set working-directory := 'webif'`）

</canonical_refs>
