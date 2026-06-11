---
phase: 4
slug: agent-profile-abstraction
status: verified
threats_open: 0
asvs_level: 1
created: 2026-06-11
---

# Phase 4 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| ディスク → プロセス | 起動時に `agents/<name>.toml` を読み込む。パスは `AGENT` + `AGENTS_DIR`（運用者制御の env）から構成 | TOML プロファイル（spawn コマンド・テンプレート） |
| 起動時設定 → 実行時挙動 | profile が spawn コマンド・ready 検知・テンプレート・fresh 分岐を駆動 | プロファイル値（command/args/ready_pattern/fresh_mode） |
| クライアント → TUI | `POST /prompt` の prompt が trigger_template 経由で TUI に渡る（v1.0 から不変） | 信頼されない HTTP ボディ |
| TOML profile → spawn コマンド | `model_flag`/`model_value` が子プロセス引数に流入 | 運用者管理の引数文字列 |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-04-01 | Tampering | `agents/*.toml` パース（`toml::from_str`） | mitigate | `#[serde(deny_unknown_fields)]` at `src/profile.rs:11`; `validate_profile` が `{result_path}` `{status_path}` `{prompt_path}` を検証 (`src/profile.rs:86-96`)、`load_agent_profile` から無条件に呼出 (`src/profile.rs:81`) | closed |
| T-04-02 | Elevation/Path | `agents_dir.join("{name}.toml")` パス構成 (`src/profile.rs:66`) | accept | Accepted Risks Log 参照 | closed |
| T-04-SC | Tampering | crates 依存追加（toml） | mitigate | `toml = "1"` のみ追加 (`Cargo.toml:18`)。全 4 プランの SUMMARY で他の新規 crate なしを確認 | closed |
| T-04-03 | Tampering | `build_prompt_body` の covenant 置換（プロファイル由来テンプレート） | mitigate | ゴールデンテスト `build_prompt_body_covenant_matches_v1_output` (`src/turn.rs:152-178`) が実 `agents/claude.toml` を `load_agent_profile` で読み、`const EXPECTED` とのバイト一致を `assert_eq!` で固定。不正テンプレートは起動時に `validate_profile` で排除 | closed |
| T-04-04 | Denial of Service | `fresh_mode` 未知値・`ready_pattern` 欠落によるタイムアウト | mitigate | 未知の fresh_mode は `anyhow::bail!` で即エラー (`src/turn.rs:63`)。`ready_pattern` は `AgentProfile` の必須フィールドで、TOML 欠落は起動時デシリアライズエラー | closed |
| T-04-05 | Information Disclosure | 起動バナー（turns パス・エージェント名出力） | accept | Accepted Risks Log 参照 | closed |
| T-04-06 | Elevation of Privilege | `AgentProfile::spawn_command()` の model_flag/model_value 引数 (`src/profile.rs:51-58`) | accept | Accepted Risks Log 参照 | closed |
| T-04-07 | Information Disclosure | `AppState.output_covenant` のロックフリー読取 (`src/http.rs:29,66`) | accept | Accepted Risks Log 参照 | closed |
| T-04-08 | Denial of Service | `prompt_handler` の worker Mutex ロック（CR-01 修正対象） | mitigate | `prompt_handler`（`src/http.rs:48-98`）に `worker.lock()` 呼出ゼロ。`output_covenant` は `state.output_covenant` から直接読取 (`src/http.rs:66`)。残る `worker.lock()` は `command_handler`/`restart_handler` のみ（lines 141, 169） | closed |
| T-04-09 | Tampering | `cargo fmt` による意図しないロジック変更 | mitigate | `cargo fmt --check` exit 0（監査時に実行確認）。`cargo test` 27 passed（04-04-SUMMARY）。コミット `7c73d17` の diff は空白・折返しのみ | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-04-01 | T-04-02 | `AGENT`/`AGENTS_DIR` は運用者制御の env でありクライアント入力ではない。HTTP エンドポイントから `name`/`agents_dir` に影響を与える経路なし。読み取り専用 `std::fs::read_to_string` のみで書込パスなし。環境を制御できる運用者は既に任意コード実行が可能であり残余リスクは無視できる | gsd-security-auditor (plan-time disposition) | 2026-06-11 |
| AR-04-02 | T-04-05 | サーバは `127.0.0.1` のみにバインド。起動ログは運用者向け stderr で HTTP レスポンスではない。出力はパスとエージェント名のみで秘密情報なし（v1.0 起動ログと同等） | gsd-security-auditor (plan-time disposition) | 2026-06-11 |
| AR-04-03 | T-04-06 | `model_flag`/`model_value` は運用者管理の TOML 由来でリモート攻撃面なし。引数は `Vec<String>` として ht-mcp の `ht_create_session` に JSON-RPC で渡され、シェル経由でないためインジェクションは構造的に不可能。`command` フィールドと同一の信頼境界 | gsd-security-auditor (plan-time disposition) | 2026-06-11 |
| AR-04-04 | T-04-07 | `output_covenant` は秘密情報を含まない静的テンプレート文字列で、起動後イミュータブル。イミュータブルな `String` の並行読取は Rust の所有権モデルにより安全。ロックフリー化は可用性改善（CR-01）でありデータ露出面は不変 | gsd-security-auditor (plan-time disposition) | 2026-06-11 |

*Accepted risks do not resurface in future audit runs.*

---

## Unregistered Threat Flags

None. 全 4 プランの SUMMARY.md Threat Surface Scan で、登録済み脅威モデル以外の新規ネットワークエンドポイント・auth パス・ファイルアクセスパターン・スキーマ変更はゼロと報告。

---

## Scope

Plans audited: 04-01, 04-02, 04-03, 04-04

Implementation files verified:
- `src/profile.rs` — AgentProfile struct, load_agent_profile, validate_profile, spawn_command
- `src/config.rs` — load_agent_name, load_agents_dir, TURN_TIMEOUT removal
- `src/worker.rs` — profile field, spawn_command() call sites (3), ready_pattern sites (4)
- `src/turn.rs` — build_prompt_body covenant param, fresh_mode dispatch, golden test
- `src/http.rs` — AppState.output_covenant, lock-free prompt_handler
- `src/main.rs` — profile load startup sequence, D-16 turns subdir
- `agents/claude.toml` — extracted profile with required placeholders
- `Cargo.toml` — toml = "1" dependency

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-06-11 | 10 | 10 | 0 | gsd-security-auditor (sonnet) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-06-11
