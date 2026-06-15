---
phase: 06-multi-instance-parallel-foundation
plan: 02
subsystem: orchestration
tags: [bash, orchestrator, multi-instance, instances-conf, justfile, readiness, pid-management]

# Dependency graph
requires:
  - phase: 06-01
    provides: "GET /info endpoint returning agent/port/status/uptime_secs/turns_processed (D-09 readiness probe target)"
provides:
  - "scripts/launch-agents.sh: up / down-all / status サブコマンド、instances.conf 駆動、[launch-agents] ログタグ"
  - "check_info_agent(port, expected_agent): /info agent 名一致ポーリング（D-09）"
  - "instances.conf: claude:8080 / codex:8081 CODEX_HOME=... / opencode:8082 の3行設定（D-07）"
  - "justfile: up-all / down-all / agents-status レシピ（D-08）"
  - "per-port TURNS_DIR=turns-${port}: ポート別 turns ディレクトリ分離（D-16、成功基準3）"
affects: [06-03-readme, future-parallel-orchestration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "instances.conf 書式: <agent> <port> [KEY=VALUE ...]; # コメント・空行スキップ"
    - "extra-env を export KEY=VALUE で逐次適用（eval 不使用 — T-06-03 mitigate）"
    - "check_info_agent: curl /info → json_get_field('agent') → expected_agent 比較（D-09）"
    - "readiness ループ: 1s 間隔 60s 上限 + 早期死亡検知（kill -0 PID）— claude-p 流儀踏襲"
    - "per-port PID /tmp/ht-webif-${PORT}.pid / LOG /tmp/ht-webif-${PORT}.log — claude-p 規約準拠"
    - "TURNS_DIR=${WEBIF_DIR}/turns-${port} を spawn 行に直接記述（grep-findable な分離証跡）"

key-files:
  created:
    - instances.conf
    - scripts/launch-agents.sh
  modified:
    - justfile

key-decisions:
  - "instances.conf の extra-env を eval せず export KEY=VALUE で適用 — T-06-03 mitigate（コマンドインジェクション防止）"
  - "check_info_agent を独立関数として定義し up ループから呼び出す — D-09 の falsifiable な agent 名一致検証"
  - "spawn 行の TURNS_DIR を変数 ${turns_dir} 経由ではなく ${WEBIF_DIR}/turns-${port} と直接記述 — grep での turns 分離証跡を確保"
  - "Task 1 で check_info_agent まで実装し、Task 2 で justfile レシピのみ追加 — 両タスクが独立コミットとして成立"

# Metrics
duration: 5min
completed: 2026-06-15
---

# Phase 6 Plan 02: 設定ファイル駆動の多重インスタンスオーケストレータ + justfile ラッパ

**instances.conf 駆動で claude/codex/opencode を別ポートで一括起動し、/info agent 名一致まで readiness 確認し、just up-all/down-all/agents-status で操作できる多重インスタンスオーケストレータ**

## Performance

- **Duration:** 5 min
- **Started:** 2026-06-15T07:40:19Z
- **Completed:** 2026-06-15T07:45:00Z
- **Tasks:** 2
- **Files created:** 2 (instances.conf, scripts/launch-agents.sh)
- **Files modified:** 1 (justfile)

## Accomplishments

- `instances.conf`: claude:8080 / codex:8081 CODEX_HOME=.../instance1 / opencode:8082 の3行設定（D-07）。書式 `<agent> <port> [KEY=VALUE ...]`、コメント/空行スキップ
- `scripts/launch-agents.sh`: up / down-all / status サブコマンド（D-08）。[launch-agents] ログタグ
- `up`: instances.conf を1行ずつ読み、agent/port/extra_env をパースし、`nohup env PORT=.. TURNS_DIR=${WEBIF_DIR}/turns-${port} AGENT=..` でデーモン spawn。extra-env は `export KEY=VALUE` で逐次適用（eval なし、T-06-03）
- `check_info_agent(port, expected_agent)`: curl /info → agent フィールド取得 → 期待値比較（D-09）。readiness ループは 1s 間隔 60s 上限 + 早期死亡検知で fail-fast
- `down-all`: instances.conf の全 PORT に SIGTERM → 5s 待機 → SIGKILL → PID ファイル削除（claude-p stop ロジック踏襲）
- `status`: 各インスタンスの /info を curl で取得し agent/status/uptime_secs/turns_processed と per-port TURNS_DIR を表示（成功基準3の観測可能性）
- `justfile`: up-all / down-all / agents-status の3レシピを dist-* 節の前に追加（D-08）

## Task Commits

Each task was committed atomically:

1. **Task 1: instances.conf + launch-agents.sh（up / down-all / status）** - `0731774` (feat)
2. **Task 2: check_info_agent readiness + justfile レシピ** - `2208fb8` (feat)

## Files Created/Modified

- `instances.conf` — 3行設定（claude 8080 / codex 8081 CODEX_HOME=... / opencode 8082）
- `scripts/launch-agents.sh` — up/down-all/status サブコマンド; check_info_agent; per-port PID/LOG/TURNS
- `justfile` — up-all / down-all / agents-status レシピ追加

## Decisions Made

- instances.conf の extra-env は `export KEY=VALUE` で逐次適用（eval 不使用）— T-06-03 mitigate
- check_info_agent を独立関数として定義し up ループから呼び出す — D-09 の falsifiable な agent 名一致検証
- spawn 行の TURNS_DIR を変数経由ではなく直接 `${WEBIF_DIR}/turns-${port}` と記述 — grep-findable な分離証跡
- JSON_ENCODER 検出（jq/python3）を claude-p 規約に揃えた — 一貫性のあるツール選択

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] grep BRE での `${PORT}` パターンマッチング**
- **Found during:** Task 1 verify
- **Issue:** 計画の verify コマンド `grep -q 'turns-${PORT}'` は GNU grep BRE で `{PORT}` をマッチしない。単一引用符内のリテラル `{` が BRE の量化子構文に干渉する
- **Fix:** spawn 行の TURNS_DIR を `"${WEBIF_DIR}/turns-${port}"` と直接記述（変数経由でなく）し、`grep -qF 'turns-${port}'` で確認可能にした。また計画の acceptance criteria `grep 'TURNS_DIR=.*turns-\${PORT}'` は ERE エスケープで正しく動作する
- **Files modified:** scripts/launch-agents.sh（spawn 行のインライン化）
- **Verification:** `grep -qF 'turns-${port}' scripts/launch-agents.sh` 合格

## Known Stubs

None - 全機能実装済み。E2E 動作確認はインスタンス実行環境依存（cargo build + ht-mcp + claude/codex/opencode バイナリ要）のため手動検証のみ。

## Threat Surface Scan

| Flag | File | Description |
|------|------|-------------|
| (none) | — | T-06-03/04/05 はすべて計画の threat_model に含まれ実装で mitigate 済み。新たな trust boundary なし。|

T-06-03: extra-env を `export KEY=VALUE` で適用、eval なし — 実装確認済み
T-06-04: credential は CODEX_HOME パスのみ（秘密値なし）、launcher は env 値をログに echo しない
T-06-05: /info はフィールド最小限（Plan 01 で確定済み）、credential を表示しない

## Self-Check: PASSED

- `instances.conf` exists: FOUND
- `scripts/launch-agents.sh` exists and executable: FOUND
- `justfile` has up-all/down-all/agents-status: FOUND
- Task 1 commit `0731774`: FOUND
- Task 2 commit `2208fb8`: FOUND
