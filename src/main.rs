use std::sync::Arc;

use anyhow::Result;
use tokio::sync::{mpsc, Mutex};

use ht_webif::config::{load_cors_origins, load_ht_mcp_path, load_port, load_turns_dir};
use ht_webif::http::{build_router, AppState};
use ht_webif::turn::{worker_loop, Job};
use ht_webif::worker::Worker;

#[tokio::main]
async fn main() -> Result<()> {
    // .env を読み込む（実環境変数が優先 → .env → 既定値 "ht-mcp" の順）
    dotenvy::dotenv().ok();
    let ht_mcp_path = load_ht_mcp_path();
    println!("ht-mcp パス: {ht_mcp_path}");

    // 1. ht-mcp 起動 + MCP ハンドシェイク + claude セッション
    let worker = Worker::new(ht_mcp_path).await?;
    println!("claude セッション: {}", worker.session_id);

    // 2. ターンディレクトリ
    let turns_dir = load_turns_dir()?;
    tokio::fs::create_dir_all(&turns_dir).await?;
    println!("ターンディレクトリ: {}", turns_dir.display());

    // 3. バックグラウンドのターン実行ループ
    let worker = Arc::new(Mutex::new(worker));
    let (job_tx, job_rx) = mpsc::channel::<Job>(64);
    tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));

    // 4. HTTP サーバ起動
    let state = Arc::new(AppState {
        worker,
        turns_dir,
        job_tx,
    });
    let cors_origins = load_cors_origins();
    println!("CORS 許可オリジン: {:?}", cors_origins);
    let app = build_router(state, cors_origins);

    let port = load_port()?;
    let addr = format!("127.0.0.1:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("WebIF 起動: http://{addr}");
    println!("  POST /prompt       {{\"prompt\":\"...\"}}             → 非同期、turn_id を即返す");
    println!(
        "  POST /prompt       {{\"prompt\":\"...\",\"wait\":true}}  → 完了まで待って結果を返す"
    );
    println!("  GET  /turns/{{id}}   → ターンの状態・結果");
    println!("  POST /command      {{\"text\":\"/clear\"}}");
    println!("  POST /restart      → ht-mcp ごと再起動");
    axum::serve(listener, app).await?;
    Ok(())
}
