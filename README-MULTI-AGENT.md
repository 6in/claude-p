# ht-webif マルチエージェント機能ガイド

このドキュメントは、マイルストーン **v2.0「マルチエージェント対応」（Phase 4〜6）** で
ht-webif に追加された機能を解説します。**何が・なぜできるようになったか**を説明する
機能ガイドであり、コマンドの逐次手順や API リファレンスは [README.md](README.md) を参照してください。

---

## 1. 概要 — 何が変わったか

v1.0 までの ht-webif は **Claude 専用**でした。ready 検知パターン・`/clear` コマンド・
出力規約などが Rust コードにハードコードされており、別の CLI エージェントを駆動するには
再ビルドが必要でした。

v2.0 では次の 3 段階でこれを解消しました。

| Phase | テーマ | 成果 |
|-------|--------|------|
| **4. Agent Profile Abstraction** | 抽象化 | エージェント固有設定を `agents/<name>.toml` に外出し。Claude を「最初のプロファイル」として再定義（挙動は v1.0 と等価な純粋リファクタ） |
| **5. Codex CLI and OpenCode Validation** | 横展開 | Codex CLI / OpenCode を実機 E2E で駆動。各プロファイルを確立 |
| **6. Multi-Instance Parallel Foundation** | 並列土台 | `GET /info` 観測性エンドポイント + 多重インスタンス一括起動 + turnId 採番の一意化 |

**到達点:** `agents/<name>.toml` を 1 ファイル追加するだけで（Rust 再ビルド不要）任意の
対話型 CLI エージェントを登録でき、複数エージェントのインスタンスを別ポートで同時に
立ち上げ、各インスタンスの状態を `GET /info` で観測しながら独立して curl で叩けます。

---

## 2. エージェントプロファイル（`agents/*.toml`）— Phase 4

### 何ができるか

エージェント固有の挙動を TOML ファイルで宣言します。起動時に `AGENT=<name>` で
プロファイルを選択し、対応する `agents/<name>.toml` が読み込まれます。
ファイルを追加するだけで新エージェントを登録でき、**Rust のリビルドは不要**です。

```bash
# just install 後は任意のディレクトリから起動できる
AGENT=claude   ht-webif   # agents/claude.toml を読む
AGENT=codex    ht-webif   # agents/codex.toml を読む
AGENT=opencode ht-webif   # agents/opencode.toml を読む
```

`AGENT=<unknown>` で対応プロファイルが見当たらない場合は、明確なエラーで即時終了します。

> `just install` を実行すると `ht-webif` が `~/.local/bin/` に配置されるため、
> リポジトリディレクトリ外のどこからでも `ht-webif` を呼び出せます。

### プロファイルのフィールド

| フィールド | 役割 |
|-----------|------|
| `cmd` / `command` | エージェントを spawn するコマンド配列（例 `["claude"]`, `["codex", "--dangerously-bypass-approvals-and-sandbox"]`） |
| `ready_pattern` | TUI が ready になったと判定する部分文字列（例 `"auto mode"`, `"YOLO mode"`） |
| `fresh_mode` | `fresh:true` 時のリセット方式。`"command"`（`clear_command` 送信）または `"respawn"`（セッション kill+再生成） |
| `clear_command` | `fresh_mode="command"` 時に送るクリアコマンド（例 `/clear`） |
| `output_covenant` | 出力規約テンプレート。`{result_path}` と `{status_path}` の両プレースホルダが必須 |
| `trigger_template` | トリガーメッセージテンプレート。`{prompt_path}` プレースホルダが必須 |
| `startup_timeout_secs` | 起動待ちタイムアウト秒（省略時デフォルトあり） |
| `turn_timeout_secs` | 1 ターンのタイムアウト秒（省略時デフォルトあり） |
| `startup_settle_ms` | ready 検出後の落ち着き待機ミリ秒 |
| `model_flag` / `model_value` | モデル選択フラグ（使う場合は両方指定） |

> 出力規約（`output_covenant`）と完了検知（`status` ファイル＝センチネル）の意味論は
> [HT-PROTOCOL.md](HT-PROTOCOL.md) に準拠します。エージェントが変わっても
> 「result を書き終えてから status を最後に書く」契約は共通です。

### agents/ プロファイルの探索順（D-01）

起動時に `AGENTS_DIR` が未設定の場合、以下の順で探索します:

1. `AGENTS_DIR` 環境変数（設定されていれば最優先）
2. `./agents/`（cwd 基準・存在すれば使用）
3. `${XDG_CONFIG_HOME:-~/.config}/claude-p/agents/`（`just install` でコピーされる XDG グローバル）

全パスが存在しない場合は試行パスを列挙したエラーで終了します。
`just install` を実行すれば XDG グローバルにプロファイルがコピーされるため、
リポジトリ外でも `AGENTS_DIR` 不要で動作します。

### 新エージェントの追加手順

1. `agents/<name>.toml` を作成し、上記フィールドを記述する。
2. （必要なら）前提となる認証・設定を済ませる。
3. `AGENT=<name> ht-webif` で起動する（`just install` 済みの場合）。

`agents/claude.toml` が最小の参考テンプレートです。

---

## 3. Codex CLI / OpenCode サポート — Phase 5

Phase 4 の抽象化を実証するため、2 つの異なる CLI エージェントを実機 E2E で駆動し、
プロファイルを確立しました。両者は `fresh` リセットの実現方式が対照的で、
プロファイル抽象化の表現力を裏付けています。

### Codex CLI（OpenAI）— `agents/codex.toml`

- **spawn:** `codex --dangerously-bypass-approvals-and-sandbox`（全承認ダイアログをスキップ）
- **ready_pattern:** `"YOLO mode"`（起動バナー）
- **fresh_mode:** `"command"` + `/clear`（in-session クリア。ロールアウトファイルを実機検査し、
  `/clear` 後に新規会話として開始されることを確認済み）
- **前提:** `codex login` 済み（`~/.codex/auth.json`）。多重インスタンスは `CODEX_HOME` で分離。
- **注意:** Codex は lean-ctx MCP hooks によりプロジェクトルート外のファイル読取を拒否するため、
  `TURNS_DIR` はプロジェクト内（デフォルト `./turns/codex/`）を使うこと。

### OpenCode（v1.4.3+）— `agents/opencode.toml`

- **spawn:** `bash scripts/opencode-runner.sh`（TUI 直駆動ではなく `opencode run` ラッパー方式 / D-09）
  - TUI を PTY で動かすと `/turn` コマンドが処理されない問題（Pitfall 9）があり、
    stdin からトリガー行を受けて `opencode run --command turn <path>` を呼ぶラッパーで回避。
- **ready_pattern:** `"OpenCodeRunner ready"`
- **fresh_mode:** `"respawn"`（`opencode run` は 1 ターンで終了するため毎ターン新コンテキスト）
- **前提:** `opencode auth login`（GitHub Copilot 推奨）＋ `bash scripts/setup-opencode.sh` を一度実行
  （`~/.config/opencode/commands/turn.md` と `opencode.json` を生成。後者がないと確認ダイアログでタイムアウト）。
- **注意:** ht-mcp の `ht_send_keys` は日本語/マルチバイトを無音破棄するため、
  `output_covenant` / `trigger_template` は ASCII のみ。

各プロファイルの先頭コメントに、認証セットアップ手順・既知の制約（Pitfall）・実測タイミングが
詳細に記載されています。E2E スクリプトは `scripts/e2e-codex.sh` / `scripts/e2e-opencode.sh`。

---

## 4. 観測性エンドポイント `GET /info` — Phase 6

### 何ができるか

稼働中インスタンスの識別情報とメトリクスを、**worker のロックを一切取らずに**返します。
ターン実行中（worker がビジー）でも即応答するため、ロードバランサや監視からの
ポーリングに使えます。

```bash
curl -s localhost:8080/info
```

```json
{
  "agent": "claude",
  "port": 8080,
  "status": "idle",
  "uptime_secs": 1234,
  "turns_processed": 7
}
```

| フィールド | 意味 |
|-----------|------|
| `agent` | 稼働中のエージェント名（プロファイル名） |
| `port` | listen ポート |
| `status` | `busy` / `idle` |
| `uptime_secs` | 起動からの経過秒 |
| `turns_processed` | 完了したターン数 |

### `status` のセマンティクス（WR-03: in-flight 方式）

`status` は **キュー在庫（in_flight）** で判定します。`POST /prompt` が
キューに投入された時点（デキュー前）で `busy` になり、ターン完了で `idle` に戻ります。

これは「キュー済みだが未実行」のインスタンスをロードバランサが**空きと誤認しない**ための
契約です。`in_flight` と `turns_processed` は lock-free atomic、識別情報（agent/port/起動時刻）は
起動後イミュータブルなので、`/info` ハンドラは Mutex を取らずに読み取ります。

---

## 5. 多重インスタンス一括起動 — Phase 6

### 何ができるか

複数エージェントのインスタンスを別ポートで一括起動・停止・状態確認できます。
設定は `instances.conf`、オーケストレータは `scripts/launch-agents.sh`、
ショートカットは `justfile` のレシピです。

```bash
just up-all          # instances.conf の全インスタンスを起動（readiness 確認まで）
just agents-status   # 各 /info を叩いて agent/status/uptime/turns を表示
just down-all        # 全インスタンスを停止（SIGTERM → 5 秒 → SIGKILL）
```

### `instances.conf` の書式

```conf
# 書式: <agent>  <port>  [KEY=VALUE ...]
# 列の区切りは空白。KEY=VALUE は spawn 時に環境変数として export される（eval なし）。
claude     8080
codex      8081  CODEX_HOME=/home/user/.codex-instance1
opencode   8082
```

- **agent:** `agents/` のプロファイル名
- **port:** listen ポート
- **追加列:** エージェント固有の credential env（複数可）。`CODEX_HOME` のように
  mutable な認証状態を持つエージェントはここで分離します。
- **制約（WR-02）:** VALUE 自体に空白は使えません（空白を含むパスはシンボリックリンクで回避）。

### 前提: `just install` の実行

`launch-agents.sh up` は `command -v ht-webif` で PATH 上のバイナリを発見して起動します
（`cargo build` は不要、D-04）。事前に `just install` を実行しておいてください。

`instances.conf` は `launch-agents.sh up` を実行した **cwd** から読みます（D-03）。
ターン成果物も同じ cwd 基準で `./turns-<port>/<agent>/` に書き出されます。

```bash
# 運用例: プロジェクト外の作業ディレクトリに instances.conf を置いて使う
mkdir ~/my-agents && cd ~/my-agents
cat > instances.conf <<'EOF'
claude  8080
codex   8081  CODEX_HOME=/home/user/.codex-instance1
EOF
launch-agents.sh up   # PATH 上の ht-webif を起動、turns は ./turns-8080/claude/ 等に書き出す
```

### 起動シーケンスの要点

- **PATH からバイナリを発見（D-04）:** `command -v ht-webif` で PATH 上のインストール済みバイナリを
  直接起動。`down-all` の SIGTERM が `ht-webif` 本体に確実に届きます。`just install` 済みであること。
- **readiness は `/info` の agent 名一致でポーリング（D-09）:** 単なる起動ではなく、
  期待したエージェントが応答するまで待ちます。
- **ポート衝突を即ハード失敗に区別（WR-06）:** `/info` が応答しても agent 名が異なる場合は
  「別エージェントが当該ポートを使用中」として即失敗扱い。
- **部分失敗の集計（WR-04）:** 1 インスタンスの失敗でループを止めず、起動できるものは起動し、
  最後にまとめて非ゼロ終了します（例: Codex の認証未設定だけ失敗 → claude/opencode は起動）。
- **PID/LOG/TURNS 規約:** `/tmp/ht-webif-${PORT}.pid` / `.log`、書き込み先は
  `<cwd>/turns-${PORT}/${AGENT}/`（ポート分離は launcher が注入する `TURNS_DIR=<cwd>/turns-${PORT}` の差、
  `<agent>/` サブディレクトリは D-16 がサーバ側で付与）。

### クロスインスタンスのファイル分離

各インスタンスは `turns-<port>/<agent>/` という別ディレクトリに書き込むため、
インスタンス間で turn ファイルが衝突することはありません（`TURNS_DIR` 分離で自動保証）。

### 各インスタンスへプロンプトを送る

`launch-agents.sh up` で起動した各インスタンスは、**それぞれ別ポートで独立した ht-webif**
です。プロンプト送信は通常の単一インスタンスと同じく `POST /prompt` を**該当ポート宛**に
投げるだけ。「どのエージェントに送るか」はポート番号で選びます（`instances.conf` の port 列）。

デフォルトの 3 インスタンス構成（claude=8080 / codex=8081 / opencode=8082）の例:

```bash
# Claude（8080）へ — 非同期（既定）: turn_id を即返す
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Rust とは何か 100 字で"}'
# → {"turn_id":"20260616-103045-123","status":"accepted"}

# Codex（8081）へ — 同期: 完了まで待って結果を返す
curl -s -X POST http://127.0.0.1:8081/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "2 + 2 は？", "wait": true}'
# → {"turn_id":"...","status":"completed","result":"4 です。"}

# OpenCode（8082）へ — fresh: 実行前に文脈リセット（-p 相当の一発実行）
curl -s -X POST http://127.0.0.1:8082/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "今日の日付は？", "fresh": true, "wait": true}'
```

非同期で投げた場合は、返ってきた `turn_id` で結果を回収します（送ったポートと同じポートへ）:

```bash
curl -s http://127.0.0.1:8080/turns/20260616-103045-123
# status が "done" になれば result が読める
```

ポイント:
- **エージェントの選択 = ポートの選択。** 同じ `{"prompt": ...}` ボディを宛先ポートだけ変えて投げ分ける。
- ターン成果物は各インスタンスの `./turns-<port>/<agent>/` に分離して書き出される（混線しない）。
- リクエスト/レスポンスの全仕様（`fresh` / `wait`、`GET /turns/{turn_id}`、`POST /command`、
  `POST /restart`）は [README.md の API セクション](README.md#api) を参照。マルチインスタンスでも
  エンドポイントの挙動は単一インスタンスと同一で、違いは「ポートで宛先エージェントを選ぶ」点だけ。

> ロードバランス例: 送信前に各ポートの `GET /info` を見て `status:"idle"` のインスタンスを
> 選べば、空いているエージェントへ振り分けられます（`status` セマンティクスは §4 参照）。

---

## 6. turnId 採番の一意化 — Phase 6（06-04 ギャップクローズ）

### 解決した問題

UAT で、**同一インスタンスへ同一ミリ秒に並行 `POST /prompt`** すると turnId が衝突し、
`prompt`/`result`/`status` ファイルが互いに上書きされる不具合が見つかりました。
原因は、turnId を `YYYYMMDD-HHMMSS-mmm`（ミリ秒精度タイムスタンプ）のみで採番しており、
並行着信した async ハンドラが同一文字列を生成しうる点でした
（直列 worker モデルは*実行*を直列化しますが、*採番*は HTTP 着信時で並行）。

### 解決方法 — `TurnIdAllocator`

`AppState` が所有する `TurnIdAllocator` を**単一直列化点**として導入しました
（worker Mutex とは別ロック）。

- **不変条件:** 発番ベースは**単調非減少**。`YYYYMMDD-HHMMSS-mmm` は固定幅なので
  辞書順比較が時系列順と一致します。
- **時計が前進したとき:** 新 base を採用し連番をリセット。サフィックス無しで返す（v1.0 と後方互換）。
- **同一ミリ秒 / 壁時計が後退したとき（NTP 補正・VM 再開・うるう秒平滑化）:** 直前 base を維持し、
  単調増加する数値サフィックスを付与して `{base}-{seq:03}`（例 `...-080-001`）を返す。
  これにより `Utc::now()` が非単調でも turnId は一意かつ単調になり、過去 turnId の再発番
  （ファイル上書き・データ損失）を防ぎます（CR-01 の単調非減少クランプ）。
- **ホワイトリスト適合:** サフィックスはハイフン＋数字のみ。既存の `^[0-9-]+$` 検証
  （`turn_id` がファイルシステムに到達する際の必須ガード）を壊しません。
- ロックはメモリ内の文字列整形の間だけ保持し、ファイル I/O や `.await` を跨ぎません。

> HT-PROTOCOL §3.2 が要求する「base 衝突時の `-<seq>` 連番ガード」を実装したものです。

### 検証状況

自動テストで以下を確証済み（38/38 グリーン）:

- **N=1000 並行採番の一意性**（multi-thread ランタイム）= 重複 0
- **backward-clock 再発番防止**（壁時計後退の回帰テスト）
- 全 turnId が `^[0-9-]+$` に適合

詳細は `.planning/phases/06-multi-instance-parallel-foundation/06-VERIFICATION.md`（9/9 must-haves VERIFIED）
および `06-UAT.md` を参照。

---

## 7. 関連ファイル早見表

| 対象 | パス |
|------|------|
| エージェントプロファイル | `agents/claude.toml`, `agents/codex.toml`, `agents/opencode.toml` |
| OpenCode ラッパー / セットアップ | `scripts/opencode-runner.sh`, `scripts/setup-opencode.sh` |
| E2E スクリプト | `scripts/e2e-codex.sh`, `scripts/e2e-opencode.sh` |
| 多重インスタンス設定 | `instances.conf` |
| 起動オーケストレータ | `scripts/launch-agents.sh`（`up` / `down-all` / `status`） |
| just レシピ | `justfile`（`up-all` / `down-all` / `agents-status`） |
| `/info` / `TurnIdAllocator` 実装 | `src/http.rs` |
| ワイヤープロトコル仕様 | [HT-PROTOCOL.md](HT-PROTOCOL.md) |
| 運用手順・API リファレンス | [README.md](README.md) |

---

*対象マイルストーン: v2.0 マルチエージェント対応（Phase 4〜6）*
