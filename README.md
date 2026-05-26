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

## ビルド

```bash
cd webif
cargo build --release
```

## 起動

1. `webif/` 直下で `.env` を用意する:

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
   ht-mcp パス: /home/parallels/.cargo/bin/ht-mcp
   claude セッション: <session-id>
   ターンディレクトリ: /path/to/ht-mcp-sample/turns
   WebIF 起動: http://127.0.0.1:8080
   ```

4. バインドアドレスは `127.0.0.1:8080`（ループバック専用）。外部から接続したい場合は SSH トンネルやリバースプロキシを使用すること。

### 複数インスタンス運用

同一ホストで複数の WebIF を走らせる場合は `PORT` と `TURNS_DIR` を分けて起動する:

```bash
PORT=8081 TURNS_DIR=./turns-8081 cargo run --release
PORT=8082 TURNS_DIR=./turns-8082 cargo run --release
```

既定値はそれぞれ `8080` と `./turns`。`.env` でも設定可能（`.env.example` を参照）。

## 動作確認

依存 (`ht-mcp` / `claude` CLI) が揃っているかと、curl で 1 ターン回せるかを
スモークテストで一括確認できる:

```bash
./scripts/smoke.sh
```

サーバ起動 → `POST /prompt` (wait:true) → 結果表示 → 後片付けまでを 1
コマンドで実行する。失敗時はビルドログの末尾 40 行を stderr に出力する。

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
| `TURNS_DIR` | `./turns` | ターン成果物の出力先ディレクトリ。多重起動時は PORT と一緒に分離する |

設定の優先順位: **実環境変数 > `.env` > 既定値**（`dotenvy` の標準動作）。`.env.example` をコピーして `.env` を作成し、必要に応じて編集すること。

## ターン成果物

各ターンの実行結果は `turns/` ディレクトリ（起動時の CWD からの相対パス）に以下の 3 点セットとして保存される:

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
