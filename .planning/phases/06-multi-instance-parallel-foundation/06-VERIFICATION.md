---
phase: 06-multi-instance-parallel-foundation
verified: 2026-06-15T08:20:00Z
status: human_needed
score: 4/4
overrides_applied: 0
human_verification:
  - test: "複数インスタンスを実際に同時起動し、各 /info が正しいエージェント名を返すことを確認"
    expected: "just up-all 実行後、curl localhost:8080/info が {\"agent\":\"claude\",...}、curl localhost:8081/info が {\"agent\":\"codex\",...}、curl localhost:8082/info が {\"agent\":\"opencode\",...} を返す"
    why_human: "ht-mcp + claude/codex/opencode の実バイナリが必要。cargo テストでは代替不可。"
  - test: "100 ターン並行実行時のターンファイルコリジョン非発生を確認"
    expected: "2インスタンス同時稼働中に各インスタンスへ 50 ターン投入しても、turns-8080/claude/ と turns-8081/codex/ が互いのファイルを上書きしない"
    why_human: "実際のマルチプロセス動作が必要。ユニットテストでは TURNS_DIR 分離の実行時挙動を確認不可。"
  - test: "/info の status フィールドがターン実行中は busy、完了後は idle になることを確認（WR-03 セマンティクス）"
    expected: "POST /prompt 直後の GET /info で status=busy、ターン完了後に status=idle が返る。in_flight 方式（キュー投入時点で busy）が意図したロードバランサ契約に合っているか確認"
    why_human: "WR-03 で busy の定義がデキューからキュー投入に変わった（in_flight > 0 で判定）。この変更がスケジューラ/ロードバランサ用途として正しい契約かは運用者の判断が必要。テストは初期値（in_flight=0 → idle）しか検証していない。"
---

# Phase 6: Multi-Instance Parallel Foundation — Verification Report

**Phase Goal:** 複数エージェントのインスタンスを同時に立ち上げ、各インスタンスの状態を `GET /info` で観測しながら独立して curl で叩ける環境が整う。
**Verified:** 2026-06-15T08:20:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `GET /info` が稼働中のエージェント名・port・status・uptime・処理ターン数を含む JSON を返す | VERIFIED | `info_handler` が `agent_name/port/status/uptime_secs/turns_processed` の5フィールドを `Json<Value>` で返す（src/http.rs:56-73）。co-located テスト `info_handler_returns_five_fields_with_initial_values` が全フィールドと初期値を assert し 34/34 passed。`status` フィールドは WR-03 修正により `in_flight > 0` で判定（idle/busy 2状態、PARA-01/02 充足） |
| 2 | `scripts/launch-agents.sh up` が instances.conf の各行を別ポートで一括起動し、各 `/info` が正しいエージェント名を返す | VERIFIED (code) / NEEDS HUMAN (runtime) | launcher が instances.conf の3行（claude:8080 / codex:8081 / opencode:8082）を読み、`check_info_agent` で `/info` の agent 名一致ポーリングを行う実装を確認（scripts/launch-agents.sh:69-87, 209-244）。`just up-all/down-all/agents-status` が launcher を呼ぶ（justfile:51-60）。bash -n 構文チェック合格。ただし実際の複数インスタンス同時起動は実バイナリが必要 |
| 3 | 複数インスタンス同時稼働中のターンファイルコリジョン非発生（`TURNS_DIR` 分離で保証） | VERIFIED (code) / NEEDS HUMAN (runtime) | launcher がポートごとに `TURNS_DIR=${WEBIF_DIR}/turns-${port}` を spawn 時に渡す（launch-agents.sh:180）。サーバ側は D-16 で `turns_base.join(&agent_name)` を適用（main.rs:52）。WR-01 修正で launcher の表示パスも `turns-${port}/${agent}` に整合。異なるポートなら `turns-8080/claude/` と `turns-8081/codex/` は分離される。実動作確認は human 検証項目 |
| 4 | README に多重インスタンス起動手順・CODEX_HOME 分離手順・クレデンシャル分離ガイドが記載されている | VERIFIED | README.md §複数インスタンス運用（line 70-165）に instances.conf 書式、just up-all/down-all/agents-status コマンド例、クレデンシャル分離表（claude=不要/理由、codex=必須+CODEX_HOME手順、opencode=不要/理由）が記載済み。CODEX_HOME 具体例 `codex login` コマンドも掲載 |

**Score:** 4/4 truths verified (2 truths have human-verifiable runtime components)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/http.rs` | InstanceInfo struct + info_handler + /info route + AppState.instance_info | VERIFIED | `pub struct InstanceInfo` (line 25), `async fn info_handler` (line 55), `.route("/info", get(info_handler::<M>))` (line 256), `pub instance_info: Arc<InstanceInfo>` in AppState (line 46) |
| `src/turn.rs` | worker_loop に instance_info 引数 + is_busy トグル + in_flight デクリメント + turns_processed インクリメント | VERIFIED | `worker_loop` signature に `instance_info: Arc<InstanceInfo>` (line 99), `is_busy.store(true/false)` (lines 103/107), `in_flight.fetch_sub(1)` (line 111), `turns_processed.fetch_add(1)` (lines 113-115) |
| `src/main.rs` | InstanceInfo 構築 + AppState/worker_loop への配線 | VERIFIED | `InstanceInfo` 構築 (lines 38-45), `instance_info.clone()` を worker_loop に渡す (line 63), AppState に `instance_info` 追加 (line 72). `load_port()` 呼び出し1回のみ (line 35) |
| `scripts/launch-agents.sh` | up/down-all/status サブコマンド、instances.conf 駆動、/info readiness、PID/ログ規約 | VERIFIED | 3サブコマンド実装済み (lines 90-406), instances.conf 読み込み (lines 111-264), check_info_agent ポーリング (lines 69-87), PID /tmp/ht-webif-${PORT}.pid (line 134), LOG /tmp/ht-webif-${PORT}.log (line 135) |
| `instances.conf` | claude:8080 / codex:8081 CODEX_HOME=... / opencode:8082 の3行 | VERIFIED | 3行確認: `claude 8080`, `codex 8081 CODEX_HOME=/home/user/.codex-instance1`, `opencode 8082` |
| `justfile` | up-all / down-all / agents-status レシピ | VERIFIED | 3レシピ確認（lines 51-60）、各レシピが `bash scripts/launch-agents.sh` を呼ぶ |
| `README.md` | 多重インスタンス + クレデンシャル分離ガイド | VERIFIED | §複数インスタンス運用節（lines 70-165）に全要素記載確認 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/main.rs` | `src/turn.rs worker_loop` | `instance_info.clone()` を第4引数で渡す | VERIFIED | `tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx, instance_info.clone()))` (main.rs:59-64) |
| `src/http.rs info_handler` | `AppState.instance_info` | lock-free atomic read（worker.lock() 呼ばない） | VERIFIED | `info_handler` body に `state.instance_info` への直接アクセスのみ。`worker.lock()` の呼び出しなし（grep 確認済み） |
| `scripts/launch-agents.sh up` | `GET /info` | agent 名一致ポーリング | VERIFIED | `check_info_agent` 関数が `curl /info` → `json_get_field "agent"` → expected と比較（lines 69-87, 226） |
| `scripts/launch-agents.sh` | `instances.conf` | 行読み込み + extra-env を spawn 時 export | VERIFIED | `while IFS= read -r line ... done < "$INSTANCES_CONF"` + `read -ra fields` + `export "$kv"` (eval なし) |
| `src/http.rs prompt_handler` | `AppState.instance_info.in_flight` | send 成功後に fetch_add(1) | VERIFIED | `state.instance_info.in_flight.fetch_add(1, Ordering::Relaxed)` (http.rs:119-124, WR-03 fix) |
| `src/turn.rs worker_loop` | `AppState.instance_info.in_flight` | process_job 後に fetch_sub(1) | VERIFIED | `instance_info.in_flight.fetch_sub(1, Ordering::Relaxed)` (turn.rs:111, WR-03 fix) |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `info_handler` | `info.agent_name`, `info.port`, `info.in_flight`, `info.started_at`, `info.turns_processed` | `Arc<InstanceInfo>` — 起動時に `main.rs` で構築、worker_loop がアトミック更新 | Yes — atomic reads of real runtime state | FLOWING |
| `worker_loop` | `instance_info.in_flight`, `instance_info.is_busy`, `instance_info.turns_processed` | `process_job` 呼び出し結果に基づき store/fetch_sub/fetch_add | Yes — actual job completion counts | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| 34テスト全件グリーン（/info テスト含む） | `cargo test --release` | 34 passed, 0 failed | PASS |
| bash構文チェック | `bash -n scripts/launch-agents.sh` | exit 0, no output | PASS |
| launcher 実行ビット | `test -x scripts/launch-agents.sh` | executable | PASS |
| info_handler に worker.lock() なし | `awk '/^async fn info_handler/,/^}/' src/http.rs \| grep worker.lock` | 出力なし | PASS |
| load_port 二重呼び出しなし | `grep -n "load_port" src/main.rs` | 1 call (line 35) only | PASS |
| eval 不使用確認 | `grep "eval" scripts/launch-agents.sh` | コメント行のみ（実 eval コードなし） | PASS |
| デットマーカーなし | `grep -rn "TBD\|FIXME\|XXX"` on phase files | 出力なし | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PARA-01 | Plan 01 | `GET /info` がエージェント名・port・status を JSON で返す | SATISFIED | `info_handler` + `/info` ルート実装済み。5フィールド（agent/port/status/uptime_secs/turns_processed）返却確認 |
| PARA-02 | Plan 01 | `/info` が uptime・処理ターン数を含む | SATISFIED | `uptime_secs: info.started_at.elapsed().as_secs()` + `turns_processed: info.turns_processed.load()` 実装確認 |
| PARA-03 | Plan 02 | launcher で複数インスタンス一括起動、`/info` ポーリングで起動確認 | SATISFIED (code) | `scripts/launch-agents.sh up` + `check_info_agent` 実装確認。実動作は human 検証 |
| PARA-04 | Plans 02+03 | PORT/TURNS_DIR 分離で並列動作、Codex credential 分離手順をドキュメント化 | SATISFIED | TURNS_DIR per-port 分離（spawn 行確認）、README §クレデンシャル分離ガイド（CODEX_HOME 手順付き）確認 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none found) | — | — | — | — |

No TBD/FIXME/XXX debt markers found. No stub return patterns. No placeholder implementations.

### Review Findings Status (06-REVIEW.md + 06-REVIEW-FIX.md)

All 7 in-scope findings (CR-01 + WR-01..06) were fixed per 06-REVIEW-FIX.md. Commits verified in git log (379eb68..72909b1):

| Finding | Fix | Commit | Verified |
|---------|-----|--------|---------|
| CR-01: cargo run wrapper PID orphan | prebuilt binary spawn | 379eb68 | VERIFIED — `nohup ... "$server_bin"` (no cargo run) |
| WR-01: TURNS_DIR display mismatch | turns_dir = turns-${port}/${agent} | 1f0be1e | VERIFIED — line 138/361 in launcher |
| WR-02: space-containing env values split | array parse `read -ra fields` | f4749ae | VERIFIED — line 123/127 |
| WR-03: is_busy dequeue blind spot | in_flight AtomicU64 | 07aa30c | VERIFIED — in_flight in InstanceInfo, prompt_handler +1, worker_loop -1 |
| WR-04: exit 1 aborts whole up loop | failures counter + continue | e839e30 | VERIFIED — lines 109, 201, 220, 236, 260 |
| WR-05: non-numeric PID files | `=~ ^[0-9]+$` validation | 34845dd | VERIFIED — lines 148, 303, 373 |
| WR-06: port collision misdiagnosed | tri-state return (0/1/2) | 72909b1 | VERIFIED — return 2 + check_rc -eq 2 |

Info findings IN-01..03 were intentionally out of scope (advisory quality improvements, not correctness blockers).

### Human Verification Required

#### 1. 複数インスタンス同時起動と /info エージェント名確認

**Test:** `just up-all` を実行し、起動後に各ポートへ `curl -s localhost:808{0,1,2}/info | jq .agent` を実行する
**Expected:** `"claude"`, `"codex"`, `"opencode"` がそれぞれ返る（エージェント名が正しく分離されている）
**Why human:** ht-mcp + claude/codex/opencode の実バイナリが必要。instances.conf の3エージェントが全部 PATH 上にある必要がある

#### 2. ターンファイルコリジョン非発生確認

**Test:** 2インスタンス（例: claude:8080, codex:8081）を同時起動し、各インスタンスへ複数ターンを並行投入する（例: 各50ターン）
**Expected:** `turns-8080/claude/` と `turns-8081/codex/` のファイルが互いに干渉しない。各ディレクトリのファイル数が投入数と一致する
**Why human:** 実際のマルチプロセス書き込みが必要。TURNS_DIR 分離の効果は実行時のみ観測可能

#### 3. /info の busy セマンティクス確認（WR-03 変更後）

**Test:** `POST /prompt {"prompt":"..."}` 投入直後（worker がまだデキューしていないタイミング）に `GET /info` を呼ぶ
**Expected:** `status: "busy"` が返る（in_flight = 1 のため）。ターン完了後に `status: "idle"` に戻る
**Why human:** WR-03 で `status` の判定が `is_busy`（デキュー時トグル）から `in_flight > 0`（キュー投入時インクリメント）に変更された。この変更がスケジューラ/ロードバランサとして期待する契約と一致するか運用者の確認が必要

### Gaps Summary

No technical gaps found. All 4 success criteria are implemented in code with substantive, wired, and data-flowing artifacts. The `human_needed` status reflects 3 runtime behaviors that require real agent binaries to verify:

1. Actual multi-instance startup and /info agent name isolation (PARA-03)
2. Turn file collision non-occurrence at runtime (success criterion 3)
3. Confirmation that the WR-03 semantic change (in_flight-based busy) matches intended load-balancer contract

---

_Verified: 2026-06-15T08:20:00Z_
_Verifier: Claude (gsd-verifier)_
