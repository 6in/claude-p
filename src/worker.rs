// ── Worker（MCP クライアント + 現在の claude セッション）──────────────────

use anyhow::{anyhow, Result};
use std::time::Duration;
use tokio::time::Instant;

use crate::mcp::{Mcp, McpClient, Restartable};

/// Worker は M: Mcp 型でジェネリック化された状態オブジェクト（D-03）。
/// デフォルト型 `M = McpClient` を持つので main.rs は `Worker::new(...)` のまま
/// `Worker<McpClient>` に推論される。
pub struct Worker<M: Mcp = McpClient> {
    client: M,
    pub session_id: String,
    ht_mcp_path: String,
}

// ── 具象 impl ブロック: McpClient::spawn を呼ぶため M = McpClient に固定 ──
impl Worker<McpClient> {
    /// ht-mcp を起動し、claude セッションを1つ立ち上げる。
    pub async fn new(ht_mcp_path: String) -> Result<Self> {
        let (client, session_id) = Self::boot(&ht_mcp_path).await?;
        Ok(Self {
            client,
            session_id,
            ht_mcp_path,
        })
    }

    /// ht-mcp 起動 → MCP ハンドシェイク → claude セッション作成。
    pub(crate) async fn boot(ht_mcp_path: &str) -> Result<(McpClient, String)> {
        let mut client = McpClient::spawn(ht_mcp_path).await?;
        client.handshake().await?;
        let session_id = Self::spawn_session(&mut client).await?;
        Ok((client, session_id))
    }

    /// claude TUI セッションを作り、ready になるまで待ってセッション ID を返す。
    /// `McpClient` 具象に紐づく（本番起動経路）。
    pub(crate) async fn spawn_session(client: &mut McpClient) -> Result<String> {
        let session_id = client.create_claude_session().await?;
        let deadline = Instant::now() + Duration::from_secs(25);
        loop {
            let snap = client.snapshot(&session_id).await?;
            if snap.contains("auto mode") {
                return Ok(session_id);
            }
            if Instant::now() > deadline {
                return Err(anyhow!("claude TUI が起動しない:\n{snap}"));
            }
            tokio::time::sleep(Duration::from_millis(700)).await;
        }
    }
}

// ── 汎用 impl ブロック: M: Mcp + Send なら何でも受ける ──
impl<M: Mcp + Send> Worker<M> {
    /// テスト時のみ使う直接コンストラクタ（D-25: #[cfg(test)] + pub(crate) の二重ガード）。
    /// FakeMcp など任意の M を受け取り、boot や spawn を経由せずに Worker<M> を組み立てる。
    /// `#[cfg(test)]` で本番ビルドからは見えず、`pub(crate)` で同一クレート内テストからのみ参照可能。
    /// 03-04 で http::tests::build_test_state から呼ばれる。
    #[cfg(test)]
    pub(crate) fn from_parts(client: M, session_id: String, ht_mcp_path: String) -> Self {
        Self {
            client,
            session_id,
            ht_mcp_path,
        }
    }

    /// 現在のセッションに1行打ち込む。
    pub async fn submit_line(&mut self, text: &str) -> Result<()> {
        let sid = self.session_id.clone();
        self.client.submit_line(&sid, text).await
    }

    /// 現在のセッションのスナップショットを取る。
    pub async fn snapshot(&mut self) -> Result<String> {
        let sid = self.session_id.clone();
        self.client.snapshot(&sid).await
    }

    /// セッションが生きているか確認し、死んでいれば再生成する（shared-fate 対策）。
    pub async fn ensure_healthy(&mut self) -> Result<()> {
        let healthy = matches!(
            self.snapshot().await,
            Ok(snap) if snap.contains("auto mode")
        );
        if !healthy {
            eprintln!("[shared-fate] claude セッション不健全 → 再生成");
            self.recreate().await?;
        }
        Ok(())
    }

    /// claude セッションを作り直す。旧セッションは後始末する（失敗は無視）。
    /// 既存挙動を保つため `create_claude_session` の後で `snapshot` を polling し
    /// "auto mode" を含むまで待つ（Phase 2 の behavior preservation 制約）。
    /// trait Mcp のメソッドのみで実装できるので汎用 impl に置ける。
    pub(crate) async fn recreate(&mut self) -> Result<()> {
        let old = self.session_id.clone();
        let new_id = self.client.create_claude_session().await?;
        // ready 待ち（spawn_session と同じロジック）。
        let deadline = Instant::now() + Duration::from_secs(25);
        loop {
            let snap = self.client.snapshot(&new_id).await?;
            if snap.contains("auto mode") {
                break;
            }
            if Instant::now() > deadline {
                return Err(anyhow!("claude TUI が起動しない:\n{snap}"));
            }
            tokio::time::sleep(Duration::from_millis(700)).await;
        }
        let _ = self.client.close_session(&old).await;
        self.session_id = new_id;
        eprintln!(
            "[shared-fate] claude セッション再生成: {} （旧 {} を閉鎖）",
            self.session_id, old
        );
        Ok(())
    }
}

// ── restart は Restartable 制約付きの追加 impl ──
//
// 設計メモ（プラン task 3a からの逸脱、Rule 3 自動修正）:
// 元の計画では restart は `impl Worker<McpClient>` 専用ブロックに置く想定だったが、
// `build_router<M>` が登録する `restart_handler<M>` を任意の M で型付けするために、
// `restart` 自体も「Restartable 制約付きジェネリック」として汎用 impl に格上げした。
// 本番（M = McpClient）では Restartable::respawn が ht-mcp 子プロセス再生成 + handshake
// を行うため挙動は完全に保たれる（旧来の Worker::restart と同じ）。テスト側 FakeMcp は
// respawn を no-op として実装するだけで build_router::<FakeMcp> がコンパイルできる。
impl<M: Mcp + Restartable + Send> Worker<M> {
    /// ht-mcp（MCPサーバ）ごと作り直す。旧 ht-mcp は kill_on_drop で停止する
    /// （Restartable::respawn の中で *self = new で旧 client が drop される）。
    pub async fn restart(&mut self) -> Result<()> {
        self.client.respawn(&self.ht_mcp_path).await?;
        let new_id = self.client.create_claude_session().await?;
        // ready 待ち（spawn_session と同じロジック）。
        let deadline = Instant::now() + Duration::from_secs(25);
        loop {
            let snap = self.client.snapshot(&new_id).await?;
            if snap.contains("auto mode") {
                break;
            }
            if Instant::now() > deadline {
                return Err(anyhow!("claude TUI が起動しない:\n{snap}"));
            }
            tokio::time::sleep(Duration::from_millis(700)).await;
        }
        self.session_id = new_id;
        eprintln!(
            "[restart] ht-mcp 再起動完了。新セッション: {}",
            self.session_id
        );
        Ok(())
    }
}
