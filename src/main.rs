use std::sync::Arc;

use anyhow::Result;
use tokio::sync::{mpsc, Mutex};

use ht_webif::config::{
    load_agent_name, load_agents_dir, load_cors_origins, load_ht_mcp_path, load_port,
    load_turns_dir,
};
use ht_webif::http::{build_router, AppState};
use ht_webif::profile::load_agent_profile;
use ht_webif::turn::{worker_loop, Job};
use ht_webif::worker::Worker;

#[tokio::main]
async fn main() -> Result<()> {
    // .env を読み込む（実環境変数が優先 → .env → 既定値 "ht-mcp" の順）
    dotenvy::dotenv().ok();
    let ht_mcp_path = load_ht_mcp_path();

    // プロファイルロード（AGENT / AGENTS_DIR 環境変数を解決）
    let agent_name = load_agent_name();
    let agents_dir = load_agents_dir()?;
    let profile = load_agent_profile(&agent_name, &agents_dir)?;
    eprintln!("[profile] エージェント: {agent_name}");

    // output_covenant は Worker::new で profile が move される前に取り出す（CR-01）。
    // プロファイルは起動後イミュータブルなので AppState に直接持たせ、
    // ターン実行中でも worker Mutex をブロックせずに読めるようにする。
    let output_covenant = profile.output_covenant.clone();

    // 1. ht-mcp 起動 + MCP ハンドシェイク + claude セッション
    let worker = Worker::new(ht_mcp_path, profile).await?;

    // 2. ターンディレクトリ（D-16: 常に <TURNS_DIR>/<agent-name>/ を使う）
    let turns_base = load_turns_dir()?;
    let turns_dir = turns_base.join(&agent_name);
    tokio::fs::create_dir_all(&turns_dir).await?;
    eprintln!("[profile] ターンディレクトリ: {}", turns_dir.display());

    // 3. バックグラウンドのターン実行ループ
    let worker = Arc::new(Mutex::new(worker));
    let (job_tx, job_rx) = mpsc::channel::<Job>(64);
    tokio::spawn(worker_loop(worker.clone(), turns_dir.clone(), job_rx));

    // 4. HTTP サーバ起動
    let state = Arc::new(AppState {
        worker,
        turns_dir,
        job_tx,
        output_covenant,
    });
    let cors_origins = load_cors_origins();
    eprintln!("[profile] CORS 許可オリジン: {:?}", cors_origins);
    let app = build_router(state, cors_origins);

    let port = load_port()?;
    let addr = format!("127.0.0.1:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    eprintln!("WebIF 起動: http://{addr}");
    eprintln!("  POST /prompt       {{\"prompt\":\"...\"}}             → 非同期、turn_id を即返す");
    eprintln!(
        "  POST /prompt       {{\"prompt\":\"...\",\"wait\":true}}  → 完了まで待って結果を返す"
    );
    eprintln!("  GET  /turns/{{id}}   → ターンの状態・結果");
    eprintln!("  POST /command      {{\"text\":\"/clear\"}}");
    eprintln!("  POST /restart      → ht-mcp ごと再起動");
    axum::serve(listener, app).await?;
    Ok(())
}
