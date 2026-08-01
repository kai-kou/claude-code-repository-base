# セキュリティ統制・補償統制まとめ（bypassPermissions 維持前提）

> このドキュメントは `.claude/settings.json` の権限設定、とりわけ **`bypassPermissions: true`** を **維持する前提** で、それを安全にしている **補償統制（compensating controls）** を1箇所に集約し、監査追跡性を高めることを目的とする。
>
> **ユーザー方針（2026-06-06）**: `bypassPermissions: true` は維持する（常に自動承認したいというユーザー明示指示）。本プロジェクトの自律運用（CP-6・Human-on-the-loop）と一体の設計判断であり、安易に無効化しない。

---

## 0. 設定の現状（SSOT: `.claude/settings.json`）

| 設定 | 値 | 意味 |
|------|----|------|
| `permissions.bypassPermissions` | `true` | 全ツールの許可プロンプトをバイパスし自律実行する |
| `sandbox.autoAllowBashIfSandboxed` | `true` | サンドボックス内 Bash を自動許可 |
| `sandbox.excludedCommands` | 接続先ドメインが動的なスクリプト限定（narrow exclusion・2026-08-01 見直し・#379） | secrets-broker 移行ツール等だけがサンドボックス外（ネットワーク制限なし）で実行。他の tools/ スクリプトは `sandbox.network.allowedDomains` の範囲内で実行される |
| `env.DISABLE_NON_ESSENTIAL_MODEL_CALLS` | `1` | 非必須モデル呼び出しを抑制 |

`bypassPermissions: true` は確認プロンプトを出さないため、**補償統制が実効的なガードレール** となる。

---

## 1. 補償統制（bypass を安全にしている多層防御）

### 1.1 deny リスト（機密の読取・特定書込を物理ブロック）

`.claude/settings.json` の `permissions.deny`:

- `Read(.env)` / `Read(.env.*)`
- `Read(**/*.pem)` / `Read(**/*.key)` / `Read(**/*.p12)`
- `Read(**/credentials*)` / `Read(**/id_rsa)` / `Read(**/id_ed25519)`
- `Read(**/.aws/**)` / `Read(**/*service-account*.json)`
- `Write(.claude/settings.local.json)` / `Edit(.claude/settings.local.json)`

→ bypass であっても **秘密情報の読取と権限設定ファイルの改変は拒否** される。

### 1.2 sandbox network allowlist（外部通信先をドメイン限定）

`sandbox.network.allowedDomains` で github / googleapis / slack / r2 / context7 等の **業務上必要なドメインのみ** を許可。未許可ドメインへの送信は遮断され、データ持ち出し面のリスクを抑える。

### 1.3 フックによる多層ガード（`.claude/hooks/`）

| フック | イベント | 役割 |
|--------|---------|------|
| `pre-tool-use-router.sh` | PreToolUse(Bash) | Bash 実行の事前検査 |
| `pre-git-push-check.sh` | （router 経由） | **main 直接 push 防止**・push 安全確認 |
| `pre-pr-create-check.sh` | （router 経由） | PR 作成前チェック |
| `pre-comment-post-check.sh` | （router 経由） | 外部コメント投稿前チェック |
| `pre-image-gen-check.sh` | PreToolUse(画像生成) | 画像生成前の予算・前提チェック |
| `post-tool-use-validate.sh` | PostToolUse | 台本 JSON 等の物理バリデーション（Lv3） |
| `post-tool-use-failure.sh` | PostToolUseFailure(Bash) | 失敗ハンドリング |
| `stop-*.sh` / `post-compact.sh` / `session-start.sh` | Stop / PostCompact / SessionStart | 未コミット保護・衛生・ルール同期 |

→ 破壊的・外向きの操作は **フックが最終防衛線** として検査する。

### 1.4 ブランチ保護とPRフロー

- `main` への直接 push は禁止（A-1・既約境界外）。全変更は作業ブランチ → PR → AIレビュー → 自動マージ。
- リモート側 branch protection と合わせて二重化（L-065 参照）。

### 1.5 MCP の最小権限

`.mcp.json` のトークンは **環境変数展開**（`${GEMINI_MCP_AUTH_TOKEN}` 等）でハードコードなし。本番 DB 系 MCP は不採用。

---

## 2. 残留リスクと運用上の注意

| 残留リスク | 補償 | 注意 |
|-----------|------|------|
| `python3 tools/*.py` がサンドボックス外でネットワーク実行される | network allowlist は sandbox 側のみ。ツールは自前で送信先を実装 | ツール追加時は送信先・秘密情報の扱いをレビューする |
| bypass のため誤操作も即実行される | deny / hook / PRフローで吸収 | 破壊的操作は必ずフック対象に含める |
| deny リストの抜け | 定期的な監査 | 新しい秘密ファイル種別が増えたら deny に追加 |

---

## 3. 変更時のルール

- **`bypassPermissions` の値を変更しない**（ユーザー方針）。変更が必要になった場合は A-6 相当としてユーザー確認する。
- deny リスト・network allowlist・フックは **補償統制の中核** のため、削る場合は本ドキュメントを更新し理由を明記する。
- 設定値の正本（SSOT）はあくまで `.claude/settings.json`。本ドキュメントはその統制内容を **解説・追跡する補助ドキュメント** であり、設定値そのものの SSOT ではない。セキュリティ統制に関わる設定変更時は、settings.json を正とし、本ドキュメントの記述を同期更新する。

---

## 4. 参照

| ドキュメント | 関係 |
|------------|------|
| `docs/rules/user-confirmation-minimization.md` | 既約境界外（A-1 main push / A-6 課金・OAuth） |
| `docs/rules/session-safety-rules.md` | 未コミット保護・セッション安全 |
| `docs/rules/lessons-core.md` L-065 | main 直接 push 防止の教訓 |
| `.claude/settings.json` | 権限・sandbox・hooks の実体（SSOT） |
