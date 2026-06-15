---
phase: 05
slug: codex-cli-and-opencode-validation
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-15
---

# Phase 05 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| curl クライアント → axum (loopback) | 信頼されない入力が `127.0.0.1` 経由で WebIF に入る | `turn_id`（`^[0-9-]+$` で検証済み）, prompt 本文 |
| WebIF → codex TUI (ht-mcp stdio) | `--dangerously-bypass-approvals-and-sandbox` により codex が無承認シェル実行 | trigger コマンド, prompt path |
| WebIF → opencode TUI (ht-mcp stdio) | trigger は `/turn {prompt_path}` カスタムコマンド経由（ASCII のみ） | trigger コマンド, prompt path |
| codex/opencode TUI → ファイルシステム | covenant に従い result/status をプロジェクトルート内 `turns/{agent}/` に書く | result/status ファイル |
| setup-opencode.sh → ~/.config/opencode/ | ホストのユーザ設定に turn.md/opencode.json を書く（冪等） | 固定 XDG パス設定ファイル |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-05-01 | Tampering | codex `--dangerously-bypass-approvals-and-sandbox`（無承認シェル実行） | accept | 既存 claude 統合と同一の脅威レベル。localhost 限定運用（SEC-01 は v3+ 繰延）。プロファイルは operator-controlled な起動設定 | closed |
| T-05-02 | Tampering | codex が covenant に従い任意ファイルを書く | accept | 書込先は `{result_path}`/`{status_path}` プレースホルダ（orchestrator 割当 turnId ベースパス）に限定。OS レベルで信頼確立済み | closed |
| T-05-03 | Spoofing | `CODEX_HOME` env var が悪意ある auth を指す可能性 | accept | operator-controlled env var（`AGENT` env と同等リスク）。多重インスタンス分離検証は Phase 6（PARA-04） | closed |
| T-05-04 | Tampering | opencode モデルが covenant に従い任意ファイルを書く | accept | 書込先は placeholder 限定。claude/codex 統合と同一脅威レベル。OS レベルで信頼確立済み | closed |
| T-05-05 | Tampering | setup-opencode.sh が `~/.config/opencode/commands/turn.md` を書く | mitigate | 固定 XDG パス（`${XDG_CONFIG_HOME:-$HOME/.config}/opencode`）+ 既存時スキップの冪等処理。外部入力で経路が変わらない。`scripts/setup-opencode.sh:20,29-31,50-57` で実装確認済み | closed |
| T-05-06 | Information Disclosure | fresh:true 後に前ターン履歴が漏れる（履歴隔離失敗） | mitigate | `fresh_mode=respawn` によるセッション kill+再生成。2026-06-15 実機 UAT で respawn 発火（before=0→after=1）と falsifiability（respawn 破壊時 stage 3 で exit 1）を実証。`scripts/e2e-opencode.sh` 段階 3 が常時ゲート | closed |
| T-05-SC | Tampering | パッケージインストール（npm/pip/cargo） | n/a | Phase 5 は config-only で新規パッケージ追加なし（05-RESEARCH.md Package Legitimacy Audit: Not applicable）。インストールタスクなし | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-05-01 | T-05-01 | codex 無承認シェル実行は既存 claude 統合と同一脅威レベル。localhost-only バインド前提（HT-PROTOCOL §7）で受容。サンドボックス強化は v3+（SEC-01）で対応 | operator (6in) | 2026-06-15 |
| AR-05-02 | T-05-02, T-05-04 | TUI のファイル書き込みは OS レベルで信頼確立済み。書込先は turnId ベース placeholder に限定 | operator (6in) | 2026-06-15 |
| AR-05-03 | T-05-03 | `CODEX_HOME` は operator-controlled env var。多重インスタンスのクレデンシャル分離検証は Phase 6（PARA-04）に委譲 | operator (6in) | 2026-06-15 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-15 | 7 | 7 | 0 | gsd-secure-phase (orchestrator, retroactive State B from PLAN threat models) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-15
