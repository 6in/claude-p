---
status: testing
phase: 06-multi-instance-parallel-foundation
source: [06-VERIFICATION.md]
started: 2026-06-15T08:20:00Z
updated: 2026-06-15T08:20:00Z
---

## Current Test

number: 1
name: 複数インスタンスを実際に同時起動し、各 /info が正しいエージェント名を返すことを確認
expected: |
  just up-all 実行後、curl localhost:8080/info が {"agent":"claude",...}、
  curl localhost:8081/info が {"agent":"codex",...}、
  curl localhost:8082/info が {"agent":"opencode",...} を返す
awaiting: user response

## Tests

### 1. 複数インスタンス同時起動 — 各 /info が正しいエージェント名を返す
expected: just up-all 実行後、curl localhost:8080/info → {"agent":"claude",...}、localhost:8081/info → {"agent":"codex",...}、localhost:8082/info → {"agent":"opencode",...}
result: [pending]

### 2. 100 ターン並行実行時のターンファイルコリジョン非発生
expected: 2インスタンス同時稼働中に各インスタンスへ 50 ターン投入しても、turns-8080/claude/ と turns-8081/codex/ が互いのファイルを上書きしない
result: [pending]

### 3. /info status フィールドの busy/idle 遷移（WR-03 セマンティクス）
expected: POST /prompt 直後の GET /info で status=busy、ターン完了後に status=idle。in_flight 方式（キュー投入時点で busy）が意図したロードバランサ契約に合っているか確認
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
