# Makefile — ht-webif クロスビルド専用
#
# 責務: Docker + cross を用いた Linux/Windows × AMD64/ARM64 のクロスビルド (3 cross-stable target)。
# 役割分担:
#   - dev フロー (build/run/test/fmt/clippy/clean) は repo 直下の justfile に集約 (D-02)。`just <recipe>` を使うこと。
#   - macOS × AMD64/ARM64 は .github/workflows/release.yml の macos-latest runner で生成 (D-01)。
#   - windows-arm64 (aarch64-pc-windows-msvc) は cross 公式 Docker image が存在しないため、
#     release.yml の windows-latest runner 上で native cargo + rustup target add に委譲する。
# 配置: cargo プロジェクト直下 webif/Makefile (D-03 revised 2026-05-26)。`cd webif && make ...` で実行する。
# 出力: webif/dist/ht-webif-<os>-<arch>[.exe] (Makefile からの相対で dist/)

# --- 変数定義 ---
CARGO_MANIFEST    := Cargo.toml
BIN_NAME          := ht-webif
DIST_DIR          := dist
CROSS             := cross

TRIPLE_LINUX_AMD64    := x86_64-unknown-linux-gnu
TRIPLE_LINUX_ARM64    := aarch64-unknown-linux-gnu
TRIPLE_WINDOWS_AMD64  := x86_64-pc-windows-gnu

.PHONY: help check-tools linux-amd64 linux-arm64 windows-amd64 all clean-dist

# --- default ターゲット: help (曖昧な default build を置かない、D-02/D-15) ---
help:
	@echo "ht-webif クロスビルド Makefile (webif/ 直下から実行)"
	@echo ""
	@echo "  使い方 (まず 'cd webif' してから):"
	@echo "    make linux-amd64    - Linux x86_64 バイナリを webif/dist/ に生成 (cross 経由)"
	@echo "    make linux-arm64    - Linux aarch64 バイナリを webif/dist/ に生成 (cross 経由)"
	@echo "    make windows-amd64  - Windows x86_64 .exe を webif/dist/ に生成 (cross + mingw)"
	@echo "    make all            - 上記 3 cross-stable target をすべて生成"
	@echo "    make check-tools    - docker と cross がインストールされているか確認"
	@echo "    make clean-dist     - webif/dist/ ディレクトリを削除"
	@echo "    make help           - このヘルプを表示 (default)"
	@echo ""
	@echo "  注記:"
	@echo "    - macOS (amd64/arm64) と windows-arm64 は .github/workflows/release.yml で生成される"
	@echo "    - 開発用ショートカット (build/run/test/fmt/clippy/clean) は repo 直下から 'just <recipe>' を使う"

# --- ツールチェック: docker と cross が両方必要 (D-04: fail-fast + install hint) ---
check-tools:
	@command -v docker >/dev/null 2>&1 || { \
		echo "ERROR: docker が見つかりません。"; \
		echo "  Docker のインストール手順: https://docs.docker.com/get-docker/"; \
		exit 1; \
	}
	@command -v $(CROSS) >/dev/null 2>&1 || { \
		echo "ERROR: cross が見つかりません。"; \
		echo "  インストール: cargo install cross --git https://github.com/cross-rs/cross"; \
		exit 1; \
	}
	@echo "OK: docker と cross が利用可能"

# --- dist/ ディレクトリ (order-only prerequisite で使用) ---
$(DIST_DIR):
	@mkdir -p $(DIST_DIR)

# --- linux-amd64: cross + x86_64-unknown-linux-gnu ---
linux-amd64: check-tools | $(DIST_DIR)
	$(CROSS) build --release --target $(TRIPLE_LINUX_AMD64) --manifest-path $(CARGO_MANIFEST)
	cp target/$(TRIPLE_LINUX_AMD64)/release/$(BIN_NAME) $(DIST_DIR)/$(BIN_NAME)-linux-amd64
	@echo "built: $(DIST_DIR)/$(BIN_NAME)-linux-amd64"

# --- linux-arm64: cross + aarch64-unknown-linux-gnu ---
linux-arm64: check-tools | $(DIST_DIR)
	$(CROSS) build --release --target $(TRIPLE_LINUX_ARM64) --manifest-path $(CARGO_MANIFEST)
	cp target/$(TRIPLE_LINUX_ARM64)/release/$(BIN_NAME) $(DIST_DIR)/$(BIN_NAME)-linux-arm64
	@echo "built: $(DIST_DIR)/$(BIN_NAME)-linux-arm64"

# --- windows-amd64: cross + x86_64-pc-windows-gnu (mingw toolchain) ---
windows-amd64: check-tools | $(DIST_DIR)
	$(CROSS) build --release --target $(TRIPLE_WINDOWS_AMD64) --manifest-path $(CARGO_MANIFEST)
	cp target/$(TRIPLE_WINDOWS_AMD64)/release/$(BIN_NAME).exe $(DIST_DIR)/$(BIN_NAME)-windows-amd64.exe
	@echo "built: $(DIST_DIR)/$(BIN_NAME)-windows-amd64.exe"

# --- all: 3 つの cross-stable target を順に実行 ---
all: linux-amd64 linux-arm64 windows-amd64
	@echo ""
	@echo "完了: 3 つの cross-stable target を生成しました"
	@echo "  macOS (amd64/arm64) と windows-arm64 は .github/workflows/release.yml で生成されます"

# --- clean-dist: dist/ を削除 (cargo clean は justfile の責務、ここでは呼ばない、D-02) ---
clean-dist:
	rm -rf $(DIST_DIR)
	@echo "removed: $(DIST_DIR)/"
