// ── HTTP 層 ──────────────────────────────────────────────────────────

use anyhow::Result;
use axum::{
    extract::{Path as AxumPath, State},
    http::{header, HeaderValue, Method, StatusCode},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex};
use tokio::time::Instant;
use tower_http::cors::{Any, CorsLayer};

use crate::mcp::{Mcp, McpClient, Restartable};
use crate::turn::{build_prompt_body, read_turn, Job};
use crate::worker::Worker;

pub struct AppState<M: Mcp + Send + 'static = McpClient> {
    pub worker: Arc<Mutex<Worker<M>>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
}

pub(crate) fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}

#[derive(Deserialize)]
pub struct PromptReq {
    prompt: String,
    /// true なら実行前に /clear で文脈をリセットする（-p 相当の一発実行）。
    #[serde(default)]
    fresh: bool,
    /// true なら完了まで待って結果を返す（既定 false = 非同期、turn_id を即返す）。
    #[serde(default)]
    wait: bool,
}

/// POST /prompt — ターンをキュー投入する。既定は非同期（turn_id を即返す）。
async fn prompt_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
    Json(req): Json<PromptReq>,
) -> Result<Json<Value>, (StatusCode, String)> {
    // turnId 発番（HT-PROTOCOL §3: ミリ秒精度、発番は制御側）
    let turn_id = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();
    let prompt_path = state.turns_dir.join(format!("prompt-{turn_id}.txt"));
    let result_path = state.turns_dir.join(format!("result-{turn_id}.txt"));
    let status_path = state.turns_dir.join(format!("status-{turn_id}.json"));

    // prompt ファイルを先に書く（GET が即「running」を返せるように）
    // output_covenant は worker の profile から取得（profile.output_covenant）
    let covenant = {
        let w = state.worker.lock().await;
        w.profile.output_covenant.clone()
    };
    let body = build_prompt_body(&req.prompt, &result_path, &status_path, &covenant);
    tokio::fs::write(&prompt_path, body).await.map_err(ise)?;

    // ジョブをキュー投入
    state
        .job_tx
        .send(Job {
            turn_id: turn_id.clone(),
            fresh: req.fresh,
        })
        .await
        .map_err(|_| ise("ジョブキューが閉じています"))?;

    if req.wait {
        // 同期オプション: status ファイルが出るまで待つ
        let deadline = Instant::now() + Duration::from_secs(700);
        while !status_path.exists() {
            if Instant::now() > deadline {
                return Err((
                    StatusCode::GATEWAY_TIMEOUT,
                    format!("turn {turn_id}: wait タイムアウト"),
                ));
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        let turn = read_turn(&state.turns_dir, &turn_id).await.map_err(ise)?;
        return Ok(Json(turn));
    }

    // 非同期（既定）: turn_id を即返す
    Ok(Json(json!({ "turn_id": turn_id, "status": "accepted" })))
}

/// GET /turns/{turn_id} — ターンの状態と結果を返す。
async fn turn_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
    AxumPath(turn_id): AxumPath<String>,
) -> Result<Json<Value>, (StatusCode, String)> {
    // パストラバーサル防止: turn_id は数字とハイフンのみ
    if turn_id.is_empty() || !turn_id.chars().all(|c| c.is_ascii_digit() || c == '-') {
        return Err((StatusCode::BAD_REQUEST, "不正な turn_id".to_string()));
    }
    let status_path = state.turns_dir.join(format!("status-{turn_id}.json"));
    let prompt_path = state.turns_dir.join(format!("prompt-{turn_id}.txt"));
    if status_path.exists() {
        let turn = read_turn(&state.turns_dir, &turn_id).await.map_err(ise)?;
        Ok(Json(turn))
    } else if prompt_path.exists() {
        Ok(Json(json!({ "turn_id": turn_id, "status": "running" })))
    } else {
        Err((
            StatusCode::NOT_FOUND,
            format!("turn {turn_id} は存在しません"),
        ))
    }
}

#[derive(Deserialize)]
pub struct CommandReq {
    /// claude TUI に打ち込む文字列。スラッシュコマンド可（例 "/clear"）。
    text: String,
}

#[derive(Serialize)]
pub struct CommandResp {
    sent: String,
    snapshot: String,
}

/// POST /command — claude TUI に生の文字列を打ち込む（スラッシュコマンド用）。
async fn command_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
    Json(req): Json<CommandReq>,
) -> Result<Json<CommandResp>, (StatusCode, String)> {
    let mut worker = state.worker.lock().await;
    worker.ensure_healthy().await.map_err(ise)?;

    worker.submit_line(&req.text).await.map_err(ise)?;
    tokio::time::sleep(Duration::from_millis(1500)).await;

    // /quit など、コマンド自体がセッションを終わらせる場合があるので snapshot は寛容に。
    let snapshot = worker
        .snapshot()
        .await
        .unwrap_or_else(|e| format!("(snapshot 取得失敗: {e})"));
    Ok(Json(CommandResp {
        sent: req.text,
        snapshot,
    }))
}

#[derive(Serialize)]
pub struct RestartResp {
    status: String,
    session_id: String,
}

/// POST /restart — ht-mcp（MCPサーバ）ごと再起動する。
/// Restartable 制約: M = McpClient は ht-mcp 子プロセス再生成、テストダブルは no-op。
async fn restart_handler<M: Mcp + Restartable + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
) -> Result<Json<RestartResp>, (StatusCode, String)> {
    let mut worker = state.worker.lock().await;
    worker.restart().await.map_err(ise)?;
    Ok(Json(RestartResp {
        status: "restarted".to_string(),
        session_id: worker.session_id.clone(),
    }))
}

/// 4 つの HTTP ルートを束ねた axum Router を返す。main.rs はこれを `axum::serve` に渡すだけ。
///
/// 型パラメータ M: Restartable を要求するのは restart_handler が ht-mcp 再起動に
/// trait Restartable を使うため。本番（M = McpClient）も テスト（FakeMcp）も Restartable を
/// 実装すれば build_router をそのまま使える。
///
/// CORS_ORIGINS で絞り込み可、既定は全許可 (`*`)。
pub fn build_router<M: Mcp + Restartable + Send + 'static>(
    state: Arc<AppState<M>>,
    cors_origins: Vec<String>,
) -> Router {
    // cors_origins に "*" が含まれる場合はワイルドカード全許可、それ以外は明示オリジンのみ許可
    let cors = if cors_origins.iter().any(|o| o == "*") {
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
            .allow_headers([header::CONTENT_TYPE])
    } else {
        let headers: Vec<HeaderValue> = cors_origins
            .iter()
            .filter_map(|o| HeaderValue::from_str(o).ok())
            .collect();
        CorsLayer::new()
            .allow_origin(headers)
            .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
            .allow_headers([header::CONTENT_TYPE])
    };

    Router::new()
        .route("/prompt", post(prompt_handler::<M>))
        .route("/turns/{turn_id}", get(turn_handler::<M>))
        .route("/command", post(command_handler::<M>))
        .route("/restart", post(restart_handler::<M>))
        .layer(cors)
        .with_state(state)
}

// ── HTTP 統合テスト（co-located、D-06）─────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::tests::FakeMcp;
    use crate::worker::Worker;
    use axum::body::Body;
    use axum::http::Request;
    use std::path::Path;
    use tempfile::tempdir;
    use tower::ServiceExt;

    /// テスト用に Worker<FakeMcp> を直接組み立て、worker_loop は spawn しない（D-09）。
    /// 戻り値の mpsc::Receiver<Job> はテスト側で `_job_rx` として保持し、
    /// job_tx (Sender) が drop されてチャネルが closed になるのを防ぐ
    /// （CONTEXT "Constraints" line 150）。
    fn build_test_state(turns_dir: PathBuf) -> (Arc<AppState<FakeMcp>>, mpsc::Receiver<Job>) {
        let (job_tx, job_rx) = mpsc::channel(64);
        // プロファイルは実 TOML からロード（Pitfall 4: turns_dir は main.rs 経由でなくここでそのまま使う）。
        let profile = crate::profile::load_agent_profile("claude", Path::new("agents"))
            .expect("テスト用 agents/claude.toml のロード失敗");
        // FakeMcp は scripted reply 不要（本テストでは turn_handler 経路のみ叩く）。
        let worker = Worker::<FakeMcp>::from_parts(
            FakeMcp::new(),
            "test-session".to_string(),
            "/dev/null".to_string(),
            profile,
        );
        let worker = Arc::new(Mutex::new(worker));
        let state = Arc::new(AppState {
            worker,
            turns_dir,
            job_tx,
        });
        (state, job_rx)
    }

    // ── パストラバーサル拒否 (a): percent-encoded slash 形式 ──
    //
    // ROADMAP Phase 3 Success #2「`../`を 400 で弾く」のリグレッション保護（ASVS V5）。
    // CONTEXT D-10 #1 verbatim「GET /turns/../etc/passwd 等の不正 turn_id」の具体化。
    //
    // axum 0.8 の Path extractor は percent-encoded slash (%2F) を path 区切りと
    // して扱わないため、`/turns/..%2Fetc%2Fpasswd` は `/turns/{turn_id}` にマッチし
    // turn_id = "../etc/passwd" がそのままハンドラに届く。whitelist
    // `c.is_ascii_digit() || c == '-'` が '.' と '/' を弾いて 400 を返す。
    #[tokio::test]
    async fn turn_handler_rejects_path_traversal_via_percent_encoded_slash() {
        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/turns/..%2Fetc%2Fpasswd")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "パストラバーサル形式 turn_id は 400 で弾かれるべき"
        );
    }

    // ── パストラバーサル拒否 (b): 英字混入の不正文字形式 ──
    //
    // ROADMAP Phase 3 Success #2「不正文字を 400 で弾く」のリグレッション保護（ASVS V5）。
    // (a) のパストラバーサル形式とは独立した保護対象を検証する
    // （whitelist の英字弾きが消えないことを保証）。
    #[tokio::test]
    async fn turn_handler_rejects_ascii_letters_in_turn_id() {
        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/turns/abc")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "英字混入 turn_id は 400 で弾かれるべき"
        );
    }

    // ── happy path: status ファイル出現で done レスポンス ──
    //
    // HT-PROTOCOL §6: status-<id>.json の存在が完了センチネル。
    // tempdir に status + result を事前配置し、read_turn 経由で
    // {turn_id, status:"done", result:"ok"} が返ることを検証する（D-09）。
    #[tokio::test]
    async fn turn_handler_returns_done_when_status_file_exists() {
        let dir = tempdir().unwrap();
        let id = "20260525-000000-000";
        tokio::fs::write(
            dir.path().join(format!("status-{id}.json")),
            "{\"status\":\"done\"}\n",
        )
        .await
        .unwrap();
        tokio::fs::write(dir.path().join(format!("result-{id}.txt")), "ok")
            .await
            .unwrap();

        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/turns/{id}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let body_bytes = axum::body::to_bytes(resp.into_body(), 64 * 1024)
            .await
            .unwrap();
        let v: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(v.get("turn_id").and_then(Value::as_str), Some(id));
        assert_eq!(v.get("status").and_then(Value::as_str), Some("done"));
        assert_eq!(v.get("result").and_then(Value::as_str), Some("ok"));
    }

    // ── CORS: preflight (OPTIONS) で Access-Control-Allow-Origin が返ること ──
    //
    // preflight (OPTIONS) で Access-Control-Allow-Origin が返ることをリグレッション保護。
    // 既定設定（vec!["*"]）で任意のオリジンの OPTIONS リクエストが 2xx を返し、
    // access-control-allow-origin ヘッダが付くことを確認する。
    #[tokio::test]
    async fn cors_preflight_allows_any_origin_under_default_config() {
        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri("/prompt")
                    .header("Origin", "https://example.com")
                    .header("Access-Control-Request-Method", "POST")
                    .header("Access-Control-Request-Headers", "content-type")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // preflight は 2xx で応答すること
        assert!(
            resp.status().is_success(),
            "preflight は 2xx で応答すること (実際: {})",
            resp.status()
        );

        // access-control-allow-origin ヘッダが存在すること（値は "*" または "https://example.com" を許容）
        let allow_origin = resp
            .headers()
            .get("access-control-allow-origin")
            .expect("access-control-allow-origin ヘッダが存在すること");
        let allow_origin_str = allow_origin.to_str().unwrap();
        assert!(
            allow_origin_str == "*" || allow_origin_str == "https://example.com",
            "access-control-allow-origin は '*' または 'https://example.com' であること (実際: {allow_origin_str})"
        );
    }

    // ── CORS: actual request（非 preflight）でも Allow-Origin ヘッダが付くことを確認 ──
    //
    // actual request（非 preflight）でも Allow-Origin ヘッダが付くことを確認。
    // turn_id "abc" は whitelist で 400 になる既存挙動が壊れていないことも兼ねて確認する。
    #[tokio::test]
    async fn cors_actual_request_includes_allow_origin_header() {
        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/turns/abc")
                    .header("Origin", "https://example.com")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        // turn_id "abc" は英字を含むため 400 で弾かれること（既存挙動リグレッション確認）
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "英字混入 turn_id は 400 で弾かれること"
        );

        // actual request でも access-control-allow-origin ヘッダが付くこと
        let allow_origin = resp
            .headers()
            .get("access-control-allow-origin")
            .expect("actual request でも access-control-allow-origin ヘッダが存在すること");
        let allow_origin_str = allow_origin.to_str().unwrap();
        assert!(
            allow_origin_str == "*" || allow_origin_str == "https://example.com",
            "access-control-allow-origin は '*' または 'https://example.com' であること (実際: {allow_origin_str})"
        );
    }
}
