//! 設定定数と環境変数読み込み。

use std::time::Duration;

use anyhow::Context;

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

#[cfg(test)]
mod tests {
    use super::*;

    // GAP-1 (PROF-02): load_agent_name はAGENT未設定時に "claude" を返す。
    // 並列テスト安全のため：unset → assert default、set → assert value、restore を1テストにまとめる。
    #[test]
    fn agent_name_defaults_to_claude_when_env_unset_and_returns_env_value_when_set() {
        // env が汚染されていないことを前提に「未設定」ケースをテスト
        // （CI でも AGENT が設定されている場合に備え save/restore する）
        let saved = std::env::var("AGENT").ok();

        // 未設定パス
        std::env::remove_var("AGENT");
        let default_val = load_agent_name();
        assert_eq!(
            default_val, "claude",
            "AGENT 未設定時の既定値は 'claude' であるべき（実際: {default_val:?}）"
        );

        // 設定パス
        std::env::set_var("AGENT", "my-custom-agent");
        let custom_val = load_agent_name();
        assert_eq!(
            custom_val, "my-custom-agent",
            "AGENT=my-custom-agent を設定したときにその値が返るべき（実際: {custom_val:?}）"
        );

        // 復元
        match saved {
            Some(v) => std::env::set_var("AGENT", v),
            None => std::env::remove_var("AGENT"),
        }
    }

    // GAP-1 (PROF-02): load_agents_dir はAGENTS_DIR未設定時にCWD/agentsを返す。
    // AGENTS_DIR 設定時はその値を PathBuf で返す。
    #[test]
    fn agents_dir_defaults_to_cwd_agents_when_unset_and_uses_env_when_set() {
        let saved = std::env::var("AGENTS_DIR").ok();

        // 未設定パス: CWD/agents を返すことを確認
        std::env::remove_var("AGENTS_DIR");
        let default_dir = load_agents_dir().expect("AGENTS_DIR 未設定でエラー");
        let expected = std::env::current_dir().unwrap().join("agents");
        assert_eq!(
            default_dir, expected,
            "AGENTS_DIR 未設定時は CWD/agents であるべき（実際: {default_dir:?}）"
        );

        // 設定パス: 指定値を PathBuf として返すことを確認
        std::env::set_var("AGENTS_DIR", "/custom/agents/path");
        let custom_dir = load_agents_dir().expect("AGENTS_DIR 設定時にエラー");
        assert_eq!(
            custom_dir,
            std::path::PathBuf::from("/custom/agents/path"),
            "AGENTS_DIR=/custom/agents/path のとき PathBuf('/custom/agents/path') を返すべき（実際: {custom_dir:?}）"
        );

        // 復元
        match saved {
            Some(v) => std::env::set_var("AGENTS_DIR", v),
            None => std::env::remove_var("AGENTS_DIR"),
        }
    }
}
