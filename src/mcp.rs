// ── MCP クライアント（newline 区切り JSON-RPC を直接話す最小実装）─────────

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, BufReader, Lines};
use tokio::process::{Child, Command};

use async_trait::async_trait;

use crate::config::MCP_TIMEOUT;

/// trait Mcp は ht-mcp ツールラッパ層の API 粒度（D-02）。
/// `request` / `call_tool` / `notify` / `write_message` / `read_response` は
/// `McpClient` の内部詳細として trait の外に残す（D-02）。
///
/// `Send` 境界は `Worker<M>` を `Arc<Mutex<...>>` に入れるため必須（D-03）。
#[async_trait]
pub trait Mcp: Send {
    async fn handshake(&mut self) -> Result<()>;
    async fn create_claude_session(&mut self) -> Result<String>;
    async fn close_session(&mut self, session_id: &str) -> Result<()>;
    async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()>;
    async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()>;
    async fn snapshot(&mut self, session_id: &str) -> Result<String>;
}

/// trait Restartable は MCP transport（ht-mcp 子プロセス）を「丸ごと作り直す」操作。
/// `Mcp` を super-trait に持つので Restartable は必ず Mcp。
///
/// 設計理由: `Worker::restart` は McpClient 専用の重い再生成（ht-mcp 子プロセスごと
/// kill→spawn→handshake）を必要とするが、ジェネリック化された `Worker<M>` 上で
/// `restart_handler` を成立させるには「restart 能力」を別 trait として括り出す必要がある。
/// FakeMcp 等のテストダブルでは no-op を実装すれば build_router::<FakeMcp> がコンパイルできる。
#[async_trait]
pub trait Restartable: Mcp {
    /// 内部のトランスポートを作り直す（McpClient なら ht-mcp 再起動 + handshake、
    /// テストダブルなら no-op）。成功時は self が「新品」に置き換わっている保証。
    async fn respawn(&mut self, ht_mcp_path: &str) -> Result<()>;
}

pub struct McpClient {
    // 本番は Some(child)、テスト時は None。Drop 時に Some の場合のみ kill される（kill_on_drop）。
    // フィールド自体は明示的に read されないが、所有保持のため必要（Drop で kill が動く）。
    #[allow(dead_code)]
    child: Option<Child>,
    // 本番は ChildStdin を Box 化、テスト時は tokio::io::duplex の片側を渡す（D-05）。
    stdin: Box<dyn AsyncWrite + Send + Unpin>,
    // 同上、本番は ChildStdout、テスト時は duplex の片側。
    lines: Lines<BufReader<Box<dyn AsyncRead + Send + Unpin>>>,
    next_id: i64,
}

impl McpClient {
    /// ht-mcp を子プロセスとして起動する。
    pub async fn spawn(program: &str) -> Result<Self> {
        let mut child = Command::new(program)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit()) // ht-mcp のログは端末にそのまま流す
            .kill_on_drop(true) // WebIF 終了・再起動時に ht-mcp も道連れにする
            .spawn()
            .with_context(|| format!("ht-mcp の起動に失敗: {program}"))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("stdin が取れない"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("stdout が取れない"))?;
        Ok(Self {
            child: Some(child),
            stdin: Box::new(stdin),
            lines: BufReader::new(Box::new(stdout) as Box<dyn AsyncRead + Send + Unpin>).lines(),
            next_id: 0,
        })
    }

    /// テスト時のみ使う直接コンストラクタ。
    /// tokio::io::duplex の片側ペアを渡して in-memory な MCP クライアントを作る。
    /// child は None（本番の kill_on_drop は不要）、next_id は 0 で初期化
    /// （03-03 の next_id テストが Some(1) を期待するため）。
    #[cfg(test)]
    pub fn from_streams<W, R>(stdin: W, stdout: R) -> Self
    where
        W: AsyncWrite + Send + Unpin + 'static,
        R: AsyncRead + Send + Unpin + 'static,
    {
        Self {
            child: None,
            stdin: Box::new(stdin),
            lines: BufReader::new(Box::new(stdout) as Box<dyn AsyncRead + Send + Unpin>).lines(),
            next_id: 0,
        }
    }

    async fn write_message(&mut self, msg: &Value) -> Result<()> {
        use tokio::io::AsyncWriteExt;
        let mut line = serde_json::to_string(msg)?;
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    /// 指定 id の応答が返るまで stdout を読む（通知などはスキップ）。
    async fn read_response(&mut self, id: i64) -> Result<Value> {
        loop {
            let line = self
                .lines
                .next_line()
                .await?
                .ok_or_else(|| anyhow!("ht-mcp が stdout を閉じた"))?;
            if line.trim().is_empty() {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v.get("id").and_then(Value::as_i64) != Some(id) {
                continue;
            }
            if let Some(err) = v.get("error") {
                return Err(anyhow!("MCP error: {err}"));
            }
            return Ok(v.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    /// リクエストを送り、MCP_TIMEOUT 以内に応答を受け取る。
    pub async fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        self.write_message(&json!({
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        }))
        .await?;
        match tokio::time::timeout(MCP_TIMEOUT, self.read_response(id)).await {
            Ok(r) => r,
            Err(_) => Err(anyhow!(
                "ht-mcp 応答タイムアウト ({}s)",
                MCP_TIMEOUT.as_secs()
            )),
        }
    }

    pub async fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        self.write_message(&json!({
            "jsonrpc": "2.0", "method": method, "params": params
        }))
        .await
    }

    /// tools/call を呼び、結果の content[0].text を返す。
    pub async fn call_tool(&mut self, name: &str, arguments: Value) -> Result<String> {
        let result = self
            .request(
                "tools/call",
                json!({ "name": name, "arguments": arguments }),
            )
            .await?;
        Ok(result
            .get("content")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .and_then(|i| i.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string())
    }
}

#[async_trait]
impl Mcp for McpClient {
    async fn handshake(&mut self) -> Result<()> {
        self.request(
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "ht-webif", "version": "0.1.0" }
            }),
        )
        .await?;
        self.notify("notifications/initialized", json!({})).await?;
        Ok(())
    }

    /// claude TUI を走らせる HT セッションを作り、セッション ID を返す。
    async fn create_claude_session(&mut self) -> Result<String> {
        let text = self
            .call_tool("ht_create_session", json!({ "command": ["claude"] }))
            .await?;
        let after = text
            .split("Session ID:")
            .nth(1)
            .ok_or_else(|| anyhow!("セッション ID が取れない:\n{text}"))?;
        Ok(after
            .split_whitespace()
            .next()
            .ok_or_else(|| anyhow!("セッション ID が空"))?
            .to_string())
    }

    async fn close_session(&mut self, session_id: &str) -> Result<()> {
        self.call_tool("ht_close_session", json!({ "sessionId": session_id }))
            .await?;
        Ok(())
    }

    async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()> {
        self.call_tool(
            "ht_send_keys",
            json!({ "sessionId": session_id, "keys": keys }),
        )
        .await?;
        Ok(())
    }

    /// claude TUI に1行打ち込んで Enter する。
    /// 長文を [text, Enter] で1回送りすると Enter が落ちるため、分割して送る。
    async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()> {
        self.send_keys(session_id, &[text.to_string()]).await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        self.send_keys(session_id, &["Enter".to_string()]).await?;
        Ok(())
    }

    async fn snapshot(&mut self, session_id: &str) -> Result<String> {
        self.call_tool("ht_take_snapshot", json!({ "sessionId": session_id }))
            .await
    }
}

#[async_trait]
impl Restartable for McpClient {
    /// ht-mcp を kill→spawn し直し、handshake までやり直す。
    /// 新セッションの create は呼び出し側（Worker::restart）が行う。
    async fn respawn(&mut self, ht_mcp_path: &str) -> Result<()> {
        let mut new = McpClient::spawn(ht_mcp_path).await?;
        new.handshake().await?;
        // 旧 self は drop され、kill_on_drop により旧 ht-mcp プロセスも kill される
        *self = new;
        Ok(())
    }
}

// ── テスト ───────────────────────────────────────────────────────────────
#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::VecDeque;
    use tokio::io::{duplex, AsyncBufReadExt, AsyncWriteExt, BufReader};

    /// scripted reply 方式のテストダブル（D-07）。
    /// 各 trait メソッドは scripted reply キュー（VecDeque）または呼び出しログ（Vec）を持つ。
    ///
    /// `pub(crate)` で同一クレート内に公開し、Wave 3 (Plan 03-04) の `http.rs` テストから
    /// `use crate::mcp::tests::FakeMcp;` で参照できるようにする。
    /// 本プラン (03-03) ではまだ自モジュール内で使わないため dead_code 警告を抑制する。
    #[allow(dead_code)]
    pub(crate) struct FakeMcp {
        // handshake の呼び出し回数を記録（assertion 用）。
        pub handshake_calls: u32,
        // create_claude_session の応答キュー。空ならエラーを返す。
        pub create_session_replies: VecDeque<Result<String>>,
        // close_session に渡された session_id のログ。
        pub close_session_log: Vec<String>,
        // send_keys に渡された (session_id, keys) のログ。
        pub send_keys_log: Vec<(String, Vec<String>)>,
        // submit_line に渡された (session_id, text) のログ。
        pub submit_line_log: Vec<(String, String)>,
        // snapshot の応答キュー。空ならエラーを返す。
        pub snapshot_replies: VecDeque<Result<String>>,
    }

    impl FakeMcp {
        /// 全フィールドを空 / デフォルトで初期化する。
        #[allow(dead_code)]
        pub(crate) fn new() -> Self {
            Self {
                handshake_calls: 0,
                create_session_replies: VecDeque::new(),
                close_session_log: Vec::new(),
                send_keys_log: Vec::new(),
                submit_line_log: Vec::new(),
                snapshot_replies: VecDeque::new(),
            }
        }
    }

    #[async_trait]
    impl Mcp for FakeMcp {
        // handshake は副作用なし、回数だけ記録する。
        async fn handshake(&mut self) -> Result<()> {
            self.handshake_calls += 1;
            Ok(())
        }

        // scripted reply キューから先頭を pop。空ならエラー。
        async fn create_claude_session(&mut self) -> Result<String> {
            self.create_session_replies
                .pop_front()
                .unwrap_or_else(|| Err(anyhow!("create_claude_session scripted reply 切れ")))
        }

        // session_id を log に積むだけの no-op。
        async fn close_session(&mut self, session_id: &str) -> Result<()> {
            self.close_session_log.push(session_id.to_string());
            Ok(())
        }

        // (session_id, keys) を log に積むだけの no-op。
        async fn send_keys(&mut self, session_id: &str, keys: &[String]) -> Result<()> {
            self.send_keys_log
                .push((session_id.to_string(), keys.to_vec()));
            Ok(())
        }

        // (session_id, text) を log に積むだけの no-op。
        async fn submit_line(&mut self, session_id: &str, text: &str) -> Result<()> {
            self.submit_line_log
                .push((session_id.to_string(), text.to_string()));
            Ok(())
        }

        // scripted reply キューから先頭を pop。空ならエラー。session_id は使わない。
        async fn snapshot(&mut self, session_id: &str) -> Result<String> {
            let _ = session_id;
            self.snapshot_replies
                .pop_front()
                .unwrap_or_else(|| Err(anyhow!("snapshot scripted reply 切れ")))
        }
    }

    // FakeMcp は Wave 3 (Plan 03-04) で `build_router::<FakeMcp>` から
    // restart_handler 経由で呼ばれるため、no-op の Restartable 実装が必須。
    // ht-mcp の物理的な再起動は行わず、handshake_calls だけインクリメントする。
    #[async_trait]
    impl Restartable for FakeMcp {
        async fn respawn(&mut self, ht_mcp_path: &str) -> Result<()> {
            let _ = ht_mcp_path;
            self.handshake_calls += 1;
            Ok(())
        }
    }

    // ── McpClient::request の hermetic 単体テスト（D-05: duplex 経由）────────
    //
    // tokio::io::duplex(1024) で in-memory な (writer, reader) ペアを 2 組作り、
    // McpClient::from_streams 経由で 実プロセスを起動しない McpClient を構築する。
    // テスト harness 側は「client が stdin に書いた JSON 行」を読み、また「擬似 ht-mcp
    // 応答 JSON 行」を client の stdout に書き戻すことで request() の完全な往復をシミュレートする。

    /// duplex 2 組で McpClient と test harness 側 (writer/reader) を組み立てるヘルパ。
    /// 戻り値: (client, harness_reader_for_client_writes, harness_writer_for_client_reads)
    fn make_client_and_harness() -> (
        McpClient,
        BufReader<tokio::io::DuplexStream>,
        tokio::io::DuplexStream,
    ) {
        // client が書く → test が読む
        let (client_stdin, test_reads) = duplex(1024);
        // test が書く → client が読む
        let (test_writes, client_stdout) = duplex(1024);
        let client = McpClient::from_streams(client_stdin, client_stdout);
        (client, BufReader::new(test_reads), test_writes)
    }

    /// JSON-RPC envelope に jsonrpc / id / method / params が揃うことを検証する。
    #[tokio::test]
    async fn request_builds_jsonrpc_envelope_with_method_and_params() {
        let (mut client, mut harness_reader, mut harness_writer) = make_client_and_harness();

        // client の request を背景タスクで起動。応答待ちでブロックするので
        // harness 側で読み→書きを終えてから join する。
        let client_task = tokio::spawn(async move {
            client
                .request("tools/call", json!({ "name": "ht_take_snapshot" }))
                .await
        });

        // client が書いた最初の行を読み取り、JSON としてパースする。
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(5), harness_reader.read_line(&mut line))
            .await
            .expect("read_line タイムアウト")
            .expect("read_line エラー");

        let parsed: Value = serde_json::from_str(line.trim()).expect("JSON パース失敗");
        assert_eq!(
            parsed.get("jsonrpc").and_then(Value::as_str),
            Some("2.0"),
            "jsonrpc フィールドが '2.0' でない"
        );
        assert!(
            parsed.get("id").and_then(Value::as_i64).is_some(),
            "id フィールドが数値でない"
        );
        assert_eq!(
            parsed.get("method").and_then(Value::as_str),
            Some("tools/call"),
            "method フィールドが 'tools/call' でない"
        );
        assert!(
            parsed.get("params").is_some(),
            "params フィールドが存在しない"
        );
        assert_eq!(
            parsed["params"]["name"].as_str(),
            Some("ht_take_snapshot"),
            "params.name が 'ht_take_snapshot' でない"
        );

        // client タスクが応答待ちで止まらないよう擬似応答を書き戻す。
        let id = parsed["id"].as_i64().unwrap();
        let response = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"content\":[{{\"text\":\"snap-data\"}}]}}}}\n"
        );
        harness_writer.write_all(response.as_bytes()).await.unwrap();
        harness_writer.flush().await.unwrap();

        let result = tokio::time::timeout(Duration::from_secs(5), client_task)
            .await
            .expect("client task タイムアウト")
            .expect("client task join 失敗")
            .expect("request エラー");
        // result は応答 JSON の "result" フィールド clone（read_response 経由）。
        assert!(result.get("content").is_some());
    }

    /// next_id が呼出ごとに +1 されること（from_streams は next_id: 0 初期化、最初の request 後に id=1）。
    #[tokio::test]
    async fn next_id_increments_per_request() {
        let (mut client, mut harness_reader, mut harness_writer) = make_client_and_harness();

        // 1 回目と 2 回目の request を順番に走らせるため、各 round で
        // harness 側の read_line → write_response → join をシリアル化する。
        // ここでは client を Arc<Mutex<...>> にせず、各 round で
        // tokio::spawn して同じ client を await する形にする。
        //
        // 代わりに 1 タスクで 2 回 request する設計にする。harness が応答を 2 回書く。
        let client_task = tokio::spawn(async move {
            let r1 = client.request("dummy_method_1", json!({})).await;
            let r2 = client.request("dummy_method_2", json!({})).await;
            (r1, r2)
        });

        // 1 回目: client の書き込みを読む → id を抽出 → 応答を書く
        let mut line1 = String::new();
        tokio::time::timeout(Duration::from_secs(5), harness_reader.read_line(&mut line1))
            .await
            .expect("read_line 1 タイムアウト")
            .unwrap();
        let parsed1: Value = serde_json::from_str(line1.trim()).unwrap();
        let id1 = parsed1["id"].as_i64().unwrap();
        assert_eq!(
            id1, 1,
            "from_streams 初期 next_id: 0 → 最初の request で id=1 を期待"
        );
        let resp1 = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id1},\"result\":{{}}}}\n");
        harness_writer.write_all(resp1.as_bytes()).await.unwrap();
        harness_writer.flush().await.unwrap();

        // 2 回目: 同様に読んで id=2 を確認する
        let mut line2 = String::new();
        tokio::time::timeout(Duration::from_secs(5), harness_reader.read_line(&mut line2))
            .await
            .expect("read_line 2 タイムアウト")
            .unwrap();
        let parsed2: Value = serde_json::from_str(line2.trim()).unwrap();
        let id2 = parsed2["id"].as_i64().unwrap();
        assert_eq!(id2, 2, "2 回目の request で id=2 を期待");
        assert_eq!(id2, id1 + 1, "next_id は呼出ごとに +1 される");
        let resp2 = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id2},\"result\":{{}}}}\n");
        harness_writer.write_all(resp2.as_bytes()).await.unwrap();
        harness_writer.flush().await.unwrap();

        let (r1, r2) = tokio::time::timeout(Duration::from_secs(5), client_task)
            .await
            .expect("client task タイムアウト")
            .unwrap();
        r1.expect("request 1 エラー");
        r2.expect("request 2 エラー");
    }

    /// request の戻り値が応答 JSON の "result" フィールドの clone であることを検証する。
    #[tokio::test]
    async fn request_extracts_result_from_response() {
        let (mut client, mut harness_reader, mut harness_writer) = make_client_and_harness();

        let client_task = tokio::spawn(async move { client.request("dummy", json!({})).await });

        // client が書いた行を捨て読みして id を取り出す。
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(5), harness_reader.read_line(&mut line))
            .await
            .expect("read_line タイムアウト")
            .unwrap();
        let parsed: Value = serde_json::from_str(line.trim()).unwrap();
        let id = parsed["id"].as_i64().unwrap();

        // result フィールドに {"foo":"bar"} を入れた応答を書き戻す。
        let resp = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"foo\":\"bar\"}}}}\n");
        harness_writer.write_all(resp.as_bytes()).await.unwrap();
        harness_writer.flush().await.unwrap();

        let v = tokio::time::timeout(Duration::from_secs(5), client_task)
            .await
            .expect("client task タイムアウト")
            .unwrap()
            .expect("request エラー");
        assert_eq!(
            v.get("foo").and_then(Value::as_str),
            Some("bar"),
            "request の戻り値が応答 result フィールドの clone でない"
        );
    }
}
