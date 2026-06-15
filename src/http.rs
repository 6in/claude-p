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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};
use tower_http::cors::{Any, CorsLayer};

use crate::mcp::{Mcp, McpClient, Restartable};
use crate::turn::{build_prompt_body, read_turn, Job};
use crate::worker::Worker;

/// turnId 採番の内部状態（単一直列化点で保護される）。
struct TurnIdAllocatorState {
    /// 直前に発番したベースタイムスタンプ文字列（YYYYMMDD-HHMMSS-mmm 形式）。
    last_base: String,
    /// 同一 base に対して払い出した連番カウンタ。新 base が来たときリセットされる。
    seq: u32,
}

/// HT-PROTOCOL §3.2 準拠の turnId アロケータ。
///
/// ## 設計根拠
///
/// base（YYYYMMDD-HHMMSS-mmm）と seq は結合した不変条件を持つ:
/// 新 base 検出時は seq をリセット、同一 base では seq を単調増加させる。
/// この2フィールド結合不変条件は AtomicU64 単体では CAS なしに表現できないため、
/// 極短時間だけ保持する `tokio::sync::Mutex` を採番の単一直列化点とする。
///
/// `std::sync::Mutex` ではなく `tokio::sync::Mutex` を選ぶのは、本クレートの
/// async/lock 慣習（CLAUDE.md）に従い、将来 `.await` を跨ぐ可能性に備えるため。
/// ただし本実装ではロックはメモリ内文字列整形のみで保持し、
/// ファイル I/O や他の `.await` を跨いで保持しない。
///
/// worker Mutex とは完全に別ロックであり、CR-01 の worker-Mutex 競合を再導入しない。
pub struct TurnIdAllocator {
    state: Mutex<TurnIdAllocatorState>,
}

impl Default for TurnIdAllocator {
    fn default() -> Self {
        Self::new()
    }
}

impl TurnIdAllocator {
    /// 初期状態（last_base 空文字、seq 0）でアロケータを構築する。
    pub fn new() -> Self {
        Self {
            state: Mutex::new(TurnIdAllocatorState {
                last_base: String::new(),
                seq: 0,
            }),
        }
    }

    /// テスト専用: last_base / seq を任意値に先取り（seed）してアロケータを構築する。
    /// CR-01 のクランプ（後退時刻）や WR-02 の同一 base 衝突を決定論的に再現するために使う。
    #[cfg(test)]
    pub fn with_seed(last_base: &str, seq: u32) -> Self {
        Self {
            state: Mutex::new(TurnIdAllocatorState {
                last_base: last_base.to_string(),
                seq,
            }),
        }
    }

    /// HT-PROTOCOL §3.2: 一意な turnId を発番して返す。
    ///
    /// 不変条件は「発番ベースは単調非減少」である。`YYYYMMDD-HHMMSS-mmm` は固定幅
    /// なので辞書順比較が時系列順と一致する。これを利用して:
    ///
    /// - 新しく整形した base が前回より厳密に大きい場合（時計が前進）: それを採用し
    ///   seq をリセットして base をそのまま返す（既存形式と後方互換。サフィックス無し）。
    /// - それ以外（同一ミリ秒、または壁時計が後退した場合 — NTP 補正・VM 再開・うるう秒
    ///   平滑化等）: last_base に張り付けて（後退した壁時計値へ戻さない）seq を進め、
    ///   `{last_base}-{seq:03}` を返す。これにより `Utc::now()` が単調でなくても
    ///   turnId は単調かつ一意になり、過去の turnId 再発番（ファイル上書き・データ損失）を防ぐ。
    ///
    /// サフィックスはハイフンと最小 3 桁ゼロ埋め数値のみで構成される（衝突が 999 を
    /// 超えた場合は 4 桁以上に伸長するが、いずれも英字を含まず http.rs の `^[0-9-]+$`
    /// ホワイトリストを満たす）。
    ///
    /// ロックはこの整形処理の間だけ保持し、ファイル I/O や他の `.await` を跨がない。
    pub async fn next_turn_id(&self) -> String {
        let base = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f").to_string();
        let mut s = self.state.lock().await;
        // 単調非減少クランプ: 固定幅形式ゆえ辞書順 = 時系列順。
        if base > s.last_base {
            // 時計が前進: 新 base を採用し seq リセット、サフィックス無しで後方互換
            s.last_base = base.clone();
            s.seq = 0;
            base
        } else {
            // 同一 ms または時計が後退（NTP 補正等）: 直前 base を維持し連番を進める。
            // 壁時計が後退しても last_base を維持し seq を進めることで過去の turnId
            // 再発番を防ぐ（単調非減少クランプ）。
            // WR-01: u32 オーバーフローを checked_add で検知する。同一 base に u32::MAX
            // 件連番が張り付くのは天文学的に非現実的だが、release で無音ラップ・debug で
            // panic するのを避け、溢れた場合は明示的に panic させて異常を可視化する。
            s.seq = s.seq.checked_add(1).expect(
                "turnId seq が u32 を溢れた（同一 base への連番が異常: 壁時計が長時間停滞）",
            );
            format!("{}-{:03}", s.last_base, s.seq)
        }
    }
}

/// 起動以降イミュータブルなインスタンス識別情報 + lock-free メトリクス。
/// worker Mutex を一切取得せず /info ハンドラが直接読む（D-02/D-05）。
pub struct InstanceInfo {
    pub agent_name: String,
    pub port: u16,
    pub started_at: Instant,
    pub is_busy: AtomicBool, // D-02: worker_loop がデキュー中のターンでトグル（実行中フラグ）
    /// WR-03: キュー投入〜完了までの在庫数。prompt_handler が send 成功で +1、
    /// worker_loop が process_job 後に -1 する。/info の status はこの値で判定するため、
    /// 「キュー済みだが未デキュー」の間も busy を返せる（ロードバランサが空きと誤認しない）。
    pub in_flight: AtomicU64,
    pub turns_processed: AtomicU64, // D-04: ターン完了ごとにインクリメント
}

pub struct AppState<M: Mcp + Send + 'static = McpClient> {
    pub worker: Arc<Mutex<Worker<M>>>,
    pub turns_dir: PathBuf,
    pub job_tx: mpsc::Sender<Job>,
    /// プロファイルは起動後イミュータブルなので Mutex 越しに取得不要。
    /// ターン実行中（worker Mutex 保持中）でも output_covenant を即読めるようにする（CR-01）。
    pub output_covenant: String,
    /// インスタンス情報は起動後イミュータブル（agent_name/port/started_at）または
    /// lock-free atomic（is_busy/turns_processed）なので Mutex 不要（D-02/D-05 CR-01 パターン）。
    pub instance_info: Arc<InstanceInfo>,
    /// turnId 採番の単一直列化点。worker Mutex とは別ロックで、
    /// prompt_handler が並行着信しても同一 turnId を採番しない（HT-PROTOCOL §3.2）。
    pub turn_id_alloc: Arc<TurnIdAllocator>,
}

pub(crate) fn ise<E: std::fmt::Display>(e: E) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}

/// GET /info — 稼働中エージェントの識別情報とメトリクスを返す。
/// worker Mutex を一切取得しない（D-02）。ターン実行中でも即応答する。
async fn info_handler<M: Mcp + Send + 'static>(
    State(state): State<Arc<AppState<M>>>,
) -> Json<Value> {
    let info = &state.instance_info;
    // WR-03: status はキュー在庫（in_flight）で判定する。デキュー前のジョブも busy 扱いに
    // することで、ロードバランサが「キュー済みだが未実行」のインスタンスを空きと誤認しない。
    let status = if info.in_flight.load(Ordering::Relaxed) > 0 {
        "busy"
    } else {
        "idle"
    };
    Json(json!({
        "agent": info.agent_name,
        "port": info.port,
        "status": status,
        "uptime_secs": info.started_at.elapsed().as_secs(),
        "turns_processed": info.turns_processed.load(Ordering::Relaxed),
    }))
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
    // turnId 発番（HT-PROTOCOL §3.2: ミリ秒精度 + 衝突時 -<seq> 連番、AppState 所有アロケータで原子化）
    let turn_id = state.turn_id_alloc.next_turn_id().await;
    let prompt_path = state.turns_dir.join(format!("prompt-{turn_id}.txt"));
    let result_path = state.turns_dir.join(format!("result-{turn_id}.txt"));
    let status_path = state.turns_dir.join(format!("status-{turn_id}.json"));

    // prompt ファイルを先に書く（GET が即「running」を返せるように）
    // output_covenant は AppState から直接取得（ロックフリー）。
    // プロファイルは起動後イミュータブルなので worker Mutex を取る必要はなく、
    // ターン実行中（最大 600s）でも POST /prompt が即応できる（CR-01 解消）。
    let body = build_prompt_body(
        &req.prompt,
        &result_path,
        &status_path,
        &state.output_covenant,
    );
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

    // WR-03: send 成功後に in_flight を +1。worker_loop が完了時に -1 する。
    // これでデキュー前から /info が busy を返せる。
    state
        .instance_info
        .in_flight
        .fetch_add(1, Ordering::Relaxed);

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
        .route("/info", get(info_handler::<M>))
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
        // output_covenant は Worker::new で profile が move される前に取り出す（CR-01 同様）。
        let output_covenant = profile.output_covenant.clone();
        // FakeMcp は scripted reply 不要（本テストでは turn_handler 経路のみ叩く）。
        let worker = Worker::<FakeMcp>::from_parts(
            FakeMcp::new(),
            "test-session".to_string(),
            "/dev/null".to_string(),
            profile,
        );
        let worker = Arc::new(Mutex::new(worker));
        let instance_info = Arc::new(InstanceInfo {
            agent_name: "claude".to_string(),
            port: 8080,
            started_at: Instant::now(),
            is_busy: AtomicBool::new(false),
            in_flight: AtomicU64::new(0),
            turns_processed: AtomicU64::new(0),
        });
        let state = Arc::new(AppState {
            worker,
            turns_dir,
            job_tx,
            output_covenant,
            instance_info,
            turn_id_alloc: Arc::new(TurnIdAllocator::new()),
        });
        (state, job_rx)
    }

    // ── GET /info: 5フィールド + 初期値確認 ──
    //
    // D-03: GET /info は agent・port・status・uptime_secs・turns_processed の5フィールドを返す。
    // 初期状態では status="idle"、turns_processed=0。
    // info_handler は worker Mutex を取得しない（lock-free）。
    #[tokio::test]
    async fn info_handler_returns_five_fields_with_initial_values() {
        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());
        let app = build_router(state, vec!["*".to_string()]);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/info")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK, "GET /info は 200 を返すべき");

        let body_bytes = axum::body::to_bytes(resp.into_body(), 4096).await.unwrap();
        let v: Value = serde_json::from_slice(&body_bytes).unwrap();

        assert_eq!(
            v.get("agent").and_then(Value::as_str),
            Some("claude"),
            "agent フィールドが 'claude' であること"
        );
        assert_eq!(
            v.get("port").and_then(Value::as_u64),
            Some(8080),
            "port フィールドが 8080 であること"
        );
        assert_eq!(
            v.get("status").and_then(Value::as_str),
            Some("idle"),
            "初期状態では status が 'idle' であること"
        );
        assert!(
            v.get("uptime_secs").and_then(Value::as_u64).is_some(),
            "uptime_secs フィールドが存在すること"
        );
        assert_eq!(
            v.get("turns_processed").and_then(Value::as_u64),
            Some(0),
            "初期状態では turns_processed が 0 であること"
        );
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

    // ── GAP-2 (PROF-03): POST /prompt は worker Mutex 保持中でもブロックしない（CR-01） ──
    //
    // prompt_handler は state.output_covenant を直読みし worker Mutex を一切取得しない。
    // このテストでは worker Mutex を取得したままロックを保持し続けた状態で
    // POST /prompt を送り、2秒以内に 200 + turn_id が返ることを検証する。
    // prompt_handler が Mutex をロックしようとすれば tokio::time::timeout が切れて失敗する。
    #[tokio::test]
    async fn prompt_handler_returns_turn_id_immediately_while_worker_mutex_is_held() {
        use std::time::Duration;

        let dir = tempdir().unwrap();
        let (state, _job_rx) = build_test_state(dir.path().to_path_buf());

        // worker Mutex を取得して保持し続ける（worker_loop が動いていないため誰も解放しない）
        let _guard = state.worker.lock().await;

        let app = build_router(Arc::clone(&state), vec!["*".to_string()]);

        let resp = tokio::time::timeout(
            Duration::from_secs(2),
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/prompt")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"prompt":"テストプロンプト"}"#))
                    .unwrap(),
            ),
        )
        .await
        .expect(
            "POST /prompt が 2 秒以内に応答しなかった（worker Mutex ロック中にブロックした可能性）",
        )
        .unwrap();

        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "POST /prompt は worker Mutex 保持中でも 200 を返すべき"
        );

        let body_bytes = axum::body::to_bytes(resp.into_body(), 4096).await.unwrap();
        let v: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert!(
            v.get("turn_id").and_then(Value::as_str).is_some(),
            "レスポンスに turn_id が含まれるべき（実際: {v}）"
        );
        assert_eq!(
            v.get("status").and_then(Value::as_str),
            Some("accepted"),
            "status は 'accepted' であるべき（実際: {v}）"
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

    // ── 並行採番一意性リグレッション(Test 1): N=1000 件の並行 next_turn_id() が全件一意 ──
    //
    // HT-PROTOCOL §3.2: 同一ミリ秒に N 並行 POST /prompt しても turnId が全件一意。
    // 1000 タスクを tokio::spawn で並行起動し、全件収集して HashSet で重複を検査する。
    // これは同一プロセス内の同一ミリ秒並行採番衝突を直接再現・防止する回帰テスト。
    // WR-03: multi_thread ランタイムで真の並列競合（Mutex 競合）を再現する。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn turn_id_allocator_concurrent_uniqueness_n1000() {
        use std::collections::HashSet;

        let alloc = Arc::new(TurnIdAllocator::new());
        let n: usize = 1000;

        // N 個のタスクを並行起動し、それぞれ turn_id を採番する
        let handles: Vec<_> = (0..n)
            .map(|_| {
                let alloc = Arc::clone(&alloc);
                tokio::spawn(async move { alloc.next_turn_id().await })
            })
            .collect();

        // 全タスクの結果を収集する
        let mut ids = Vec::with_capacity(n);
        for h in handles {
            ids.push(h.await.expect("タスクが正常終了すること"));
        }

        // 全件一意性を検証する（HT-PROTOCOL §3.2）
        let unique: HashSet<_> = ids.iter().collect();
        assert_eq!(
            unique.len(),
            n,
            "同一ミリ秒並行採番でも turnId は全件一意であること（HT-PROTOCOL §3.2）: 重複 {} 件",
            n - unique.len()
        );
    }

    // ── 採番形式適合(Test 2): 全採番結果が ^[0-9-]+$ ホワイトリストを満たす ──
    //
    // http.rs:152 の `c.is_ascii_digit() || c == '-'` ホワイトリストへの適合を検証する。
    // サフィックス付き（...-080-001）も無し（...-080）も両方このルールを満たすこと。
    // 英字（e.g. -w02）を含む形式は whitelist で弾かれるため使用禁止であることの保証。
    // WR-03: multi_thread ランタイムで真の並列競合を再現する。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn turn_id_allocator_all_ids_pass_whitelist() {
        use std::collections::HashSet;

        let alloc = Arc::new(TurnIdAllocator::new());
        let n: usize = 1000;

        let handles: Vec<_> = (0..n)
            .map(|_| {
                let alloc = Arc::clone(&alloc);
                tokio::spawn(async move { alloc.next_turn_id().await })
            })
            .collect();

        let mut ids = Vec::with_capacity(n);
        for h in handles {
            ids.push(h.await.expect("タスクが正常終了すること"));
        }

        // 重複排除して形式確認（形式検査は一意なIDのみ確認すればよい）
        let unique: HashSet<_> = ids.into_iter().collect();
        for id in &unique {
            assert!(
                !id.is_empty() && id.chars().all(|c| c.is_ascii_digit() || c == '-'),
                "turnId '{id}' がホワイトリスト ^[0-9-]+$ を満たさない（英字を含む形式は不可）"
            );
        }
    }

    // ── 連番サフィックス形式(Test 3): 同一 base の 2 件目以降が <base>-NNN 形式 ──
    //
    // WR-02: 以前は N=1000 並行結果からサフィックス付きエントリを抽出していたが、全件が
    // 別ミリ秒に着地すると suffixed が空になり何も検証しない（タイミング依存の no-op）に
    // なりうる。ここでは with_seed で last_base を未来の固定タイムスタンプに先取りし、
    // 後続の next_turn_id() が必ずクランプ経路（同一/後退 base）に入って連番サフィックスを
    // 付けることを決定論的に保証する。
    #[tokio::test]
    async fn turn_id_allocator_suffix_segment_is_three_digit_numeric() {
        use std::collections::HashSet;

        // 未来のタイムスタンプを先取りすることで、現在時刻からの base は必ず last_base 以下に
        // なり、すべての発番がクランプ経路（サフィックス付き）を通る。
        let seed = "29991231-235959-999";
        let alloc = Arc::new(TurnIdAllocator::with_seed(seed, 0));
        let n: usize = 1000;

        let handles: Vec<_> = (0..n)
            .map(|_| {
                let alloc = Arc::clone(&alloc);
                tokio::spawn(async move { alloc.next_turn_id().await })
            })
            .collect();

        let mut ids = Vec::with_capacity(n);
        for h in handles {
            ids.push(h.await.expect("タスクが正常終了すること"));
        }

        let unique: HashSet<_> = ids.into_iter().collect();

        // 全件一意であること（クランプ経路でも seq により一意）。
        assert_eq!(
            unique.len(),
            n,
            "クランプ経路でも turnId は全件一意であること: 重複 {} 件",
            n - unique.len()
        );

        // サフィックス付きエントリ（セグメント数 4 = YYYYMMDD-HHMMSS-mmm-NNN）を抽出して検証。
        // 先取りにより全件がサフィックス付きになるはずなので、空でないことを保証する（WR-02）。
        let suffixed: Vec<_> = unique
            .iter()
            .filter(|id| id.split('-').count() == 4)
            .collect();
        assert!(
            !suffixed.is_empty(),
            "先取りシードにより少なくとも 1 件はサフィックス付きであるべき（WR-02: no-op 防止）"
        );

        for id in &suffixed {
            let segments: Vec<&str> = id.split('-').collect();
            let suffix = segments[3];
            // IN-01: サフィックスは最小 3 桁ゼロ埋め。衝突が 999 を超えると 4 桁以上に
            // 伸長する（N=1000 の先取りシードでは seq が 1000 まで進むため 4 桁が出る）。
            // いずれも数字のみでホワイトリスト適合であることを確認する。
            assert!(
                suffix.len() >= 3 && suffix.chars().all(|c| c.is_ascii_digit()),
                "turnId '{id}' のサフィックスセグメント '{suffix}' が最小 3 桁の数字形式でない（-NNN 形式であること）"
            );
        }
    }

    // ── CR-01 回帰: 壁時計後退時に過去 turnId を再発番しない ──
    //
    // last_base を未来の固定タイムスタンプに先取りした状態で next_turn_id() を複数回呼ぶ。
    // 現在の壁時計はシード値より過去なので、クランプが効いていなければ「bare base 再発番」
    // が起き last_base より辞書順で小さい ID が返る。クランプが効いていれば全 ID は
    // last_base に張り付いた連番（last_base より厳密に大きい）になり、かつ全件一意になる。
    #[tokio::test]
    async fn turn_id_allocator_clamps_on_backward_clock_no_bare_reemit() {
        use std::collections::HashSet;

        let seed = "29991231-235959-999";
        let alloc = TurnIdAllocator::with_seed(seed, 0);

        let mut ids = Vec::new();
        for _ in 0..50 {
            ids.push(alloc.next_turn_id().await);
        }

        // 全件一意であること（bare base 再発番が起きれば重複しうる）。
        let unique: HashSet<_> = ids.iter().cloned().collect();
        assert_eq!(
            unique.len(),
            ids.len(),
            "クランプ経路でも全件一意であること"
        );

        for id in &ids {
            // bare base 再発番が起きていないこと: すべて last_base にサフィックスが付き、
            // 辞書順で seed より厳密に大きい（= 過去値へ後退していない）。
            assert!(
                id.as_str() > seed,
                "turnId '{id}' が seed '{seed}' 以下（壁時計後退で過去 base を再発番した疑い）"
            );
            assert_eq!(
                id.split('-').count(),
                4,
                "クランプ経路の turnId '{id}' はサフィックス付き（4 セグメント）であるべき"
            );
            assert!(
                id.chars().all(|c| c.is_ascii_digit() || c == '-'),
                "turnId '{id}' がホワイトリスト ^[0-9-]+$ を満たさない"
            );
        }
    }
}
