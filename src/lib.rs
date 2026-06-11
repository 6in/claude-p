//! ht-webif — curl で叩く薄い WebIF。
//!
//! [curl] --HTTP--> WebIF --MCP(stdio)--> ht-mcp --> ht --PTY--> claude
//!
//! 非同期ジョブモデル:
//!   POST /prompt        → prompt ファイルを書き、ジョブをキュー投入、turn_id を即返す
//!   GET  /turns/{id}    → ターンの状態/結果（ファイルシステムが状態ストア）
//!   バックグラウンドの worker_loop がターンを1件ずつ直列処理する。
//!   POST /prompt {"wait":true} なら完了まで待って結果を返す（同期オプション）。
//!
//! HT-PROTOCOL v1.1 のターンファイル:
//!   prompt-<turnId>.txt   指示    （WebIF が書く）
//!   result-<turnId>.txt   回答本文（claude が書く）
//!   status-<turnId>.json  状態    （claude が最後に書く = 完了シグナル）
//!
//! 回復: claude セッション死亡 → 自動再生成 / ターンのタイムアウト → 再生成+リトライ /
//!       ht-mcp 異常 → POST /restart。MCP 呼び出しは 30s でタイムアウトする。

pub mod config;
pub mod http;
pub mod mcp;
pub mod profile;
pub mod turn;
pub mod worker;
