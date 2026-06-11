# Phase 3: Testing & CI Automation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in 03-CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-25
**Phase:** 3-testing-ci-automation
**Areas discussed:** モック境界の置き方, HTTP 統合テストの駆動方式, タスクランナー: justfile vs Makefile, CI ワークフローのスコープ

---

## Gray area selection (multiSelect)

| Option | Description | Selected |
|--------|-------------|----------|
| モック境界の置き方 | ht-mcp をテストで差し替える継ぎ目 — trait Mcp 抽出 / Worker ジェネリック化 / scripted child / モック無し | ✓ |
| HTTP 統合テストの駆動方式 | tower::oneshot in-process vs 実 TcpListener vs axum_test | ✓ |
| タスクランナー: justfile vs Makefile | just は構文綺麗だが追加インストール、make は POSIX 標準だが Tab 必須 | ✓ |
| CI ワークフローのスコープ | トリガ・マトリクス・キャッシュ・E2E 除外方針 | ✓ |

**User's choice:** 全 4 領域を選択（4/4）
**Notes:** どの領域も実装方針への影響が大きく、planner に渡す前に決め切りたいとの判断。

---

## モック境界の置き方

### Q1: ht-mcp をテストで差し替える「継ぎ目」をどこに入れますか？

| Option | Description | Selected |
|--------|-------------|----------|
| trait Mcp を mcp.rs に抽出（推奨） | #[async_trait] trait Mcp を作り McpClient と FakeMcp 両方に impl。Worker<M: Mcp> ジェネリック化。TESTING.md 推奨パターン。async_trait 依存追加。 | ✓ |
| scripted child process で stdio をスタブ化 | tokio::process::Command で scripted child を起動して newline JSON-RPC を流し込む。依存 0 だが OS 依存・Windows 互換性低い。 | |
| McpClient を誤差り許容型で作る（TEST-02 は request body 組み立てだけ、統合はスキップ） | 抽象化コスト 0、ただし TEST-03 のカバレッジが弱くなる。 | |

**User's choice:** trait Mcp を mcp.rs に抽出
**Notes:** TESTING.md 推奨と一致。Phase 2 で確立した依存方向 turn → worker → mcp とも整合。

### Q2: trait Mcp を Worker / AppState にどう伝播させますか？

| Option | Description | Selected |
|--------|-------------|----------|
| Worker<M: Mcp> ジェネリック化 + main は Worker<McpClient>（推奨） | コンパイル時ディスパッチ、zero-cost。AppState も Arc<Mutex<Worker<M>>> へ型パラメータ伝播。 | ✓ |
| Worker 内部だけ Box<dyn Mcp>、AppState はそのまま | ダイナミックディスパッチ。HTTP 側にジェネリック伝播 0。 | |
| FakeMcp を #[cfg(test)] の中だけで使い、本体では trait を公開しない | TEST-02 だけに効いて TEST-03 には効かない。 | |

**User's choice:** Worker<M: Mcp> ジェネリック化
**Notes:** 型安全 + ホットパスではないがランタイムコスト 0。HTTP 層まで型パラメータ伝播は許容。

### Q3: trait Mcp の API はどの粒度で切りますか？

| Option | Description | Selected |
|--------|-------------|----------|
| ht-mcp ツールラッパに揃える（推奨） | create_claude_session / close_session / send_keys / submit_line / snapshot / handshake を trait に並べる。FakeMcp はセッション lifecycle をスクリプトでトレースできる。 | ✓ |
| JSON-RPC レベルだけ trait に（call_tool / request / notify） | 低レベルで FakeMcp が JSON Value 組み立てに毎回コスト。 | |
| call_tool だけ trait、handshake / session ops は inherent method のまま | FakeMcp の越える壁が低いが handshake 等の parsing がテストできない。 | |

**User's choice:** ht-mcp ツールラッパに揃える
**Notes:** create_claude_session の `Session ID:` 解析や snapshot の `auto mode` 検知も FakeMcp で再現可能になる。

### Q4: TEST-02（McpClient の JSON-RPC 組み立て）はどう触りますか？

| Option | Description | Selected |
|--------|-------------|----------|
| in-memory duplex で stdin/stdout を取り出して検証（推奨） | McpClient::spawn をバイパスし from_streams(impl AsyncWrite, impl AsyncRead) を追加。tokio::io::duplex でテスト。子プロセス 0、高速。 | ✓ |
| scripted child で エンドツーエンド検証 | OS 依存・遅い・シェルスクリプトのメンテナンス負債。 | |
| request を pub(crate) build_request fn に分けて純関数テスト | I/O は見ないため高速だが read_response / handshake の仕事はカバーされない。 | |

**User's choice:** in-memory duplex で stdin/stdout を取り出して検証
**Notes:** #[cfg(test)] pub で本番 API 影響なし。read_response の id matching と write_message の serialize 両方が duplex 越しに検証できる。

---

## HTTP 統合テストの駆動方式

### Q1: HTTP ハンドラの統合テストは Router をどう駆動しますか？

| Option | Description | Selected |
|--------|-------------|----------|
| tower::ServiceExt::oneshot で in-process に Router を叩く（推奨） | tower を [dev-dependencies] に追加。TcpListener 不要、hermetic・高速・並列安全。TESTING.md 推奨。 | ✓ |
| axum::serve + ランダムポートで実 HTTP | TcpListener::bind("127.0.0.1:0") から reqwest 等で叩く。実 HTTP スタックを通るが遅い + reqwest 追加。 | |
| axum_test クレートを使う | TestServer::new(app).await。便利だが依存追加 + tower::oneshot より重い。 | |

**User's choice:** tower::ServiceExt::oneshot
**Notes:** build_router(state) が pub で取り出せるので採用しやすい。reqwest 追加を避けたい意図と一致。

### Q2: HTTP テストで AppState をどう仕立てますか？

| Option | Description | Selected |
|--------|-------------|----------|
| FakeMcp + 本物の worker_loop を spawn（推奨） | Worker<FakeMcp> を作り tokio::spawn(worker_loop(...)) を起こす。POST -> 完了までの統合をテストできる。 | ✓ |
| Router だけ取り出し worker_loop は起こさない | job_tx の rx 側を保持するだけ。worker_loop の振る舞いはテストされない。 | |
| /prompt と /turns/{id} は独立でテストし worker_loop は完全に除外 | 2 つ完全分離。turn.rs の単体テストで process_job を直接叩く。 | |

**User's choice:** FakeMcp + 本物の worker_loop を spawn
**Notes:** Phase 3 必須テスト 2 本（GET-only）では worker_loop を起こさないが、将来の POST 系統合テスト拡張のために scaffolding は用意する方針（D-09）。

### Q3: HTTP 統合テストのカバレッジはどこまで取りますか？

| Option | Description | Selected |
|--------|-------------|----------|
| ROADMAP 要求ずばり：GET トラバーサル拒否 + GET happy path の 2 本だけ | Phase 3 success criteria #2 の最低ライン。 | ✓ |
| GET 2 本 + POST /prompt 非同期 happy path（推奨） | worker_loop 連携で 3 本になる。主要動線を押さえる。 | |
| 4 エンドポイント全部 + エッジケースを厚く | wait:true / fresh:true / /command / /restart 全部。「最小限」を超える。 | |

**User's choice:** GET 2 本だけ
**Notes:** 「最小限」を優先。Phase 2 の curl smoke 8 件で POST 系挙動は実証済み、テストハーネスは scaffolding として用意するが Phase 3 では追加テストは書かない。

---

## タスクランナー: justfile vs Makefile

### Q1: タスクランナーはどちらにしますか？

| Option | Description | Selected |
|--------|-------------|----------|
| justfile（推奨） | Rust コミュニティで事実上標準。Tab 不要、シェル互換性高い、just --list 軽快。cargo install just が必要。 | ✓ |
| Makefile | POSIX 標準で追加インストール不要。Tab 必須・.PHONY 必要・Windows 互換性低い。 | |
| 両方不要 — README に cargo コマンド直接 | 追加ツール 0、ただし ROADMAP TOOL-01 違反。 | |

**User's choice:** justfile
**Notes:** TOOL-01 要件を満たし、Rust コミュニティ慣行と一致。

### Q2: justfile のレシピはどこまで入れますか？

| Option | Description | Selected |
|--------|-------------|----------|
| ROADMAP 規定の 6 コマンドだけ（推奨） | build / run / test / fmt / clippy / clean の 6 レシピ。最小限。 | ✓ |
| 6 + check（CI ローカル実行）+ default レシピ | default を check にエイリアス。 | |
| サブコマンドを厚く（watch / cov / smoke / setup） | 開発者体験重視だが「最小限」を超える。 | |

**User's choice:** 6 コマンドだけ
**Notes:** スコープを最小に抑える方針。将来 v2 で必要になれば追加。

### Q3: justfile の配置場所は？

| Option | Description | Selected |
|--------|-------------|----------|
| リポジトリ直下（ht-mcp-sample/justfile）（推奨） | git root と揃える。CI とも一貫。 | ✓ |
| webif/justfile（サブプロジェクト下） | cargo コマンドがそのまま書ける。 | |
| 両方に置く（ルートは thin wrapper） | 二重定義になりメンテナンスコスト高い。 | |

**User's choice:** あとは推奨案で最後まで進めて（Other / freeform）
**Notes:** 残りすべての判断を Claude の推奨に委譲。配置はリポジトリ直下 ht-mcp-sample/justfile を採用（CI の cwd と一貫させるため）。

---

## CI ワークフローのスコープ

> 上記 Q3 の「推奨案で最後まで」を受けて、CI 4 サブ判断は全て Claude 推奨で確定（D-16〜D-23）。AskUserQuestion はスキップ。

| サブ判断 | 推奨（採用） |
|---|---|
| トリガ | push: branches: [main] + pull_request: branches: [main] |
| OS マトリクス | ubuntu-latest 単一 |
| Rust toolchain | stable 単一（actions-rust-lang/setup-rust-toolchain@v1） |
| キャッシュ | Swatinem/rust-cache@v2 |
| ジョブ構成 | 単一 check ジョブで fmt --check → clippy → test --release を直列実行 |
| working-directory | webif/（defaults.run.working-directory: webif） |
| E2E ゲート | Phase 3 では実装しない（v2 deferred） |
| Release / debug | cargo test --release / cargo clippy --release のみ（ROADMAP cross-cutting と整合） |
| justfile 連携 | CI からは justfile を呼ばず cargo 直接（二重定義回避） |

---

## Claude's Discretion

ユーザ判断 "あとは推奨案で最後まで進めて" 以降のすべての決定が含まれる:

- justfile 配置（リポジトリ直下）
- CI トリガ・OS・toolchain・キャッシュ・ジョブ構成・working-directory・E2E 方針・profile 選択・justfile 連携の有無

実装レベルの裁量（D-26 相当、CONTEXT.md "Claude's Discretion" セクション）:
- tempfile クレートの version pin
- justfile の working-directory 指定方法
- 各テスト関数の具体的命名
- Swatinem/rust-cache の細かいパラメータ

---

## Deferred Ideas

Phase 3 では着手しない、v2 もしくは別 phase で評価:

- E2E テスト（実 ht-mcp + claude TUI 必要）— #[ignore] + RUN_E2E=1 opt-in パターン
- cargo llvm-cov によるカバレッジ計測 + CI 集計
- cargo nextest 採用（テストランナー高速化）
- cargo audit を CI に組み込む（セキュリティ依存スキャン、SEC-01 と関連）
- cargo watch レシピを justfile に追加
- OS マトリクス拡張（macOS / Windows）
- Rust toolchain マトリクス（beta / MSRV）
- HTTP 統合テストの POST / /command / /restart カバレッジ拡張
- justfile に check / default / cov / watch などの便利レシピ追加
- CI で並列ジョブ化（fmt / clippy / test 分離）
- CI から justfile を呼ぶ統合
- OPS-02 tracing structured logging

---

*Discussion log for human reference only. Downstream agents read 03-CONTEXT.md, not this file.*
