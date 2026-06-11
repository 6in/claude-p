---
phase: 04-agent-profile-abstraction
reviewed: 2026-06-11T08:30:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - agents/claude.toml
  - src/config.rs
  - src/http.rs
  - src/lib.rs
  - src/main.rs
  - src/mcp.rs
  - src/profile.rs
  - src/turn.rs
  - src/worker.rs
findings:
  critical: 3
  warning: 6
  info: 4
  total: 13
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-06-11T08:30:00Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Phase 04 のエージェントプロファイル抽象化（`agents/claude.toml` + `src/profile.rs` + 各層への配線）をレビューした。テストは 24/24 パス、clippy はクリーン。しかし本フェーズの diff（`5df2cb1^..HEAD`）に対する検証で **3 件の Critical** を確認した:

1. `prompt_handler` が covenant 取得のために worker Mutex をロックするようになり、ターン実行中（worker_loop がロックを最大 2×turn_timeout ≒ 600 秒以上保持）は **非同期 POST /prompt が即時応答できなくなる**回帰。
2. `cargo fmt --check` が失敗する（profile.rs / turn.rs / worker.rs 計 5 箇所）。CI の最初のジョブ（fmt-check）がハード失敗する。
3. `model_flag` / `model_value` がパース・テストされるだけで **どこにも配線されておらず**、設定しても無視される（agents/claude.toml は「使用する場合は両方指定」と機能するように文書化している）。

加えて、起動時バリデーションの抜け（fresh_mode / 空 command）、AGENT 環境変数のファイルシステム到達前ホワイトリスト欠如（プロジェクト規約違反）、本フェーズで死蔵化した `config::TURN_TIMEOUT` 等の Warning 6 件、Info 4 件を検出した。

検証手段: 全 9 ファイル精読、`git diff 5df2cb1^..HEAD` による本フェーズ変更の特定、`cargo fmt --check`（失敗を確認）、`cargo clippy --all-targets`（クリーン）、`cargo test`（24 passed）。

## Critical Issues

### CR-01: prompt_handler が worker Mutex をロックし、ターン実行中は非同期 POST /prompt がブロックする（回帰）

**File:** `src/http.rs:57-60`
**Issue:** 本フェーズで `build_prompt_body` に covenant 引数が追加され、その取得のために `state.worker.lock().await` が新規導入された。一方 `worker_loop`（`src/turn.rs:91-93`）は `process_job` の実行中ずっと同じ Mutex を保持する（プロファイルの `turn_timeout_secs` が既定 300 秒 × 最大 2 試行 ≒ 600 秒超）。その結果、ターン実行中に届いた `POST /prompt` は covenant のクローン取得だけのために現行ターンの完了までブロックされ、「非同期、turn_id を即返す」という API 契約（lib.rs doc / main.rs の起動メッセージ）が破壊される。v1.0 では covenant は `turn.rs` 内の `format!` リテラルでロック不要だったため、これは本フェーズが導入した回帰。`wait:true` クライアントも prompt ファイル書き込み前に数百秒待たされる。
**Fix:** プロファイルは起動後イミュータブルなので、Mutex 越しに取得する必要がない。`AppState` に covenant（またはプロファイル全体）を直接持たせる:
```rust
// http.rs
pub struct AppState<M: Mcp + Send + 'static = McpClient> {
    pub worker: Arc<Mutex<Worker<M>>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
    pub output_covenant: String, // または profile: Arc<AgentProfile>
}

// prompt_handler 内 — ロック不要に
let body = build_prompt_body(&req.prompt, &result_path, &status_path, &state.output_covenant);
```
main.rs では `Worker::new` にプロファイルを渡す前に `profile.output_covenant.clone()` を取り出して `AppState` に格納する。`build_test_state`（http.rs:224）も同様に更新。

### CR-02: cargo fmt --check が失敗する — CI ゲート（fmt-check）がハード失敗

**File:** `src/profile.rs:63-64,71-72` / `src/turn.rs:23,40-41,167` / `src/worker.rs:23-34` 付近（計 5+ 箇所）
**Issue:** `cargo fmt --check` を実行すると profile.rs（2 箇所）、turn.rs（3 箇所）、worker.rs に差分が出る。代表例: `src/turn.rs:23` の `build_prompt_body` シグネチャが 1 行 100 文字超、`src/turn.rs:40-41` のメソッドチェーン折返し、`src/profile.rs:71-72` の `if` 条件。プロジェクト規約は「cargo fmt + cargo clippy before commits。CI enforces cargo fmt --check」であり、CI パイプライン（fmt-check → clippy → test）が最初のステップで失敗する。このままでは出荷できない。
**Fix:**
```bash
cargo fmt
```
を実行してコミットに含める（rustfmt の自動整形のみで解消、ロジック変更なし）。

### CR-03: model_flag / model_value がパースされるだけで一切使用されない — 文書化済み設定の無言ノーオプ

**File:** `src/profile.rs:31-34` / `src/worker.rs:44,107,147` / `agents/claude.toml:33-35`
**Issue:** `AgentProfile` は `model_flag` / `model_value` を定義し、`agents/claude.toml` は「モデル選択（使用する場合は両方指定）」と機能するかのように文書化し、テスト（profile.rs:284-315、D-13 参照）はパースのみ検証している。しかし `grep` で確認した結果、これらのフィールドを参照するのは profile.rs のみで、セッション生成 3 箇所（`spawn_session`/`recreate`/`restart`）はすべて `profile.command` のみを `create_session` に渡す。利用者が `model_flag = "--model"` / `model_value = "opus"` を設定しても **何も起こらず、既定モデルで動く**。設定が受理・検証（deny_unknown_fields を通過）されながら無視されるのは無言の誤動作。
**Fix:** spawn コマンド組み立て時にフラグを付与する（3 箇所で共通化するなら `AgentProfile` にメソッドを追加）:
```rust
impl AgentProfile {
    /// model_flag/model_value を付与した実 spawn コマンドを返す。
    pub fn spawn_command(&self) -> Vec<String> {
        let mut cmd = self.command.clone();
        if let (Some(flag), Some(value)) = (&self.model_flag, &self.model_value) {
            cmd.push(flag.clone());
            cmd.push(value.clone());
        }
        cmd
    }
}
```
`worker.rs` の `create_session(&profile.command)` 3 箇所を `create_session(&profile.spawn_command())` に置換。意図的に後続フェーズへ先送りするなら、フィールドを削除するか TOML コメントに「未実装」と明記し、片方のみ指定をエラーにすること（WR 参照）。

## Warnings

### WR-01: fresh_mode が起動時に検証されず、不正値が実行時（fresh ジョブ到着時）まで検出されない

**File:** `src/profile.rs:70-82` / `src/turn.rs:47-58`
**Issue:** `validate_profile` はプレースホルダのみ検証し、`fresh_mode` の値域（"command" / "respawn"）を検証しない。`fresh_mode = "typo"` の TOML は起動に成功し、`fresh: true` のジョブが来た時点で初めて `process_job` が `anyhow::bail!("未知の fresh_mode: ...")` で失敗、そのターンが "failed" になる。プレースホルダ欠落を起動時即エラーとする D-11 の fail-fast 方針と非対称。
**Fix:** `validate_profile` に追加:
```rust
if !matches!(p.fresh_mode.as_str(), "command" | "respawn") {
    anyhow::bail!("agents/{name}.toml: fresh_mode は \"command\" か \"respawn\"（実際: {:?}）", p.fresh_mode);
}
```

### WR-02: AGENT 環境変数（agent_name）が未検証のままファイルシステムパスに合流する — 規約違反

**File:** `src/config.rs:44-46` / `src/profile.rs:50` / `src/main.rs:29`
**Issue:** プロジェクト規約は「ファイルシステムに到達する識別子はホワイトリスト必須」と定める。`agent_name` は `agents_dir.join(format!("{name}.toml"))`（profile.rs:50）と `turns_base.join(&agent_name)`（main.rs:29）の 2 箇所でファイルシステムに到達するが、検証がない。`AGENT="../../etc/foo"` は agents ディレクトリ外の TOML を読み、`turns` 外にディレクトリを作成する。運用者制御の環境変数なのでリモート攻撃面ではないが、`AGENT="a/b"` のような値が黙って入れ子ディレクトリを生む事故も防げない。
**Fix:** 起動時（`load_agent_profile` 冒頭または `load_agent_name`）に名前をホワイトリスト検証:
```rust
if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
    anyhow::bail!("不正なエージェント名: {name:?}（英数字・ハイフン・アンダースコアのみ）");
}
```

### WR-03: config::TURN_TIMEOUT が本フェーズで死蔵化（唯一の利用箇所を削除）

**File:** `src/config.rs:7-8`
**Issue:** 本フェーズの diff で `use crate::config::TURN_TIMEOUT;` と `Instant::now() + TURN_TIMEOUT`（turn.rs）が削除され、`profile.turn_timeout_secs` に置き換えられた。結果、`pub const TURN_TIMEOUT` は参照ゼロの死蔵定数（`pub` のため clippy 警告も出ない）。doc コメント「1ターンの最大待ち時間」も実態と乖離し、デフォルト値 300 が `profile.rs::default_turn_timeout()` と二重定義になっており将来の divergence 源になる。CLAUDE.md のアーキテクチャ記述（`TURN_TIMEOUT = 300s`）とも不整合化が進む。
**Fix:** `TURN_TIMEOUT` 定数を削除する。あるいは `default_turn_timeout()` が `TURN_TIMEOUT.as_secs()` を返すよう一本化して single source of truth にする。

### WR-04: wait:true の 700 秒デッドラインが profile.turn_timeout_secs から導出されない

**File:** `src/http.rs:76` / `src/turn.rs:64`
**Issue:** 同期 `wait:true` パスのデッドラインは `Duration::from_secs(700)` のハードコードで、これは旧 TURN_TIMEOUT(300s)×2 試行 + 余裕という前提で校正された値。本フェーズでターンタイムアウトが `turn_timeout_secs` でプロファイル設定可能になったため（例: 600 秒）、最大試行時間（2×600=1200 秒）が wait デッドラインを超え、ターンがまだ正常進行中なのに 504 を返すケースが生じる。
**Fix:** デッドラインをプロファイルから導出する。CR-01 の修正で AppState がプロファイル（またはタイムアウト値）を持つようになるため:
```rust
let wait_deadline_secs = state.turn_timeout_secs * 2 + 100; // 2試行 + 再生成余裕
let deadline = Instant::now() + Duration::from_secs(wait_deadline_secs);
```

### WR-05: 空の command 配列が検証を通過し、ht_create_session で不可解なエラーになる

**File:** `src/profile.rs:70-82` / `src/worker.rs:44`
**Issue:** `command = []` の TOML は `validate_profile` を通過し、起動は `client.create_session(&[])` まで進んで ht-mcp 側のエラー（または "セッション ID が取れない"）として表面化する。エラーメッセージから原因（プロファイルの空 command）を辿れない。
**Fix:** `validate_profile` に追加:
```rust
if p.command.is_empty() {
    anyhow::bail!("agents/{name}.toml: command が空です（例: [\"claude\"]）");
}
```
あわせて `model_flag`/`model_value` の片方のみ指定（"model_flag とセットで指定" の文書化に反する状態）も同所で拒否するとよい（CR-03 修正後に意味を持つ）。

### WR-06: ready 待ちポーリングループが worker.rs 内で 3 回複製されている

**File:** `src/worker.rs:45-55, 109-121, 148-160`
**Issue:** 「`create_session` → deadline = startup_timeout_secs → snapshot を 700ms 間隔で polling → ready_pattern を含めば成功 / 期限超過で "claude TUI が起動しない"」というロジックが `spawn_session` / `recreate` / `restart` に逐語的に 3 回出現する（コメント自身が「spawn_session と同じロジック」と認めている）。startup タイムアウトの扱いやエラーメッセージを変更する際に 3 箇所の同期更新が必要で、divergence バグの温床。
**Fix:** trait メソッドのみで書ける汎用ヘルパに抽出:
```rust
async fn wait_ready<M: Mcp>(client: &mut M, session_id: &str, pattern: &str, timeout_secs: u64) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    loop {
        let snap = client.snapshot(session_id).await?;
        if snap.contains(pattern) { return Ok(()); }
        if Instant::now() > deadline { return Err(anyhow!("claude TUI が起動しない:\n{snap}")); }
        tokio::time::sleep(Duration::from_millis(700)).await;
    }
}
```

## Info

### IN-01: テストが相対パス "agents" で実 TOML をロードし、CWD に依存する

**File:** `src/turn.rs:157` / `src/http.rs:227`
**Issue:** ゴールデンテストと `build_test_state` は `Path::new("agents")` で実ファイルをロードする。`cargo test` がクレートルートから走る限り動くが、ワークスペース化や別 CWD からの実行で全 http テスト + ゴールデンテストが壊れる。
**Fix:** `Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/agents"))` を使い CWD 非依存にする。

### IN-02: CORS ログ行に `[profile]` タグが付いている

**File:** `src/main.rs:45`
**Issue:** `eprintln!("[profile] CORS 許可オリジン: ...")` — CORS 設定はプロファイル由来ではなく、規約のブラケット付きソースタグとして誤分類。
**Fix:** `[cors]` または `[config]` タグに変更。

### IN-03: deny_unknown_fields テストのアサーションが空虚

**File:** `src/profile.rs:278-281`
**Issue:** `assert!(!err.to_string().is_empty())` は anyhow エラーなら常に真で、「未知フィールドが拒否された」ことを実質検証していない（unwrap_err がエラー発生自体は保証するが、エラー理由は不問）。プレースホルダ検証エラー等でも通る。
**Fix:** `assert!(err.to_string().contains("unknown_field") || format!("{err:#}").contains("unknown_field"))` のように原因フィールド名を検証する。

### IN-04: fresh_mode = "respawn" のエージェントでも clear_command が必須フィールド

**File:** `src/profile.rs:19-20` / `agents/claude.toml:15-16`
**Issue:** `clear_command` は非 Option の必須フィールドのため、respawn 方式のエージェント（clear コマンドを持たない TUI）でもダミー値の記入を強制される。
**Fix:** `Option<String>`（または `#[serde(default)]`）にし、`validate_profile` で「fresh_mode = "command" なら clear_command 必須（非空）」を検証する。

---

_Reviewed: 2026-06-11T08:30:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
