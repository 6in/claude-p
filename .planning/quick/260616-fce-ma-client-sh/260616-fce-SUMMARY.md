---
phase: quick-260616-fce
plan: 01
subsystem: scripts
tags: [bash, curl, multi-agent, instances-conf, jq, python3]

# Dependency graph
requires:
  - phase: quick-260615-t7k
    provides: "launch-agents.sh, instances.conf, just install"
provides:
  - "scripts/ma-client.sh — エージェント名で POST /prompt / GET /turns / GET /info を叩く curl ラッパー"
  - "justfile install/uninstall に ma-client.sh 同梱"
  - "README-MULTI-AGENT.md §5 に ma-client.sh 使用例追記"
  - "README.md に ma-client.sh 一行紹介追記"
affects: [future-multi-agent-workflows]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "JSON_ENCODER 検出: jq 優先、python3 フォールバック、両方なしでエラー exit 1 — launch-agents.sh 規約踏襲"
    - "json_encode_string: jq -Rs. / python3 json.dumps で stdin を JSON 文字列リテラルに変換（T-fce-01 緩和: 文字列連結回避）"
    - "resolve_port: $(pwd)/instances.conf を read -ra fields でパース、最初の agent 一致の port を返す"
    - "サブコマンド dispatch: case '${1:-}' で result/status/-h/--help/空/'*'(=send) に分岐"

key-files:
  created:
    - scripts/ma-client.sh
  modified:
    - justfile
    - README-MULTI-AGENT.md
    - README.md

key-decisions:
  - "GET /turns のステータス完了判定は 'done'（status ファイルの JSON 値）。plan interface_context の 'completed' は誤記 — src/turn.rs の read_turn と src/http.rs の turn_handler_returns_done_when_status_file_exists テストで確認"
  - "リクエストボディは jq -n --argjson / python3 json.dumps で構築。encoder 変数（jq/python3）と body 構築を統一することで安全にエンコードできる"
  - "send サブコマンドは暗黙（第1引数がエージェント名なら cmd_send に委譲）。result/status は明示サブコマンド"

patterns-established:
  - "ma-client.sh が launch-agents.sh と同じ JSON_ENCODER 検出 + json_get_field 実装を自己完結で持つ（重複コード許容、依存関係ゼロ）"

requirements-completed: [MA-CLIENT-01]

# Metrics
duration: 4min
completed: 2026-06-16
---

# Quick Task 260616-fce: ma-client.sh Summary

**エージェント名で instances.conf のポートを自動解決して POST /prompt / GET /turns / GET /info を叩く curl ラッパー（D-1〜D-6 全対応、jq 優先 python3 フォールバック、T-fce-01 JSON injection 緩和済み）**

## Performance

- **Duration:** 4 min
- **Started:** 2026-06-16T02:06:47Z
- **Completed:** 2026-06-16T02:10:27Z
- **Tasks:** 2
- **Files modified:** 4 (scripts/ma-client.sh 新規, justfile, README-MULTI-AGENT.md, README.md)

## Accomplishments

- `scripts/ma-client.sh` 新規作成（397 行）。send/result/status の 3 サブコマンド、D-1〜D-6 全実装。
- `justfile` install/uninstall に ma-client.sh の cp+chmod/rm を追加。`just install` 1 コマンドでバイナリ・ラッパ・ma-client が一括配置される。
- `README-MULTI-AGENT.md` §5 に ma-client.sh の使用例（6 パターン + --async ポーリング例）を日本語で追記。
- `README.md` に ma-client.sh の一行紹介と claude-p（単一インスタンス向け）との棲み分けを追記。

## Task Commits

1. **Task 1: scripts/ma-client.sh 新規作成** — `881ba32` (feat)
2. **Task 2: justfile install/uninstall 同梱 + README 2 本のドキュメント追記** — `3885efe` (feat)

## Verification Results

```
bash -n scripts/ma-client.sh               → OK（syntax エラーなし）
ma-client.sh --help | grep -q send         → OK（"send（既定）" が usage に含まれる）
ma-client.sh 2>&1 | grep -qi result/status → OK
grep -q ma-client.sh justfile              → OK（5 箇所一致）
grep -q ma-client.sh README-MULTI-AGENT.md → OK
grep -q ma-client.sh README.md             → OK
just --list | grep -q install              → OK
cargo fmt --check                          → OK（グリーン）
cargo clippy --all-targets --release -- -D warnings → OK（グリーン）
cargo test --release                       → OK（42/42 テスト通過）
```

## Files Created/Modified

- `scripts/ma-client.sh` — D-1〜D-6 全実装。send/result/status サブコマンド。jq/python3 JSON_ENCODER 検出。instances.conf agent→port 解決。--async/--fresh/--port フラグ。プロンプト: -p / positional / stdin の 3 方式。接続先 127.0.0.1 固定。
- `justfile` — install レシピに `cp scripts/ma-client.sh + chmod +x`、uninstall レシピに `rm -f ~/.local/bin/ma-client.sh` を追加。
- `README-MULTI-AGENT.md` — §5「各インスタンスへプロンプトを送る」末尾に ma-client.sh の使い方を追記（6 例 + --async ポーリング例）。
- `README.md` — `## claude-p` セクション手前に `## ma-client.sh` 一行紹介を追記（claude-p との棲み分け明記）。

## Decisions Made

- **GET /turns の完了判定を "done" に統一:** plan の interface_context は "completed" と記載していたが、サーバの実装 `src/turn.rs:read_turn` および `src/http.rs:turn_handler_returns_done_when_status_file_exists` テストを確認した結果、status ファイルの JSON 値は `{"status":"done"}` であり、GET /turns の応答もそのままこの値を返す。クライアントの完了判定は "done" が正しい。
- **python3 ボディ構築は stdin ルートで統一:** jq ルートは `--argjson` でエンコード済み変数を渡す方式、python3 ルートは `printf '%s' "$prompt" | python3 -c '... json.dumps ...'` で stdin から直接読む方式を採用。変数展開でのシェルエスケープ問題を回避。

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] GET /turns の status 判定: "completed" → "done"**

- **Found during:** Task 1 実装前の src/http.rs + src/turn.rs レビュー
- **Issue:** plan の `<interface_context>` は `status` 値として `"accepted" / "running" / "completed"` と記載していたが、実際の `read_turn`（turn.rs:140）はステータスファイルの JSON `{"status":"done"}` をそのまま返す。GET /turns の完了時 status は `"done"` であり `"completed"` ではない。
- **Fix:** ma-client.sh の cmd_send（同期パス）および cmd_result の完了判定を `"done"` で実装した。
- **Files modified:** scripts/ma-client.sh
- **Verification:** `src/http.rs:turn_handler_returns_done_when_status_file_exists` テストが `Some("done")` をアサートしており、実装と整合することを確認。
- **Committed in:** 881ba32 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug: サーバ API の status 値誤記を修正)
**Impact on plan:** クライアントが完了ターンを "unknown status" として扱うバグを回避。スコープ逸脱なし。

## Known Stubs

なし — 全サブコマンドが実際の HTTP エンドポイントに接続する実装（モック・プレースホルダーなし）。

## Threat Surface Scan

新規ネットワークエンドポイント・auth パス・スキーマ変更なし。bash スクリプトのみ。
threat_model 記載の T-fce-01〜T-fce-03 は全て plan の disposition 通りに処置済み。

| Flag | File | Description |
|------|------|-------------|
| (なし) | — | 新規 network/auth surface なし。T-fce-01: json_encode_string で緩和済み。T-fce-03: 127.0.0.1 固定で緩和済み。 |

## Issues Encountered

なし — plan の verify コマンドで 1 件（`grep -q send` が `--help` に "send" を期待）の軽微な不一致が発見されたため、usage 出力に "send（既定）:" 接頭辞を追加して解決した。

## Next Phase Readiness

- `scripts/ma-client.sh` が利用可能。`launch-agents.sh up` で立ち上げた全エージェントに対して agent 名でプロンプトを送受信できる。
- `just install` で全ツール（ht-webif / launch-agents.sh / ma-client.sh）が PATH に配置される。

---
*Quick task: 260616-fce*
*Completed: 2026-06-16*

## Self-Check: PASSED

- `scripts/ma-client.sh` — FOUND
- `justfile` changes — FOUND (grep ma-client.sh: 5 hits)
- `README-MULTI-AGENT.md` changes — FOUND (grep ma-client.sh: hit)
- `README.md` changes — FOUND (grep ma-client.sh: hit)
- Commit `881ba32` — FOUND
- Commit `3885efe` — FOUND
- cargo test — 42/42 PASSED
