# Phase 6: Multi-Instance Parallel Foundation - Context

**Gathered:** 2026-06-15
**Status:** Ready for planning

<domain>
## Phase Boundary

複数エージェントのインスタンスを同時に立ち上げ、各インスタンスを `GET /info` で観測しながら独立して curl で叩ける環境を作る。成果物は 2 系統:

1. **新規 Rust エンドポイント `GET /info`**（v1.0 以来初の新規エンドポイント）— 稼働中エージェント名・port・status（idle/busy）・uptime・処理ターン数を JSON で返す（PARA-01 / PARA-02）。
2. **多重インスタンス起動ツール + クレデンシャル分離手順**（PARA-03 / PARA-04）— `scripts/launch-agents.sh`（設定ファイル駆動の up/down-all/status）+ `just up-all`/`down-all` ラッパ + README へのインスタンス分離（PORT/TURNS_DIR/CODEX_HOME 等）ガイド。

対象要件は **PARA-01〜04**。

**スコープ外（明示）:** WebIF 内のエージェント間ルーティング/ファンアウト/パイプライン、リクエスト単位のエージェント切替（`POST /prompt {"agent":...}`）、エージェントレジストリ/サービスディスカバリ、マルチホスト分散（PROJECT.md / REQUIREMENTS.md Out of Scope）。組み合わせ方は呼び出し側の責務。

**注意（既知のドキュメント齟齬）:** `.planning/codebase/*.md` のマップは v1.0 時点の `webif/src/` パスを参照しているが、現コードはリポジトリ直下 `src/` にある。ファイル/行参照は現物が正。

</domain>

<decisions>
## Implementation Decisions

### `GET /info` の status フィールド（PARA-01）
- **D-01:** `status` は **`idle` / `busy` の 2 状態**。ターン処理中かどうかを表す。worker_loop がターン開始/終了で共有フラグをトグルし、`/info` ハンドラはそれを読むだけ。
- **D-02:** status の実装は **lock-free な `AtomicBool`**。CR-01 の教訓（ターンは worker Mutex を最大 600s 保持する）から、`/info` は worker Mutex を一切取得してはならない。`snapshot()`（= Mutex + MCP 往復）を使う health 判定方式（idle/running/unhealthy）は不採用 — `/info` がブロッキング/重くなるため。
- **D-03:** `/info` が返すフィールドは成功基準で確定している集合に揃える: **エージェント名・port・status・uptime・処理ターン数**。agent 名と port は現状 AppState に無いので、起動時イミュータブル値として AppState に追加して lock-free に読む（output_covenant が CR-01 で AppState 直持ちされたのと同じパターン）。

### 処理ターン数のカウント方式（PARA-02）
- **D-04:** **メモリ内 `AtomicU64`**。worker_loop がターン完了ごとにインクリメントする。uptime と同じ「このプロセス起動以降」の意味論で一貫し、`/restart` でプロセス内状態がリセットされるのと整合する。turns_dir の status ファイル数を数える方式（filesystem 走査・古いファイル混入・uptime と意味がずれる）は不採用。
- **D-05:** status の `AtomicBool`（D-02）と処理ターン数の `AtomicU64`（D-04）+ uptime 起点（起動時 `Instant`）+ agent 名 + port を、**1 つの共有 lock-free 状態（例: `Arc<InstanceInfo>`）に集約**し、AppState と worker_loop の双方から参照する。uptime は起動時刻からの経過で算出。
  - *Claude's Discretion:* 処理ターン数が「成功のみ」か「成功+失敗の総数」か。PARA-02 は「処理ターン数」のみ要求するため total（done/failed 問わずターン試行が完了した数）を既定とするが、worker_loop の実装都合で自然な定義を採る。total/success/failed への分解は今回スコープ外（過剰）。

### ランチャー設計（PARA-03）
- **D-06:** **新規 `scripts/launch-agents.sh` を独立実装**する（既存 `scripts/claude-p` は拡張しない）。claude-p は claude 専用の単一ポート利用者向けラッパとして現状維持。launch-agents.sh は運用者向けの多重インスタンス・オーケストレータという役割分担。デーモン化/PID/readiness のロジックが部分的に重複することは許容する。
- **D-07:** インスタンスセットは **設定ファイル駆動**（例: `instances.conf`）。各行で agent・port・インスタンス固有 env（D-10 のクレデンシャル分離 env を含む）を記述し、launcher が読んで一括起動する。
- **D-08:** launch-agents.sh は **`up`（一括起動 + readiness 確認）/ `down-all`（全 PID に SIGTERM）/ `status`** を提供する。`just up-all` / `just down-all` でラップしてライフサイクル操作の入口を justfile に揃える（既存 justfile の流儀に追加）。
- **D-09:** readiness 確認は **`GET /info` ポーリング**で行う。単なる liveness（claude-p の `/turns/0` 400 応答）ではなく、`/info` が返す **エージェント名が期待値と一致すること**まで確認する（成功基準 2「各 /info がそれぞれの正しいエージェント名を返す」を満たす）。

### クレデンシャル分離方式（PARA-04）
- **D-10:** インスタンス固有のクレデンシャル env（Codex の `CODEX_HOME` 等）を **`instances.conf` の列として記述し、launcher が spawn 時に export** する。D-15（env = インスタンス基盤、TOML = エージェント挙動）と整合 — TOML スキーマは変更しない。手順は README にも記載する。
- **D-11:** **全 3 エージェント分の分離手順を用意**する。実際に分離が必須なのは Codex（セッション/auth 状態を `~/.codex` に書く）だが、claude（`~/.claude` の OAuth は読み取り中心で共有可能の見込み）・opencode（`~/.config/opencode`）についても「共有可否を検証 → 共有可なら明記、要分離なら分離手順」を README にまとめ、運用者が迷わないようにする。Phase 5 で繰延された A2/A3（CODEX_HOME / OpenCode インスタンス分離検証）をここで決着させる。

### Claude's Discretion
- `/info` レスポンス JSON の正確な形（フィールド名・追加で session_id 等を載せるか）。成功基準の必須フィールドは満たした上で最小限に。
- 共有 lock-free 状態の型と配置（`Arc<InstanceInfo>` 構造体を新規モジュールに置くか既存に同居させるか、`std::sync::atomic` の Ordering 選択）。
- `instances.conf` のフォーマット詳細（行ごとの区切り、env の表現方法、コメント記法、デフォルトファイルをコミットするかサンプルのみか）。
- launch-agents.sh の内部実装（PID/ログの置き場所 — claude-p の `/tmp/ht-webif-${PORT}.{pid,log}` 規約に倣うか、readiness タイムアウト値、TURNS_DIR の per-instance 割当方法）。
- `/info` の CORS / ルーティング配線（既存 build_router の流儀をそのまま踏襲）。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase boundary / requirements
- `.planning/ROADMAP.md` §"Phase 6: Multi-Instance Parallel Foundation" — Goal / Success Criteria 4 件
- `.planning/REQUIREMENTS.md` §"観測性・並列駆動土台（PARA）" — PARA-01〜04 の文面 + Out of Scope（per-request 切替・ルーティング・レジストリ）

### 現行エンドポイント実装（`GET /info` 追加の手本 + lock-free パターンの出典）
- `src/http.rs` — `AppState`（CR-01 で `output_covenant` を Mutex 越しでなく直持ちにした lock-free パターン = D-02/D-03/D-05 の手本）、`build_router`（4 ルート登録 + CORS）、`prompt_handler`（ターン投入経路）、co-located テスト構造
- `src/turn.rs` `worker_loop` — ターン処理ループ本体。status トグル（D-02）と処理ターン数インクリメント（D-04）の埋め込み先
- `src/main.rs` — 起動シーケンス（agent_name / port / turns_dir の確定箇所。共有状態の生成と AppState への配線位置）
- `src/worker.rs` — `Worker<M>` 構造（session_id 等の既存状態。`/info` は worker をロックしない方針）

### 既存ツーリング（launcher の土台）
- `scripts/claude-p` — デーモン化・PID(`/tmp/ht-webif-${PORT}.pid`)・ログ(`/tmp/ht-webif-${PORT}.log`)・readiness 待機・stop/status の実装。launch-agents.sh が踏襲する規約の手本（D-06/D-08）
- `justfile` — レシピ追加（`up-all`/`down-all`、D-08）の配置先。既存の変数定義・レシピ流儀に従う
- `README.md` 既存「多重インスタンス」節（行 72-86, 165 の CODEX_HOME プレースホルダ注記）+ claude-p 節（行 169-201）— PARA-04 ドキュメントの更新対象

### Project-level invariants
- `.planning/PROJECT.md` §"Constraints" / §"Out of Scope" — 1 worker = 1 TUI、リクエスト単位エージェント切替なし、WebIF 内ルーティングなし、単一ホスト前提
- `HT-PROTOCOL.md` §3-§7 — turnId 規格・3 ファイル方式・status 出現 = 完了センチネル（不変）

### Prior phase decisions（前提）
- `.planning/phases/04-agent-profile-abstraction/04-CONTEXT.md` — **D-15**（env = インスタンス基盤 / TOML = エージェント挙動の 2 層）が PARA-04 の env ベース分離（D-10）の根拠。**D-16**（turns 常に `<TURNS_DIR>/<agent>/`）が成功基準 3 のコリジョン安全を構造的に保証
- `.planning/phases/05-codex-cli-and-opencode-validation/05-CONTEXT.md` — Codex/OpenCode のプロファイル確定値。Deferred Ideas に「CODEX_HOME / OpenCode インスタンス分離検証は Phase 6（PARA-04）」と明記（D-11 で決着）
- `.planning/phases/05-codex-cli-and-opencode-validation/05-RESEARCH.md` — Codex/OpenCode の実機検証データ（auth セットアップ・Pitfall）。クレデンシャル分離手順の出典

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **AppState の lock-free フィールド方式**（`src/http.rs`）— CR-01 で `output_covenant` を worker Mutex の外に持たせた。agent 名・port・status・uptime・処理ターン数の共有状態も同じ要領で AppState に持たせれば `/info` は worker をブロックしない（D-02/D-03/D-05）
- **`scripts/claude-p`** — nohup デーモン化・PID/ログ規約・readiness ポーリング・SIGTERM→SIGKILL の stop・status サブコマンドが完成済み。launch-agents.sh はこの設計を多インスタンス向けに再構成できる（D-06）
- **`build_router` の型ジェネリック構造**（`src/http.rs`）— `/info` ルート追加は既存 4 ルートと同じく `.route("/info", get(info_handler::<M>))` を足すだけ。CORS/テストも既存流儀に乗る
- **D-16 の turns サブディレクトリ** — `<TURNS_DIR>/<agent>/` 自動分離で、別エージェントのインスタンス同士は構造的にコリジョンしない（成功基準 3）。同一エージェントの多重起動時は per-instance で `TURNS_DIR` を変える（claude-p の `turns-${PORT}` 方式が手本）

### Established Patterns
- 環境変数は env > .env > デフォルト（`AGENT` / `PORT` / `TURNS_DIR` / `HT_MCP_PATH` / `CORS_ORIGINS`）。launcher は instances.conf の値をインスタンス毎の env として export して起動する
- `eprintln!` + ブラケットタグ（`[profile]` / `[worker]` / `[restart]` / `[shared-fate]`）のログ慣行。`/info` 関連のログは `[info]` 等が自然
- 識別子英語・コメント/ログ/エラー文言は日本語
- HTTP の co-located テスト（`#[cfg(test)] mod tests` + tower oneshot）。`/info` ハンドラのテストもこの構造で追加

### Integration Points
- `src/http.rs` — `info_handler` 追加 + `build_router` にルート登録 + `AppState` に共有状態フィールド追加
- `src/turn.rs` `worker_loop` — status トグル + 処理ターン数インクリメントの埋め込み（共有状態への参照を引数で受け取る）
- `src/main.rs` — 共有状態の生成（起動時刻 Instant・agent 名・port）と AppState/worker_loop への配線
- `scripts/launch-agents.sh`（新規）+ `instances.conf`（新規）+ `justfile`（`up-all`/`down-all` レシピ追加）+ `README.md`（多重インスタンス + クレデンシャル分離ガイド更新）

</code_context>

<specifics>
## Specific Ideas

- `/info` のフィールド集合は成功基準どおり最小限（agent / port / status / uptime / turns_processed）。uptime は秒数 or 起動時刻、Claude 判断
- launch-agents.sh の readiness 確認は `/info` の `agent` 名が instances.conf の期待値と一致するまでポーリング（成功基準 2 を falsifiable に検証）
- PID/ログは claude-p の `/tmp/ht-webif-${PORT}.{pid,log}` 規約に揃えると status/down-all の実装が一貫する
- instances.conf のデフォルト 3 セット例は claude:8080 / codex:8081 / opencode:8082（成功基準の例に合わせる）。Codex 行には `CODEX_HOME` 列の例を入れる
- README には「共有可否を検証した結果」を明記: claude/opencode が共有可なら理由付きで、Codex は CODEX_HOME 分離手順を具体例で

</specifics>

<deferred>
## Deferred Ideas

- **status の idle/busy を超える詳細化（running/unhealthy、health チェック）** — snapshot ベースの health 判定は `/info` をブロッキング/重くするため不採用（D-02）。運用で必要になれば別系統のヘルスチェックとして将来検討
- **処理ターン数の total/success/failed 分解** — PARA-02 の要求を超える。監視ニーズが出たら将来追加（メモリ内カウンタなので後付け容易）
- **処理ターン数・uptime の永続化（再起動跨ぎ）** — メモリ内方式（D-04）はプロセス起動以降の意味論。永続メトリクスは OPS-02（tracing 構造化ロギング、v3+ 繰延）の領域
- **エージェント間ルーティング/ファンアウト/パイプライン** — PROJECT.md / REQUIREMENTS.md で明示的に Out of Scope。呼び出し側の責務
- **プロファイル hot-reload（FUT-02）** — 将来マイルストーン。現状は新ポートでの新インスタンス起動 or `/restart` で代替
- **同一プロセス内並列ワーカー（SCALE-01）** — v3+ 繰延。v2.0 は多重インスタンス（プロセス分離）で並列を実現
- **launch-agents.sh の config への TURNS_DIR/詳細 env 拡張** — まず agent/port + クレデンシャル env で十分。運用で項目が増えたら instances.conf フォーマットを拡張（後方互換に追加可能）

### Reviewed Todos (not folded)
None — todo マッチ 0 件（`gsd-tools query todo.match-phase 6` 結果）

</deferred>

---

*Phase: 6-multi-instance-parallel-foundation*
*Context gathered: 2026-06-15*
