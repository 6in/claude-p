# Phase 6: Multi-Instance Parallel Foundation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-15
**Phase:** 6-multi-instance-parallel-foundation
**Areas discussed:** /info の status の意味, 処理ターン数のカウント方式, ランチャー設計, クレデンシャル分離方式

---

## /info の status の意味

| Option | Description | Selected |
|--------|-------------|----------|
| idle/busy の2状態 | ターン処理中か。worker_loop が AtomicBool をトグル、/info が読む。lock-free。 | ✓ |
| alive のみ（固定値） | 応答すれば status:"ok"。最小実装だが busy/idle が見えずポーリング価値が低い。 | |
| idle/running/unhealthy の3状態 | unhealthy も区別。ただし health 判定は snapshot(Mutex+MCP往復)が必要で /info を重く・ブロッキングにする。 | |

**User's choice:** idle/busy の2状態
**Notes:** いずれも worker Mutex をブロックせず読める実装に限る（CR-01）。AtomicBool 方式で確定。

---

## 処理ターン数のカウント方式

| Option | Description | Selected |
|--------|-------------|----------|
| メモリ内 AtomicU64 | worker_loop がターン完了毎にインクリメント。uptime と同じ意味論で一貫、restart でリセット。 | ✓ |
| turns_dir の status ファイル数 | リクエスト時に数える。再起動跨ぎで持続するが filesystem 走査コスト + 古いファイル混入。 | |
| total/success/failed 分解 | メモリ内カウンタ 3 本。豊かだが PARA-02 の要求を超える。 | |

**User's choice:** メモリ内 AtomicU64
**Notes:** status の AtomicBool と同じ共有 lock-free 状態に集約する方針。

---

## ランチャー設計

| Option | Description | Selected |
|--------|-------------|----------|
| 新規 launch-agents.sh + claude-p 拡張 | claude-p に AGENT 対応を足し、launch-agents.sh がそれをループ呼び出し。DRY。 | |
| 新規 launch-agents.sh 独立実装 | claude-p は触らず、launch-agents.sh 単体で nohup/PID/info ポーリングを自前実装。 | ✓ |
| claude-p のみ拡張 | claude-p に多起動サブコマンドを集約。ファイルは増えないがスクリプト肥大化。 | |

**User's choice:** 新規 launch-agents.sh 独立実装
**Notes:** claude-p は claude 専用の利用者向けラッパとして現状維持、launch-agents.sh は運用者向けオーケストレータという役割分担。ロジック部分重複は許容。

### 起動セット指定方法

| Option | Description | Selected |
|--------|-------------|----------|
| 引数駆動 + 既定セット | 引数なしで既定3セット、agent:port を引数で上書き可。 | |
| 固定セットのみ | claude:8080 codex:8081 opencode:8082 をハードコード。 | |
| 設定ファイル駆動 | instances.conf に agent:port 一覧を記述して読み込む。 | ✓ |

**User's choice:** 設定ファイル駆動

### 起動後のライフサイクル管理

| Option | Description | Selected |
|--------|-------------|----------|
| up + down-all + status | 起動 + 一括停止(SIGTERM) + status を提供。just up-all/down-all でラップ、/info ポーリングで ready 確認。 | ✓ |
| 起動のみ | 起動 + readiness のみ、停止は手動。 | |
| just up-all/down-all に集約 | スクリプトは起動のみ、ライフサイクル入口は justfile。 | |

**User's choice:** up + down-all + status

---

## クレデンシャル分離方式

### CODEX_HOME 等の分離方法

| Option | Description | Selected |
|--------|-------------|----------|
| instances.conf に列追加しランチャーが自動設定 | 設定ファイルに CODEX_HOME 等の env をインスタンス毎に記述、launcher が spawn 時に export。D-15 と整合。README にも記載。 | ✓ |
| README ドキュメントのみ | 成功基準4の最小限。運用者が手動で CODEX_HOME 設定。launcher は関与せず。 | |

**User's choice:** instances.conf に列追加しランチャーが自動設定

### 分離の検証範囲

| Option | Description | Selected |
|--------|-------------|----------|
| Codex のみ分離、claude/opencode は共有可と明記 | 実害ある Codex のみ CODEX_HOME 分離を手順化、他は共有可を検証・明記。 | |
| 全エージェントで分離手順を用意 | claude/codex/opencode それぞれに専用 HOME/config 分離手順を用意。 | ✓ |

**User's choice:** 全エージェントで分離手順を用意
**Notes:** Phase 5 で繰延された A2/A3（CODEX_HOME / OpenCode インスタンス分離検証）をここで決着。

---

## Claude's Discretion

- `/info` レスポンス JSON の正確な形（フィールド名・追加 session_id 等の載否）
- 共有 lock-free 状態の型と配置（`Arc<InstanceInfo>` 等、atomic Ordering の選択）
- instances.conf のフォーマット詳細（区切り・env 表現・コメント記法・デフォルトファイルのコミット要否）
- launch-agents.sh の内部実装（PID/ログ置き場、readiness タイムアウト値、per-instance TURNS_DIR 割当）
- `/info` の CORS/ルーティング配線（既存 build_router 踏襲）
- 処理ターン数を「成功のみ」か「成功+失敗総数」か

## Deferred Ideas

- status の idle/busy を超える詳細化（running/unhealthy、health チェック）
- 処理ターン数の total/success/failed 分解
- 処理ターン数・uptime の永続化（再起動跨ぎ）— OPS-02 領域
- エージェント間ルーティング/ファンアウト/パイプライン（Out of Scope）
- プロファイル hot-reload（FUT-02）
- 同一プロセス内並列ワーカー（SCALE-01、v3+）
- launch-agents.sh の config への TURNS_DIR/詳細 env 拡張
