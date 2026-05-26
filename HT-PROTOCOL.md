# HT-PROTOCOL — HT内Claude実行規格 v1.1

ht-mcp 経由で「HT(headless terminal)内に常駐する Claude Code」へタスクを投入し、
結果を構造化データとして回収するための規格。

対話型 TUI を使うため課金はサブスクリプション扱いのまま、入出力の信頼性だけを
ファイルベースで担保することを目的とする。

---

## 0. 変更履歴

| 版 | 変更点 |
|---|---|
| v1.0 | 初版。`.ht-jobs/<job-id>/` ディレクトリ + `request.json`/`result.json`/`done` |
| v1.1 | **ターンID** 導入。3点セット（prompt/result/status）をIDで束ねるフラット構成へ。`status.json` の出現を完了シグナルに統合。`waiting_input` 状態を追加。発番を制御側に一元化 |

---

## 1. 登場人物

| 名称 | 実体 | 役割 |
|---|---|---|
| **Orchestrator** | HT-WEB / ループプロセス（制御側） | ターンIDの発番・prompt投入・完了監視・結果回収・履歴管理 |
| **Worker** | HT セッション内に常駐する `claude` TUI | ターンを1件ずつ処理 |
| **Turn** | 1往復の作業単位。`turnId` で識別 | prompt → result/status の1サイクル |

> 原則: **ループはコードで制御、判断は LLM**。ファイル名・ID・発番・ポーリングと
> いった機械的要素はすべて Orchestrator（コード側）が持つ。Worker は「渡された
> ID のファイルを読み書きする」だけで、IDの生成も発番もしない。

---

## 2. アーキテクチャ

```
┌──────────────────────────────────────────────────┐
│ Orchestrator (HT-WEB / ループプロセス)               │
│   ・turnId 発番   ・prompt 書き込み                  │
│   ・status 出現ポーリング   ・result 回収            │
└──────┬───────────────────────────┬────────────────┘
       │ ht_send_keys              │ ファイル read/write
       │ ht_take_snapshot          │ (配置は §7 参照)
       ▼                           ▼
┌────────────────────┐   ┌────────────────────────┐
│ HT セッション         │   │  共有ストレージ           │
│ = Worker            │   │   prompt-<turnId>.txt   │
│ claude TUI 常駐      │◀─▶│   result-<turnId>.txt   │
└────────────────────┘   │   status-<turnId>.json  │
   read prompt /          └────────────────────────┘
   write result+status
```

---

## 3. ターンID（turnId）

### 3.1 形式

```
turnId = <UTCタイムスタンプ・ミリ秒精度> [ -w<workerId> ] [ -<seq> ]
```

- 単一ワーカー（現状）: `20260522-154500-123`   ← `YYYYMMDD-HHMMSS-mmm`
- 並列ワーカー（将来）: `20260522-154500-123-w02` または連番 `20260522-154500-123-007`

### 3.2 規則

- **発番は Orchestrator のみ**。Worker・TUI内Claude には絶対に発番させない。
- ミリ秒精度で同一時刻衝突を回避。なお衝突した場合は Orchestrator が連番
  （`-<seq>`）を付与して一意性を**コードで保証**する。
- 人間がファイル一覧を見て時系列が読めること（可読性）と、機械的一意性の
  両方を満たす。可読性はタイムスタンプ形式、一意性は粒度＋補助要素で担保。
- `turnId` は prompt / result / status の3ファイルで**完全に共有**する。

---

## 4. ファイル仕様

1ターン = 同じ `turnId` を持つ3ファイル。

| ファイル | 書く人 | 内容 |
|---|---|---|
| `prompt-<turnId>.txt`  | Orchestrator | 指示本文（長文・複数行可、プレーンテキスト） |
| `result-<turnId>.txt`  | Worker | 成果物本文（`done` 時のみ。`.tmp`→rename で原子的に） |
| `status-<turnId>.json` | Worker | 状態・メタデータ（**必ず最後**に原子的書き込み） |

### 4.1 prompt-<turnId>.txt

プレーンテキスト。指示本文をそのまま書く。TUI へ打つキーは短いトリガのみに
保ち、長文・改行・特殊文字はすべてこのファイルに入れる。
`timeout` などの制御メタは Orchestrator 側が保持し、ファイルには入れない。

### 4.2 result-<turnId>.txt

成果物本文。プレーンテキスト。巨大化してよい（画面ではなくファイルなので安全、
かつ JSON エスケープ不要）。`status` が `done` のときのみ生成。

### 4.3 status-<turnId>.json

```json
{
  "turn_id": "20260522-154500-123",
  "status": "done",
  "started_at": "2026-05-22T15:45:00.123Z",
  "finished_at": "2026-05-22T15:45:48.900Z",
  "summary": "READMEを3行に要約した",
  "files_changed": [
    { "path": "src/foo.ts", "action": "modified" }
  ],
  "error": null,
  "question": null
}
```

| フィールド | 必須 | 説明 |
|---|---|---|
| `turn_id` | ✅ | prompt と一致 |
| `status` | ✅ | `done` / `failed` / `waiting_input`（§5） |
| `started_at` / `finished_at` | ✅ | ISO8601 (UTC, ミリ秒) |
| `summary` | ✅ | 1行要約 |
| `files_changed` | — | 変更ファイル一覧。`action`: `created`/`modified`/`deleted` |
| `error` | ✅ | `failed` 時のメッセージ。それ以外は `null` |
| `question` | ✅ | `waiting_input` 時に Orchestrator へ尋ねたい内容。それ以外は `null` |

---

## 5. 状態（status）

| status | 意味 | `result.txt` | 次のアクション |
|---|---|---|---|
| `done` | 正常完了 | あり | Orchestrator が result を回収。ターン終了 |
| `failed` | 失敗 | なし/部分的 | `error` を読む。ターン終了（失敗） |
| `waiting_input` | 追加入力待ちで中断 | なし | `question` を読み、Worker へ回答を送って継続（§8.3） |

---

## 6. 完了検知（センチネル）

- `status-<turnId>.json` の**出現**が完了シグナル。専用の `done` ファイルは持たない。
- Worker は書き込み順序を厳守する:
  1. （`done` 時）`result-<turnId>.txt.tmp` に書く → `mv` で `result-<turnId>.txt` にrename
  2. `status-<turnId>.json.tmp` に書く → `mv` で `status-<turnId>.json` にrename
- `status` の原子的 rename により、ファイルが「出現した時点で中身は完全」が保証される。
  result が先に完成しているため、status 出現 = result も完全。

> **二段ポーリング注意**: 出現監視で捕まえられるのは初回だけ。`waiting_input`
> から `done` への遷移は同一ファイルの書き換えになるため、初回読み取り後は
> `status.json` の **mtime（または内容）変化**を追う必要がある（§8.3）。

---

## 7. ファイル配置（⚠ 未確定 — びんさん確認待ち）

3ファイルをコンテナ内のどこに置き、Orchestrator がどう読むか。タイムスタンプ
運用では履歴ファイルが蓄積するため、以下のいずれかで確定する。

- **案A（推奨）: 共有ボリューム** — HT コンテナと Orchestrator(HT-WEB) が共有
  ボリュームをマウントし、Orchestrator はホスト側から直接 read/write する。
  Monitor 用の追加 HT セッションも `ht_execute_command` での都度 `cat` も不要。
  Spirit Room の「共有ボリュームにフラグを書く」運用と地続き。
- **案B（フォールバック）: HT Monitor セッション** — 共有ボリュームが無い場合、
  素の bash の HT セッションをもう1つ立てて Monitor とし、`ht_execute_command`
  で `test -f` / `cat` によりポーリングする。

→ 確定したら本セクションと §8 を更新する。

---

## 8. Orchestrator手順

### 8.1 起動・ブートストラップ

1. HT セッションを作成し `claude` を起動。
2. `auto mode on` をスナップショットで確認（OFFなら `Shift+Tab`）。
3. ブートストラップメッセージを1回だけ送信:

```
あなたはHTワーカーです。HT-PROTOCOL.md の「§9 Worker手順」に従ってください。
私が各ターンで prompt/result/status のファイル名を明示するので、その指示どおり
読み書きしてください。turnId の発番はしません。準備ができたら「READY」とだけ返答。
```

### 8.2 ターン投入 `dispatch(instruction)`

```
turnId = generate_turn_id()              # §3。発番は Orchestrator のみ
write  prompt-<turnId>.txt  = instruction
ht_send_keys(Worker, [
  "ターン実行: prompt-<turnId>.txt を読んで実行。",
  " 成果物→ result-<turnId>.txt（.tmp経由でrename）",
  " 状態→ status-<turnId>.json", "Enter"])
return turnId
```

> `ht_send_keys` の指示文には3ファイル名（＝同一 turnId）を**明示**する。
> Worker が書き先を取り違えないため。

### 8.3 完了待ち・回収 `collect(turnId, timeout_sec)`

```
deadline = now + timeout_sec
last_mtime = none
loop:
  if exists(status-<turnId>.json):
      st = read_json(status-<turnId>.json)
      if st.mtime == last_mtime: continue        # 未更新はスキップ
      last_mtime = st.mtime

      if st.status == "done":
          return read(result-<turnId>.txt)        # ターン完了
      if st.status == "failed":
          return FAILED(st.error)
      if st.status == "waiting_input":
          answer = decide(st.question)            # Orchestratorが判断
          ht_send_keys(Worker, [answer, "Enter"])
          continue                                 # mtime変化を待ち継続
  if now > deadline:
      snap = ht_take_snapshot(Worker)             # 停止箇所を診断
      return TIMEOUT(snap)
  sleep(poll_interval)                            # 既定 3〜5 秒
```

---

## 9. Worker手順（HT内Claudeが従う）

トリガメッセージで指定された `prompt-<turnId>.txt` を受けたら:

1. `prompt-<turnId>.txt` を読む。
2. 指示を実行する。
3. （成功時）成果物を `result-<turnId>.txt.tmp` に書き → `mv` で
   `result-<turnId>.txt` にrename（原子的）。
4. **最後に** `status-<turnId>.json` を `.tmp`→`mv` で原子的に書く。
   - 成功 → `status:"done"`
   - 失敗 → `status:"failed"`, `error` 記入（`result` は無くてよい）
   - 追加入力が要る → `status:"waiting_input"`, `question` 記入。回答が来たら
     作業を続行し、完了後に同じ `status-<turnId>.json` を `done` で上書き。
5. turnId は指示で渡されたものを使う。**自分で発番・生成しない**。

> result と status の順序厳守。status が先に出ると不完全な result を読まれる。

---

## 10. エラー処理

| 事象 | 検知 | 対応 |
|---|---|---|
| Worker がエラー | `status:"failed"` | `error` を読んで処理 |
| 追加入力待ち | `status:"waiting_input"` | `question` を読み、回答を `ht_send_keys`（§8.3） |
| タイムアウト | 期限内に status 出現/更新なし | Worker をスナップショット。`Esc` で中断 → 失敗扱い |
| 許可ダイアログで停止 | status 不在 + スナップショットにダイアログ | Orchestrator が判断して応答キー送信 |
| TUI クラッシュ | スナップショットがシェルプロンプト | Worker 再起動 → ブートストラップやり直し |

---

## 11. 履歴とクリーンアップ

タイムスタンプ運用により、全ターンの prompt/result/status がそのまま時系列の
ファイル列として残る。これは**修行のリプレイ・振り返り**の資産であり、
Spirit Room の「設計意図・判断根拠の蓄積」と同じ価値を持つ。

したがって古いファイルの整理は **delete ではなく archive/rotate** とする:

- **hot 領域** — 進行中・直近のターン。Orchestrator が監視する作業ディレクトリ。
- **archive 領域** — 完了済みターンを turnId 単位で移送。履歴として保全。

「掃除」は hot 領域を軽く保つための **archive への移動**であって、履歴の破棄
ではない。

---

## 12. 制約・注意

- **直列処理**: 1 Worker = 同時1ターン。並列化は Worker（HTセッション）を複数立て、
  `turnId` に `-w<workerId>` を付けて名前空間を分離する。
- **auto mode は ON** を維持（ツール呼び出しでブロックしないため）。
- **TUIへ打つのは短いトリガのみ**。長文は `prompt-<turnId>.txt` 経由。
- **原子的書き込み**: result も status も `.tmp`→`mv`。status は必ず最後。
- **発番は制御側**: turnId・ファイル名は Orchestrator が一意性を保証する。
- `turn_id` フィールドは3ファイルで一致させる。

---

## 13. シーケンス例

```
Orchestrator: turnId = 20260522-154500-123                 (発番)
Orchestrator: write prompt-20260522-154500-123.txt
              = "READMEを3行に要約して"
Orchestrator: ht_send_keys(Worker,
              "ターン実行: prompt-20260522-154500-123.txt を読んで実行。
               成果物→ result-20260522-154500-123.txt …" + Enter)
Worker:       prompt を読む → 要約
Worker:       result-...-123.txt.tmp → mv result-...-123.txt
Worker:       status-...-123.json.tmp → mv status-...-123.json  (status:"done")
Orchestrator: status-20260522-154500-123.json の出現を検知
Orchestrator: status="done" → result-20260522-154500-123.txt を読む
Orchestrator: 完了済みターンを archive へ移送 → 次の turnId を発番 …
```
