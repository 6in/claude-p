// ── ターン処理（バックグラウンド）────────────────────────────────────────

use anyhow::Result;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Instant;

use crate::config::TURN_TIMEOUT;
use crate::mcp::Mcp;
use crate::worker::Worker;

/// キューに積まれる1ジョブ。
pub struct Job {
    pub turn_id: String,
    pub fresh: bool,
}

/// turn_id 用の prompt ファイル本文を組み立てる。
pub fn build_prompt_body(task: &str, result_path: &Path, status_path: &Path) -> String {
    format!(
        "{task}

────────────────────────────────
【ht-webif 出力規約】上のタスクを実行し、次のとおりファイルに書き出してください:
1. 回答本文を次のファイルに書く: {result}
2. 完了したら最後に次のファイルを作る: {status}
   中身は JSON 1行: {{\"status\":\"done\"}}（失敗時は {{\"status\":\"failed\",\"error\":\"理由\"}}）
status ファイルが完了検知シグナルです。必ず result を書き終えてから最後に status を書いてください。",
        task = task,
        result = result_path.display(),
        status = status_path.display(),
    )
}

/// 1ジョブを実行する。完了すれば claude が status ファイルを書く。
/// タイムアウトしたらセッション再生成して1回リトライ。
pub(crate) async fn process_job<M: Mcp + Send>(
    worker: &mut Worker<M>,
    turns_dir: &Path,
    job: &Job,
) -> Result<()> {
    let prompt_path = turns_dir.join(format!("prompt-{}.txt", job.turn_id));
    let status_path = turns_dir.join(format!("status-{}.json", job.turn_id));
    let trigger = format!(
        "{} を読んで、その指示に従ってください。",
        prompt_path.display()
    );

    worker.ensure_healthy().await?;
    for attempt in 1..=2u32 {
        if job.fresh {
            worker.submit_line("/clear").await?;
            tokio::time::sleep(Duration::from_millis(1000)).await;
        }
        worker.submit_line(&trigger).await?;

        let deadline = Instant::now() + TURN_TIMEOUT;
        loop {
            if status_path.exists() {
                return Ok(()); // claude が status を書いた = 完了
            }
            if Instant::now() > deadline {
                break; // タイムアウト
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        eprintln!(
            "[worker] ターン {} タイムアウト（試行 {attempt}/2）→ セッション再生成",
            job.turn_id
        );
        worker.recreate().await?;
    }
    // 2回ともダメ → timeout を status に記録（GET が拾えるように）
    tokio::fs::write(&status_path, "{\"status\":\"timeout\"}\n").await?;
    Ok(())
}

/// ジョブキューを1件ずつ直列処理するバックグラウンドループ。
pub async fn worker_loop<M: Mcp + Send + 'static>(
    worker: Arc<Mutex<Worker<M>>>,
    turns_dir: PathBuf,
    mut job_rx: mpsc::Receiver<Job>,
) {
    while let Some(job) = job_rx.recv().await {
        let mut w = worker.lock().await;
        if let Err(e) = process_job(&mut w, &turns_dir, &job).await {
            eprintln!("[worker] ジョブ {} 失敗: {e}", job.turn_id);
            // 失敗を status ファイルに記録（GET が拾えるように）
            let status_path = turns_dir.join(format!("status-{}.json", job.turn_id));
            let err_json =
                serde_json::to_string(&e.to_string()).unwrap_or_else(|_| "\"error\"".to_string());
            let body = format!("{{\"status\":\"failed\",\"error\":{err_json}}}\n");
            let _ = tokio::fs::write(&status_path, body).await;
        }
    }
}

/// turn_id（status/result）をファイルシステムから読んで JSON にする。
pub async fn read_turn(turns_dir: &Path, turn_id: &str) -> Result<Value> {
    let status_path = turns_dir.join(format!("status-{turn_id}.json"));
    let result_path = turns_dir.join(format!("result-{turn_id}.txt"));
    let status_raw = tokio::fs::read_to_string(&status_path).await?;
    let status = serde_json::from_str::<Value>(&status_raw)
        .ok()
        .and_then(|v| v.get("status").and_then(Value::as_str).map(String::from))
        .unwrap_or_else(|| "unknown".to_string());
    let result = tokio::fs::read_to_string(&result_path)
        .await
        .unwrap_or_default();
    Ok(json!({ "turn_id": turn_id, "status": status, "result": result }))
}

// ── 単体テスト（co-located、D-06）─────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::tempdir;

    // build_prompt_body はタスク本文・両パス・出力規約マーカーの 4 要素を含むこと。
    #[test]
    fn build_prompt_body_includes_task_and_paths() {
        let result_path = PathBuf::from("/tmp/result-X.txt");
        let status_path = PathBuf::from("/tmp/status-X.json");
        let body = build_prompt_body("やってほしいこと", &result_path, &status_path);
        assert!(body.contains("やってほしいこと"));
        assert!(body.contains("/tmp/result-X.txt"));
        assert!(body.contains("/tmp/status-X.json"));
        assert!(body.contains("【ht-webif 出力規約】"));
    }

    // turn_id formatter は YYYYMMDD-HHMMSS-mmm 形式（19 文字、3 セグメント、全数字）になること。
    #[test]
    fn turn_id_formatter_matches_expected_shape() {
        let id = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();
        // 8 + 1 + 6 + 1 + 3 = 19 文字
        assert_eq!(id.len(), 19);
        let parts: Vec<&str> = id.split('-').collect();
        assert_eq!(parts.len(), 3);
        // 日付部 8 桁、全数字
        assert_eq!(parts[0].len(), 8);
        assert!(parts[0].chars().all(|c| c.is_ascii_digit()));
        // 時刻部 6 桁、全数字
        assert_eq!(parts[1].len(), 6);
        assert!(parts[1].chars().all(|c| c.is_ascii_digit()));
        // ミリ秒部 3 桁、全数字
        assert_eq!(parts[2].len(), 3);
        assert!(parts[2].chars().all(|c| c.is_ascii_digit()));
    }

    // read_turn happy path: 完全な done を返す
    #[tokio::test]
    async fn read_turn_returns_done_when_status_complete() {
        let dir = tempdir().unwrap();
        let id = "20260525-000000-000";
        tokio::fs::write(
            dir.path().join(format!("status-{id}.json")),
            "{\"status\":\"done\"}\n",
        )
        .await
        .unwrap();
        tokio::fs::write(dir.path().join(format!("result-{id}.txt")), "回答本文")
            .await
            .unwrap();
        let v = read_turn(dir.path(), id).await.unwrap();
        assert_eq!(v.get("turn_id").and_then(Value::as_str), Some(id));
        assert_eq!(v.get("status").and_then(Value::as_str), Some("done"));
        assert_eq!(v.get("result").and_then(Value::as_str), Some("回答本文"));
    }

    // status JSON が壊れたら "unknown" にフォールバック（unwrap_or_else パス）
    #[tokio::test]
    async fn read_turn_marks_unknown_when_status_garbled() {
        let dir = tempdir().unwrap();
        let id = "X";
        tokio::fs::write(
            dir.path().join(format!("status-{id}.json")),
            "not a json{{{",
        )
        .await
        .unwrap();
        tokio::fs::write(dir.path().join(format!("result-{id}.txt")), "")
            .await
            .unwrap();
        let v = read_turn(dir.path(), id).await.unwrap();
        assert_eq!(v.get("status").and_then(Value::as_str), Some("unknown"));
    }

    // result ファイル不在は空文字フォールバック（unwrap_or_default パス）
    #[tokio::test]
    async fn read_turn_returns_empty_result_when_result_file_missing() {
        let dir = tempdir().unwrap();
        let id = "Y";
        tokio::fs::write(
            dir.path().join(format!("status-{id}.json")),
            "{\"status\":\"done\"}\n",
        )
        .await
        .unwrap();
        // result-Y.txt は書かない
        let v = read_turn(dir.path(), id).await.unwrap();
        assert_eq!(v.get("status").and_then(Value::as_str), Some("done"));
        assert_eq!(v.get("result").and_then(Value::as_str), Some(""));
    }
}
