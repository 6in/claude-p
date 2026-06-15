---
status: testing
phase: 06-multi-instance-parallel-foundation
source: [06-VERIFICATION.md]
started: 2026-06-15T08:20:00Z
updated: 2026-06-15T09:45:00Z
---

## Current Test

number: 2
name: 100 ターン並行実行時のターンファイルコリジョン非発生（06-04 修正後の再確認）
expected: |
  同一インスタンスへ同一ミリ秒に N 並行 POST /prompt しても turnId が全件一意で、
  prompt/result/status ファイルが互いに上書きされない。
awaiting: user response（実機での再確認、任意）

## Tests

### 1. 複数インスタンス同時起動 — 各 /info が正しいエージェント名を返す
expected: just up-all 実行後、curl localhost:8080/info → {"agent":"claude",...}、localhost:8081/info → {"agent":"codex",...}、localhost:8082/info → {"agent":"opencode",...}
result: pass
note: |
  実機確認済み。8080→{"agent":"claude"}、8082→{"agent":"opencode"} は as-is で ready。
  8081(codex) は instances.conf のプレースホルダ CODEX_HOME=/home/user/.codex-instance1
  が未編集だったため初回失敗。実在の認証済み CODEX_HOME を与えると 8081→{"agent":"codex"}
  で正常起動を確認。launcher は codex 失敗を飛ばして claude/opencode を起動し、最後に
  非ゼロ終了（WR-04 設計どおり）。codex 失敗はコード欠陥ではなく一度の認証セットアップ手順。

### 2. 100 ターン並行実行時のターンファイルコリジョン非発生
expected: 2インスタンス同時稼働中に各インスタンスへ 50 ターン投入しても、turns-8080/claude/ と turns-8081/codex/ が互いのファイルを上書きしない
result: resolved-in-code
reported: "同一インスタンスへ同一ミリ秒に並行POSTすると turnId(YYYYMMDD-HHMMSS-mmm) が衝突し、prompt/result/status が上書きされる。8080は3ターン処理でディスク上ファイルセット2、8081は2ターン処理で1。クロスインスタンス分離(turns-8080/claude vs turns-8081/codex)は成立。"
severity: major
resolved_by: 06-04（TurnIdAllocator + CR-01 単調非減少クランプ）
note: |
  当初 issue: 同一インスタンス内で同一ミリ秒並行採番すると turnId が衝突していた。
  06-04 で AppState 所有の TurnIdAllocator（単一直列化点）を導入し、衝突時に -<seq>
  数値サフィックスを付与。さらにコードレビュー CR-01 で壁時計後退時の再発番を
  単調非減少クランプ（base > last_base）で封じた。
  自動テストで検証済み: N=1000 並行採番一意性（multi_thread ランタイム）= 重複 0、
  backward-clock 再発番防止、全 turnId が ^[0-9-]+$ 適合。38/38 テスト green。
  実機での 100 ターン並行再確認は任意（コード修正は自動テストで確証済み）。

### 3. /info status フィールドの busy/idle 遷移（WR-03 セマンティクス）
expected: POST /prompt 直後の GET /info で status=busy、ターン完了後に status=idle。in_flight 方式（キュー投入時点で busy）が意図したロードバランサ契約に合っているか確認
result: pass
note: |
  実機確認済み。idle → POST /prompt 直後に busy（投入時点で busy = in_flight/WR-03）
  → 完了後 idle、turns_processed 0→1、turn ファイルは turns-8080/claude/ に出力。

## Summary

total: 3
passed: 2
issues: 0
resolved: 1
pending: 0
skipped: 0
blocked: 0

## Gaps

- truth: "並行実行時にターンファイルのコリジョンが発生しない"
  status: resolved
  resolved_by: 06-04
  resolution: "AppState 所有 TurnIdAllocator を単一直列化点として導入し、同一ミリ秒衝突時に単調増加の数値サフィックス -<seq> を付与。CR-01 で壁時計後退時の再発番も base > last_base クランプで封止。N=1000 並行採番一意性テスト（multi_thread）+ backward-clock 回帰テストで検証。06-VERIFICATION.md で 9/9 must-haves VERIFIED。"
  reason: "ユーザ承認のもと実機テスト: 同一インスタンスへ同一ミリ秒に並行POSTすると turnId(YYYYMMDD-HHMMSS-mmm) が衝突し prompt/result/status ファイルが上書きされる。8080で3ターン処理に対しディスク上のファイルセットは2、8081で2ターン処理に対し1。クロスインスタンス分離(turns-8080/claude vs turns-8081/codex)は成立。"
  severity: major
  test: 2
  root_cause: "src/http.rs:92 — prompt_handler が turnId をミリ秒精度タイムスタンプ chrono::Utc::now().format(\"%Y%m%d-%H%M%S-%3f\") のみで採番し一意性ガードが無い。同一ミリ秒に並行着信した async ハンドラが同一文字列を生成 → 同一の prompt/result/status パスへ書き込み worker が上書き。HT-PROTOCOL §3.2 が要求する衝突時 -<seq> 連番ガードが未実装。直列 worker モデル(§12)は実行を直列化するが採番は HTTP 着信時で並行のため衝突は enqueue 時点で確定。"
  artifacts:
    - path: "src/http.rs:92"
      issue: "turnId をタイムスタンプのみで採番、一意性ガード無し（衝突時 -<seq> 未実装）"
    - path: "src/turn.rs:17-20,44-45,119,130-131"
      issue: "turn_id を verbatim でパス構築に使用。id が一意なら変更不要"
    - path: "HT-PROTOCOL.md §3.1/§3.2/§12"
      issue: "コードが満たすべき -<seq> 衝突ガード仕様。コードが未実装"
  missing:
    - "prompt_handler（または AppState 所有の共有アロケータ）で turnId 採番を原子化し衝突耐性を持たせる"
    - "HT-PROTOCOL §3.2 準拠で、base タイムスタンプ衝突時に単調増加の数値サフィックス -<seq>（例 ...-080-001）を付与"
    - "per-instance の last-issued-id 状態 + AtomicU64/短い Mutex を単一直列化点にし、並行ハンドラが同一 prior state を読めないようにする"
    - "サフィックスは数値+ハイフンのみとし既存の ^[0-9-]+$ ホワイトリスト(http.rs:152)を壊さない（-w<workerId> の文字形式は不可）"
  debug_session: ".planning/debug/turnid-collision.md"
