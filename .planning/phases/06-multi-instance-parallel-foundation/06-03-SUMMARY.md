---
phase: 06-multi-instance-parallel-foundation
plan: 03
subsystem: docs
tags: [readme, multi-instance, instances-conf, credential-isolation, codex, opencode, justfile]

# Dependency graph
requires:
  - phase: 06-02
    provides: "instances.conf 書式、scripts/launch-agents.sh（up/down-all/status）、justfile up-all/down-all/agents-status レシピ"
  - phase: 06-01
    provides: "GET /info endpoint（agent/port/status/uptime_secs/turns_processed）— just agents-status の /info 表示の根拠"
  - phase: 05-codex-cli-and-opencode-validation
    provides: "Codex CODEX_HOME 分離の根拠（~/.codex/ mutable）、OpenCode ~/.config/opencode/ 共有可の Phase5 実機検証"
provides:
  - "README.md §複数インスタンス運用: instances.conf 書式説明 + just up-all/down-all/agents-status 使用例 + クレデンシャル分離表（claude/codex/opencode）"
  - "Codex CODEX_HOME 分離手順（instances.conf KEY=VALUE 列 + codex login 手順）"
  - "OpenCode 共有可の根拠（Phase 5 実機検証 2026-06-12 明記）"
  - "D-11 決着: CODEX_HOME / OpenCode インスタンス分離検証の結論を README に反映"
affects: [future-users, future-multi-agent]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "instances.conf KEY=VALUE 列でエージェント別 env を宣言する規約（README に文書化）"
    - "クレデンシャル分離判断基準: ~/.xxx/ が mutable（read/write）なら分離必須、read-only なら共有可"

key-files:
  created: []
  modified:
    - README.md

key-decisions:
  - "claude: ~/.claude/ OAuth は read-only 共有可（セッション状態は ht-mcp 管理、~/.claude/ への書き戻しなし）"
  - "codex: CODEX_HOME 分離必須（~/.codex/ は mutable session/auth 状態を含む。同時書き込みで競合発生）"
  - "opencode: ~/.config/opencode/ は read-only 参照のみ、分離不要（Phase 5 実機検証 2026-06-12 根拠）"
  - "D-11 決着: Phase 5 で繰延されていた CODEX_HOME / OpenCode 分離検証を README に明記して完了"
  - "OpenCode エージェント節の旧注記（Phase 6 で検討予定）を検証済み結論に更新"

patterns-established:
  - "Pattern: エージェント別クレデンシャル分離ガイドを表形式（agent/保存先/分離要否/理由）で README に記載"
  - "Pattern: CODEX_HOME 分離手順は instances.conf コメント例 + codex login コマンド例をセットで掲載"

requirements-completed: [PARA-04]

# Metrics
duration: 1min
completed: 2026-06-15
---

# Phase 6 Plan 03: README 多重インスタンス + クレデンシャル分離ガイド

**instances.conf 書式と just up-all/down-all/agents-status 手順、claude/codex/opencode のクレデンシャル分離ガイド（CODEX_HOME 分離手順付き）を README §複数インスタンス運用節に追加し、D-11（Phase 5 繰延の分離検証）を決着させた**

## Performance

- **Duration:** 1 min
- **Started:** 2026-06-15T07:49:36Z
- **Completed:** 2026-06-15T07:51:00Z
- **Tasks:** 1
- **Files modified:** 1 (README.md)

## Accomplishments

- `README.md §複数インスタンス運用`: 既存の手動起動例（旧 §72-86）を instances.conf 駆動の包括的なガイドに更新
- instances.conf 書式（`<agent> <port> [KEY=VALUE ...]`、コメント/空行スキップ）を説明、3行デフォルト例（claude:8080 / codex:8081 CODEX_HOME=... / opencode:8082）を掲載
- `just up-all` / `just agents-status` / `just down-all` の使用例と各コマンドの動作説明を追加
- クレデンシャル分離ガイドを表形式で: claude=共有可（OAuth read-only/理由明記）、codex=CODEX_HOME 分離必須（手順付き）、opencode=共有可（Phase 5 実機検証根拠明記）
- TURNS_DIR コリジョン回避（D-16 per-port 自動分離）と per-instance 管理ファイル規約を説明
- 直接起動（launcher 不使用）のコマンド例を §直接起動節として保持
- OpenCode エージェント節の旧注記（「Phase 6 で検討予定」）を検証済み結論に更新（D-11 決着）

## Task Commits

Each task was committed atomically:

1. **Task 1: README 多重インスタンス + クレデンシャル分離ガイド更新** - `1243b6f` (docs)

## Files Created/Modified

- `README.md` — §複数インスタンス運用節を instances.conf 書式 + just コマンド + クレデンシャル分離ガイドに更新（旧 15 行 → 89 行追加）

## Decisions Made

- claude の共有可根拠を README に明記: OAuth トークンは read-only で共有される、セッション状態は ht-mcp 管理で `~/.claude/` への書き戻しなし
- codex の CODEX_HOME 分離手順を具体的に記載: instances.conf の KEY=VALUE 列 + `CODEX_HOME=/home/youruser/.codex-instance1 codex login` コマンド例
- opencode の共有可根拠を Phase 5 実機検証（2026-06-12）に紐付けて明記（D-11 決着）
- 直接起動の手動コマンド例（旧 §複数インスタンス運用の内容）は §直接起動節として残し、launcher 不使用ユーザへの配慮を継続

## Deviations from Plan

None - plan executed exactly as written. README update covered all acceptance criteria on first attempt.

## Known Stubs

None - 全項目実装済み。クレデンシャル例はすべてプレースホルダパス（`/home/youruser/...`）のみで実トークン・実秘密値の記載なし（T-06-06 mitigate）。

## Threat Surface Scan

| Flag | File | Description |
|------|------|-------------|
| (none) | — | README 更新のみ。新規コードパス・エンドポイント・ファイルアクセスなし。T-06-06: クレデンシャル例はプレースホルダのみ（実値なし）— 実装確認済み |

## Issues Encountered

None.

## User Setup Required

None - README は文書のみ。Codex 多重インスタンスを実際に使用する際は `CODEX_HOME=/home/youruser/.codex-instance1 codex login` を各インスタンスで実行する必要があるが、これは README に手順として記載済み。

## Next Phase Readiness

- Phase 6 完了: GET /info（Plan 01）+ 多重インスタンスオーケストレータ（Plan 02）+ README ガイド（Plan 03）
- D-11 決着: CODEX_HOME / OpenCode インスタンス分離検証の結論が README に反映済み
- v2.0 マルチエージェント対応 milestone の全要件が充足

---
*Phase: 06-multi-instance-parallel-foundation*
*Completed: 2026-06-15*

## Self-Check: PASSED

- `README.md` modified: FOUND (1243b6f — 89 lines added)
- `instances.conf` mentioned in README: FOUND
- `up-all` mentioned in README: FOUND
- `CODEX_HOME` mentioned in README: FOUND
- `down-all` mentioned in README: FOUND
- Task commit `1243b6f`: FOUND
