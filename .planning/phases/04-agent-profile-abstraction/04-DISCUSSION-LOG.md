# Phase 4: Agent Profile Abstraction - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-11
**Phase:** 4-agent-profile-abstraction
**Areas discussed:** プロファイル探索・解決, TOML スキーマ設計, output_covenant テンプレート, 上書きフィールドの形 (PROF-05)

---

## プロファイル探索・解決

| Option | Description | Selected |
| --- | --- | --- |
| CWD 相対 + env 上書き | `./agents/` 既定、AGENTS_DIR で上書き。.env/TURNS_DIR と同じ慣行 | ✓ |
| CWD 相対のみ | 固定パス。systemd 等で WorkingDirectory 必須化 | |
| バイナリ相対 | デプロイ向きだが cargo run と release でパスが変わる | |

**User's choice:** CWD 相対 + env 上書き

| Option | Description | Selected |
| --- | --- | --- |
| 即エラー終了 | TOML が唯一の真実源、二重管理ドリフトなし | ✓ |
| 組み込みデフォルトへフォールバック | include_str! 埋め込み。ゼロ設定起動が維持されるが編集が効かない事故の余地 | |

**User's choice:** claude.toml 欠落時も即エラー終了

| Option | Description | Selected |
| --- | --- | --- |
| 探索パス + 利用可能一覧 | agents/ スキャンで候補列挙、typo 即判明 | ✓ |
| 探索パスのみ | 実装最小 | |

**User's choice:** 探索パス + 利用可能一覧

| Option | Description | Selected |
| --- | --- | --- |
| テスト内で動的生成 | tempdir に test.toml を書いて hermetic 検証、リポはクリーン | ✓ |
| リポにコミット | AGENT=test で即動作確認できるがダミー混在 | |
| 両方 | | |

**User's choice:** テスト内で動的生成

---

## TOML スキーマ設計

| Option | Description | Selected |
| --- | --- | --- |
| 部分文字列一致 | 現行 contains() と同一、新規依存ゼロ | ✓ |
| 最初から regex | ANSI 分断に備えるが依存 +1、純粋リファクタから逸脱 | |
| 複数パターンの OR | 配列 contains。現時点で必要な証拠なし | |

**User's choice:** ready_pattern は部分文字列一致

| Option | Description | Selected |
| --- | --- | --- |
| 挙動必須・数値任意 | 挙動定義は必須、タイムアウトは任意 + 現行デフォルト（PROF-05 通り） | ✓ |
| 最小必須（command のみ） | Claude 固有値が Rust に残り Success Criteria 2 に反する | |
| 全フィールド必須 | PROF-05 の「未指定時は現行デフォルト」と矛盾 | |

**User's choice:** 挙動必須・数値任意

| Option | Description | Selected |
| --- | --- | --- |
| 拒否する | deny_unknown_fields で typo を起動時検出 | ✓ |
| 無視する | 前方互換に寛容だが typo 事故リスク | |

**User's choice:** 未知キーは拒否

| Option | Description | Selected |
| --- | --- | --- |
| 実装するものだけ | Phase 4 で配線するフィールドのみ。後から任意フィールド追加は後方互換 | ✓ |
| 研究のフルスキーマを今定義 | wedge_pattern 等を未配線で定義。デッド設定のリスク | |

**User's choice:** 実装するものだけ

---

## output_covenant テンプレート

| Option | Description | Selected |
| --- | --- | --- |
| {result_path} / {status_path} | 現行 format! と同じ見た目、str::replace 実装 | ✓ |
| ${result_path} | シェル風。現行表記から変わる | |
| 位置引数なし・末尾自動付与 | パス提示の文言調整余地を殺す | |

**User's choice:** {placeholder} 記法

| Option | Description | Selected |
| --- | --- | --- |
| フィールド化する | trigger_template を必須フィールドに。エージェント可視文字列を TOML に集約 | ✓ |
| ハードコードのまま | 研究特定の 4 箇所に留める。PROF-06 理念と歯逆さ | |

**User's choice:** トリガーメッセージもフィールド化（第 5 の抽出 site）

| Option | Description | Selected |
| --- | --- | --- |
| 必須プレースホルダを検証 | 欠落 = 起動時 anyhow エラー。タイムアウト顕在化を防ぐ | ✓ |
| 検証しない | 実装は減るが原因特定が遅い事故を許容 | |

**User's choice:** 起動時検証する

| Option | Description | Selected |
| --- | --- | --- |
| ゴールデンテストで固定 | v1.0 format! 出力とのバイト一致を assert | ✓ |
| セクション含有チェックのみ | 微妙な差異を検出できない | |

**User's choice:** ゴールデンテストで固定

---

## 上書きフィールドの形 (PROF-05)

| Option | Description | Selected |
| --- | --- | --- |
| model_flag + model_value フィールド | PROF-05 の「flag/value」文面に忠実、未指定なら付加なし | ✓ |
| command 配列に直接書く | 実装最小だが要件の再解釈になる | |

**User's choice:** model_flag + model_value フィールド

| Option | Description | Selected |
| --- | --- | --- |
| グローバル定数のまま | MCP_TIMEOUT はトランスポート層の関心事 | ✓ |
| プロファイル化する | 必要になったら Phase 5 で後付け可 | |

**User's choice:** MCP_TIMEOUT はグローバルのまま

| Option | Description | Selected |
| --- | --- | --- |
| 設けない — 役割分離 | env = インフラ、TOML = エージェント挙動の 2 層固定 | ✓ |
| タイムアウトのみ env 上書き可 | 3 層化。設定の出所が増える | |

**User's choice:** env 上書きは設けない

| Option | Description | Selected |
| --- | --- | --- |
| 明示指定はそのまま使う（推奨案） | 明示は運用者の意思を尊重、未設定時のみ ./turns/<agent>/ | |
| 常に agent サブディレクトリを付与 | コリジョンを構造的に排除。v1.0 の明示指定運用と非互換 | ✓ |

**User's choice:** 常に agent サブディレクトリを付与（推奨案を退けて選択 — コリジョン安全性を一貫保証。README に挙動変更明記が条件）

---

## Claude's Discretion

- AgentProfile 構造体の内部構成・doc コメント
- ゴールデンテストの配置先モジュール
- エラーメッセージの具体的文言（日本語、anyhow コンテキスト）
- fresh_mode = "respawn" の実装詳細と FakeMcp でのテスト方法
- 利用可能プロファイル一覧スキャンの実装

## Deferred Ideas

- wedge_pattern / prerequisite_check フィールド → Phase 5
- ready_pattern の regex 化 + ANSI ストリップ → Phase 5（実測後）
- mcp_timeout_secs のプロファイル化 → Phase 5（実測後）
- タイムアウトの env 上書き 3 層化 → 必要時に後付け
- GET /info → Phase 6（ROADMAP 確定済み）
- result ファイル存在チェック → Phase 5 の covenant 検証と合わせて
- プロファイル hot-reload → FUT-02（将来マイルストーン）
