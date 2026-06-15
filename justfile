# justfile — ht-webif 開発 + クロスリリースショートカット
# webif/ 直下に配置。`cd webif && just <recipe>` で起動する。
#
# 責務:
#   - 開発フロー (build/run/test/fmt/clippy/clean) は cargo を直接呼ぶ。CI も同じく cargo を直接呼ぶ（D-23）。
#   - クロスリリースビルド (dist-*) は Docker + cross を用いて Linux/Windows × AMD64/ARM64 の
#     cross-stable 3 target を生成する。実行には Docker daemon と cross が必須。
#
# 役割分担:
#   - macOS × AMD64/ARM64 は .github/workflows/release.yml の macos-latest runner で生成 (D-01)。
#   - windows-arm64 (aarch64-pc-windows-msvc) は cross 公式 Docker image が存在しないため、
#     release.yml の windows-latest runner 上で native cargo + rustup target add に委譲する。
# 出力: webif/dist/ht-webif-<os>-<arch>[.exe] (justfile からの相対で dist/)
#
# `just --list` でレシピ一覧を確認できる。

# --- 変数定義 ---
cargo_manifest := "Cargo.toml"
bin_name := "ht-webif"
dist_dir := "dist"
cross_cmd := "cross"
triple_linux_amd64 := "x86_64-unknown-linux-gnu"
triple_linux_arm64 := "aarch64-unknown-linux-gnu"
triple_windows_amd64 := "x86_64-pc-windows-gnu"

# リリースビルド
build:
    cargo build --release

# 開発実行（dev profile、.env は webif/.env を dotenvy が読む）
run:
    cargo run

# 全テスト（release profile、CI と揃える）
test:
    cargo test --release

# rustfmt 適用
fmt:
    cargo fmt --all

# clippy（all-targets + release + -D warnings、ROADMAP cross-cutting constraint 準拠）
clippy:
    cargo clippy --all-targets --release -- -D warnings

# ビルド成果物削除
clean:
    cargo clean

# 全インスタンスを起動する（instances.conf ドリブン、readiness は /info agent 名一致まで待つ）
up-all:
    bash scripts/launch-agents.sh up

# 全インスタンスを停止する（SIGTERM → SIGKILL）
down-all:
    bash scripts/launch-agents.sh down-all

# 各インスタンスの /info を叩いて状態を表示する
agents-status:
    bash scripts/launch-agents.sh status

# docker と cross の存在を fail-fast チェック
dist-check-tools:
    @command -v docker >/dev/null 2>&1 || { \
        echo "ERROR: docker が見つかりません。"; \
        echo "  Docker のインストール手順: https://docs.docker.com/get-docker/"; \
        exit 1; \
    }
    @command -v {{cross_cmd}} >/dev/null 2>&1 || { \
        echo "ERROR: cross が見つかりません。"; \
        echo "  インストール: cargo install cross --git https://github.com/cross-rs/cross"; \
        exit 1; \
    }
    @echo "OK: docker と cross が利用可能"

# Linux x86_64 バイナリ生成 (cross + x86_64-unknown-linux-gnu)
dist-linux-amd64: dist-check-tools
    mkdir -p {{dist_dir}}
    {{cross_cmd}} build --release --target {{triple_linux_amd64}} --manifest-path {{cargo_manifest}}
    cp target/{{triple_linux_amd64}}/release/{{bin_name}} {{dist_dir}}/{{bin_name}}-linux-amd64
    @echo "built: {{dist_dir}}/{{bin_name}}-linux-amd64"

# Linux aarch64 バイナリ生成 (cross + aarch64-unknown-linux-gnu)
dist-linux-arm64: dist-check-tools
    mkdir -p {{dist_dir}}
    {{cross_cmd}} build --release --target {{triple_linux_arm64}} --manifest-path {{cargo_manifest}}
    cp target/{{triple_linux_arm64}}/release/{{bin_name}} {{dist_dir}}/{{bin_name}}-linux-arm64
    @echo "built: {{dist_dir}}/{{bin_name}}-linux-arm64"

# Windows x86_64 .exe 生成 (cross + mingw)
dist-windows-amd64: dist-check-tools
    mkdir -p {{dist_dir}}
    {{cross_cmd}} build --release --target {{triple_windows_amd64}} --manifest-path {{cargo_manifest}}
    cp target/{{triple_windows_amd64}}/release/{{bin_name}}.exe {{dist_dir}}/{{bin_name}}-windows-amd64.exe
    @echo "built: {{dist_dir}}/{{bin_name}}-windows-amd64.exe"

# 3 つの cross-stable target を順次生成
dist-all: dist-linux-amd64 dist-linux-arm64 dist-windows-amd64
    @echo ""
    @echo "完了: 3 つの cross-stable target を生成しました"
    @echo "  macOS (amd64/arm64) と windows-arm64 は .github/workflows/release.yml で生成されます"

# dist/ ディレクトリを削除 (cargo clean とは独立)
dist-clean:
    rm -rf {{dist_dir}}
    @echo "removed: {{dist_dir}}/"

# ht-webif と launch-agents.sh を ~/.local/bin に、agents/*.toml を XDG グローバルに配置する。
# D-04: PATH 配布。インストール後は任意のディレクトリから ht-webif / launch-agents.sh up を呼べる。
install:
    #!/usr/bin/env bash
    set -euo pipefail
    # ビルド
    cargo build --release

    # バイナリとランチャーを ~/.local/bin に配置
    mkdir -p "$HOME/.local/bin"
    cp target/release/ht-webif "$HOME/.local/bin/ht-webif"
    cp scripts/launch-agents.sh "$HOME/.local/bin/launch-agents.sh"
    chmod +x "$HOME/.local/bin/launch-agents.sh"
    echo "インストール完了:"
    echo "  $HOME/.local/bin/ht-webif"
    echo "  $HOME/.local/bin/launch-agents.sh"

    # agents/*.toml を XDG グローバルにコピー（既存ファイルは上書き）
    # D-02: XDG_CONFIG_HOME 尊重（未設定時は HOME/.config）
    AGENTS_GLOBAL="${XDG_CONFIG_HOME:-$HOME/.config}/claude-p/agents"
    mkdir -p "$AGENTS_GLOBAL"
    if ls agents/*.toml >/dev/null 2>&1; then
        for f in agents/*.toml; do
            cp "$f" "$AGENTS_GLOBAL/"
            echo "  $AGENTS_GLOBAL/$(basename "$f")"
        done
        echo "agents プロファイルをコピーしました: $AGENTS_GLOBAL"
    else
        echo "agents/*.toml が見つかりません（スキップ）"
    fi

    # PATH 未登録時の注意表示
    case ":$PATH:" in
        *":$HOME/.local/bin:"*)
            echo "PATH に ~/.local/bin が含まれています。すぐに使用できます。"
            ;;
        *)
            echo ""
            echo "注意: ~/.local/bin が PATH に含まれていません。"
            echo "以下をシェル設定ファイル（~/.bashrc / ~/.zshrc 等）に追加してください:"
            echo '  export PATH="$HOME/.local/bin:$PATH"'
            ;;
    esac

# ht-webif と launch-agents.sh を ~/.local/bin から削除する（agents グローバルは保持）。
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f "$HOME/.local/bin/ht-webif" "$HOME/.local/bin/launch-agents.sh"
    echo "アンインストール完了: ~/.local/bin/ht-webif, ~/.local/bin/launch-agents.sh を削除しました"
    echo "注意: agents グローバル（${XDG_CONFIG_HOME:-$HOME/.config}/claude-p/agents）は削除しませんでした。"
    echo "  手動で削除する場合: rm -rf \"${XDG_CONFIG_HOME:-$HOME/.config}/claude-p/agents\""
