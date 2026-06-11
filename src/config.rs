//! 設定定数と環境変数読み込み。

use std::time::Duration;

use anyhow::Context;

/// 1ターンの最大待ち時間（1試行あたり）。
pub const TURN_TIMEOUT: Duration = Duration::from_secs(300);

/// MCP 呼び出し1回のタイムアウト（ht-mcp の wedge 対策）。
pub const MCP_TIMEOUT: Duration = Duration::from_secs(30);

/// HT_MCP_PATH 環境変数を読む。存在しない場合は "ht-mcp" を既定値とする。
pub fn load_ht_mcp_path() -> String {
    std::env::var("HT_MCP_PATH").unwrap_or_else(|_| "ht-mcp".to_string())
}

/// PORT 環境変数を読む。存在しない場合は 8080 を既定値とする。
/// 優先順位: 実環境変数 PORT > .env の値 > 既定値 8080。
/// 数値としてパースできない値が設定されている場合は anyhow エラーを返す。
pub fn load_port() -> anyhow::Result<u16> {
    match std::env::var("PORT") {
        Ok(s) => s
            .parse::<u16>()
            .with_context(|| format!("PORT のパースに失敗 (値: {s:?})")),
        Err(_) => Ok(8080),
    }
}

/// TURNS_DIR 環境変数を読む。存在しない場合は CWD/turns を既定値とする。
/// 優先順位: 実環境変数 TURNS_DIR > .env の値 > 既定値 (CWD/turns)。
/// 相対パスが指定された場合は CWD 起点で解釈される（OS の通常の挙動）。
pub fn load_turns_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("TURNS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("turns")),
    }
}

/// AGENT 環境変数を読む。未設定なら "claude"（後方互換）。
/// 優先順位: 実環境変数 AGENT > .env の値 > 既定値 "claude"。
pub fn load_agent_name() -> String {
    std::env::var("AGENT").unwrap_or_else(|_| "claude".to_string())
}

/// AGENTS_DIR 環境変数を読む。未設定なら CWD/agents を既定値とする。
/// 優先順位: 実環境変数 AGENTS_DIR > .env の値 > 既定値 (CWD/agents)。
pub fn load_agents_dir() -> anyhow::Result<std::path::PathBuf> {
    match std::env::var("AGENTS_DIR") {
        Ok(s) => Ok(std::path::PathBuf::from(s)),
        Err(_) => Ok(std::env::current_dir()
            .with_context(|| "current_dir 取得失敗")?
            .join("agents")),
    }
}

/// CORS_ORIGINS 環境変数を読む。カンマ区切りリスト、または `*` でワイルドカード。
/// 未設定なら既定値 `vec!["*"]` (フルパーミッシブ)。
/// 優先順位: 実環境変数 CORS_ORIGINS > .env の値 > 既定値。
pub fn load_cors_origins() -> Vec<String> {
    match std::env::var("CORS_ORIGINS") {
        Ok(s) => {
            let origins: Vec<String> = s
                .split(',')
                .map(|o| o.trim().to_string())
                .filter(|o| !o.is_empty())
                .collect();
            if origins.is_empty() {
                vec!["*".to_string()]
            } else {
                origins
            }
        }
        Err(_) => vec!["*".to_string()],
    }
}
