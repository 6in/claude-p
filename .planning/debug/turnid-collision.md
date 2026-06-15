---
status: diagnosed
trigger: "並行実行時にターンファイルのコリジョン: 同一インスタンスへ同一ミリ秒の2 POST /prompt が同一 turn_id 20260615-090456-080 を取得しファイルを上書き"
created: 2026-06-15T00:00:00Z
updated: 2026-06-15T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED — turnId 採番が HTTP ハンドラ内のタイムスタンプ生成のみで一意性ガードが無いため、同一ミリ秒の並行リクエストが同一 turnId を得る
test: src/http.rs:92 の採番ロジックを読み、並行性ガード(counter/atomic/重複検出)の有無を確認
expecting: chrono タイムスタンプのみで採番 → ガード無し → 衝突可能 と判明
next_action: 診断完了。fix planner へ root cause を返す

## Symptoms

expected: 各リクエストが固有 turnId を持ち prompt/result/status ファイルが互いに上書きされない
actual: 同一インスタンスへ同一ミリ秒の 2 POST /prompt が両方 turn_id 20260615-090456-080 を取得。ファイルが 1 セットに上書き。turns_processed=3 だがディスク上ファイルセットは 2 件（1 ターン分消失）
errors: なし（silent overwrite）
reproduction: 06-UAT.md Test 2 — 同一インスタンスへ 4 並行 curl POST /prompt（同一ミリ秒着弾）
started: phase 6 UAT 中に発見

## Eliminated

- hypothesis: 採番が worker dequeue 時点で行われ、直列化により衝突回避される
  evidence: src/turn.rs の Job 構造体は turn_id: String を既に保持して受け取る。worker_loop/process_job は turn_id を生成せず受け取った値を使うだけ。採番は HTTP ハンドラ側で完結している
  timestamp: 2026-06-15T00:00:00Z

- hypothesis: クロスインスタンス間の turns_dir 分離が壊れている
  evidence: UAT 報告どおり turns-8080/claude vs turns-8081/codex は正しく分離。問題は同一インスタンス内に限定
  timestamp: 2026-06-15T00:00:00Z

## Evidence

- timestamp: 2026-06-15T00:00:00Z
  checked: src/http.rs:87-117 prompt_handler の採番〜キュー投入
  found: 92行目 `let turn_id = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();` がミリ秒精度タイムスタンプを唯一の turnId 源とする。続く 93-95 行でこの turn_id から prompt/result/status パスを構築、107 行で prompt ファイルを無条件 write、112 行で Job を send。同一/重複チェック、原子的カウンタ、ファイル存在チェックのいずれも存在しない
  implication: 同一ミリ秒に到達した 2 つの async ハンドラが独立に now() を呼ぶと同一文字列を得る。両者が同じ prompt パスに書き、同じ result/status パスを後段(claude)が上書きする。GET /turns/{id} は遅い方のターン結果だけを返し、もう一方のクライアントは他人の結果を受け取る

- timestamp: 2026-06-15T00:00:00Z
  checked: src/turn.rs:17-20 Job 構造体, 95-126 worker_loop
  found: Job は turn_id を外から受け取るのみで生成しない。worker_loop は直列(1件ずつ recv→process_job)だが、衝突した turn_id は既にキュー投入時点で確定済み。直列処理は採番の一意性を保証しない（直列なのは実行であって採番ではない）
  implication: 「1 worker = 同時1ターン (HT-PROTOCOL §12)」の直列性は実行段の保証であり、採番段の競合を防がない。turns_processed=3 は worker が 3 ジョブを実行したことを示すが、うち 2 つが同一ファイルパスを共有したため成果物が 2 セットに潰れた

- timestamp: 2026-06-15T00:00:00Z
  checked: HT-PROTOCOL.md §3.2, §12
  found: §3.2 「ミリ秒精度で同一時刻衝突を回避。なお衝突した場合は Orchestrator が連番(`-<seq>`)を付与して一意性をコードで保証する」。§12 「発番は制御側: turnId・ファイル名は Orchestrator が一意性を保証する」。形式 §3.1 は連番サフィックス `-<seq>` を明示的に許容
  implication: これは設計上の想定内ではなく未実装の欠陥。プロトコルは衝突時の連番付与を明示的に要求しているが、コードは実装していない。ミリ秒精度は「衝突しにくくする」だけで「衝突しない」を保証せず、プロトコルもそれを認識して連番ガードを要求している

- timestamp: 2026-06-15T00:00:00Z
  checked: src/http.rs:152 turn_handler の whitelist, CLAUDE.md HTTP safety 規則
  found: turn_id ホワイトリストは `c.is_ascii_digit() || c == '-'`（^[0-9-]+$ 相当）。連番サフィックス `-007` 形式はハイフンと数字のみなのでこの規則に適合する
  implication: 修正で `-<seq>` サフィックスを付与してもパストラバーサル防止規則を壊さない。`-w<workerId>` 形式も同様に [0-9-] のみなら適合（ただし w は英字なので不可、§3.1 の -w02 は現行 whitelist では弾かれる点に注意）

## Resolution

root_cause: src/http.rs:92 の prompt_handler が turnId をミリ秒精度タイムスタンプ `chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f")` のみで採番し、HT-PROTOCOL §3.2/§12 が要求する「衝突時の連番付与による一意性保証」を実装していない。複数の async ハンドラが同一ミリ秒に並行実行されると同一 turnId を得て、prompt/result/status ファイルを互いに上書きする。実害: あるクライアントのターン結果が別ターンに上書きされ、GET /turns/{id} が誤った（他人の）結果を返す。サイレントに 1 ターン分が消失する
fix: （fix planner 担当 — 適用しない）
verification: （未適用）
files_changed: []
