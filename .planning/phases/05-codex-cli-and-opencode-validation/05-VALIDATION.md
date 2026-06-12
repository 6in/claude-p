---
phase: 5
slug: codex-cli-and-opencode-validation
status: approved
nyquist_compliant: true
wave_0_complete: true
created: 2026-06-12
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (既存・27 件グリーン) — リグレッションチェックのみ。E2E は live bash スクリプト |
| **Config file** | none — `cargo test` をプロジェクトルートで実行 |
| **Quick run command** | `cargo test --lib profile` |
| **Full suite command** | `cargo test` |
| **Estimated runtime** | ~10 秒（cargo test）。E2E は Codex 18-27s / OpenCode ~13s（live、課金あり） |

---

## Sampling Rate

- **After every task commit:** Run `cargo test --lib profile`（profile ロード確認 + リグレッション）
- **After every plan wave:** Run `cargo test`（27 件グリーン維持）
- **Before `/gsd-verify-work`:** `cargo test` 全グリーン + 両 E2E スクリプトが手動で pass（checkpoint）
- **Max feedback latency:** ~10 秒（cargo test）

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 05-01-01 | 01 | 1 | AGNT-01/02 | T-05-01/02 | covenant 書き込み先は turnId ベースパスに限定 | config + regression | `cargo test --lib profile` + TOML grep | ✅ 既存 | ⬜ pending |
| 05-01-02 | 01 | 1 | AGNT-01/02 | T-05-06 | 履歴隔離 2 ターンテスト | script syntax | `bash -n scripts/e2e-codex.sh` | ❌ W0（Task 2 が作成） | ⬜ pending |
| 05-01-03 | 01 | 1 | AGNT-01/02 | T-05-01/02 | result/status 生成 + /clear 履歴隔離 | live e2e (manual) | `bash scripts/e2e-codex.sh`（checkpoint, CI 不可 D-08） | ❌ W0（Task 2 が作成） | ⬜ pending |
| 05-02-01 | 02 | 1 | AGNT-03/04 | T-05-05 | turn.md 冪等生成（上書きなし） | script syntax + config | `bash -n scripts/setup-opencode.sh` + `cargo test --lib profile` | ❌ W0（Task 1 が作成） | ⬜ pending |
| 05-02-02 | 02 | 1 | AGNT-03/04 | T-05-06 | 履歴隔離 + fresh_mode 確定 | script syntax | `bash -n scripts/e2e-opencode.sh` | ❌ W0（Task 2 が作成） | ⬜ pending |
| 05-02-03 | 02 | 1 | AGNT-03/04 | — | ドキュメント整合（D-03） | source assertion | `grep -q 'setup-opencode.sh' README.md` | ✅ 既存 | ⬜ pending |
| 05-02-04 | 02 | 1 | AGNT-03/04 | T-05-04/06 | result/status 生成 + 履歴隔離 + fresh_mode 確定 | live e2e (manual) | `bash scripts/e2e-opencode.sh`（checkpoint, CI 不可 D-08） | ❌ W0（Task 2 が作成） | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `scripts/e2e-codex.sh` — AGNT-01/02 をカバー（05-01 Task 2 が作成、live E2E スクリプト）
- [x] `scripts/e2e-opencode.sh` — AGNT-03/04 をカバー（05-02 Task 2 が作成）
- [x] `scripts/setup-opencode.sh` — turn.md 前提生成（05-02 Task 1 が作成）

既存 `cargo test` 27 件がすべての Rust リグレッションをカバーする（Phase 5 は Rust 変更なし）。E2E スクリプトは各プランの Task で作成され、checkpoint で実行される。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Codex フル E2E（result/status 生成 + /clear 履歴隔離） | AGNT-01/02 | 実 Codex バイナリ + ChatGPT Plus 課金が必要（FakeMcp 不可、CI 不可 D-08） | `bash scripts/e2e-codex.sh` → exit 0 + result 非空 + status done + 7331 非漏洩 |
| OpenCode フル E2E（result/status 生成 + fresh:true 履歴隔離） | AGNT-03/04 | 実 OpenCode バイナリ + GitHub Copilot 課金が必要（CI 不可 D-08）。fresh_mode 確定（/new 試行 → respawn フォールバック判断） | `bash scripts/e2e-opencode.sh` → exit 0 + result 非空 + status done + 7331 非漏洩 |

E2E は live エージェント駆動のため自動 CI 化しない（D-08）。acceptance はスクリプト exit code + SUMMARY エビデンスで判定する。

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies（E2E は live manual + script syntax check）
- [x] Sampling continuity: no 3 consecutive tasks without automated verify（各 auto タスクに cargo test / bash -n / grep）
- [x] Wave 0 covers all MISSING references（e2e/setup スクリプトは各プラン Task で作成）
- [x] No watch-mode flags
- [x] Feedback latency < 10s（cargo test）
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-12
