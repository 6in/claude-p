//! エージェントプロファイル — agents/<name>.toml を AgentProfile に読み込む。
//!
//! 利用例: load_agent_profile("claude", &agents_dir) でプロファイルを取得し、
//! Worker::new に渡す。

use anyhow::Context;
use std::path::Path;

/// エージェントの挙動を定義する値型。agents/<name>.toml からデシリアライズされる。
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentProfile {
    /// エージェントに渡す spawn コマンド（例: ["claude"]）
    pub command: Vec<String>,
    /// TUI ready 状態の部分文字列（例: "auto mode"）
    pub ready_pattern: String,
    /// fresh_mode: "command" = clear_command 送信 / "respawn" = セッション kill+再生成
    pub fresh_mode: String,
    /// fresh_mode = "command" 時に送るクリアコマンド（例: "/clear"）
    pub clear_command: String,
    /// 出力規約テンプレート — {result_path} / {status_path} を含む必須
    pub output_covenant: String,
    /// トリガーメッセージテンプレート — {prompt_path} を含む必須
    pub trigger_template: String,
    /// セッション起動タイムアウト秒（デフォルト 25）
    #[serde(default = "default_startup_timeout")]
    pub startup_timeout_secs: u64,
    /// ready_pattern 検出後の落ち着き待機ミリ秒（デフォルト 0）。
    /// OpenCode のように ready_pattern が現れてもネットワーク認証中に
    /// 画面が一時的にブランクになるエージェントで入力取りこぼしを防ぐ。
    #[serde(default)]
    pub startup_settle_ms: u64,
    /// 1 ターンのタイムアウト秒（デフォルト 300）
    #[serde(default = "default_turn_timeout")]
    pub turn_timeout_secs: u64,
    /// モデル選択フラグ（例: "--model"）。未指定なら spawn コマンドに追加しない
    pub model_flag: Option<String>,
    /// モデル選択値（例: "opus"）。model_flag とセットで指定
    pub model_value: Option<String>,
}

fn default_startup_timeout() -> u64 {
    25
}

fn default_turn_timeout() -> u64 {
    300
}

impl AgentProfile {
    /// ht-mcp の create_session に渡す実際の spawn コマンドを組み立てる。
    ///
    /// `model_flag` と `model_value` の両方が指定されている場合のみ、
    /// フラグと値を末尾に追加する（D-13: 片方のみは無視）。
    /// 両方未指定の場合は `command` そのままを返す。
    pub fn spawn_command(&self) -> Vec<String> {
        let mut cmd = self.command.clone();
        if let (Some(flag), Some(value)) = (&self.model_flag, &self.model_value) {
            cmd.push(flag.clone());
            cmd.push(value.clone());
        }
        cmd
    }
}

/// エージェント名と探索ディレクトリからプロファイルを読み込む。
///
/// 失敗時は探索パスと利用可能プロファイル一覧を含むエラーを返す。
/// プレースホルダ欠落は即エラー（validate_profile）。
pub fn load_agent_profile(name: &str, agents_dir: &Path) -> anyhow::Result<AgentProfile> {
    let path = agents_dir.join(format!("{name}.toml"));
    let content = std::fs::read_to_string(&path).map_err(|_| {
        let available = list_available_profiles(agents_dir);
        anyhow::anyhow!(
            "agents/{name}.toml が見つかりません（探索: {}）。利用可能: {}",
            agents_dir.display(),
            if available.is_empty() {
                "なし".to_string()
            } else {
                available.join(", ")
            }
        )
    })?;
    let profile: AgentProfile =
        toml::from_str(&content).with_context(|| format!("agents/{name}.toml のパースに失敗"))?;
    validate_profile(&profile, name)?;
    Ok(profile)
}

/// プロファイルの必須プレースホルダを検証する。欠落があれば即エラー（D-11）。
fn validate_profile(p: &AgentProfile, name: &str) -> anyhow::Result<()> {
    if !p.output_covenant.contains("{result_path}") || !p.output_covenant.contains("{status_path}")
    {
        anyhow::bail!(
            "agents/{name}.toml: output_covenant に {{result_path}} と {{status_path}} が必要"
        );
    }
    if !p.trigger_template.contains("{prompt_path}") {
        anyhow::bail!("agents/{name}.toml: trigger_template に {{prompt_path}} が必要");
    }
    Ok(())
}

/// agents_dir 内の *.toml ファイルの stem 一覧を返す。失敗時は空 Vec（D-03 フォールバック）。
fn list_available_profiles(agents_dir: &Path) -> Vec<String> {
    std::fs::read_dir(agents_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter_map(|e| {
                    let p = e.path();
                    if p.extension().and_then(|s| s.to_str()) == Some("toml") {
                        p.file_stem()
                            .and_then(|s| s.to_str())
                            .map(|s| s.to_string())
                    } else {
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    /// テスト用の最小有効プロファイル TOML を生成するヘルパー。
    fn minimal_valid_toml() -> &'static str {
        r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "x {result_path} {status_path}"
trigger_template = "{prompt_path}"
"#
    }

    // (a) 正常なプロファイルのパース成功
    #[test]
    fn load_agent_profile_parses_valid_toml() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("myagent.toml"), minimal_valid_toml()).unwrap();
        let profile = load_agent_profile("myagent", dir.path()).unwrap();
        assert_eq!(profile.command, vec!["claude"]);
        assert_eq!(profile.ready_pattern, "auto mode");
        assert_eq!(profile.fresh_mode, "command");
        assert_eq!(profile.clear_command, "/clear");
    }

    // (b) 不在エージェントでエラー — エラー文字列にエージェント名・"agents/"・"claude" を含む
    #[test]
    fn load_agent_profile_errors_on_missing_toml() {
        let dir = tempdir().unwrap();
        // 利用可能な claude.toml を作成しておく（一覧に "claude" が含まれることを確認）
        std::fs::write(dir.path().join("claude.toml"), minimal_valid_toml()).unwrap();

        let err = load_agent_profile("unknown_agent", dir.path()).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("unknown_agent"),
            "エラーにエージェント名が含まれない: {msg}"
        );
        assert!(
            msg.contains("agents/"),
            "エラーに探索パス prefix が含まれない: {msg}"
        );
        assert!(
            msg.contains("claude"),
            "エラーに利用可能プロファイル一覧が含まれない: {msg}"
        );
    }

    // (c) output_covenant プレースホルダ欠落で bail
    #[test]
    fn validate_profile_rejects_missing_result_path_in_covenant() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("bad.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "only {status_path} here"
trigger_template = "{prompt_path}"
"#,
        )
        .unwrap();
        let err = load_agent_profile("bad", dir.path()).unwrap_err();
        assert!(
            err.to_string().contains("result_path"),
            "エラーに result_path が含まれない"
        );
    }

    // (c2) output_covenant の {status_path} 欠落で bail
    #[test]
    fn validate_profile_rejects_missing_status_path_in_covenant() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("bad2.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "only {result_path} here"
trigger_template = "{prompt_path}"
"#,
        )
        .unwrap();
        let err = load_agent_profile("bad2", dir.path()).unwrap_err();
        assert!(
            err.to_string().contains("status_path"),
            "エラーに status_path が含まれない"
        );
    }

    // (d) trigger_template プレースホルダ欠落で bail
    #[test]
    fn validate_profile_rejects_missing_prompt_path_in_trigger() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("bad3.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "no placeholder here"
"#,
        )
        .unwrap();
        let err = load_agent_profile("bad3", dir.path()).unwrap_err();
        assert!(
            err.to_string().contains("prompt_path"),
            "エラーに prompt_path が含まれない"
        );
    }

    // (e) 任意タイムアウトのデフォルト値（startup=25 / turn=300）
    #[test]
    fn optional_timeouts_use_defaults_when_not_specified() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("defaults.toml"), minimal_valid_toml()).unwrap();
        let profile = load_agent_profile("defaults", dir.path()).unwrap();
        assert_eq!(profile.startup_timeout_secs, 25);
        assert_eq!(profile.turn_timeout_secs, 300);
    }

    // (e2) タイムアウトを明示指定した場合は指定値が使われる
    #[test]
    fn optional_timeouts_use_specified_values() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("custom.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "{prompt_path}"
startup_timeout_secs = 60
turn_timeout_secs = 600
"#,
        )
        .unwrap();
        let profile = load_agent_profile("custom", dir.path()).unwrap();
        assert_eq!(profile.startup_timeout_secs, 60);
        assert_eq!(profile.turn_timeout_secs, 600);
    }

    // (f) deny_unknown_fields による未知キー拒否
    #[test]
    fn deny_unknown_fields_rejects_extra_keys() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("unknown.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "{prompt_path}"
unknown_field = "this should fail"
"#,
        )
        .unwrap();
        let err = load_agent_profile("unknown", dir.path()).unwrap_err();
        // パースエラーまたは deny_unknown_fields エラー
        assert!(
            !err.to_string().is_empty(),
            "未知フィールドがエラーにならない"
        );
    }

    // (g) D-13: model_flag/model_value は任意 — 未指定でも成功
    #[test]
    fn model_fields_are_optional() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("nomodel.toml"), minimal_valid_toml()).unwrap();
        let profile = load_agent_profile("nomodel", dir.path()).unwrap();
        assert!(profile.model_flag.is_none());
        assert!(profile.model_value.is_none());
    }

    // (g2) model_flag/model_value を指定した場合は Some で返る
    #[test]
    fn model_fields_parse_when_specified() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("withmodel.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "{prompt_path}"
model_flag = "--model"
model_value = "opus"
"#,
        )
        .unwrap();
        let profile = load_agent_profile("withmodel", dir.path()).unwrap();
        assert_eq!(profile.model_flag, Some("--model".to_string()));
        assert_eq!(profile.model_value, Some("opus".to_string()));
    }

    // (h) spawn_command: model_flag/model_value 未指定なら command と同一
    #[test]
    fn spawn_command_without_model_equals_command() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("nomodel.toml"), minimal_valid_toml()).unwrap();
        let profile = load_agent_profile("nomodel", dir.path()).unwrap();
        assert_eq!(profile.spawn_command(), profile.command);
    }

    // (h2) spawn_command: model_flag/model_value 両方指定なら command 末尾にフラグと値が追加される
    #[test]
    fn spawn_command_appends_flag_and_value_when_both_specified() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("withmodel.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "{prompt_path}"
model_flag = "--model"
model_value = "opus"
"#,
        )
        .unwrap();
        let profile = load_agent_profile("withmodel", dir.path()).unwrap();
        assert_eq!(
            profile.spawn_command(),
            vec!["claude", "--model", "opus"],
            "model_flag/model_value 両指定で spawn コマンドに追加されること"
        );
    }

    // (h3) spawn_command: model_flag のみ指定でも追加されない（D-13: 両方指定時のみ有効）
    #[test]
    fn spawn_command_does_not_append_when_only_flag_specified() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("flagonly.toml"),
            r#"
command = ["claude"]
ready_pattern = "auto mode"
fresh_mode = "command"
clear_command = "/clear"
output_covenant = "{result_path} {status_path}"
trigger_template = "{prompt_path}"
model_flag = "--model"
"#,
        )
        .unwrap();
        let profile = load_agent_profile("flagonly", dir.path()).unwrap();
        assert_eq!(
            profile.spawn_command(),
            vec!["claude"],
            "model_flag のみ指定では spawn コマンドに追加されないこと（D-13）"
        );
    }
}
