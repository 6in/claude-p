# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — 開発リポジトリ整備

**Shipped:** 2026-06-10
**Phases:** 3 | **Plans:** 13 | **Quick tasks:** 8

### What Was Built
- リポジトリ体裁: README.md・MIT LICENSE・ルート .gitignore・Cargo.toml メタデータ（Phase 1）
- モジュール分割: main.rs ~561 行 → config/mcp/worker/turn/http/lib.rs + wiring-only main.rs ~52 行、挙動完全保存（Phase 2）
- テスト + CI: 11 本のテスト（純粋関数 5 / MCP 3 / HTTP 統合 3）、justfile 6 レシピ、GitHub Actions CI（Phase 3）
- Quick tasks: claude-p ラッパー、CORS、PORT/TURNS_DIR env 化、smoke.sh、cross-build レシピ、CLAUDE.md slim 化

### What Worked
- Wave 方式の段階的モジュール移送（スケルトン → リーフ → 中間 → 最終層）で、各プランがビルド可能な状態を保ったまま分割完了
- trait Mcp 抽出 + デフォルト型パラメータ `Worker<M: Mcp = McpClient>` により main.rs 無変更でテスト土台を導入
- 8 curl smoke test による「挙動完全保存」の実証ゲートが refactor の安心材料として機能

### What Was Inefficient
- ROADMAP.md の進捗集計（4/6 表記）と実態（6/6 完了）の乖離が放置され、クローズ時の確認コストになった
- quick task の status metadata が未記録のまま蓄積し、クローズ監査で 7 件が "unknown" として浮上（実装はすべてコミット済みだった）
- cargo fmt の pre-existing drift（20 箇所）が複数プランをまたいで deferred され続けた

### Patterns Established
- lib/bin 越境の可視性は `pub(crate)` でなく `pub`（bin crate から不可視のため）
- テストは `webif/tests/` でなく各モジュール末尾の `#[cfg(test)] mod tests` に co-locate
- justfile は `set working-directory := 'webif'` で DRY、CI は justfile 非依存で cargo 直叩き

### Key Lessons
1. フェーズ完了時に ROADMAP の Progress テーブルとチェックボックスを同期させること — 乖離はマイルストーンクローズまで発見されない
2. quick task 完了時に status metadata を残すこと — audit-open が "unknown" を積み上げる
3. human-verify が必要な検証（リモート CI の red/green 確認等）は、実施タイミングを明示して繰延を意図的にすること

### Cost Observations
- Model mix: 未計測
- Sessions: 複数セッション（2026-05-23 〜 2026-05-28 に集中）
- Notable: Phase 2 の 4 プランは平均 ~6 分/プランで完走（STATE.md velocity 記録より）

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Sessions | Phases | Key Change |
| v1.0 | — | 3 | 初回マイルストーン — coarse 粒度 3 フェーズ + quick task 並走の運用を確立 |

### Cumulative Quality

| Milestone | Tests | Coverage | Zero-Dep Additions |
| v1.0 | 11 | 未計測 | regex 不採用（std のみで turn_id 検証）等、依存最小化を維持 |

### Top Lessons (Verified Across Milestones)

1. （次マイルストーン以降に検証を持ち越し）
