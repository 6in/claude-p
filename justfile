# justfile — ht-webif 開発ショートカット
# webif/ 直下に配置。`cd webif && just <recipe>` で起動する。
# 全レシピは cargo を直接呼ぶ。CI も同じく cargo を直接呼ぶ（D-23）。

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
