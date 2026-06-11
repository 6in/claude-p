# ht-webif 紹介ブログ 骨子

**媒体:** Zenn / 個人技術ブログ（日本語）
**想定分量:** 約 1,500 字 / 5 分読了
**主軸メッセージ:** *Max サブスクリプションを維持したまま、curl 1発で Claude を駆動できる*
**想定読者:** Claude Max を契約済みで Claude Code TUI を日常使いしている個人開発者・エンジニア

---

## タイトル案（3 案）

1. **「Max サブスクのまま curl で Claude を叩く — `claude -p` を使わない HTTP WebIF を作った」**
   主軸メッセージ直球。SEO 的にもクエリにかかりやすい。
2. **「`claude -p` の API 課金を回避する curl 駆動ラッパを Rust で作った話」**
   「課金を回避」を前面に出す煽り強め版。技術記事として読まれやすい。
3. **「対話型 Claude Code を ht-mcp 越しに叩いて、curl で動かす — ht-webif のしくみ」**
   仕組み寄り。エンジニア向け、内容で選ぶ読者向け。

> 推奨: **案 1**（主軸とタイトルが一致、読者の検索意図にも合致）

---

## リード文（約 150 字）

> Claude Max を契約しているのに、シェルスクリプトや自動化ループから Claude を呼ぼうとすると `claude -p` で API クレジット課金が発生してしまう。
> サブスク内で完結させたい。けれど対話型 TUI を `expect` で叩くのは脆い。
>
> そこで `ht-mcp` (headless terminal MCP) 越しに Claude Code TUI を駆動し、`curl` 1発でタスク投入と結果取得を完結させる薄い HTTP WebIF を Rust で作った。

---

## 章構成

### 1. なぜ作ったか — `claude -p` を避けたい（約 200 字）

- Claude Max を契約済みなら、API 経由ではなくサブスク枠で Claude を回したい
- `claude -p` は便利だが **API クレジット課金** が発生する（Max とは別請求）
- 対話型 TUI を `tmux` + `expect` で叩く方式は脆い・PTY 制御が面倒
- 「curl 1発で Claude にタスクを送って結果を受け取る」をサブスク維持で実現したい

### 2. ht-webif がやること（約 200 字）

- HTTP POST でプロンプトを投げる → JSON で結果が返る、それだけ
- 課金経路は **Max サブスクの OAuth (`~/.claude/.credentials.json`)** のみ
- `ANTHROPIC_API_KEY` は使わない / `claude -p` も呼ばない
- ターンは直列処理（同時 1 件）、`turns/` ディレクトリにすべての入出力が残る

### 3. アーキテクチャ — `ht-mcp` で対話型 TUI を駆動する（約 350 字）

データフロー図（README から流用）:

```
[curl] ─HTTP─▶ WebIF (axum) ─MCP(stdio)─▶ ht-mcp ─PTY─▶ claude TUI
                  │                                       │
                  ▼                                       ▼
              turns/ ◀──── prompt / result / status ファイル
```

- **WebIF (axum)**: HTTP を受けてターン ID を発番、`turns/prompt-<id>.txt` に書き出す
- **ht-mcp**: stdio MCP サーバ、claude TUI を子プロセスとして PTY で抱える
- **claude TUI**: 普段ユーザが対話で使うもの。今回はプロンプト末尾の「出力規約」に従って `result-<id>.txt` と `status-<id>.json` を書き出す
- **status ファイルの出現 = 完了シグナル** — インメモリでジョブ管理せず、ファイルシステムを唯一の真実にする
- TUI が wedge したら `ht-mcp` ごと再起動して新しいセッションを立てる **shared-fate recovery**

### 4. 使い方 — `curl` 1 発（約 250 字）

最小例:

```bash
curl -s -X POST http://127.0.0.1:8080/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Rust とは何か 100 字で教えて", "wait": true}'
```

```json
{ "turn_id": "20260527-...", "status": "completed", "result": "Rust は ..." }
```

- 非同期 (`wait` なし) + `GET /turns/{id}` ポーリングも可
- `fresh: true` で `/clear` 相当のステートレス実行（`-p` 代替）
- 同梱の `scripts/claude-p` を使えば curl すら不要で `claude-p 8080 "..."` 1発

### 5. つまずきポイントと割り切り（約 200 字）

- **同時 1 ターン直列処理** — 並列化は worker 増設で対応する設計（v1 では非対応）
- **ループバック専用・認証なし** — `127.0.0.1:8080` のみ、外から叩くなら SSH トンネル
- **シングルホスト前提** — WebIF / ht-mcp / claude が `turns/` ディレクトリを共有
- **タイムアウト**: MCP 30 秒 / 1 ターン 300 秒 / `wait:true` は最大 700 秒
- 万一 TUI が固まっても `POST /restart` で丸ごと立て直せる

### 6. まとめ（約 150 字）

- Max サブスク維持のまま、curl でプログラマブルに Claude を呼べる
- 対話型 TUI を切り離すのではなく **対話のまま叩く** のがミソ
- Rust + axum + tokio で単一バイナリ、ファイルシステム = 状態
- リポジトリ: `github.com/<your>/ht-mcp-sample/webif`（後で差し替え）
- フィードバック・Issue 歓迎

---

## キーフレーズ集（本文執筆時に効かせたい語）

- **「Max サブスクのまま」** — リード・主軸・まとめで 3 回繰り返す
- **「curl 1 発」** — タイトル・リード・章 4 で必出
- **「対話型 TUI を `ht-mcp` 越しに駆動」** — 章 3 の説明軸
- **「ファイルシステムを唯一の真実 (state store)」** — 設計判断の独自性
- **「shared-fate recovery」** — 自己回復機構の名前付け
- **「`-p` を避ける」** — Core Value、メタ的にも繰り返す

## 想定 CTA（記事末尾）

- リポジトリへの誘導（GitHub URL）
- `scripts/smoke.sh` 1 発で動作確認できる旨を再強調
- 似た悩み（`claude -p` 課金回避）を持つ人への共有

## 字数感まとめ

| 章 | 字数目安 |
|----|----------|
| リード | 150 |
| 1. なぜ作ったか | 200 |
| 2. ht-webif がやること | 200 |
| 3. アーキテクチャ | 350 |
| 4. 使い方 | 250 |
| 5. つまずきポイント | 200 |
| 6. まとめ | 150 |
| **合計** | **約 1,500 字** |

---

## レビューしてほしい観点（ユーザ向け）

1. **タイトル案 1〜3 のうちどれで行くか**（あるいは別案）
2. **章立ては 6 章でよいか** — 章 5「つまずきポイント」を削って 5 章にして本文を厚くする案もあり
3. **コードブロックの粒度** — README から流用するか、簡略化するか
4. **CTA に GitHub URL を載せるか**（リポジトリ未公開ならどうするか）
5. **「`-p` を避ける」を煽り気味に書くか、ニュートラルに書くか**

---

## 次タスク（本文執筆フェーズ）

骨子に対するフィードバックを反映して、次の `/gsd-quick` で本文を Markdown 記事として書き起こす。
出力先候補: `.planning/quick/260527-XXX-blog-post-tool-intro/260527-XXX-POST.md`
