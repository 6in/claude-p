# ht-webif

`curl` 1発で Claude にタスクを送って結果を受け取れる、軽量な HTTP WebIF。

## Core Value

**`-p` を避けつつ curl で Claude を実行できる。** これがすべての設計判断の原点。

`claude -p`（API クレジット課金）を回避し、対話型 Claude Code TUI を `ht-mcp`（headless terminal MCP サーバ）越しに駆動することで **Max サブスクリプション課金のまま** Claude をプログラマブルに呼び出せる。サブスクリプション課金の維持、対話型 TUI の駆動、ファイル経由の入出力、自己回復機構 — どれもこの一点を成立させるために存在する。

## アーキテクチャ概要

```
[curl] ──HTTP──▶ WebIF (axum) ──MCP(stdio)──▶ ht-mcp ──PTY──▶ claude TUI
                    │                                              │
                    ▼                                              ▼
               turns/ ディレクトリ ◀────────── prompt/result/status ファイル書き出し
```

HTTP リクエストを受けた WebIF は `turns/` に `prompt-<turnId>.txt` を書き、MCP 越しに claude TUI へトリガを送信する。claude TUI は指示を実行し `result-<turnId>.txt` と `status-<turnId>.json` を書き出す。WebIF はファイルの出現をポーリングして結果を回収する。詳細は [HT-PROTOCOL.md](./HT-PROTOCOL.md) を参照。

## 前提依存

- **Rust toolchain**: edition 2021 をサポートする stable Rust（`rustup` でインストール）
- **`ht-mcp` バイナリ**: 別途インストール済みで PATH 上にあるか、`HT_MCP_PATH` 環境変数でパスを指定すること。参考例: `/home/parallels/.cargo/bin/ht-mcp`
- **`claude` CLI**: PATH 上にあり、**Max サブスクリプションで既にログイン済み**であること（`~/.claude/.credentials.json` の OAuth 認証情報に依存）。**`ANTHROPIC_API_KEY` は使用しない**（これが Core Value の根拠）
- **POSIX-like OS**: ファイルの atomic rename（`.tmp` → 本名）を前提とする（[HT-PROTOCOL.md](./HT-PROTOCOL.md) v1.1 §6）

## インストール（PATH 配布）

```bash
just install
```

`just install` を実行すると:

1. リリースビルドを行う（`cargo build --release`）
2. `ht-webif` と `launch-agents.sh` を `~/.local/bin/` にコピーする
3. `agents/*.toml` を `${XDG_CONFIG_HOME:-~/.config}/claude-p/agents/` にコピーする
4. `~/.local/bin` が `PATH` に含まれていない場合は追加手順を表示する

インストール後は任意のディレクトリから `ht-webif` や `launch-agents.sh up` を呼べる。

```bash
# PATH に ~/.local/bin が含まれていない場合は追加する（~/.bashrc / ~/.zshrc 等）
export PATH="$HOME/.local/bin:$PATH"
```

## ビルド（リポジトリ内で直接使う場合）

```bash
cargo build --release
```

## 起動

1. リポジトリ直下で `.env` を用意する:

   ```bash
   cd webif
   cp .env.example .env
   # 必要であれば .env の HT_MCP_PATH を編集
   ```

2. `webif/` から起動する（`dotenvy` が cwd の `.env` を読むため、`webif/` で実行する）:

   ```bash
   cd webif
   cargo run
   ```

   または `just`:

   ```bash
   cd webif
   just run
   ```

3. 起動成功時のログ例:

   ```
   [profile] エージェント: claude
   [profile] ターンディレクトリ: /path/to/ht-mcp-sample/turns/claude
   WebIF 起動: http://127.0.0.1:8080
   ```

4. バインドアドレスは `127.0.0.1:8080`（ループバック専用）。外部から接続したい場合は SSH トンネルやリバースプロキシを使用すること。

### 複数インスタンス運用

`instances.conf` + `just up-all` / `just down-all` / `just agents-status` で複数の WebIF インスタンスを一括管理できる。

> **重要:** `instances.conf` は `launch-agents.sh` を実行した **cwd**（カレントディレクトリ）から読む（`D-03`）。ターン成果物も同じ cwd 基準で `./turns-<port>/<agent>/` に書き出される。任意のディレクトリに `instances.conf` を置き、そのディレクトリで `launch-agents.sh up` を実行すること。

#### instances.conf — 設定ファイル書式

`instances.conf` がインスタンス定義ファイル（cwd から読む）。書式は `<agent> <port> [KEY=VALUE ...]` で、`#` で始まるコメント行と空行は無視される:

```
# instances.conf — 多重インスタンス設定。
# 書式: <agent>  <port>  [KEY=VALUE ...]
# コメント行（# で始まる行）と空行は無視される。
# KEY=VALUE 列は spawn 時に環境変数として export される（eval なし）。

# Claude: ~/.claude/ の OAuth は read-only 共有のため分離不要
claude     8080

# Codex: ~/.codex/ に mutable な session/auth 状態を書くため CODEX_HOME 分離必須
codex      8081  CODEX_HOME=/home/youruser/.codex-instance1

# OpenCode: ~/.config/opencode/ — 共有可（§クレデンシャル分離ガイド を参照）
opencode   8082
```

`KEY=VALUE` の追加列はスペース区切りで複数指定できる（例: `codex 8081 CODEX_HOME=... FOO=bar`）。

#### just コマンドで一括管理

`webif/` で以下を実行する（内部で `scripts/launch-agents.sh` を呼び出す）:

```bash
# 全インスタンスを起動 — /info の agent 名一致まで readiness を確認
just up-all

# 各インスタンスの状態を確認（/info を叩いて agent/status/uptime/turns を表示）
just agents-status

# 全インスタンスを停止（SIGTERM → 5 秒待機 → SIGKILL）
just down-all
```

`up-all` はインスタンスごとに `GET /info` をポーリングし、`agent` フィールドが期待値と一致したら次のインスタンスに進む（最大 60 秒）。起動に失敗した場合はログの末尾 20 行を stderr に出力して終了する。

per-instance 管理ファイル（claude-p 規約準拠）:
- PID: `/tmp/ht-webif-<port>.pid`
- ログ: `/tmp/ht-webif-<port>.log`
- ターン成果物: `<cwd>/turns-<port>/`（`launch-agents.sh` を実行した cwd 基準）

#### ターンディレクトリのコリジョン回避

ターン成果物は常に `<TURNS_DIR>/<agent-name>/` に書き出される（D-16）。`AGENT` が異なれば自動的にサブディレクトリが分離されるため、通常は `TURNS_DIR` を変える必要はない。

同一エージェントを複数ポートで起動する場合は `TURNS_DIR` をポート別に分ける。`launch-agents.sh` はこれを自動的に行う（`TURNS_DIR=<cwd>/turns-<port>` として spawn）。

#### クレデンシャル分離ガイド

エージェントごとにクレデンシャルの書き込み先が異なるため、多重インスタンス時の扱いが変わる:

| エージェント | 認証情報の保存先 | 分離要否 | 理由 |
|------------|----------------|---------|------|
| **claude** | `~/.claude/.credentials.json`（OAuth トークン） | **不要** | トークンは read-only で共有される。セッション状態は `ht-mcp` が管理し `~/.claude/` には書き戻さない |
| **codex** | `~/.codex/`（`auth.json` + セッション状態） | **必須** | `~/.codex/` には mutable な session/auth 状態が含まれるため、同時書き込みで競合が発生する |
| **opencode** | `~/.config/opencode/`（プロバイダ認証） | **不要** | 認証情報（GitHub Copilot OAuth 等）は read-only で参照される。Phase 5 実機検証（2026-06-12）で複数インスタンスでの同時使用に問題なし |

**Codex の CODEX_HOME 分離手順（必須）:**

Codex の場合は `instances.conf` の `KEY=VALUE` 列に `CODEX_HOME` を指定して、インスタンスごとに独立した設定ディレクトリを持たせる:

```
# instances.conf の Codex エントリ例（ユーザ名は実際のものに変更すること）
codex  8081  CODEX_HOME=/home/youruser/.codex-instance1
codex  8082  CODEX_HOME=/home/youruser/.codex-instance2
```

`CODEX_HOME` ディレクトリは事前に作成しておく必要はない（Codex が初回起動時に作成する）。認証情報は `codex login` を各 `CODEX_HOME` で実行してセットアップする:

```bash
CODEX_HOME=/home/youruser/.codex-instance1 codex login
```

> **注意:** `CODEX_HOME` に実際のトークンや秘密値を直接記述しないこと。`instances.conf` に記載する値はディレクトリパスのみ（プレースホルダ `/home/youruser/...` を実際のパスに置き換える）。

#### 直接起動（launcher 不使用）

`launch-agents.sh` を使わず手動で起動する場合:

```bash
# 異なるエージェントを別ポートで起動（TURNS_DIR は agent-name で自動分離）
PORT=8081 AGENT=claude cargo run --release
PORT=8082 AGENT=codex  CODEX_HOME=/home/youruser/.codex-instance1 cargo run --release

# 同一エージェントを複数ポートで起動（TURNS_DIR を明示的に分ける）
PORT=8081 TURNS_DIR=./turns-8081 AGENT=claude cargo run --release
PORT=8082 TURNS_DIR=./turns-8082 AGENT=claude cargo run --release
```

既定値: `PORT=8080`、`TURNS_DIR=./turns`、`AGENT=claude`。`.env` でも設定可能（`.env.example` を参照）。

## 動作確認

依存 (`ht-mcp` / `claude` CLI) が揃っているかと、curl で 1 ターン回せるかを
スモークテストで一括確認できる:

```bash
./scripts/smoke.sh
```

サーバ起動 → `POST /prompt` (wait:true) → 結果表示 → 後片付けまでを 1
コマンドで実行する。失敗時はビルドログの末尾 40 行を stderr に出力する。

## エージェントの追加・設定

ht-webif はエージェントプロファイル（`agents/<name>.toml`）を追加するだけで任意の対話型 CLI エージェントを使用できる（TOML 追加のみ、Rust リビルド不要）。

`agents/<name>.toml` に `[env]` テーブルを書くと、spawn 時に ht-mcp 子プロセスへ環境変数を既定値として注入できる（未設定キーのみ・リテラルのみ、`instances.conf` の `KEY=VALUE` が設定済みならそちらが優先）。Codex の `CODEX_HOME` 分離も `[env]` で宣言的に設定できる（ただし `instances.conf` 記述が優先される）。

### Codex CLI（OpenAI）

**前提条件:**

1. `codex` CLI が PATH 上にあること（`~/.local/bin/codex`）
2. ChatGPT Plus で認証済み: `codex login`（`~/.codex/auth.json` が作成される）
3. プロジェクトディレクトリが信頼済み（`--dangerously-bypass-approvals-and-sandbox` フラグ採用のため不要だが推奨）

**起動:**

```bash
AGENT=codex PORT=8081 cargo run --release
```

**動作確認:**

```bash
bash scripts/e2e-codex.sh
```

基本 E2E（AGNT-01）+ `fresh:true` 履歴隔離（AGNT-02）の 3 段階を自動検証する。
`fresh_mode = "command"` + `clear_command = "/clear"` が確定値（2026-06-12 ロールアウトファイル調査で検証済み）。

### OpenCode（v1.4.3+）

**前提条件:**

1. `opencode` CLI が PATH 上にあること（`~/.opencode/bin/opencode` または `~/.local/share/opencode/bin/opencode`）
2. GitHub Copilot 認証済み（推奨）または他プロバイダ認証済み:
   ```bash
   opencode auth login
   opencode providers list  # 確認用
   ```
3. `/turn` カスタムコマンドを生成する（一度だけ実行）:
   ```bash
   bash scripts/setup-opencode.sh
   # → ~/.config/opencode/commands/turn.md が作成される
   ```
   このコマンドは冪等（既に存在すればスキップ）。`scripts/e2e-opencode.sh` 実行時は自動的に呼び出される。

**既知の制約:**
- トリガーは ASCII のみ有効（`ht-mcp` のマルチバイト無音破棄制約 — Pitfall 1）
- GLM-4.6（OpenRouter デフォルト）は出力規約に不安定 → GitHub Copilot の Claude Haiku 4.5 推奨
- `fresh:true` は `fresh_mode = "respawn"` 方式（プロセス kill+再生成）で動作する
  （`/new` はエージェント選択ダイアログが開くため Enter 2 回必要 — `ht-webif` は 1 回のみ送信）

**起動:**

```bash
AGENT=opencode PORT=8082 cargo run --release
```

**動作確認:**

```bash
bash scripts/e2e-opencode.sh
```

基本 E2E（AGNT-03）+ `fresh:true` 履歴隔離（AGNT-04）の 3 段階を自動検証する。
スクリプトは `scripts/setup-opencode.sh` を自動的に呼び出して前提条件を充足する。

> **Codex 多重インスタンス:** `CODEX_HOME` 分離が必須。手順は §複数インスタンス運用 → クレデンシャル分離ガイドを参照。
> **OpenCode 多重インスタンス:** `~/.config/opencode/` は read-only 参照のため分離不要（Phase 6 実機検証済み）。

## ma-client.sh — マルチエージェント版の薄いラッパ

`just install` 済みなら `ma-client.sh <agent> -p "..."` で agent 名（`instances.conf` の port を自動解決）宛に同期送信できます。ポート番号を指定せずエージェント名で操作でき、`result`/`status` サブコマンドでターン結果取得・全インスタンス状態確認も可能。`launch-agents.sh up` で立てた複数インスタンスへの一括管理向け。詳細は [README-MULTI-AGENT.md §5](README-MULTI-AGENT.md#5-多重インスタンス一括起動--phase-6) を参照。

動作環境の診断は `ma-doctor.sh`（`just install` 後は `ma-doctor.sh` で実行、リポジトリ内では `bash scripts/ma-doctor.sh`）を参照（report-only フル診断、8 セクション、詳細は [README-MULTI-AGENT.md §6](README-MULTI-AGENT.md#6-動作環境の診断ma-doctorsh)）。

## claude-p — curl 不要の薄いラッパ（単一インスタンス向け）

`POST /prompt` を毎回 curl で書く代わりに、`claude-p {port} {prompt}` 一発でターン投入＋結果取得まで完結させるラッパスクリプト。指定ポートにサーバが居なければ自動でデーモン化起動し、既に居れば再利用する。マルチエージェント環境では `ma-client.sh` を使うことを推奨（エージェント名で宛先を指定できる）。

### 基本使い方

```bash
# ポート 8080 に投入（サーバが居なければ自動起動してデーモン化）
./scripts/claude-p 8080 "Rust とは何か 100 字で教えて"

# 長文プロンプトを stdin から渡す
cat my-prompt.txt | ./scripts/claude-p 8080 -
```

### 動作の詳細

- サーバ liveness probe を実行する。応答すれば再利用、無ければ `nohup cargo run --release` で起動して `disown` する
- PID は `/tmp/ht-webif-${PORT}.pid`、ログは `/tmp/ht-webif-${PORT}.log` に書かれる
- 各ポート専用に `webif/turns-${PORT}/` ディレクトリを `TURNS_DIR` として使う（ポート間でターン成果物が混ざらない）
- 投入は非同期（`wait: true` を使わない）。30 秒間隔で `GET /turns/{turn_id}` をポーリング、上限 20 回 = 10 分
- 成功時は **stdout に result 本文のみ**、stderr に進捗ログを出す（パイプ可能）

### サブコマンド

```bash
# 稼働状況確認
./scripts/claude-p status 8080

# 停止（SIGTERM → 5秒待機 → SIGKILL）
./scripts/claude-p stop 8080
```

### 注意点

- サーバはラッパが exit した後もバックグラウンドで稼働を継続する。明示的に止めたい時は `claude-p stop {port}` を使う
- Ctrl-C はラッパだけを止め、ターン処理中のサーバは継続する（curl で叩いている時と同じ挙動）
- `claude` CLI が Max でログイン済みであることは `./scripts/smoke.sh` と同様の前提

## CORS

ht-webif の HTTP API は **既定で全オリジン許可**（フルパーミッシブ `*`）。Web フロントエンドや
別オリジンのページから直接叩ける。絞り込みたい場合は `CORS_ORIGINS` 環境変数にカンマ区切りで
オリジンを指定する:

```bash
CORS_ORIGINS=http://localhost:3000 cargo run --release
# 複数オリジン
CORS_ORIGINS=http://localhost:3000,https://example.com cargo run --release
```

許可メソッドは `GET, POST, OPTIONS`、許可ヘッダは `Content-Type`。Cookie / 認証情報は
扱わないため `Access-Control-Allow-Credentials` は意図的に有効化していない。

## API

すべてのエンドポイントは `http://127.0.0.1:8080` で待ち受ける。レスポンスは JSON。

### `POST /prompt` — ターン投入

Claude へタスクを投入する。既定は**非同期**（`turn_id` を即返す）。

**非同期（既定）:**

```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Rust とは何か 100 字で教えて"}'
```

```json
{
  "turn_id": "20260523-103045-123",
  "status": "accepted"
}
```

**同期（`wait: true`）:** 完了まで最大 700 秒ブロックして結果を返す。

```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "2 + 2 は何？", "wait": true}'
```

```json
{
  "turn_id": "20260523-103045-456",
  "status": "completed",
  "result": "4 です。"
}
```

**`fresh: true`** を指定すると、実行前に `/clear` で claude TUI の文脈をリセットする（`-p` 相当のステートレス一発実行）。

```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "今日の日付は？", "fresh": true, "wait": true}'
```

### `GET /turns/{turn_id}` — ターン状態照会

`turn_id` は数字とハイフンのみ許可（例: `20260523-103045-123`）。

```bash
curl -s http://127.0.0.1:8080/turns/20260523-103045-123
```

**実行中:**

```json
{
  "turn_id": "20260523-103045-123",
  "status": "running"
}
```

**完了後:**

```json
{
  "turn_id": "20260523-103045-123",
  "status": "completed",
  "result": "Rust はシステムプログラミング言語で..."
}
```

**存在しないターン:** `404 Not Found`

### `POST /command` — TUI に生文字列送信

claude TUI に直接キー入力を送る。スラッシュコマンドの実行に使用する。

```bash
curl -s -X POST http://127.0.0.1:8080/command \
  -H 'Content-Type: application/json' \
  -d '{"text": "/clear"}'
```

```json
{
  "sent": "/clear",
  "snapshot": "╭─ Claude Code ─ ... ╮\n│  > │\n╰──────────────────╯"
}
```

`snapshot` フィールドに、コマンド送信後の claude TUI の画面テキストが入る（デバッグや状態確認に使用）。

### `POST /restart` — ht-mcp ごと再起動

ht-mcp プロセスを終了して新たに起動し直す。ht-mcp または claude TUI が wedge（応答不能）になった場合の回復手段。

```bash
curl -s -X POST http://127.0.0.1:8080/restart
```

```json
{
  "status": "restarted",
  "session_id": "<新しい claude セッション ID>"
}
```

## 環境変数

| 変数 | 既定値 | 説明 |
|------|--------|------|
| `HT_MCP_PATH` | `ht-mcp` | `ht-mcp` バイナリのパス。未設定なら PATH 上を探索 |
| `PORT` | `8080` | HTTP listener のポート番号。多重起動時はインスタンス毎に変える |
| `AGENT` | `claude` | 使用するエージェントプロファイル名。`agents/<name>.toml` を読む。未指定なら `claude`（後方互換） |
| `AGENTS_DIR` | （自動探索） | プロファイル TOML の探索ディレクトリ。未設定時は `./agents`（cwd 基準）→ `${XDG_CONFIG_HOME:-~/.config}/claude-p/agents` の順で探索し、見つからなければエラー。`just install` で XDG グローバルに自動コピーされる |
| `TURNS_DIR` | `./turns` | ターン成果物の出力先ベースディレクトリ。**実際の書き込み先は常に `<TURNS_DIR>/<agent-name>/`**（D-16）。これは v1.0 で `TURNS_DIR` を明示指定していた場合と非互換になるため注意 |
| `CORS_ORIGINS` | `*` | CORS 許可オリジン（カンマ区切り）。`*` で全許可。Web フロントから直接叩く場合に絞り込める |

設定の優先順位: **実環境変数 > `.env` > 既定値**（`dotenvy` の標準動作）。`.env.example` をコピーして `.env` を作成し、必要に応じて編集すること。

## ターン成果物

各ターンの実行結果は `turns/<agent-name>/` ディレクトリ（例: `AGENT=claude` のとき `turns/claude/`）に以下の 3 点セットとして保存される:

| ファイル | 書く人 | 内容 |
|----------|--------|------|
| `prompt-<turnId>.txt` | WebIF | タスク指示文（プレーンテキスト） |
| `result-<turnId>.txt` | claude TUI | 成果物本文（`done` 時のみ） |
| `status-<turnId>.json` | claude TUI | 状態・メタデータ（完了シグナル） |

`status-<turnId>.json` の出現が完了シグナル（HT-PROTOCOL §6）。ファイルの書き込みはすべて `.tmp` → `mv` による atomic rename で行われる。詳細は [HT-PROTOCOL.md](./HT-PROTOCOL.md) を参照。

## 制約

- **同時 1 ターン（直列処理）**: `Arc<Mutex<Worker>>` でターンを排他処理する。並列化は将来の worker 増設で対応（v2 以降）
- **ループバック専用、認証なし**: `127.0.0.1:8080` のみ。HTTP 認証は v2 (SEC-01) で予定
- **シングルホスト前提**: WebIF・ht-mcp・claude が同一ファイルシステムを共有すること（`turns/` ディレクトリを共有）
- **タイムアウト**: MCP 呼び出し 30 秒 / 1 ターン 300 秒（最大 2 試行）/ `wait: true` デッドライン 700 秒
- **`ANTHROPIC_API_KEY` 不使用**: Max サブスクリプションの OAuth 認証のみ。`claude -p` は呼ばない

## 詳細仕様

HT-PROTOCOL の詳細（ターン ID 発番規則、status ファイル形式、回復シナリオ、Worker 手順）は [HT-PROTOCOL.md](./HT-PROTOCOL.md) を参照。

## ライセンス

MIT License — 詳細は [LICENSE](./LICENSE) を参照。
