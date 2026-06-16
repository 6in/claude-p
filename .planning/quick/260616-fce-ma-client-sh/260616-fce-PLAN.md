---
phase: quick-260616-fce
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - scripts/ma-client.sh
  - justfile
  - README-MULTI-AGENT.md
  - README.md
autonomous: true
requirements: [MA-CLIENT-01]

must_haves:
  truths:
    - "ma-client.sh claude -p \"...\" で同期送信し result 本文が表示される（D-1）"
    - "--async を付けると wait なしで turn_id が即表示される（D-1）"
    - "positional 引数 ma-client.sh claude \"...\" が後方互換で動く（D-2）"
    - "ma-client.sh result claude <turn_id> で GET /turns の status と result が表示される（D-3）"
    - "ma-client.sh status で instances.conf 全 agent の /info 一覧が表示される（D-3）"
    - "--port <N> で agent→port 解決を上書きできる（D-5）"
    - "--fresh で fresh:true がボディに乗る（D-6）"
    - "just install で ma-client.sh が ~/.local/bin に配置される（D-4）"
  artifacts:
    - path: "scripts/ma-client.sh"
      provides: "マルチエージェント curl ラッパー（send/result/status サブコマンド）"
      min_lines: 120
    - path: "justfile"
      provides: "install/uninstall に ma-client.sh 同梱"
      contains: "ma-client.sh"
  key_links:
    - from: "scripts/ma-client.sh"
      to: "instances.conf"
      via: "$(pwd)/instances.conf を読み agent→port 解決（D-5）"
      pattern: "instances.conf"
    - from: "scripts/ma-client.sh"
      to: "POST /prompt / GET /turns / GET /info"
      via: "curl 127.0.0.1:<port>"
      pattern: "127.0.0.1"
    - from: "justfile install"
      to: "~/.local/bin/ma-client.sh"
      via: "cp + chmod +x"
      pattern: "ma-client.sh"
---

<objective>
マルチエージェント用クライアント `scripts/ma-client.sh` を新規作成する。エージェント名でプロンプトを送れる薄い curl ラッパーで、`launch-agents.sh` のパターン（JSON_ENCODER 検出 / json_get_field / $(pwd)/instances.conf 読み込み）を踏襲する。あわせて justfile の install/uninstall に同梱し、README 2 本にドキュメントを追記する。

設計はユーザと確定済み（D-1〜D-6、locked — 再検討しない）。

Purpose: `launch-agents.sh up` で立てた各インスタンスへ、ポート番号を意識せず agent 名で curl を投げられるようにする。既存の単一インスタンス向け `claude-p` ラッパーのマルチエージェント版。
Output: scripts/ma-client.sh（新規）、justfile（install/uninstall 更新）、README-MULTI-AGENT.md §5 追記、README.md 一行紹介。
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md
@scripts/launch-agents.sh
@instances.conf
@justfile
@README.md
@README-MULTI-AGENT.md
</context>

<interface_context>
踏襲する `scripts/launch-agents.sh` の確立パターン:

- **JSON_ENCODER 検出:** `command -v jq` 優先、なければ `command -v python3`、両方無ければエラー exit 1。
- **json_get_field(json, field):** jq なら `jq -r ".${field} // empty"`、python3 なら `json.loads(...).get('field','')`。
- **instances.conf パース:** `$(pwd)/instances.conf`。`# ` コメント行・空行スキップ。`read -ra fields <<< "$line"` で `agent=${fields[0]}` `port=${fields[1]}`。最初の一致を採用。
- **/info 応答形:** `{"agent","port","status","uptime_secs","turns_processed"}`（README-MULTI-AGENT.md §4）。

接続先サーバの応答形（README.md API セクション）:

- **POST /prompt 非同期:** `{"turn_id":"...","status":"accepted"}`
- **POST /prompt 同期(wait:true):** `{"turn_id":"...","status":"completed","result":"..."}`
- **GET /turns/{turn_id}:** 実行中 `{"turn_id":"...","status":"running"}` / 完了 `{"turn_id":"...","status":"completed","result":"..."}` / 不在 `404`
- **status 値:** `accepted` / `running` / `completed`（"done" ではなく "completed"）。

プロンプトの JSON エンコードは `jq -Rs .`（raw string slurp）または `python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'` で安全化する（スラッシュ・引用符・改行 OK）。
</interface_context>

<tasks>

<task type="auto">
  <name>Task 1: scripts/ma-client.sh 新規作成</name>
  <files>scripts/ma-client.sh</files>
  <action>
新規 bash スクリプトを作成する。`set -euo pipefail` で開始。コメント・ログ・エラーメッセージは日本語、識別子は英語（プロジェクト規約）。`launch-agents.sh` の方式を自己完結で踏襲する（重複コード許容）。

冒頭にスクリプト概要コメント（D-1〜D-6 の使い方網羅）と `log()`（`echo "[ma-client] $*" >&2`）を置く。

JSON_ENCODER 検出（D-6）: `command -v jq` 優先、なければ `python3`、両方無ければ日本語エラーで exit 1。launch-agents.sh の検出ブロックを踏襲。

ヘルパー関数を定義:
- `json_get_field(json, field)`: launch-agents.sh と同形（jq -r ".${field} // empty" / python3 get）。
- `json_encode_string(stdin)`: プロンプト文字列を安全に JSON 文字列リテラル化。jq なら `jq -Rs .`、python3 なら `python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'`。末尾改行の扱いに注意（jq -Rs は入力をそのまま slurp）。
- `resolve_port(agent)`: `$(pwd)/instances.conf` を読む（D-5）。無ければ「instances.conf が見つかりません: <path>」で exit 1。`# `コメント・空行をスキップしつつ `read -ra fields` で各行を解析し、`fields[0]==agent` の最初の一致の `fields[1]` を返す。一致なしなら「エージェント '<agent>' が見つかりません。利用可能: <一覧>」（一覧は instances.conf の全 agent 名をスペース区切り）で exit 1。

usage(): D-3 のサブコマンド体系を日本語で表示。`send`（既定）/ `result <agent> <turn_id>` / `status`。send のフラグ（-p / positional / --async / --fresh / --port / stdin パイプ）も記載。exit 1。

引数 dispatch（D-3）: 第1引数が `result` なら cmd_result、`status` なら cmd_status、`-h`/`--help`/空 なら usage、それ以外は agent 名として cmd_send に委譲。

cmd_send(agent, 残り引数):
- フラグ解析ループ: `-p <prompt>` でプロンプト指定（D-2）、`--async`（wait なし）、`--fresh`（fresh:true、D-6）、`--port <N>`（port 上書き、D-5）。`-p`/`--port` 以外の非フラグ引数は positional プロンプト候補として保持（D-2 後方互換）。
- プロンプト決定（D-2）: `-p` 指定 > positional 引数 > stdin がパイプ（`[[ ! -t 0 ]]`）なら `cat` で stdin から読む。どれも無ければ usage 相当のエラーで exit 1。
- port 決定: `--port` 指定があればそれ、無ければ resolve_port(agent)（D-5）。
- リクエストボディ構築: `prompt` は json_encode_string で安全化。`wait` は --async が無ければ true、あれば付けない（または false）。--fresh があれば `"fresh":true`。jq があれば `jq -n --argjson prompt "<encoded>" ...` 等で組み立て、無ければ python3 で組み立てる（json_encode_string と同じ encoder を使い、文字列連結ではなく encoder 経由で安全に）。
- 送信: `curl -s -X POST http://127.0.0.1:<port>/prompt -H 'Content-Type: application/json' -d '<body>'`。curl 失敗（exit 非ゼロ）または空応答なら「port <N> の <agent> に接続できません。launch-agents.sh up で起動済みか確認してください」で exit 1。
- 応答処理: 同期（既定）なら `status` を json_get_field で取り、`completed` なら `result` を本文として stdout に出力。`completed` でなければ status も表示（result があれば併記）。非同期（--async）なら `turn_id` を表示。

cmd_result(agent, turn_id):
- agent と turn_id の両方必須。欠落なら日本語エラー + usage 相当で exit 1。
- port 決定: resolve_port(agent)。
- `curl -s http://127.0.0.1:<port>/turns/<turn_id>`。接続不可（curl 失敗 or 空）は cmd_send と同じ接続エラーで exit 1。HTTP 404 相当（応答が空 or turn_id 不明）は「ターン <turn_id> が見つかりません」を表示。
- 応答から status を表示し、`completed` なら result 本文も表示。

cmd_status():
- `$(pwd)/instances.conf` を読む（無ければ exit 1）。全 agent 行について `curl -s --max-time 3 http://127.0.0.1:<port>/info` を叩き、agent / port / status / uptime_secs / turns_processed を json_get_field で取り出して一覧表示。応答なしは「応答なし (DOWN)」と表示（launch-agents.sh cmd_status の表示方式を踏襲、ただし /info の値中心の簡潔な一覧）。

接続先は常に 127.0.0.1（D-6）。NEVER place fenced code blocks in this action — implementation goes in the file via Write.
  </action>
  <verify>
    <automated>bash -n scripts/ma-client.sh && bash scripts/ma-client.sh --help 2>&1 | grep -q send && bash scripts/ma-client.sh 2>&1 | grep -qi 'result\|status\|send'</automated>
  </verify>
  <done>bash -n が通る。`--help` と引数なし実行で usage が表示され send/result/status が現れる。jq/python3 検出・instances.conf 解決・3 サブコマンドが実装されている。日本語コメント/ログ・英語識別子。</done>
</task>

<task type="auto">
  <name>Task 2: justfile install/uninstall 同梱 + README 2 本のドキュメント追記</name>
  <files>justfile, README-MULTI-AGENT.md, README.md</files>
  <action>
**justfile install レシピ（行 110-150 付近）:** `cp scripts/launch-agents.sh "$HOME/.local/bin/launch-agents.sh"` の直後に `cp scripts/ma-client.sh "$HOME/.local/bin/ma-client.sh"` と `chmod +x "$HOME/.local/bin/ma-client.sh"` を追加する。完了メッセージ（`echo "  $HOME/.local/bin/launch-agents.sh"` のブロック）にも `echo "  $HOME/.local/bin/ma-client.sh"` を追記する。

**justfile uninstall レシピ（行 153-159 付近）:** `rm -f "$HOME/.local/bin/ht-webif" "$HOME/.local/bin/launch-agents.sh"` の削除対象に `"$HOME/.local/bin/ma-client.sh"` を追加し、続く `echo "アンインストール完了: ..."` メッセージにも ma-client.sh を列挙する。

**README-MULTI-AGENT.md §5「各インスタンスへプロンプトを送る」（行 235-278 付近）:** 既存の curl 版例の下に、ma-client.sh の簡略版を日本語で追記する。`just install` 済みなら ma-client.sh が PATH にある旨を一言。例として (a) 同期既定の send（`ma-client.sh claude -p "..."` → result 本文）、(b) `--async`（turn_id 表示）、(c) `result claude <turn_id>`、(d) `status`、(e) `--port` での上書き、(f) `--fresh`。port 直打ち curl との対応（agent 名 → instances.conf の port 自動解決）を一言添える。説明文・コメントは日本語。

**README.md:** 既存の「## claude-p — curl 不要の薄いラッパ」セクション（行 271 付近）の近辺、または API セクション付近に、ma-client.sh の一行紹介を追記する。「マルチエージェント版の薄いラッパ。`ma-client.sh <agent> -p \"...\"` で agent 名（instances.conf の port を自動解決）宛に同期送信。詳細は README-MULTI-AGENT.md §5」程度。claude-p（単一インスタンス向け）との棲み分けが分かるようにする。
  </action>
  <verify>
    <automated>grep -q 'ma-client.sh' justfile && grep -c 'ma-client.sh' justfile | grep -qv '^0$' && grep -q 'ma-client.sh' README-MULTI-AGENT.md && grep -q 'ma-client.sh' README.md && just --list 2>/dev/null | grep -q install</automated>
  </verify>
  <done>justfile の install/uninstall 両方に ma-client.sh の cp+chmod / rm が入り、`just --list` が壊れていない。README-MULTI-AGENT.md §5 と README.md に ma-client.sh の記述がある。</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| クライアント引数 → curl ボディ | ユーザが渡す prompt/turn_id がローカル ht-webif へ送られる |
| instances.conf → port 解決 | ローカル設定ファイルから読んだ port を curl 宛先に使う |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-fce-01 | Injection | prompt の JSON 組み立て | mitigate | jq -Rs / python3 json.dumps で文字列をエンコード。シェル文字列連結で JSON を組まない（引用符・改行・スラッシュを encoder に委譲） |
| T-fce-02 | Tampering | turn_id がサーバの FS 検証に到達 | accept | サーバ側が `^[0-9-]+$` ホワイトリストで検証済み（既存ガード）。クライアントは透過、追加検証不要 |
| T-fce-03 | Information Disclosure | 接続先 | mitigate | 接続先は 127.0.0.1 固定（D-6）。リモート送信なし |
| T-fce-04 | (該当なし) | パッケージインストール | n/a | npm/pip/cargo install なし。bash + 既存 jq/python3 のみ |
</threat_model>

<verification>
- `bash -n scripts/ma-client.sh` がエラーなく通る。
- `ma-client.sh --help` と引数なしで usage が表示される。
- `just --list` が install/uninstall を含み壊れていない。
- `grep ma-client.sh` が justfile / README-MULTI-AGENT.md / README.md でヒットする。
- Rust 変更は無い想定だが、最後に `cargo fmt --check` / `cargo clippy --all-targets --release -- -D warnings` / `cargo test --release` がグリーンであることを確認する（リグレッション無しの担保）。
</verification>

<success_criteria>
- scripts/ma-client.sh が D-1〜D-6 を全て満たす（同期既定 / --async / -p + positional + stdin / send|result|status / install 同梱 / agent→port 解決 + --port 上書き / --fresh + jq優先python3フォールバック + 127.0.0.1）。
- justfile install/uninstall に ma-client.sh が同梱・削除される。
- README 2 本にドキュメントが追記される。
- bash -n / usage / just --list の verify が通り、cargo fmt/clippy/test がグリーン。
</success_criteria>

<output>
Create `.planning/quick/260616-fce-ma-client-sh/260616-fce-SUMMARY.md` when done
</output>
