//! 設定定数と環境変数読み込み。

use std::time::Duration;

/// 1ターンの最大待ち時間（1試行あたり）。
pub const TURN_TIMEOUT: Duration = Duration::from_secs(300);

/// MCP 呼び出し1回のタイムアウト（ht-mcp の wedge 対策）。
pub const MCP_TIMEOUT: Duration = Duration::from_secs(30);

/// HT_MCP_PATH 環境変数を読む。存在しない場合は "ht-mcp" を既定値とする。
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}
